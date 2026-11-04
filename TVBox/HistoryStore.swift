import Foundation

/// 播放历史条目：一部影片一条（同站点同影片覆盖更新）
struct HistoryEntry: Codable, Identifiable {
    let siteKey: String
    let siteName: String
    let siteApi: String
    let vodId: String
    let vodName: String
    let vodPic: String
    var sourceIndex: Int
    var episodeIndex: Int
    var episodeName: String
    var position: Double      // 已看秒数
    var duration: Double      // 总秒数，0 = 未知
    var updatedAt: Date

    var id: String { "\(siteKey)_\(vodId)" }

    var updatedText: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: updatedAt, relativeTo: Date())
    }

    static func fmt(_ seconds: Double) -> String {
        guard seconds > 0 else { return "--:--" }
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let key = "tvbox_play_history"
    private let limit = 50

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
    }

    func record(site: Site, vod: VodItem, sourceIndex: Int, episodeIndex: Int,
                episodeName: String, position: Double, duration: Double) {
        guard position > 5, !vod.vodId.isEmpty else { return }   // 太短不记
        let e = HistoryEntry(siteKey: site.key, siteName: site.name, siteApi: site.api,
                             vodId: vod.vodId, vodName: vod.vodName, vodPic: vod.vodPic,
                             sourceIndex: sourceIndex, episodeIndex: episodeIndex,
                             episodeName: episodeName, position: position, duration: duration,
                             updatedAt: Date())
        entries.removeAll { $0.id == e.id }
        entries.insert(e, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
    }

    /// 播完（≥95%）视为看完，自动移除（电视端同款语义）
    func removeIfFinished(siteKey: String, vodId: String, position: Double, duration: Double) {
        guard duration > 0, position / duration >= 0.95 else { return }
        entries.removeAll { $0.siteKey == siteKey && $0.vodId == vodId }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
