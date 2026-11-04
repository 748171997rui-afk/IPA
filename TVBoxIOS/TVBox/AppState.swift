import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// 内置源模式标记：从 App 包内 default_config.json 读取（无需网络）
    static let bundledAPI = "bundled://"
    static let defaultAPI = bundledAPI
    private let apiDefaultsKey = "tvbox_api_url"

    // 配置
    @Published var apiURL: String {
        didSet { UserDefaults.standard.set(apiURL, forKey: apiDefaultsKey) }
    }
    @Published var sites: [Site] = []
    @Published var configLoading = false
    @Published var configError: String?

    // 当前源
    @Published var selectedSite: Site?
    @Published var categories: [VodClass] = []
    @Published var selectedCategory: VodClass?
    @Published var vods: [VodItem] = []
    @Published var page = 1
    @Published var totalPages = 1
    @Published var listLoading = false
    @Published var listError: String?

    // 搜索
    @Published var searchResults: [VodItem] = []
    @Published var searching = false

    init() {
        let saved = UserDefaults.standard.string(forKey: apiDefaultsKey)
        apiURL = (saved?.isEmpty == false) ? saved! : Self.defaultAPI
    }

    func loadConfig() async {
        configLoading = true
        configError = nil
        sites = []
        selectedSite = nil
        categories = []
        vods = []
        defer { configLoading = false }
        do {
            let cfg: TVBoxConfig
            if apiURL == Self.bundledAPI {
                cfg = try Self.loadBundledConfig()
            } else {
                cfg = try await ApiClient.shared.fetchConfig(apiURL)
            }
            let usable = cfg.sites.filter(\.usableOnIOS)
            guard !usable.isEmpty else {
                configError = "该接口的源全部是爬虫源（csp/js），iOS 版暂不支持。请在设置中更换包含直连 JSON 源（type 0/1）的接口。"
                return
            }
            sites = usable
            if let first = usable.first {
                await selectSite(first)
            }
        } catch {
            configError = error.localizedDescription
        }
    }

    func selectSite(_ site: Site) async {
        selectedSite = site
        categories = []
        selectedCategory = nil
        listError = nil
        listLoading = true
        defer { listLoading = false }
        do {
            let resp = try await ApiClient.shared.getVodList(api: site.api, page: 1)
            categories = resp.classes
            vods = resp.list
            page = 1
            totalPages = max(resp.pagecount, 1)
        } catch {
            listError = error.localizedDescription
        }
    }

    func selectCategory(_ cat: VodClass?) async {
        selectedCategory = cat
        await reloadList()
    }

    func reloadList() async {
        guard let site = selectedSite else { return }
        listError = nil
        listLoading = true
        defer { listLoading = false }
        do {
            let resp = try await ApiClient.shared.getVodList(
                api: site.api,
                categoryId: selectedCategory?.typeId,
                page: 1
            )
            vods = resp.list
            page = 1
            totalPages = max(resp.pagecount, 1)
        } catch {
            listError = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let site = selectedSite, !listLoading, page < totalPages else { return }
        listLoading = true
        defer { listLoading = false }
        do {
            let next = page + 1
            let resp = try await ApiClient.shared.getVodList(
                api: site.api,
                categoryId: selectedCategory?.typeId,
                page: next
            )
            let known = Set(vods.map(\.id))
            vods.append(contentsOf: resp.list.filter { !known.contains($0.id) })
            page = next
            totalPages = max(resp.pagecount, next)
        } catch {
            listError = error.localizedDescription
        }
    }

    func search(_ keyword: String) async {
        guard let site = selectedSite, !keyword.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            let resp = try await ApiClient.shared.getVodList(api: site.api, keyword: keyword)
            searchResults = resp.list
        } catch {
            searchResults = []
        }
    }

    func getDetail(_ item: VodItem) async -> VodItem? {
        guard let site = selectedSite else { return nil }
        return try? await ApiClient.shared.getVodList(api: site.api, ids: item.vodId).list.first
    }

    /// 读取包内内置源配置
    static func loadBundledConfig() throws -> TVBoxConfig {
        guard let url = Bundle.main.url(forResource: "default_config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ApiError.parse("内置配置缺失")
        }
        return try JSONDecoder().decode(TVBoxConfig.self, from: data)
    }
}
