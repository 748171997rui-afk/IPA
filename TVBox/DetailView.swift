import SwiftUI

struct PlayerItem: Identifiable {
    let url: URL
    var siteKey: String = ""
    var siteName: String = ""
    var siteApi: String = ""
    var vodId: String = ""
    var vodName: String = ""
    var vodPic: String = ""
    var sourceIndex: Int = 0
    var episodeIndex: Int = 0
    var episodeName: String = ""
    var resumeAt: Double = 0
    // 含集索引：避免同影片同集二次弹出时 fullScreenCover identity 冲突不刷新
    var id: String { url.absoluteString + "#\(sourceIndex)_\(episodeIndex)" }
}

struct DetailView: View {
    @EnvironmentObject var state: AppState
    let vodItem: VodItem
    /// 聚合搜索/历史记录的来源站点；nil = 当前选中源
    var sourceSite: Site? = nil
    /// 从播放历史进入时自动续播
    var autoResume: HistoryEntry? = nil

    @State private var detail: VodItem?
    @State private var loading = true
    @State private var errorText: String?
    @State private var playItem: PlayerItem?
    @State private var selectedSourceIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let err = errorText {
                    Text(err).foregroundColor(.gray)
                } else if let d = detail {
                    if !d.vodContent.isEmpty {
                        Text(d.vodContent)
                            .font(.callout)
                            .foregroundColor(Color(white: 0.75))
                            .lineLimit(5)
                    }
                    if !d.vodActor.isEmpty {
                        infoRow("主演", d.vodActor)
                    }
                    episodesSection(d)
                }
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle(detail?.vodName ?? vodItem.vodName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playItem) { item in
            PlayerView(item: item)
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: URL(string: vodItem.vodPic)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.12)
                }
            }
            .frame(width: 110, height: 155)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text(detail?.vodName ?? vodItem.vodName)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                tagRow
                if let year = effectiveDate { Text("年份：\(year)").font(.footnote).foregroundColor(.gray) }
                if let area = detail?.vodArea, !area.isEmpty { Text("地区：\(area)").font(.footnote).foregroundColor(.gray) }
            }
            Spacer()
        }
    }

    private var effectiveDate: String? {
        let y = detail?.vodYear ?? vodItem.vodYear
        return y.isEmpty ? nil : y
    }

    @ViewBuilder
    private var tagRow: some View {
        HStack(spacing: 8) {
            if let r = detail?.vodRemarks ?? (vodItem.vodRemarks.isEmpty ? nil : vodItem.vodRemarks) {
                TagView(text: r, accent: true)
            }
        }
    }

    @ViewBuilder
    private func episodesSection(_ d: VodItem) -> some View {
        let sources = PlayUrlParser.parse(from: d.vodPlayFrom, url: d.vodPlayUrl)
        if sources.isEmpty {
            Text("无可用播放地址").foregroundColor(.gray)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if sources.count > 1 {
                    Picker("线路", selection: $selectedSourceIndex) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { idx, src in
                            Text(src.name).tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                let source = sources[min(selectedSourceIndex, sources.count - 1)]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(Array(source.episodes.enumerated()), id: \.element.id) { idx, ep in
                        Button {
                            startPlayback(makeItem(urlString: ep.url, name: ep.name,
                                                   vod: d, sources: sources,
                                                   sourceIndex: min(selectedSourceIndex, sources.count - 1),
                                                   episodeIndex: idx))
                        } label: {
                            Text(ep.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color(white: 0.15))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundColor(.gray)
            Text(value).font(.footnote).foregroundColor(Color(white: 0.8)).lineLimit(2)
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        if let d = await state.getDetail(vodItem, site: sourceSite) {
            detail = d
            if let entry = autoResume {
                autoStartResume(d, entry)
            }
        } else {
            errorText = "加载详情失败"
        }
        loading = false
    }

    // MARK: - 播放辅助

    private func currentSite() -> Site {
        sourceSite ?? state.selectedSite
            ?? Site(key: "", name: "", type: 1, api: "", searchable: nil)
    }

    private func makeItem(urlString: String, name: String, vod: VodItem,
                          sources: [PlaySource], sourceIndex: Int, episodeIndex: Int) -> PlayerItem? {
        guard let u = URL(string: urlString) else { return nil }
        let site = currentSite()
        return PlayerItem(url: u, siteKey: site.key, siteName: site.name, siteApi: site.api,
                          vodId: vod.vodId, vodName: vod.vodName, vodPic: vod.vodPic,
                          sourceIndex: sourceIndex, episodeIndex: episodeIndex,
                          episodeName: name)
    }

    /// 选集与自动续播共用：先转横屏，窗口旋转后再弹出全屏播放页
    private func startPlayback(_ item: PlayerItem?) {
        guard let item = item else { return }
        OrientationHelper.setLandscape(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            playItem = item
        }
    }

    /// 历史续播：定位上次的线路/集数，seek 到上次进度
    private func autoStartResume(_ d: VodItem, _ entry: HistoryEntry) {
        let sources = PlayUrlParser.parse(from: d.vodPlayFrom, url: d.vodPlayUrl)
        guard !sources.isEmpty else { return }              // 源已失效：只展示详情页
        let si = min(max(entry.sourceIndex, 0), sources.count - 1)
        let eps = sources[si].episodes
        guard !eps.isEmpty else { return }
        let ei = min(max(entry.episodeIndex, 0), eps.count - 1)  // 集数越界 → clamp
        guard let u = URL(string: eps[ei].url) else { return }
        let site = currentSite()
        let item = PlayerItem(url: u, siteKey: site.key.isEmpty ? entry.siteKey : site.key,
                              siteName: site.name.isEmpty ? entry.siteName : site.name,
                              siteApi: site.api.isEmpty ? entry.siteApi : site.api,
                              vodId: d.vodId, vodName: d.vodName, vodPic: d.vodPic,
                              sourceIndex: si, episodeIndex: ei,
                              episodeName: eps[ei].name,
                              resumeAt: entry.position)
        startPlayback(item)
    }
}

struct TagView: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(accent ? Color.red.opacity(0.85) : Color(white: 0.2))
            .foregroundColor(.white)
            .cornerRadius(5)
    }
}
