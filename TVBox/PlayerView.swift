import SwiftUI
import AVKit
import UIKit

// 全局方向锁：默认竖屏，播放页全屏时切横屏
final class OrientationState {
    static var mask: UIInterfaceOrientationMask = .portrait
}

enum OrientationHelper {
    static func setLandscape(_ landscape: Bool) {
        OrientationState.mask = landscape ? .landscapeRight : .portrait
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: OrientationState.mask))
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientation()
        }
    }
}

struct PlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var isFullscreen = false
    @State private var controlsVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerViewController(url: url)
                .ignoresSafeArea()

            if controlsVisible {
                // 顶部：返回按钮
                VStack {
                    HStack {
                        Button {
                            exitFullscreenIfNeeded()
                            dismiss()
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
                    // 底部：全屏切换按钮
                    HStack {
                        Spacer()
                        Button {
                            toggleFullscreen()
                        } label: {
                            Image(systemName: isFullscreen
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                    }
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
        .onDisappear { exitFullscreenIfNeeded() }
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        OrientationHelper.setLandscape(isFullscreen)
    }

    private func exitFullscreenIfNeeded() {
        if isFullscreen {
            isFullscreen = false
            OrientationHelper.setLandscape(false)
        }
        OrientationState.mask = .portrait
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
