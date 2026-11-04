import SwiftUI

/// 独立分类页：展示某站点某分类下的影片（独立状态，不干扰首页"全部"列表）
struct CategoryView: View {
    let site: Site
    let category: VodClass

    @State private var vods: [VodItem] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var loading = false
    @State private var errorText: String?
    @State private var loadedOnce = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        Group {
            if loading && vods.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("加载中…")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorText, vods.isEmpty {
                VStack {
                    Spacer()
                    ErrorView(message: err) {
                        Task { await load(1) }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vods.isEmpty {
                VStack {
                    Spacer()
                    Text("该分类暂无内容").foregroundColor(.gray)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(vods) { vod in
                            NavigationLink {
                                DetailView(vodItem: vod, sourceSite: site)
                            } label: {
                                PosterCard(vod: vod)
                            }
                            .buttonStyle(.plain)
                        }
                        if page < totalPages {
                            Button {
                                Task { await load(page + 1) }
                            } label: {
                                VStack(spacing: 6) {
                                    if loading {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                        Text("加载更多 (\(page)/\(totalPages))")
                                            .font(.caption)
                                    }
                                }
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, minHeight: 120)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(category.typeName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await load(1)
        }
    }

    private func load(_ p: Int) async {
        guard !loading else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let resp = try await ApiClient.shared.getVodList(
                api: site.api, categoryId: category.typeId, page: p)
            if p == 1 {
                vods = resp.list
            } else {
                let known = Set(vods.map(\.id))
                vods.append(contentsOf: resp.list.filter { !known.contains($0.id) })
            }
            page = p
            totalPages = max(resp.pagecount, 1)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
