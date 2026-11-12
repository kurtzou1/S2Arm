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
        try? FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        // --control（S2ARM_CONTROL=1）= AI / 测试驱动的实例：按后台辅助应用起——不进 Dock、不抢焦点（窗口照建：s2armctl snapshot 截它）。
        //   S2ARM_CONTROL=1 写进本进程环境，作业层据此让测试起局的 s2arm-host 静默崩溃（pack/jobs/core.py env）
        let args = CommandLine.arguments
        if args.contains("--control") || ProcessInfo.processInfo.environment["S2ARM_CONTROL"] == "1" {
            setenv("S2ARM_CONTROL", "1", 1)
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // swift run 起的是裸可执行文件：要成为前台普通 App 才有 Dock 图标和菜单
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct S2ArmAppleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = S2ArmLauncherModel(client: JobClient(environment: AppSetup.environment()))

    var body: some Scene {
        WindowGroup(Brand.name) {
            S2ArmAppleRootView(model: model, brand: Brand.name)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: Brand.name,
                        .credits: NSAttributedString(string: Brand.credits),
                    ])
                }
            }
        }
    }
}
