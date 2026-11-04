import SwiftUI
import AVKit
import UIKit

// 全局方向锁：默认竖屏，播放页横屏
final class OrientationState {
    static var mask: UIInterfaceOrientationMask = .portrait
}

enum OrientationHelper {
    static func setLandscape(_ landscape: Bool) {
        OrientationState.mask = landscape ? .landscapeRight : .portrait
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: OrientationState.mask))
            // 关键配套调用：通知根控制器方向约束已变化（UIViewController 上的复数方法）
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

struct PlayerView: View {
    let item: PlayerItem
    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true
    @State private var lastPos: Double = 0
    @State private var lastDur: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerViewController(url: item.url,
                                      resumeAt: item.resumeAt,
                                      onTimeUpdate: { pos, dur in
                                          lastPos = pos
                                          lastDur = dur
                                          saveHistory()
                                      })
                .ignoresSafeArea()

            if controlsVisible {
                VStack {
                    HStack {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.leading, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible.toggle()
            }
            if controlsVisible { scheduleAutoHide() }
        }
        .onAppear { scheduleAutoHide() }
        .onDisappear {
            saveHistory()
            // 兜底：任何路径退出都恢复竖屏
            OrientationHelper.setLandscape(false)
        }
    }

    private func saveHistory() {
        guard !item.siteKey.isEmpty, !item.vodId.isEmpty else { return }
        let site = Site(key: item.siteKey, name: item.siteName, type: 1,
                        api: item.siteApi, searchable: nil)
        let vod = VodItem(vodId: item.vodId, vodName: item.vodName, vodPic: item.vodPic)
        HistoryStore.shared.record(site: site, vod: vod,
                                   sourceIndex: item.sourceIndex,
                                   episodeIndex: item.episodeIndex,
                                   episodeName: item.episodeName,
                                   position: lastPos, duration: lastDur)
        HistoryStore.shared.removeIfFinished(siteKey: item.siteKey, vodId: item.vodId,
                                             position: lastPos, duration: lastDur)
    }

    private func close() {
        controlsVisible = true
        saveHistory()
        // 先转回竖屏，再收起播放页（避免 dismissal 后窗口才旋转）
        OrientationHelper.setLandscape(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }

    private func scheduleAutoHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }
}

struct VideoPlayerViewController: UIViewControllerRepresentable {
    let url: URL
    var resumeAt: Double = 0
    var onTimeUpdate: ((Double, Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var statusObs: NSKeyValueObservation?
        var timeObs: Any?
        var didSeek = false
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let avItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: avItem)
        vc.player = player
        player.play()

        // 等 readyToPlay 再 seek（直接 seek 会静默失败；HLS 此时 duration 才可靠）
        context.coordinator.statusObs = avItem.observe(\.status, options: [.new]) { it, _ in
            guard !context.coordinator.didSeek,
                  it.status == .readyToPlay,
                  resumeAt > 5 else { return }
            context.coordinator.didSeek = true
            var target = resumeAt
            let dur = it.duration.seconds
            if dur.isFinite && dur > 10 {
                target = min(target, dur - 5)
            }
            if target > 0 {
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        // 每 5 秒上报播放进度（duration 过 isFinite 守卫，HLS 未加载首分片时是 NaN）
        context.coordinator.timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { t in
                let d = player.currentItem?.duration.seconds ?? 0
                onTimeUpdate?(t.seconds, d.isFinite ? d : 0)
            }
        return vc
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.statusObs?.invalidate()
        if let t = coordinator.timeObs {
            vc.player?.removeTimeObserver(t)
        }
        coordinator.timeObs = nil
        vc.player?.pause()
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
