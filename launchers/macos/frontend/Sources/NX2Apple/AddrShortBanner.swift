// S2Arm（不是上游文件）：「地址空间不够这款」提示条（Mac）。宿主命中时只打黄行、照常起局（Mac 没有确认页），启动器收到作业层 notice addr_short 后
//   在屏幕顶部弹这条：不抢焦点（非激活面板）、浮在全屏游戏之上、15 秒后自己收，点一下也收。不用系统通知（要先弹授权框）
import AppKit
import SwiftUI

@MainActor
enum AddrShortBanner {
    private static var panel: NSPanel?

    static func show(title: String, body: String, seconds: Double = 15) {
        if NSClassFromString("XCTestCase") != nil { return }   // 单测里只看模型标记，不真弹窗
        hide()
        let view = NSHostingView(rootView: Banner(title: title, detail: body) { hide() })
        let size = view.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: max(size.height, 96))),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = false
        p.contentView = view
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - p.frame.width / 2, y: screen.maxY - p.frame.height - 24))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if panel === p { hide() } }
    }

    static func hide() { panel?.orderOut(nil); panel = nil }

    private struct Banner: View {
        let title: String, detail: String, close: () -> Void
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16).frame(width: 560, alignment: .leading)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle()).onTapGesture { close() }
            .accessibilityElement(children: .combine).accessibilityIdentifier("play.addrShort")
        }
    }
}
