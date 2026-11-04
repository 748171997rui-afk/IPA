import SwiftUI
import UIKit

// 方向锁实现：App 层根据 OrientationState.mask 返回支持的方向
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationState.mask
    }
}

@main
struct TVBoxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showHistory = false
    @State private var loadedOnce = false

    var body: some View {
        NavigationStack {
            HomeView(showSettings: $showSettings)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("TVBox").font(.headline).foregroundColor(.red)
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await state.loadConfig()
        }
    }
}

// MARK: - 首页：源选择 + 分类 + 视频网格

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @Binding var showSettings: Bool

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            siteBar
            if !state.categories.isEmpty {
                categoryBar
            }
            content
        }
        .background(Color.black)
    }

    // 源横条
    private var siteBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if state.sites.isEmpty && state.configLoading {
                    ProgressView().padding(.vertical, 10)
                }
                ForEach(state.sites, id: \.key) { site in
                    let selected = state.selectedSite?.key == site.key
                    Button {
                        Task { await state.selectSite(site) }
                    } label: {
                        Text(site.name)
                            .font(.system(size: 13, weight: selected ? .bold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Color.red : Color(white: 0.15))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // 分类横条：点击进入独立分类页（该分类下的影片）
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let site = state.selectedSite {
                    ForEach(state.categories, id: \.typeId) { cat in
                        NavigationLink {
                            CategoryView(site: site, category: cat)
                        } label: {
                            CategoryChip(text: cat.typeName, selected: false, action: {})
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.configLoading || state.listLoading && state.vods.isEmpty {
            Spacer()
            ProgressView("加载中…")
            Spacer()
        } else if let err = state.configError {
            Spacer()
            ErrorView(message: err) {
                Task { await state.loadConfig() }
            }
            Spacer()
        } else if let err = state.listError {
            Spacer()
            ErrorView(message: err) {
                Task { await state.reloadList() }
            }
            Spacer()
        } else if state.vods.isEmpty {
            Spacer()
            Text("暂无内容").foregroundColor(.gray)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(state.vods) { vod in
                        NavigationLink {
                            DetailView(vodItem: vod)
                        } label: {
                            PosterCard(vod: vod)
                        }
                        .buttonStyle(.plain)
                    }
                    if state.page < state.totalPages {
                        Button {
                            Task { await state.loadMore() }
                        } label: {
                            VStack(spacing: 6) {
                                if state.listLoading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                    Text("加载更多 (\(state.page)/\(state.totalPages))")
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
}

struct CategoryChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.red : Color(white: 0.15))
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }
}

// MARK: - 海报卡片

struct PosterCard: View {
    let vod: VodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: vod.vodPic)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    ZStack {
                        Color(white: 0.12)
                        Image(systemName: "film").foregroundColor(.gray)
                    }
                default:
                    ZStack {
                        Color(white: 0.12)
                        ProgressView()
                    }
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if !vod.vodRemarks.isEmpty {
                    Text(vod.vodRemarks)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            Text(vod.vodName)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundColor(.white)
        }
    }
}

// MARK: - 错误提示

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.yellow)
            Text(message)
                .font(.callout)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}
