import SwiftUI

struct SearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var searched = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("聚合搜索全部源…", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await doSearch() } }
                    Button("搜索") {
                        Task { await doSearch() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(12)

                content
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if state.searching {
            Spacer()
            ProgressView()
            Spacer()
        } else if state.searchResults.isEmpty {
            Spacer()
            Text(searched ? "全部源都没有找到相关内容" : "聚合搜索：同时搜索 \(state.sites.count) 个源")
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        } else {
            ScrollView {
                Text("共 \(state.searchResults.count) 条结果")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(state.searchResults) { hit in
                        NavigationLink {
                            DetailView(vodItem: hit.item, sourceSite: hit.site)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterCard(vod: hit.item)
                                Text(hit.site.name)
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private func doSearch() async {
        searched = true
        await state.search(keyword)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var urlInput = ""
    @State private var applying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("数据源") {
                    Button {
                        Task { await useBundled() }
                    } label: {
                        HStack {
                            Image(systemName: "iphone.circle")
                            Text("使用内置直连源（推荐，免配置）")
                        }
                    }
                    if state.apiURL == AppState.bundledAPI {
                        Text("当前：内置源（暴风/索尼/量子/非凡）")
                            .font(.footnote)
                            .foregroundColor(.green)
                    }
                }
                Section("远程接口地址（TVBox 配置 JSON）") {
                    TextField("https://…", text: $urlInput, axis: .vertical)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(3...6)
                        .font(.system(size: 13))
                }
                Section {
                    Button {
                        Task { await apply() }
                    } label: {
                        HStack {
                            Text("保存并重新加载")
                            if applying { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(urlInput.isEmpty || applying)
                }
                Section("说明") {
                    Text("iOS 版仅支持直连 JSON 源（type 0/1 苹果CMS接口）；配置中的 csp/js 爬虫源无法在 iOS 运行，会自动过滤。")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    if let site = state.selectedSite {
                        Text("当前源：\(site.name)")
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { urlInput = state.apiURL }
        }
        .preferredColorScheme(.dark)
    }

    private func apply() async {
        applying = true
        state.apiURL = urlInput.trimmingCharacters(in: .whitespaces)
        await state.loadConfig()
        applying = false
        dismiss()
    }

    private func useBundled() async {
        state.apiURL = AppState.bundledAPI
        await state.loadConfig()
        dismiss()
    }
}
