import Foundation
import Darwin

/// App 内置的只读 ERP 服务：只监听 127.0.0.1，WKWebView 直接访问本机，
/// 由 App 自己直连厂商云。不需要局域网里的电脑，也不需要填服务器地址。
/// 与 Windows EXE / Android APK 内是同一套规则、同一份 index.html。
/// 账号密码只存在于内存与「本机 -> sjmsai.vip」请求中，不落盘、不写日志。
final class ErpServer {

    static let company = "江西鼎城铝模科技有限公司"
    private static let base = "http://sjmsai.vip"
    private static let gridURL = base + "/Admin/ashx/GridHandler.ashx"
    private static let loginURL = base + "/admin/ashx/ControlHandle.ashx"
    private static let basePort: UInt16 = 8788
    private static let pageSize = 500
    private static let maxRows = 50000
    private static let cacheSeconds: TimeInterval = 600
    private static let queryCacheSeconds: TimeInterval = 60

    private static let typeOptions = ["标准库", "型材库", "配件库", "拉片库", "待维修库", "半成品库", "成品库", "待拼库", "待清理库", "废料", "拼装", "铝支撑", "铝背楞", "钢背楞", "新型背楞", "爬架", "支撑架", "来料加工", "生产清单", "打包清单", "材料库房"]
    private static let typeOptionsWithData = ["标准库", "型材库", "半成品库", "成品库", "待清理库", "废料", "支撑架", "材料库房"]
    private static let keywordFields = ["mingcheng", "daima", "erp_pinhao", "beizhu", "cangku", "leixing", "laiyuan_telephone", "crkxmmc"]

    private static let rukuColumns: [[Any]] = [
        ["rukushijian", "入库时间", 150], ["leixing", "类型", 140], ["mingcheng", "名称", 130],
        ["daima", "编码", 130], ["spec", "规格", 110], ["cangku", "仓库", 100],
        ["shuliang", "数量", 90], ["shiji_zhongliang", "实际重量", 90],
        ["crkxmmc", "项目", 130],
        ["laiyuan_telephone", "来源", 140], ["beizhu", "备注", 180]
    ]
    private static let chukuColumns: [[Any]] = [
        ["chukushijian", "出库时间", 150], ["leixing", "类型", 140], ["mingcheng", "名称", 130],
        ["daima", "编码", 130], ["spec", "规格", 110], ["cangku", "仓库", 100],
        ["shuliang", "数量", 90], ["shiji_zhongliang", "实际重量", 90],
        ["crkxmmc", "项目", 130],
        ["laiyuan_telephone", "来源", 140], ["beizhu", "备注", 180]
    ]
    private static let stockColumns: [[Any]] = [
        ["daima", "编码", 8], ["mingcheng", "名称", 19], ["spec", "规格(宽×长)", 17],
        ["leixing", "类型", 28], ["cangku", "仓库", 13], ["stockQty", "库存数量", 15]
    ]

    private struct Session {
        let cookie: String, user: String, message: String, permissions: String
    }
    private struct CacheItem {
        let time: TimeInterval, sid: String, json: String
    }
    private struct Request {
        var method = "GET", path = "/", query = "", cookie = "", body = "", contentType = ""
        var params: [String: String] = [:]
    }
    /// 并发抓取分页时用的线程安全容器：避免闭包捕获并改写局部 var
    /// （Xcode 16 / Swift 6 模式下会直接编译报错）。
    private final class Box {
        private let lock = NSLock()
        private var values: [Int: [[String: Any]]] = [:]
        func set(_ key: Int, _ value: [[String: Any]]) {
            lock.lock(); values[key] = value; lock.unlock()
        }
        func get(_ key: Int) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return values[key] ?? []
        }
    }

    private struct Reply {
        var code = 200
        var type = "application/json; charset=utf-8"
        var body = Data()
        var setCookie: String? = nil
        var cacheable = false
        var extraHeaders = ""
        static func json(_ object: Any, code: Int = 200, setCookie: String? = nil) -> Reply {
            var r = Reply()
            r.code = code
            r.setCookie = setCookie
            if let d = try? JSONSerialization.data(withJSONObject: object, options: []) { r.body = d }
            return r
        }
        static func text(_ s: String) -> Reply { return Reply.json(["error": s], code: 500) }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var cache: [String: CacheItem] = [:]
    private var listenFD: Int32 = -1
    private var running = false
    private(set) var port: Int = 0

    // ---------------- 本地数据仓库（与 Windows EXE / 安卓 同一套规则） ----------------
    // 全量同步入库/出库历史到本机，查询/搜索/翻页/库存全部本地毫秒级计算。
    // 登录后后台对比厂商云：每表 1 次请求对总数+首页指纹 → 无差异秒结束；有差异增量拉取；异常全量兜底。
    // 每 1 分钟静默复查、每 6 小时自动升级为全量校验。数据是用户自有业务数据；删除数据文件即回到纯云端模式。
    private static let syncSeconds: TimeInterval = 60
    private static let fullCheckSeconds: TimeInterval = 6 * 60 * 60
    private static let syncPageLimit = 600
    private enum SyncError: Error { case upstream }

    private let storeLock = NSLock()
    private var storeRuku: [[String: Any]] = []
    private var storeChuku: [[String: Any]] = []
    private var dataReadyFlag = false
    private var storeSyncingFlag = false
    private var syncedAt: TimeInterval = 0
    private var lastNew = 0
    private var lastFullCheck: TimeInterval = 0
    private let syncQueue = DispatchQueue(label: "erp.sync")
    private var syncTimer: DispatchSourceTimer?
    private let dataFile: URL?

    private var storeReady: Bool { storeLock.lock(); defer { storeLock.unlock() }; return dataReadyFlag }
    private var isStoreSyncing: Bool { storeLock.lock(); defer { storeLock.unlock() }; return storeSyncingFlag }
    private var currentSyncedAt: TimeInterval { storeLock.lock(); defer { storeLock.unlock() }; return syncedAt }
    private var currentLastNew: Int { storeLock.lock(); defer { storeLock.unlock() }; return lastNew }

    /// dataDir 缺省用 App Documents；传 nil 则纯内存（不持久化）
    init(dataDir: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) {
        self.dataFile = dataDir?.appendingPathComponent("erp-data.json.gz")
        loadStore()
    }

    // MARK: - 启动 / 停止

    func start(completion: @escaping (Int) -> Void, failure: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var fd: Int32 = -1
            var chosen = 0
            for p in 0..<20 {
                let candidate = Int(ErpServer.basePort) + p
                let s = socket(AF_INET, SOCK_STREAM, 0)
                if s < 0 { continue }
                var reuse: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(candidate).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let ok = withUnsafePointer(to: &addr) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                        bind(s, p, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if ok == 0 && listen(s, 64) == 0 {
                    fd = s
                    chosen = candidate
                    break
                }
                close(s)
            }
            if fd < 0 {
                DispatchQueue.main.async { failure("本机 8788~8807 端口都被占用") }
                return
            }
            self.listenFD = fd
            self.port = chosen
            self.running = true
            self.startSyncTimer()
            DispatchQueue.main.async { completion(chosen) }
            while self.running {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
            }
            close(fd)
        }
    }

    func stop() {
        running = false
        syncTimer?.cancel()
        syncTimer = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        lock.lock()
        sessions.removeAll()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - HTTP 层

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd = -1
        var expected = 0
        var chunked = false
        for _ in 0..<200 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if let end = ErpServer.headerBoundary(in: data) {
                headerEnd = end
                let head = String(data: data.subdata(in: 0..<end), encoding: .utf8) ?? ""
                for (k, v) in ErpServer.headerFields(head) {
                    if k == "content-length" { expected = Int(v) ?? 0 }
                    else if k == "transfer-encoding" && v.lowercased().contains("chunked") { chunked = true }
                }
                break
            }
        }
        guard headerEnd >= 0 else { return }
        // WKWebView 有时会把 header 与 body 分两次送达，甚至不带 Content-Length。
        // 统一把 header 之后的全部字节都当作请求体，避免 POST body 被截成空串。
        while data.count - headerEnd < expected && expected < 65536 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let headText = String(data: data.subdata(in: 0..<headerEnd), encoding: .utf8) ?? ""
        var bodyData = data.subdata(in: headerEnd..<data.count)
        if expected > 0 && bodyData.count > expected { bodyData = bodyData.subdata(in: 0..<expected) }
        let bodyText = chunked ? ErpServer.dechunk(bodyData)
                               : (String(data: bodyData, encoding: .utf8) ?? "")
        let reply = route(parse(headText, body: bodyText))
        let reason = reply.code == 200 ? "OK" : reply.code == 401 ? "Unauthorized"
            : reply.code == 400 ? "Bad Request" : reply.code == 404 ? "Not Found"
            : reply.code == 405 ? "Method Not Allowed" : reply.code == 415 ? "Unsupported Media Type" : "Error"
        var header = "HTTP/1.1 \(reply.code) \(reason)\r\n"
        header += "Content-Type: \(reply.type)\r\n"
        header += "Content-Length: \(reply.body.count)\r\n"
        header += "Cache-Control: \(reply.cacheable ? "public, max-age=86400" : "no-store")\r\n"
        if let c = reply.setCookie { header += "Set-Cookie: \(c)\r\n" }
        header += reply.extraHeaders
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(reply.body)
        out.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = send(fd, ptr.advanced(by: sent), out.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// 定位请求头结束位置，兼容 CRLFCRLF 与 LFLF 两种分隔。
    private static func headerBoundary(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        if bytes.count < 2 { return nil }
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 10 && bytes[i + 1] == 10 { return i + 2 }
            if i + 3 < bytes.count && bytes[i] == 13 && bytes[i + 1] == 10
                && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i + 4 }
            i += 1
        }
        return nil
    }

    /// 逐行解析请求头，字段名统一小写；兼容 CRLF、LF 与冒号后多余空格。
    private static func headerFields(_ head: String) -> [(String, String)] {
        let normalized = head.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        var out: [(String, String)] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count < 2 { continue }
            let k = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let v = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { out.append((k, v)) }
        }
        return out
    }

    /// 极简 chunked 解码，只用于本机 WKWebView 上传的小请求体。
    private static func dechunk(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var i = 0
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 10 && bytes[j] != 13 { j += 1 }
            let sizeLine = String(bytes: bytes[i..<j], encoding: .utf8) ?? ""
            guard let first = sizeLine.split(separator: ";").first,
                  let n = Int(first.trimmingCharacters(in: .whitespaces), radix: 16), n > 0 else { break }
            while j < bytes.count && (bytes[j] == 10 || bytes[j] == 13) { j += 1 }
            let end = min(bytes.count, j + n)
            if end <= j { break }
            result.append(contentsOf: bytes[j..<end])
            i = end
            while i < bytes.count && (bytes[i] == 10 || bytes[i] == 13) { i += 1 }
        }
        return String(bytes: result, encoding: .utf8) ?? ""
    }

    private func parse(_ head: String, body: String) -> Request {
        var req = Request()
        req.body = body
        let lines = head.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count >= 2 {
                req.method = String(parts[0]).uppercased()
                let full = String(parts[1])
                if let q = full.firstIndex(of: "?") {
                    req.path = String(full[full.startIndex..<q])
                    req.query = String(full[full.index(after: q)...])
                } else { req.path = full }
            }
        }
        for (k, v) in ErpServer.headerFields(head) {
            if k == "cookie" { req.cookie = v }
            else if k == "content-type" { req.contentType = v }
        }
        for pair in req.query.split(separator: "&") {
            guard let i = pair.firstIndex(of: "=") else { continue }
            let k = String(pair[pair.startIndex..<i]).removingPercentEncoding ?? String(pair[pair.startIndex..<i])
            let v = String(pair[pair.index(after: i)...]).removingPercentEncoding ?? String(pair[pair.index(after: i)...])
            req.params[k] = v.replacingOccurrences(of: "+", with: " ")
        }
        return req
    }

    // MARK: - 路由

    private func route(_ req: Request) -> Reply {
        // 万一 WKWebView 把带 application/json 的 POST 当成非简单请求发了预检，
        // 直接放行，避免登录请求根本到不了服务端。
        if req.method == "OPTIONS" {
            var r = Reply()
            r.extraHeaders = "Access-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Headers: *\r\n"
                + "Access-Control-Allow-Methods: GET,POST,OPTIONS\r\n"
                + "Access-Control-Max-Age: 86400\r\n"
            return r
        }
        let p = req.path
        if p == "/" || p == "/index.html" || p == "/m.html" || p == "/m" { return htmlPage() }
        if p == "/manifest.webmanifest" {
            var r = Reply()
            r.type = "application/manifest+json; charset=utf-8"
            r.body = Data("{\"name\":\"鼎城 ERP 库存查询\",\"short_name\":\"鼎城 ERP\",\"start_url\":\"/m.html\",\"display\":\"standalone\",\"background_color\":\"#ffffff\",\"theme_color\":\"#0B8A3D\"}".utf8)
            return r
        }
        if p == "/api/meta" { return meta(req) }
        if p == "/api/login" { return login(req) }
        if p == "/api/logout" { return logout(req) }
        if p == "/api/query" { return query(req) }
        if p == "/api/stock" { return stock(req) }
        if p == "/api/jinxiao" { return jinxiao(req) }
        return Reply.json(["error": "not found"], code: 404)
    }

    private func htmlPage() -> Reply {
        var r = Reply()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let d = try? Data(contentsOf: url) {
            r.body = d
            r.type = "text/html; charset=utf-8"
        } else {
            r.code = 500
            r.body = Data("无法读取内置网页 index.html".utf8)
            r.type = "text/plain; charset=utf-8"
        }
        return r
    }

    private func readSid(_ req: Request) -> String {
        for part in req.cookie.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "erp_sid" {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func meta(_ req: Request) -> Reply {
        let sid = readSid(req)
        lock.lock()
        let s = sid.isEmpty ? nil : sessions[sid]
        lock.unlock()
        let ruku: [String: Any] = ["title": "入库记录", "columns": ErpServer.rukuColumns]
        let chuku: [String: Any] = ["title": "出库记录", "columns": ErpServer.chukuColumns]
        let tables: [String: Any] = ["ruku": ruku, "chuku": chuku]
        let object: [String: Any] = [
            "company": ErpServer.company,
            "loggedIn": s != nil,
            "user": s?.user ?? "",
            "message": s?.message ?? "未登录",
            "officialStockUrl": ErpServer.base + "/admin/view/Stock_RealTime.html?dizhilan_danwei=" + pct(ErpServer.company),
            "tables": tables,
            "typeOptions": ErpServer.typeOptions,
            "typeOptionsWithData": ErpServer.typeOptionsWithData,
            "exportMaxRows": 5000,
            "dataReady": storeReady,
            "syncing": isStoreSyncing,
            "syncedAt": currentSyncedAt,
            "lastNew": currentLastNew
        ]
        return Reply.json(object)
    }

    private func login(_ req: Request) -> Reply {
        if req.method != "POST" { return fail(405, "请用 POST", "BAD_METHOD") }
        // WKWebView 在部分 iOS 版本会改写或丢弃自定义 Content-Type 请求头，
        // 这里不再强制校验请求头：只要请求体能解析出账号密码就放行。
        // 同时兼容 JSON 与 x-www-form-urlencoded 两种请求体。
        var dict: [String: Any]? = nil
        if let d = req.body.data(using: .utf8),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            dict = j
        } else if req.body.contains("=") {
            var tmp: [String: Any] = [:]
            for pair in req.body.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 {
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    tmp[k] = v.replacingOccurrences(of: "+", with: " ")
                }
            }
            dict = tmp
        }
        guard let b = dict else {
            let hint = req.contentType.isEmpty ? "无" : req.contentType
            return fail(400, "请求体不是合法 JSON（Content-Type=\(hint)，长度=\(req.body.utf8.count)）", "BAD_BODY")
        }
        let user = (b["user"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = b["password"] as? String ?? ""
        if user.isEmpty || pass.isEmpty { return fail(400, "请填写账号和密码", "BAD_FIELDS") }
        if user.count > 64 || pass.count > 128 { return fail(400, "账号或密码过长", "BAD_FIELDS") }

        let result = doLogin(user: user, password: pass)
        if !result.ok { return fail(401, result.message, "LOGIN_FAILED") }
        let newSid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        lock.lock()
        if !readSid(req).isEmpty { sessions.removeValue(forKey: readSid(req)) }
        sessions[newSid] = Session(cookie: result.cookie, user: user,
                                   message: result.message, permissions: result.permissions)
        lock.unlock()
        let object: [String: Any] = ["ok": true, "user": user, "message": result.message]
        // 登录成功后后台无感同步（首次全量下载或快速对比），不阻塞登录响应
        syncQueue.async { [weak self] in self?.syncAll("login") }
        return Reply.json(object,
                          setCookie: "erp_sid=\(newSid); Path=/; HttpOnly; SameSite=Lax; Max-Age=604800")
    }

    private func logout(_ req: Request) -> Reply {
        dropSession(readSid(req))
        return Reply.json(["ok": true], setCookie: "erp_sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")
    }

    private func dropSession(_ sid: String) {
        if sid.isEmpty { return }
        lock.lock()
        sessions.removeValue(forKey: sid)
        for (k, v) in cache where v.sid == sid { cache.removeValue(forKey: k) }
        lock.unlock()
    }

    private func fail(_ code: Int, _ msg: String, _ tag: String) -> Reply {
        return Reply.json(["error": msg, "code": tag], code: code)
    }
    private func needLogin() -> Reply { return fail(401, "未登录", "NEED_LOGIN") }

    private func query(_ req: Request) -> Reply {
        let sid = readSid(req)
        lock.lock()
        let s = sid.isEmpty ? nil : sessions[sid]
        lock.unlock()
        guard let session = s else { return needLogin() }
        let isOut = req.params["type"] == "chuku"
        let page = max(1, Int(req.params["page"] ?? "") ?? 1)
        let rows = min(5000, max(1, Int(req.params["rows"] ?? "") ?? 20))
        let con = buildCon(isOut: isOut, f: req.params)
        // 本地仓库就绪 → 毫秒级本地查询（数据同步即时反映，不走缓存）；未就绪 → 回退远程实时查询
        if storeReady { return localQuery(isOut: isOut, page: page, rows: rows, f: req.params, con: con) }
        // 60 秒会话隔离查询缓存：重复点击/翻页回看秒出（dropSession 时自动清理）
        let qkey = "q|\(sid)|\(isOut ? "chuku" : "ruku")|\(page)|\(rows)|\(con)"
        lock.lock()
        let qhit = cache[qkey]
        lock.unlock()
        if let h = qhit, Date().timeIntervalSince1970 - h.time < ErpServer.queryCacheSeconds {
            var r = Reply(); r.body = Data(h.json.utf8); return r
        }
        guard let g = grid(isOut: isOut, page: page, rows: rows, con: con, cookie: session.cookie) else {
            return Reply.text("上游查询失败")
        }
        var list = (g["rows"] as? [[String: Any]]) ?? []
        for i in 0..<list.count { decorate(&list[i]) }
        let object: [String: Any] = [
            "total": Int(num(g["total"])), "rows": list,
            "columns": isOut ? ErpServer.chukuColumns : ErpServer.rukuColumns,
            "type": isOut ? "chuku" : "ruku", "con": con
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Reply.text("结果序列化失败")
        }
        let json = String(data: d, encoding: .utf8) ?? "{}"
        lock.lock()
        cache[qkey] = CacheItem(time: Date().timeIntervalSince1970, sid: sid, json: json)
        lock.unlock()
        var reply = Reply(); reply.body = d; return reply
    }

    private func stock(_ req: Request) -> Reply {
        let sid = readSid(req)
        lock.lock()
        let s = sid.isEmpty ? nil : sessions[sid]
        lock.unlock()
        guard let session = s else { return needLogin() }
        // 本地仓库就绪 → 毫秒级本地汇总；未就绪 → 回退远程实时拉取
        if storeReady { return localStock(req.params) }
        let keys = req.params.keys.sorted()
        let key = sid + "|" + keys.map { "\($0)=\(req.params[$0] ?? "")" }.joined(separator: "&")
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let h = hit, Date().timeIntervalSince1970 - h.time < ErpServer.cacheSeconds {
            var r = Reply(); r.body = Data(h.json.utf8); return r
        }
        let conIn = buildCon(isOut: false, f: req.params)
        let conOut = buildCon(isOut: true, f: req.params)
        let box = ErpServer.Box()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let list = self.fetchAll(isOut: i == 1, con: i == 1 ? conOut : conIn, cookie: session.cookie)
            box.set(i, list)
        }
        let inRows = box.get(0)
        let outRows = box.get(1)
        var map: [String: [String: Any]] = [:]
        var order: [String] = []
        addRows(&map, order: &order, rows: inRows)
        addRows(&map, order: &order, rows: outRows)
        let sorted = order.sorted { a, b in
            let x = map[a] ?? [:], y = map[b] ?? [:]
            for k in ["leixing", "daima", "spec", "mingcheng", "cangku"] {
                let l = str(x[k]), r = str(y[k])
                let c = l.isEmpty ? "\u{ffff}" : l
                let d = r.isEmpty ? "\u{ffff}" : r
                let result = c.localizedStandardCompare(d)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
        let rows: [[String: Any]] = sorted.compactMap { map[$0] }
        let scanned: [String: Any] = ["ruku": inRows.count, "chuku": outRows.count]
        let object: [String: Any] = [
            "rows": rows, "columns": ErpServer.stockColumns, "total": rows.count,
            "scanned": scanned, "available": scanned, "truncated": false
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Reply.text("结果序列化失败")
        }
        let json = String(data: d, encoding: .utf8) ?? "{}"
        lock.lock()
        cache[key] = CacheItem(time: Date().timeIntervalSince1970, sid: sid, json: json)
        lock.unlock()
        var r = Reply(); r.body = d; return r
    }

    // MARK: - 本地数据仓库

    /// 启动即加载本地数据（不依赖登录）。文件为本 App 自产 zlib(deflate) 压缩 JSON。
    private func loadStore() {
        guard let f = dataFile, FileManager.default.fileExists(atPath: f.path),
              let raw = try? Data(contentsOf: f),
              let plain = try? (raw as NSData).decompressed(using: .zlib) as Data,
              let j = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let a = j["ruku"] as? [[String: Any]],
              let b = j["chuku"] as? [[String: Any]] else { return }
        storeLock.lock()
        storeRuku = a; storeChuku = b
        syncedAt = (j["syncedAt"] as? NSNumber)?.doubleValue ?? 0
        dataReadyFlag = a.count + b.count > 0
        storeLock.unlock()
    }

    /// 序列化整仓为 zlib 压缩 JSON（临时文件 + 原子替换），只在后台同步队列调用
    private func saveStore() {
        guard let f = dataFile else { return }
        storeLock.lock()
        let dict: [String: Any] = ["ruku": storeRuku, "chuku": storeChuku, "syncedAt": syncedAt]
        storeLock.unlock()
        guard let plain = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let gz = try? (plain as NSData).compressed(using: .zlib) as Data else { return }
        let tmp = f.appendingPathExtension("tmp")
        do {
            try gz.write(to: tmp)
            if FileManager.default.fileExists(atPath: f.path) {
                _ = try FileManager.default.replaceItemAt(f, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: f)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 记录唯一键：优先厂商 ID 号，退化到 时间+编码+宽+长+数量 组合（与 server.js rowKey 同语义）
    private func rowKey(_ r: [String: Any]) -> String {
        var id = str(r["ID"])
        if id.isEmpty { id = str(r["id"]) }
        if !id.isEmpty { return id }
        var t = str(r["rukushijian"])
        if t.isEmpty { t = str(r["chukushijian"]) }
        return [t, str(r["daima"]), str(r["kuan"]), str(r["chang"]), str(r["shuliang"])].joined(separator: "|")
    }

    /// 行内容指纹：所有字段值参与对比，total 不变但记录被修改也能发现
    private func fingerprint(_ r: [String: Any]) -> String {
        var out = ""
        for k in r.keys.sorted() { out += k + "\u{01}" + str(r[k]) + "\u{02}" }
        return out
    }

    private func commitStore(isOut: Bool, rows: [[String: Any]]) {
        storeLock.lock()
        if isOut { storeChuku = rows } else { storeRuku = rows }
        dataReadyFlag = storeRuku.count + storeChuku.count > 0
        storeLock.unlock()
    }

    private func snapshot(isOut: Bool) -> [[String: Any]] {
        storeLock.lock(); defer { storeLock.unlock() }
        return isOut ? storeChuku : storeRuku
    }

    private func countOf(isOut: Bool) -> Int {
        storeLock.lock(); defer { storeLock.unlock() }
        return (isOut ? storeChuku : storeRuku).count
    }

    /// 单表同步：首页整行指纹快速对比 → 无差异 1 请求/表秒结束；
    /// 有差异按时间倒序增量翻页（连续 2 页全已知才停，上限 40 页）；数量对不齐则全量兜底。
    /// 返回本次是否产生了数据变更（决定是否落盘，避免无谓的整仓序列化）。
    private func syncTable(isOut: Bool, cookie: String, full: Bool) throws -> Bool {
        let con = "danwei = '" + esc(ErpServer.company) + "'"
        guard let first = grid(isOut: isOut, page: 1, rows: ErpServer.pageSize, con: con, cookie: cookie) else {
            throw SyncError.upstream
        }
        let total = Int(num(first["total"]))
        let firstRows = (first["rows"] as? [[String: Any]]) ?? []
        let local = snapshot(isOut: isOut)
        var byKey: [String: [String: Any]] = [:]
        for r in local { byKey[rowKey(r)] = r }

        var firstNew = false, firstChanged = false
        loop: for r in firstRows {
            guard let l = byKey[rowKey(r)] else { firstNew = true; break }
            if fingerprint(l) != fingerprint(r) { firstChanged = true; break loop }
        }
        if local.count == total && !firstNew && !firstChanged { return false }
        if full { try fullSyncTable(isOut: isOut, cookie: cookie, total: total, merge: true); return true }

        var working = local
        var changed = false
        if firstNew || firstChanged {
            var idxByKey: [String: Int] = [:]
            for (i, r) in working.enumerated() { idxByKey[rowKey(r)] = i }
            var seen = Set(byKey.keys)
            let totalPages = Int(ceil(Double(total) / Double(ErpServer.pageSize)))
            let maxPages = max(1, min(40, totalPages))
            var streak = 0
            pageLoop: for p in 1...maxPages {
                let rows: [[String: Any]]
                if p == 1 {
                    rows = firstRows
                } else {
                    guard let g = grid(isOut: isOut, page: p, rows: ErpServer.pageSize, con: con, cookie: cookie) else { break }
                    rows = (g["rows"] as? [[String: Any]]) ?? []
                }
                for r in rows {
                    let k = rowKey(r)
                    if let idx = idxByKey[k] {
                        if fingerprint(working[idx]) != fingerprint(r) {
                            working[idx] = r; byKey[k] = r; changed = true
                        }
                    } else {
                        seen.insert(k)
                        idxByKey[k] = working.count
                        working.append(r)
                        byKey[k] = r
                        changed = true
                    }
                }
                let allKnown = !rows.isEmpty && rows.allSatisfy { seen.contains(rowKey($0)) }
                streak = allKnown ? streak + 1 : 0
                if streak >= 2 { break pageLoop }
            }
        }
        if working.count != total {
            try fullSyncTable(isOut: isOut, cookie: cookie, total: total, merge: true)
            return true
        }
        if changed { commitStore(isOut: isOut, rows: working) }
        return changed
    }

    /// 全量拉取单表。merge=true 时与本地逐条 diff 合并；分页拉取不完整时只补/覆盖、不删（防误删）。
    private func fullSyncTable(isOut: Bool, cookie: String, total: Int, merge: Bool) throws {
        let con = "danwei = '" + esc(ErpServer.company) + "'"
        guard let g1 = grid(isOut: isOut, page: 1, rows: ErpServer.pageSize, con: con, cookie: cookie) else {
            throw SyncError.upstream
        }
        let pages = min(Int(ceil(Double(max(total, 0)) / Double(ErpServer.pageSize))) + 2, ErpServer.syncPageLimit)
        var all: [[String: Any]] = (g1["rows"] as? [[String: Any]]) ?? []
        if pages > 1 {
            let box = ErpServer.Box()
            var from = 2
            while from <= pages {
                let batch = min(4, pages - from + 1)
                let start = from
                DispatchQueue.concurrentPerform(iterations: batch) { i in
                    let page = start + i
                    if let g = self.grid(isOut: isOut, page: page, rows: ErpServer.pageSize, con: con, cookie: cookie),
                       let list = g["rows"] as? [[String: Any]] {
                        box.set(page, list)
                    }
                }
                for p in start..<(start + batch) { all.append(contentsOf: box.get(p)) }
                from += batch
            }
        }
        // 去重：保持首次出现顺序，后值覆盖前值（与 server.js 同语义）
        var outMap: [String: [String: Any]] = [:]
        var ordered: [String] = []
        for r in all {
            let k = rowKey(r)
            if outMap[k] == nil { ordered.append(k) }
            outMap[k] = r
        }
        var merged: [[String: Any]]
        if merge {
            let fetchedOk = ordered.count >= Double(total > 0 ? total : ordered.count) * 0.98
            if fetchedOk {
                merged = ordered.compactMap { outMap[$0] }   // 以云端为准：新增+修改覆盖+本地多余删除
            } else {
                var cur: [String: [String: Any]] = [:]
                var curOrder: [String] = []
                for r in snapshot(isOut: isOut) {
                    let k = rowKey(r)
                    if cur[k] == nil { curOrder.append(k) }
                    cur[k] = r
                }
                for k in ordered {                            // 不完整：只 upsert，不删
                    if cur[k] == nil { curOrder.append(k) }
                    cur[k] = outMap[k] ?? cur[k]
                }
                merged = curOrder.compactMap { cur[$0] }
            }
        } else {
            merged = ordered.compactMap { outMap[$0] }
        }
        commitStore(isOut: isOut, rows: merged)
    }

    private func startSyncTimer() {
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + ErpServer.syncSeconds, repeating: ErpServer.syncSeconds)
        timer.setEventHandler { [weak self] in self?.syncAll("定时") }
        timer.resume()
        syncTimer = timer
    }

    /// 后台同步：需要一个已登录会话的 cookie（有会话才查）。每 1 分钟增量复查；超 6 小时自动升级全量。
    private func syncAll(_ reason: String) {
        storeLock.lock()
        if storeSyncingFlag { storeLock.unlock(); return }
        var found: Session? = nil
        for s in sessions.values where !s.cookie.isEmpty { found = s; break }
        guard let session = found else { storeLock.unlock(); return }
        storeSyncingFlag = true
        storeLock.unlock()
        defer {
            storeLock.lock(); storeSyncingFlag = false; storeLock.unlock()
        }
        let full = Date().timeIntervalSince1970 - lastFullCheck > ErpServer.fullCheckSeconds
        storeLock.lock()
        let before = storeRuku.count + storeChuku.count
        lastNew = 0
        storeLock.unlock()
        do {
            var changed = try syncTable(isOut: false, cookie: session.cookie, full: full)
            changed = try syncTable(isOut: true, cookie: session.cookie, full: full) || changed
            if full { lastFullCheck = Date().timeIntervalSince1970 }
            storeLock.lock()
            syncedAt = Date().timeIntervalSince1970
            dataReadyFlag = storeRuku.count + storeChuku.count > 0
            lastNew = max(0, storeRuku.count + storeChuku.count - before)
            storeLock.unlock()
            if changed || before == 0 { saveStore() }
        } catch {
            // 同步失败不影响查询（本地旧数据或远程实时路径兜底）
        }
    }

    /// 本地筛选：复刻远程 con 的语义（日期范围 / 关键字含来源项目 / 宽×长与纯数字规格 / 仓库类型项目 like）
    private func localRowsFiltered(isOut: Bool, f: [String: String]) -> [[String: Any]] {
        let dateField = isOut ? "chukushijian" : "rukushijian"
        let s = (f["start"] ?? "").trimmingCharacters(in: .whitespaces)
        let e = (f["end"] ?? "").trimmingCharacters(in: .whitespaces)
        let startC = s.isEmpty ? nil : s + " 00:00:00"
        let endC = e.isEmpty ? nil : e + " 23:59:59"
        let qRaw = (f["q"] ?? "").trimmingCharacters(in: .whitespaces)
        let q = qRaw.lowercased()
        let ck = (f["cangku"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let lx = (f["leixing"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let xm = (f["xmmc"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        var pa = Double.nan, pb = 0.0, pn = 0.0, isNum = false
        if let re = try? NSRegularExpression(pattern: "^(\\d+(?:\\.\\d+)?)\\s*[xX*×＊/\\-\\s]\\s*(\\d+(?:\\.\\d+)?)$"),
           let m = re.firstMatch(in: qRaw, range: NSRange(qRaw.startIndex..., in: qRaw)), m.numberOfRanges == 3,
           let r1 = Range(m.range(at: 1), in: qRaw), let r2 = Range(m.range(at: 2), in: qRaw) {
            pa = Double(qRaw[r1]) ?? 0
            pb = Double(qRaw[r2]) ?? 0
        } else if !qRaw.isEmpty,
                  let re = try? NSRegularExpression(pattern: "^\\d+(?:\\.\\d+)?$"),
                  re.firstMatch(in: qRaw, range: NSRange(qRaw.startIndex..., in: qRaw)) != nil {
            isNum = true
            pn = Double(qRaw) ?? 0
        }

        var rows: [[String: Any]] = []
        for r in snapshot(isOut: isOut) {
            let d = str(r[dateField])
            if let sc = startC, d < sc { continue }
            if let ec = endC, d > ec { continue }
            if !ck.isEmpty && !str(r["cangku"]).lowercased().contains(ck) { continue }
            if !lx.isEmpty && !str(r["leixing"]).lowercased().contains(lx) { continue }
            if !xm.isEmpty && !str(r["crkxmmc"]).lowercased().contains(xm) { continue }
            if !q.isEmpty {
                var hit = false
                for k in ErpServer.keywordFields where str(r[k]).lowercased().contains(q) { hit = true; break }
                if !hit && !pa.isNaN {
                    let k = num(r["kuan"]), c = num(r["chang"])
                    hit = (k == pa && c == pb) || (k == pb && c == pa)
                } else if !hit && isNum {
                    hit = num(r["kuan"]) == pn || num(r["chang"]) == pn
                }
                if !hit { continue }
            }
            rows.append(r)
        }
        rows.sort { str($0[dateField]) > str($1[dateField]) }
        return rows
    }

    /// 本地查询：筛选+排序+分页+规格装饰，毫秒级返回（与 server.js localQuery 同结构）
    private func localQuery(isOut: Bool, page: Int, rows: Int, f: [String: String], con: String) -> Reply {
        let all = localRowsFiltered(isOut: isOut, f: f)
        let from = min((page - 1) * rows, all.count)
        let to = min(from + rows, all.count)
        var list: [[String: Any]] = []
        for i in from..<to {
            var r = all[i]
            decorate(&r)
            list.append(r)
        }
        let object: [String: Any] = [
            "total": all.count, "rows": list,
            "columns": isOut ? ErpServer.chukuColumns : ErpServer.rukuColumns,
            "type": isOut ? "chuku" : "ruku", "con": con,
            "syncedAt": currentSyncedAt
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Reply.text("结果序列化失败")
        }
        var r = Reply(); r.body = d; return r
    }

    /// 本地库存汇总：两表筛选后直接累加，毫秒级（与 server.js localStock 同结构）
    private func localStock(_ f: [String: String]) -> Reply {
        let a = localRowsFiltered(isOut: false, f: f)
        let b = localRowsFiltered(isOut: true, f: f)
        var map: [String: [String: Any]] = [:]
        var order: [String] = []
        addRows(&map, order: &order, rows: a)
        addRows(&map, order: &order, rows: b)
        let sorted = order.sorted { x, y in
            let u = map[x] ?? [:], v = map[y] ?? [:]
            for k in ["leixing", "daima", "spec", "mingcheng", "cangku"] {
                let l = str(u[k]), r = str(v[k])
                let c = l.isEmpty ? "\u{ffff}" : l
                let d = r.isEmpty ? "\u{ffff}" : r
                let result = c.localizedStandardCompare(d)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
        let rows: [[String: Any]] = sorted.compactMap { map[$0] }
        let scanned: [String: Any] = ["ruku": a.count, "chuku": b.count]
        let object: [String: Any] = [
            "rows": rows, "columns": ErpServer.stockColumns, "total": rows.count,
            "scanned": scanned, "available": scanned, "truncated": false,
            "syncedAt": currentSyncedAt
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Reply.text("结果序列化失败")
        }
        var r = Reply(); r.body = d; return r
    }

    // MARK: - ERP 业务

    /// 进销动态：每天一行的各仓库收发存汇总。全历史仅几百行，实时调厂商
    /// ControlHandle.ashx?method=jinxiaocun_dongtai，60 秒会话级缓存，不做本地同步。
    /// 与 Windows EXE 里 server.js 的 /api/jinxiao 同一套规则。
    private func jinxiao(_ req: Request) -> Reply {
        let sid = readSid(req)
        lock.lock()
        let s = sid.isEmpty ? nil : sessions[sid]
        lock.unlock()
        guard let session = s else { return needLogin() }
        // 只接受合法日期格式，防止把奇怪参数透传给厂商云
        let start = dateParam(req.params["start"])
        let end = dateParam(req.params["end"])
        let key = "jx|\(sid)|\(start)|\(end)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let h = hit, Date().timeIntervalSince1970 - h.time < ErpServer.queryCacheSeconds {
            var r = Reply(); r.body = Data(h.json.utf8); return r
        }
        let url = ErpServer.loginURL + "?method=jinxiaocun_dongtai&danwei=" + pct(ErpServer.company)
            + "&StartDate=" + qenc(start) + "&EndDate=" + qenc(end) + "&sjmsver=20250821000009"
        guard let text = httpGet(url, cookie: session.cookie, timeout: 25),
              let d = text.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let rows = j["rows"] as? [[String: Any]] else {
            return fail(502, "厂商云未返回进销动态数据", "UPSTREAM")
        }
        let object: [String: Any] = ["total": Int(num(j["total"])), "rows": rows]
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Reply.text("结果序列化失败")
        }
        let json = String(data: out, encoding: .utf8) ?? "{}"
        lock.lock()
        cache[key] = CacheItem(time: Date().timeIntervalSince1970, sid: sid, json: json)
        lock.unlock()
        var r = Reply(); r.body = out; return r
    }

    private func dateParam(_ v: String?) -> String {
        guard let v = v, !v.isEmpty else { return "" }
        return v.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil ? v : ""
    }

    private struct LoginResult {
        let ok: Bool, message: String, permissions: String, cookie: String
    }

    private func doLogin(user: String, password: String) -> LoginResult {
        let q = "method=UserLogin&xingming=" + qenc(user) + "&danwei=" + qenc(ErpServer.company)
            + "&mima=" + qenc(password) + "&ip=&mac=&sjmsver=20250821000009"
        guard let text = httpGet(ErpServer.loginURL + "?" + q, cookie: "", timeout: 15),
              let d = text.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return LoginResult(ok: false, message: "连接失败", permissions: "", cookie: "")
        }
        let raw = str(j["message"])
        // 厂商接口无论对错都返回 state=success，必须看 message 是否含「成功」
        let ok = str(j["state"]) == "success" && raw.contains("成功")
        let detail = str(j["message2"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = ok ? (raw.isEmpty ? "已连接" : raw)
            : (!detail.isEmpty && detail != raw ? detail : (raw.isEmpty ? "账号或密码错误" : raw))
        let tel = str(j["telephone"]).isEmpty ? password : str(j["telephone"])
        let cookie = ok ? ("sjmslvmo_danwei=" + pct(ErpServer.company)
            + "; sjmslvmo_username=" + pct(user)
            + "; sjmslvmo_telephone=" + pct(tel)) : ""
        return LoginResult(ok: ok, message: message,
                           permissions: ok ? str(j["message1"]) : "", cookie: cookie)
    }

    private func grid(isOut: Bool, page: Int, rows: Int, con: String, cookie: String) -> [String: Any]? {
        let url = ErpServer.gridURL + "?method=getGridData&xmlName="
            + (isOut ? "output_record" : "input_record")
            + "&page=\(page)&rows=\(rows)&sort="
            + (isOut ? "chukushijian" : "rukushijian")
            + "&order=desc&con=" + qenc(con)
        guard let text = httpGet(url, cookie: cookie, timeout: 25),
              let d = text.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return j
    }

    private func fetchAll(isOut: Bool, con: String, cookie: String) -> [[String: Any]] {
        guard let first = grid(isOut: isOut, page: 1, rows: ErpServer.pageSize, con: con, cookie: cookie) else { return [] }
        var rows = (first["rows"] as? [[String: Any]]) ?? []
        let total = Int(num(first["total"]))
        let pages = min(Int(ceil(Double(total) / Double(ErpServer.pageSize))),
                        Int(ceil(Double(ErpServer.maxRows) / Double(ErpServer.pageSize))))
        if pages > 1 {
            let box = ErpServer.Box()
            var from = 2
            while from <= pages && rows.count < ErpServer.maxRows {
                let batch = min(4, pages - from + 1)
                let start = from
                DispatchQueue.concurrentPerform(iterations: batch) { i in
                    let page = start + i
                    guard let g = self.grid(isOut: isOut, page: page, rows: ErpServer.pageSize, con: con, cookie: cookie),
                          let list = g["rows"] as? [[String: Any]] else { return }
                    box.set(page, list)
                }
                for p in start..<(start + batch) where rows.count < ErpServer.maxRows {
                    rows.append(contentsOf: box.get(p))
                }
                from += batch
            }
        }
        if rows.count > ErpServer.maxRows { return Array(rows.prefix(ErpServer.maxRows)) }
        return rows
    }

    private func addRows(_ map: inout [String: [String: Any]], order: inout [String], rows: [[String: Any]]) {
        for r in rows {
            let kuan = num(r["kuan"]), chang = num(r["chang"])
            // 与 server.js localStock 同键：changdu1/changdu2 进分组键（C槽同宽长不同长度不能合并）
            let key = [str(r["daima"]), str(r["mingcheng"]), fmt(kuan), fmt(chang),
                       fmt(num(r["changdu1"])), fmt(num(r["changdu2"])),
                       str(r["leixing"]), str(r["cangku"])].joined(separator: "|")
            if map[key] == nil {
                let item: [String: Any] = [
                    "daima": str(r["daima"]), "mingcheng": str(r["mingcheng"]),
                    "leixing": str(r["leixing"]), "cangku": str(r["cangku"]),
                    "spec": rowSpec(r),
                    "stockQty": 0
                ]
                map[key] = item
                order.append(key)
            }
            let value = num(map[key]?["stockQty"]) + num(r["shuliang"])
            if value == value.rounded() { map[key]?["stockQty"] = Int64(value) }
            else { map[key]?["stockQty"] = value }
        }
    }

    private func decorate(_ row: inout [String: Any]) {
        row["spec"] = rowSpec(row)
    }

    // C槽类型规格（与 server.js 同语义）：IC→IC长1；ICA/SNTL→ICA长1；SNTR→IC长1A；SNTT→ICA长1A；SCU→SCU长1(+长2)
    private func cslotSpec(_ r: [String: Any]) -> String {
        guard str(r["leixing"]).contains("C槽") else { return "" }
        let daima = str(r["daima"]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let c1 = num(r["changdu1"]), c2 = num(r["changdu2"])
        guard c1 != 0 else { return "" }
        let w = fmt(num(r["kuan"])) + "×" + fmt(num(r["chang"]))
        switch daima {
        case "IC": return w + "IC" + fmt(c1)
        case "ICA", "SNTL": return w + "ICA" + fmt(c1)
        case "SNTR": return w + "IC" + fmt(c1) + "A"
        case "SNTT": return w + "ICA" + fmt(c1) + "A"
        case "SCU": return c2 != 0 ? w + "SCU" + fmt(c1) + "+" + fmt(c2) : w + "SCU" + fmt(c1)
        default: return ""
        }
    }

    // 字母连接类（与 server.js 同语义）：只看编码，规格=宽度左+编码+宽度右，无长度段
    private static let letterCodes: Set<String> = ["P", "FP", "K", "EB", "BP", "BPP", "CPPP", "CPP", "PT", "MB", "PS"]

    private func letterSpec(_ r: [String: Any]) -> String {
        let daima = str(r["daima"]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.letterCodes.contains(daima) else { return "" }
        let w1 = num(r["kuan"]), w2 = num(r["chang"])
        guard w1 != 0, w2 != 0 else { return "" }
        return fmt(w1) + daima + fmt(w2)
    }

    // 统一规格出口：C槽规则 → 字母连接类 → 兜底宽×长。出入库与库存汇总共用。
    private func rowSpec(_ r: [String: Any]) -> String {
        let cs = cslotSpec(r)
        if !cs.isEmpty { return cs }
        let ls = letterSpec(r)
        if !ls.isEmpty { return ls }
        let kuan = num(r["kuan"]), chang = num(r["chang"])
        return (kuan != 0 || chang != 0) ? fmt(kuan) + "×" + fmt(chang) : ""
    }

    private func buildCon(isOut: Bool, f: [String: String]) -> String {
        let dateField = isOut ? "chukushijian" : "rukushijian"
        var parts = ["danwei = '" + esc(ErpServer.company) + "'"]
        if let v = f["start"], !v.isEmpty { parts.append(dateField + " >= '" + esc(v) + " 00:00:00'") }
        if let v = f["end"], !v.isEmpty { parts.append(dateField + " <= '" + esc(v) + " 23:59:59'") }
        if let v = f["q"], !v.isEmpty { parts.append(keywordClause(v)) }
        if let v = f["cangku"], !v.isEmpty { parts.append("cangku like '%" + esc(v) + "%'") }
        if let v = f["leixing"], !v.isEmpty { parts.append("leixing like '%" + esc(v) + "%'") }
        if let v = f["xmmc"], !v.isEmpty { parts.append("crkxmmc like '%" + esc(v) + "%'") }
        return parts.joined(separator: " and ")
    }

    private func keywordClause(_ rawQ: String) -> String {
        let raw = rawQ.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = esc(raw)
        var parts = ErpServer.keywordFields.map { $0 + " like '%" + q + "%'" }
        let pattern = "^(\\d+(?:\\.\\d+)?)\\s*[xX*×＊/\\-\\s]\\s*(\\d+(?:\\.\\d+)?)$"
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           m.numberOfRanges == 3,
           let r1 = Range(m.range(at: 1), in: raw), let r2 = Range(m.range(at: 2), in: raw) {
            let a = String(raw[r1]), b = String(raw[r2])
            parts.append("((kuan = \(a) and chang = \(b)) or (kuan = \(b) and chang = \(a)))")
        } else if let numRe = try? NSRegularExpression(pattern: "^\\d+(?:\\.\\d+)?$"),
                  numRe.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil {
            parts.append("kuan = \(raw)")
            parts.append("chang = \(raw)")
            parts.append("kuan like '%" + q + "%'")
            parts.append("chang like '%" + q + "%'")
        }
        return "(" + parts.joined(separator: " or ") + ")"
    }

    // MARK: - 工具

    private func httpGet(_ urlString: String, cookie: String, timeout: TimeInterval) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue(ErpServer.base + "/admin/index.html", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { result = String(data: d, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return result
    }

    private func qenc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.*")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    private func pct(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    private func esc(_ s: String?) -> String {
        let v = s ?? ""
        let doubled = v.replacingOccurrences(of: "'", with: "''")
        guard let re = try? NSRegularExpression(pattern: "[;\\-]{2,}") else { return doubled }
        return re.stringByReplacingMatches(in: doubled, range: NSRange(doubled.startIndex..., in: doubled), withTemplate: "")
    }
    private func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    private func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
    private func fmt(_ d: Double) -> String {
        return d == d.rounded() ? String(Int64(d)) : String(d)
    }
}
