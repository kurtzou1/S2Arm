// S2Arm（不是上游文件）：装到 iPhone 前的清单（installCheck 作业：iPhone 版做好了没有、签名团队、连上 / 信任 / 开发者模式），
// 每几秒重查一次（玩家在手机上点信任、开开发者模式后自动打勾），iPhone 版做好就能点「开始装」，其余项只提示（install 作业，跑在作业页、可停）。
// 卡片同 NXLauncher（CardGroup / CardRow）。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct InstallView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    @State private var showRemoveConfirm = false
    @State private var showRestoreConfirm = false

    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private static let pollSeconds: UInt64 = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(model.installKey("s2arm.install.title"))).font(.manrope(26, .heavy)).tracking(-0.6)
                    if let game { Text(game.name).font(.manrope(14)).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.installChecking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            if let error = model.installError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30).padding(.bottom, 12)
            }
            if model.installDone == gameID { doneContent } else if let job = installJob {
                VStack(alignment: .leading, spacing: 10) {
                    // 手机作业三态统一（PhoneJobPanel）：钥匙串提示只在后端标了 keychainPrompt 的阶段挂（#266），在组件里
                    ScrollView { PhoneJobPanel(model: model, session: job).frame(maxWidth: .infinity, alignment: .leading) }
                    // 装机在后台照跑：关掉弹层回游戏库，顶部胶囊「正在装到 iPhone · 查看进度」能回来（#308，Mac 与 Windows 同一套）
                    HStack { Spacer(); Button(text("install.background")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.background") }
                }
                .padding(.horizontal, 30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 上一次手机作业没成：同一个结局组件（原因 + 下一步 + 复制错误摘要 + 详细过程），下面照旧是清单，改好了直接再点
                    if let failed = model.inlineFailure, [.install, .installRemove, .installRestore].contains(failed.kind),
                       let last = model.lastPhoneSession, last.kind == failed.kind {
                        PhoneJobPanel(model: model, session: last)
                    }
                    // 装到哪台：和出包页同一行；选过的那台不在线时如实说、让玩家改选（清单只看这台、每次现查）
                    TargetDeviceRow(model: model).onChange(of: model.installDeviceID) { _ in model.checkInstall(gameID) }
                    if let r = model.installReadiness {
                        CardGroup(loc.t("s2arm.install.checklist"), footnote: footnote(r)) {
                            ForEach(r.items) { item in
                                CardRow(loc.backend(item.title), detail: loc.backend(item.detail), dot: dot(item)) {
                                    if !item.ok, item.id == "package", let game {
                                        Button(loc.t("s2arm.action.ipa")) { dismiss(); model.exportFor = game.id }
                                            .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy).busyHint(model)
                                    }
                                    if !item.ok, item.id == "appleId" {
                                        // 团队号手填 / 引导项目收进环境检查「装到 iPhone 的方式」（v0.3.0）：这里只给一个去设置
                                        Button(BackendText.launcherText("install.mode.go_settings", language: loc.lang == .zh ? "zh-Hans" : "en")) {
                                            dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showEnvironment = true }
                                        }
                                        .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.goSettings")
                                        Button(text("install.apple.open")) {
                                            if case .open(let url) = model.provider.environment.repairStep(for: "openXcode") { NSWorkspace.shared.open(url) }
                                        }
                                        .buttonStyle(LauncherSecondaryButtonStyle())
                                    }
                                }
                                if item.id != r.items.last?.id { CardDivider() }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("install.container_note")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(text("install.legacy_note")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let game, game.iphoneRestorable {
                        // 只换宿主后（手机上的 S2Arm 换了新版运行层）新版不好用：装回上一版
                        Button(text("install.restore")) { showRestoreConfirm = true }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .disabled(model.busy).busyHint(model)
                            .confirmationDialog(text("install.restore_title"), isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                                Button(text("install.restore_confirm")) { model.restorePhone(game) }
                                Button(loc.t("launch.done"), role: .cancel) {}
                            } message: {
                                Text(text("install.restore_body"))
                            }
                    }
                    if let game {
                        Button(text("install.remove")) { showRemoveConfirm = true }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .disabled(model.busy).busyHint(model)
                            .confirmationDialog(text("install.remove_title"), isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                                Button(text("install.remove_confirm"), role: .destructive) { model.removeFromPhone(game) }
                                Button(loc.t("launch.done"), role: .cancel) {}
                            } message: {
                                Text(text("install.remove_body"))
                            }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 24)
            }
            // 认得出的风险（会挤掉别处装的游戏 / 存档没能备份……）在结局页里问（PhoneJobPanel），不弹框
            }
            Divider().opacity(0.3)
            if model.installDone == gameID {
                HStack { Spacer(); Button(text("install.close")) { model.installDone = nil; dismiss() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    .padding(.horizontal, 30).padding(.vertical, 16)
            } else if let job = installJob {
                HStack { Spacer(); Button(loc.t("s2arm.job.cancel")) { model.stop() }.buttonStyle(LauncherSecondaryButtonStyle()).disabled(job.phase == .stopping) }
                    .padding(.horizontal, 30).padding(.vertical, 16)
            } else {
            HStack(spacing: 14) {
                Text(loc.t("s2arm.install.note")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 8)
                if let ipa = model.installReadiness?.ipaPath, !ipa.isEmpty {
                    Button(loc.t("s2arm.export.revealIpa")) { model.revealIpa(ipa) }
                        .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.revealIpa")
                }
                Button(loc.t("launch.done")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle())
                Button {
                    if let game { model.clearInlineFailure(); model.install(game) }
                } label: {
                    Text(loc.t("s2arm.install.start")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                // 不按清单置灰（维护者 11-11：玩家主动点装机不许前端挡）：清单可能是旧的（在外面登录好、插好线回来仍灰），
                // 真做不下去的（没出 iPhone 版、没连设备、签名失败）作业层开头自己判、回真实原因；只在有作业在跑时置灰
                .disabled(model.busy)
                .opacity(model.busy ? 0.45 : 1)
                .busyHint(model)
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
            }
        }
        .task {
            // 开着、且启动器在前台时每几秒问一次（玩家插手机 / 点信任后界面自己变过来）；切到别的程序就不问（剃刀 M5：原先后台也一直起作业），
            //   切回来立刻问一次（下面 didBecomeActive）；关掉页面 Task 自动取消
            while !Task.isCancelled {
                if NSApp.isActive, installJob == nil, model.installDone != gameID { model.checkInstall(gameID) }
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if installJob == nil, model.installDone != gameID { model.checkInstall(gameID) }
        }
        .onAppear { if model.phoneResult?.gameID == gameID { model.phoneResult = nil } }   // 回来看过结果，顶部胶囊收起
        .frame(width: 600, height: 520)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    private var installJob: JobSession? { (model.session?.kind == .install || model.session?.kind == .installRemove || model.session?.kind == .installRestore) ? model.session : nil }
    private func text(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    @ViewBuilder private var doneContent: some View {
        if let last = model.lastPhoneSession, last.phase == .finished(.completed), last.gameID == gameID {
            ScrollView {
                PhoneJobPanel(model: model, session: last, notes: doneNotes).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { legacyDone }
    }

    /// 装好以后的附加提示：只传到手机、要打开 S2Arm 才装完 / 第一次打开前信任开发者 / 免费 Apple ID 7 天到期
    private var doneNotes: [String] {
        guard model.lastPhoneSession?.kind == .install, (model.phoneOutcome?.exportFolder ?? "").isEmpty else { return [] }   // 导出的说明在成功页自己那几行
        var n: [String] = []
        if model.installOpenToFinish { n.append(text("install.done.open")) }
        n.append(text("install.done.trust"))
        if game?.iphoneFree == true { n.append(text("install.done.free")) }
        return n
    }

    private var legacyDone: some View {
        VStack(spacing: 16) {
            SuccessSeal()
            // 写实际装上的那台（装机结果的 deviceKind / deviceName），不写死 iPhone
            Text(text("install.done.title").replacingOccurrences(of: "{0}", with: model.installedTo.isEmpty ? "iPhone / iPad" : model.installedTo))
                .font(.manrope(30, .heavy)).tracking(-0.8).multilineTextAlignment(.center).accessibilityIdentifier("install.done.title")
            if model.installOpenToFinish {
                Text(text("install.done.open")).font(.manrope(15, .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(text("install.done.trust")).font(.manrope(14)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if game?.iphoneFree == true {
                Text(text("install.done.free")).font(.manrope(13)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dot(_ item: InstallItem) -> Color {
        item.ok ? LauncherPalette.ready : (item.waiting ? LauncherPalette.unbuilt : LauncherPalette.building)
    }

    private func footnote(_ r: InstallReadiness) -> String {
        var parts: [String] = []
        if !r.device.isEmpty { parts.append(String(format: loc.t("s2arm.install.device"), r.device)) }
        if !r.account.isEmpty { parts.append(String(format: loc.t("s2arm.install.account"), r.account)) }
        return parts.joined(separator: " · ")
    }
}
