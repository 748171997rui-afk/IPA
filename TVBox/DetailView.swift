import SwiftUI

struct PlayerItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct DetailView: View {
    @EnvironmentObject var state: AppState
    let vodItem: VodItem
    /// 聚合搜索结果的来源站点；nil = 当前选中源
    var sourceSite: Site? = nil

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
            PlayerView(url: item.url)
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
                    ForEach(source.episodes) { ep in
                        Button {
                            if let u = URL(string: ep.url) {
                                // 先转横屏，窗口旋转后再弹出全屏播放页
                                OrientationHelper.setLandscape(true)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    playItem = PlayerItem(url: u)
                                }
                            }
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
        } else {
            errorText = "加载详情失败"
        }
        loading = false
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
