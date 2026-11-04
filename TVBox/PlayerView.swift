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
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerViewController(url: url)
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
            // 兜底：任何路径退出都恢复竖屏
            OrientationHelper.setLandscape(false)
        }
    }

    private func close() {
        controlsVisible = true
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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(url: url)
        vc.player = player
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
