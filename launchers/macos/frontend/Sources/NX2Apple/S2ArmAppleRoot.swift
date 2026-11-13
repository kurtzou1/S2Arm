// S2Arm（不是上游文件）：本包对外唯一入口。launchers/macos 的 S2ArmApple 可执行 target 只用这里的 public 类型装配，
// 上游各 target 之间的 package 级类型不外露（package 访问级别不跨 SwiftPM 包）。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 窗口的根视图：界面语言（NX2Apple l10n）、库 → 出包 / Play → 运行页 → 回库。
public struct S2ArmAppleRootView: View {
    @ObservedObject private var model: S2ArmLauncherModel
    @StateObject private var loc = Localizer()
    private let brand: String

    public init(model: S2ArmLauncherModel, brand: String) {
        self.model = model
        self.brand = brand
    }

    public var body: some View {
        LauncherView(model: model, brand: brand)
            .environmentObject(loc)
            .onAppear { model.setUILanguage(loc.lang == .zh ? "zh-Hans" : "en") }   // 作业请求带界面语言（JobEnvironment.uiLanguage）：导出文件夹 / 说明等按它出
            .onReceive(loc.objectWillChange.receive(on: RunLoop.main)) { _ in model.setUILanguage(loc.lang == .zh ? "zh-Hans" : "en") }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.shutdownControllerConnection()
            }
    }
}
