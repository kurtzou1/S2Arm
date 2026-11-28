// S2Arm × NX2Apple 的 Mac 入口：只做装配——定数据目录 / 资源 / 引擎位置，建 S2Arm 作业客户端，交给 NX2Apple 派生界面。
// 界面在 launchers/macos/frontend（NX2Apple 快照，见其 UPSTREAM.md），与作业层的接缝在 launchers/macos/adapter。
// 11-07 起是发版缺省（build_app.py）；旧 S2ArmLauncher 留作回退（S2A_APP_FRONTEND=launcher）。
import AppKit
import SwiftUI
import NX2AppleUI
import S2ArmAppleAdapter

enum Brand {
    static let name = "S2Arm × NX2Apple"
    static let credits = """
    S2Arm — Switch 2 games on Apple silicon.
    Interface derived from NX2Apple (MIT, LNPANDY and NX2Apple contributors; the reference port, seedds; d2r-mobile, jhaizhou).
    Manrope typeface: SIL Open Font License 1.1.
    """
}

enum AppSetup {
    static func defaultWindowSize(displaySize: CGSize, visibleSize: CGSize) -> CGSize {
        // Use the whole screen's height; only shrink further when a narrow display cannot fit 16:9.
        let height = min(displaySize.height * 0.7, min(visibleSize.height, visibleSize.width * 9 / 16))
        return CGSize(width: height * 16 / 9, height: height)
    }

    /// 源码树根（由本文件位置推出）只编进调试版：发布版不带出包机的源码绝对路径（同旧启动器 Store.sourceTree）。
    static var sourceTree: URL? {
        #if DEBUG
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }; return u
        #else
        return nil
        #endif
    }

    /// `--data-root=<目录>` / `--data-root <目录>`：同旧启动器（Store.dataRoot），缺省 ~/Library/Application Support/S2Arm，两个前端读同一套库。
    static func dataRoot(_ args: [String]) -> URL {
        if let a = args.first(where: { $0.hasPrefix("--data-root=") }) { return URL(fileURLWithPath: String(a.dropFirst("--data-root=".count))) }
        if let i = args.firstIndex(of: "--data-root"), args.count > i + 1 { return URL(fileURLWithPath: args[i + 1]) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("S2Arm")
    }

    static func environment() -> JobEnvironment {
        let privateRoot = dataRoot(CommandLine.arguments)
        try? FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        let resources: URL
        if let r = Bundle.main.resourceURL, Bundle.main.bundleURL.pathExtension == "app" || FileManager.default.fileExists(atPath: r.appendingPathComponent("Jobs/main.py").path) {
            resources = r
        } else {
            resources = sourceTree?.appendingPathComponent("launchers/macos") ?? Bundle.main.bundleURL
        }
        var env = JobEnvironment.load(privateRoot: privateRoot, resources: resources,
                                      buildId: Bundle.main.object(forInfoDictionaryKey: "S2ABuildID") as? String ?? "")
        // 只在源码树里直接跑（swift run）时按源码位置找引擎；.app 里用自带 Engine
        if env.engineDir == nil, Bundle.main.bundleURL.pathExtension != "app", let tree = sourceTree,
           FileManager.default.fileExists(atPath: tree.appendingPathComponent("runtime/include/s2a_native.h").path) {
            env.engineDir = tree.path
        }
        return env
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BackendText.preload()   // 文案资源启动时一次读完：Sparkle「更新并重启」换盘上 .app 时不再去读（0.5.1 退出崩溃）
        // --control（S2ARM_CONTROL=1）= AI / 测试驱动的实例：照常是普通 App，只是不抢焦点（不调 activate）。
        //   原来按后台辅助应用（.accessory）起：这种 App 永远不算活跃，窗口背景的毛玻璃在屏幕上整片变成浅灰、按钮发暗，
        //   人看着像界面卡了一层蒙层（自签走查 11-19）；AI 起的窗口本来就是给人看的，要和玩家自己打开的一样。
        //   S2ARM_CONTROL=1 写进本进程环境，作业层据此让测试起局的 s2arm-host 静默崩溃（pack/jobs/core.py env）
        let args = CommandLine.arguments
        if args.contains("--control") || ProcessInfo.processInfo.environment["S2ARM_CONTROL"] == "1" {
            setenv("S2ARM_CONTROL", "1", 1)
            NSApp.setActivationPolicy(.regular)
            return
        }
        // swift run 起的是裸可执行文件：要成为前台普通 App 才有 Dock 图标和菜单
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct S2ArmAppleApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // 用 @State 只保住同一个 model，不订阅它的变更：@StateObject 会让整个 App body（含应用菜单）在每次进度变化时重建，
    //   展开着的子菜单会被关掉；窗口里的视图和更新菜单各自观察自己要的部分
    @State private var model = S2ArmLauncherModel(client: JobClient(environment: AppSetup.environment()))

    init() { BackendText.preload() }

    var body: some Scene {
        WindowGroup(Brand.name, id: "launcher") {
            S2ArmAppleRootView(model: model, brand: Brand.name)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // 启动时一定开主窗口，不按上次退出时的窗口状态恢复：AppKit 的窗口状态恢复按签名身份记，记着「上次没有窗口」（测试 / 验收按 pid 收掉进程就会留下）时，
        //   下次启动 WindowGroup 不建主窗口、激活也不补；控制口挂在窗口出现后的 startup() 上，control.json 就一直不出
        //   （11-28 发版冷跑验收卡住，v0.6.10 同样；只对这个 bundle id 设 ApplePersistenceIgnoreState 后两次都出窗口）。窗口大小位置照旧（NSWindow Frame）
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: AppSetup.defaultWindowSize(displaySize: context.defaultDisplay.bounds.size,
                                                             visibleSize: context.defaultDisplay.visibleRect.size))
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: Brand.name,
                        .credits: NSAttributedString(string: Brand.credits),
                    ])
                }
                Divider()
                S2ArmUpdateMenu(model: model, activateWindow: activateLauncherWindow)
            }
        }
    }

    private func activateLauncherWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == Brand.name && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "launcher")
        }
    }
}
