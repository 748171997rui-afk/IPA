import Foundation

// MARK: - TVBox 接口配置

struct TVBoxConfig: Decodable {
    let sites: [Site]
}

struct Site: Decodable {
    let key: String
    let name: String
    let type: Int
    let api: String
    let searchable: Int?

    /// iOS 版可用性：仅支持 type 0/1 的直连 JSON API（苹果CMS 类）。
    /// csp_* 爬虫（dex jar）与 .js 爬虫在 iOS 上无法运行，自动过滤。
    var usableOnIOS: Bool {
        guard type == 0 || type == 1 else { return false }
        let a = api.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return false }
        let lower = a.lowercased()
        if lower.hasPrefix("csp_") || lower.hasPrefix("./") || lower.hasSuffix(".js") || lower.contains("drpy") { return false }
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) { return false }
        return true
    }
}

// MARK: - VOD 数据（苹果CMS10 协议）

struct VodClass: Decodable {
    let typeId: String
    let typeName: String

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
    }

    init(typeId: String, typeName: String) {
        self.typeId = typeId
        self.typeName = typeName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .typeId) {
            typeId = s
        } else if let i = try? c.decode(Int.self, forKey: .typeId) {
            typeId = String(i)
        } else {
            typeId = "0"
        }
        typeName = (try? c.decode(String.self, forKey: .typeName)) ?? "未分类"
    }
}

struct VodItem: Identifiable, Hashable, Decodable {
    let vodId: String
    let vodName: String
    let vodPic: String
    let vodRemarks: String
    let vodYear: String
    let vodArea: String
    let vodActor: String
    let vodDirector: String
    let vodContent: String
    let vodPlayFrom: String
    let vodPlayUrl: String

    var id: String { "\(vodId)_\(vodName)" }

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodActor = "vod_actor"
        case vodDirector = "vod_director"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys) -> String {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            return ""
        }
        vodId = str(.vodId)
        vodName = str(.vodName)
        vodPic = str(.vodPic)
        vodRemarks = str(.vodRemarks)
        vodYear = str(.vodYear)
        vodArea = str(.vodArea)
        vodActor = str(.vodActor)
        vodDirector = str(.vodDirector)
        vodContent = str(.vodContent).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        vodPlayFrom = str(.vodPlayFrom)
        vodPlayUrl = str(.vodPlayUrl)
    }
}

struct VodListResponse: Decodable {
    let classes: [VodClass]
    let list: [VodItem]
    let pagecount: Int

    enum CodingKeys: String, CodingKey {
        case classes = "class"
        case list
        case pagecount
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classes = (try? c.decode([VodClass].self, forKey: .classes)) ?? []
        if let l = try? c.decode([VodItem].self, forKey: .list) {
            list = l
        } else if let d = try? c.decode(VodListResponse.self, forKey: .data) {
            list = d.list
            pagecount = d.pagecount
        } else {
            list = []
        }
        pagecount = (try? c.decode(Int.self, forKey: .pagecount)) ?? 1
    }
}

// MARK: - 播放地址解析

struct PlaySource: Identifiable {
    let name: String
    let episodes: [Episode]
    var id: String { name }
}

struct Episode: Identifiable {
    let name: String
    let url: String
    var id: String { name + url }
}

enum PlayUrlParser {
    /// 解析 vod_play_url / vod_play_from（多源以 $$$ 或 ### 分隔）
    static func parse(from: String, url: String) -> [PlaySource] {
        var sep = "$$$"
        if url.contains("###") && !url.contains("$$$") { sep = "###" }
        let fromParts = from.components(separatedBy: sep)
        let urlParts = url.components(separatedBy: sep)
        var sources: [PlaySource] = []
        for (i, u) in urlParts.enumerated() {
            let sourceName = i < fromParts.count && !fromParts[i].isEmpty ? fromParts[i] : "线路\(i + 1)"
            let eps = u.components(separatedBy: "#").compactMap { raw -> Episode? in
                let parts = raw.components(separatedBy: "$")
                guard parts.count >= 2, !parts[1].isEmpty else { return nil }
                return Episode(name: parts[0].trimmingCharacters(in: .whitespaces), url: parts[1].trimmingCharacters(in: .whitespaces))
            }
            if !eps.isEmpty { sources.append(PlaySource(name: sourceName, episodes: eps)) }
        }
        return sources
    }
}
