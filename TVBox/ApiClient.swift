import Foundation

enum ApiError: LocalizedError {
    case badURL
    case http(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址无效"
        case .http(let code): return "请求失败 (HTTP \(code))"
        case .parse(let msg): return "数据解析失败：\(msg)"
        }
    }
}

final class ApiClient {
    static let shared = ApiClient()

    private var session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": "okhttp/3.15"]
        session = URLSession(configuration: cfg)
    }

    /// 下载接口配置 JSON（自动去掉 BOM 与注释行）
    func fetchConfig(_ urlString: String) async throws -> TVBoxConfig {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else { throw ApiError.badURL }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw ApiError.http(http.statusCode)
        }
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // 去掉 // 注释行（部分配置带注释）
        let cleaned = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let jsonData = cleaned.data(using: .utf8) else { throw ApiError.parse("编码错误") }
        do {
            return try JSONDecoder().decode(TVBoxConfig.self, from: jsonData)
        } catch {
            throw ApiError.parse("配置格式不正确（缺少 sites）")
        }
    }

    /// 构造 VOD 请求 URL（ac=videolist）
    static func vodURL(api: String, categoryId: String?, page: Int, keyword: String?, ids: String?) -> URL? {
        guard var comps = URLComponents(string: api) else { return nil }
        var items = comps.queryItems ?? []
        func upsert(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        upsert("ac", "videolist")
        if let c = categoryId, c != "0" { upsert("t", c) }
        upsert("pg", String(page))
        if let w = keyword, !w.isEmpty { upsert("wd", w) }
        if let i = ids, !i.isEmpty { upsert("ids", i) }
        comps.queryItems = items
        return comps.url
    }

    func getVodList(api: String, categoryId: String? = nil, page: Int = 1, keyword: String? = nil, ids: String? = nil) async throws -> VodListResponse {
        guard let url = Self.vodURL(api: api, categoryId: categoryId, page: page, keyword: keyword, ids: ids) else { throw ApiError.badURL }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw ApiError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(VodListResponse.self, from: data)
        } catch {
            throw ApiError.parse("该源不是标准苹果CMS接口")
        }
    }
}
