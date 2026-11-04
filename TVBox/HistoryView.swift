import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("暂无播放记录")
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            row(entry)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black)
            .navigationTitle("播放历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空", role: .destructive) {
                        showClearConfirm = true
                    }
                    .disabled(store.entries.isEmpty)
                }
            }
            .confirmationDialog("确定清空全部播放历史？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clear() }
                Button("取消", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ e: HistoryEntry) -> some View {
        NavigationLink {
            DetailView(vodItem: VodItem(vodId: e.vodId, vodName: e.vodName, vodPic: e.vodPic),
                       sourceSite: Site(key: e.siteKey, name: e.siteName, type: 1,
                                        api: e.siteApi, searchable: nil),
                       autoResume: e)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: e.vodPic)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color(white: 0.12)
                            Image(systemName: "film").foregroundColor(.gray)
                        }
                    }
                }
                .frame(width: 56, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(e.vodName)
                        .font(.body)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(e.episodeName) · 已看 \(HistoryEntry.fmt(e.position)) / \(HistoryEntry.fmt(e.duration))")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text(e.updatedText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.remove(e)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}
