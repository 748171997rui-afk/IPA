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
        ["daima", "编码", 130], ["spec", "规格(宽×长)", 110], ["cangku", "仓库", 100],
        ["shuliang", "数量", 90], ["shiji_zhongliang", "实际重量", 90],
        ["erp_pinhao", "ERP品号", 110], ["crkxmmc", "项目", 130], ["yonghu", "操作人", 110],
        ["laiyuan_telephone", "来源", 140], ["beizhu", "备注", 180]
    ]
    private static let chukuColumns: [[Any]] = [
        ["chukushijian", "出库时间", 150], ["leixing", "类型", 140], ["mingcheng", "名称", 130],
        ["daima", "编码", 130], ["spec", "规格(宽×长)", 110], ["cangku", "仓库", 100],
        ["shuliang", "数量", 90], ["shiji_zhongliang", "实际重量", 90],
        ["erp_pinhao", "ERP品号", 110], ["crkxmmc", "项目", 130], ["yonghu", "操作人", 110],
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
            "exportMaxRows": 5000
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

    // MARK: - ERP 业务

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
            let key = [str(r["daima"]), str(r["mingcheng"]), fmt(kuan), fmt(chang),
                       str(r["leixing"]), str(r["cangku"])].joined(separator: "|")
            if map[key] == nil {
                let item: [String: Any] = [
                    "daima": str(r["daima"]), "mingcheng": str(r["mingcheng"]),
                    "leixing": str(r["leixing"]), "cangku": str(r["cangku"]),
                    "spec": (kuan != 0 || chang != 0) ? fmt(kuan) + "×" + fmt(chang) : "",
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
        let kuan = num(row["kuan"]), chang = num(row["chang"])
        row["spec"] = (kuan != 0 || chang != 0) ? fmt(kuan) + "×" + fmt(chang) : ""
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
