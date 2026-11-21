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
    var onOpenSettings: (() -> Void)? = nil
    @State private var showRemoveConfirm = false
    @State private var showRestoreConfirm = false

    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private static let pollSeconds: UInt64 = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // 导出自签包时标题照导出写，不写「推到 iPhone」。
                LauncherSheetHeading(exportJob != nil ? text("library.hero.selfSign") : loc.t(model.installKey("s2arm.install.title")), subtitle: game?.name ?? "")
                if model.installChecking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.top, LauncherTheme.Space.page).padding(.bottom, 20)
            if let error = model.installError {
                Text(loc.backend(error)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, 12)
            }
            if let job = exportJob {
                // 导出自签包（11-15 维护者：1 下开始导出，进度 / 完成 / 失败都只在这一张卡上，不出现装机清单、Apple ID、数据线、装回、删除）
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView { PhoneJobPanel(model: model, session: job, showsOperation: false).frame(maxWidth: .infinity, alignment: .leading) }
                    if case .finished = job.phase {} else {   // 跑着才给「放到后台继续」，跑完底栏「完成」
                        HStack { Spacer(); Button(text("install.background")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.background").controllerShortcut(.back) }
                    }
                }
                .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.installDone == gameID { doneContent } else if let job = installJob {
                VStack(alignment: .leading, spacing: 10) {
                    // 手机作业三态统一（PhoneJobPanel）：钥匙串提示只在后端标了 keychainPrompt 的阶段挂（#266），在组件里
                    ScrollView { PhoneJobPanel(model: model, session: job).frame(maxWidth: .infinity, alignment: .leading) }
                    // 装机在后台照跑：关掉弹层回游戏库，顶部胶囊「正在推到 iPhone · 查看进度」能回来（#308，Mac 与 Windows 同一套）
                    HStack { Spacer(); Button(text("install.background")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.background").controllerShortcut(.back) }
                }
                .padding(.horizontal, LauncherTheme.Space.page).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 上一次手机作业没成：同一个结局组件（原因 + 下一步 + 复制错误摘要 + 详细过程），下面照旧是清单，改好了直接再点
                    if let failed = model.inlineFailure, [.install, .installRemove, .installRestore].contains(failed.kind),
                       let last = model.lastPhoneSession, last.kind == failed.kind {
                        PhoneJobPanel(model: model, session: last)
                    }
                    // 装到哪台：和出包页同一行；选过的那台不在线时如实说、让玩家改选（清单只看这台、每次现查）。清单「选设备」点过来时亮边框
                    TargetDeviceRow(model: model).onChange(of: model.installDeviceID) { _ in model.pickDeviceFocus = false; model.checkInstall(gameID) }
                        .padding(model.pickDeviceFocus ? 8 : 0)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cream, lineWidth: model.pickDeviceFocus ? 1.5 : 0))
                        .id(Self.deviceRowID)
                    // 这款推成通用 S2Arm 里的一款还是独立 App（0.6.3）：缺省跟随设置，单款可改
                    if let game { InstallLayoutRow(model: model, gameId: game.id) }
                    if let r = model.installReadiness {
                        CardGroup(loc.t("s2arm.install.checklist"), footnote: footnote(r)) {
                            ForEach(r.items) { item in
                                CardRow(loc.backend(item.title), detail: loc.backend(item.detail), dot: dot(item)) {
                                    // 按钮只按作业层给的动作 / 官方网页画（落点表 install_landing），点了走同一个派发（控制口 /install-action 也走它）；
                                    //   只是去出包页 / 登录 / 看说明 / 开网页，别的作业在跑也不置灰
                                    if let action = item.action, S2ArmLauncherModel.installActions.contains(action) {
                                        Button(actionTitle(action)) { model.performInstallAction(action, gameId: gameID) }
                                            .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("install.action." + item.id)
                                    } else if let url = item.url.flatMap(URL.init(string:)) {
                                        Button(text("action.open_official")) { NSWorkspace.shared.open(url) }
                                            .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("install.url." + item.id)
                                    }
                                }
                                if item.id != r.items.last?.id { CardDivider() }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("install.container_note")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(text("install.legacy_note")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let game, game.iphoneRestorable {
                        // 只换宿主后（手机上的 S2Arm 换了新版运行层）新版不好用：装回上一版
                        Button(text("install.restore")) { showRestoreConfirm = true }
                            .controllerButtonStyle(LauncherSecondaryButtonStyle())
                            .disabled(queued)
                            .confirmationDialog(text("install.restore_title"), isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                                Button(text("install.restore_confirm")) { model.restorePhone(game) }
                                Button(loc.t("launch.done"), role: .cancel) {}
                            } message: {
                                Text(text("install.restore_body"))
                            }
                    }
                    if let game {
                        Button(text("install.remove")) { showRemoveConfirm = true }
                            .controllerButtonStyle(LauncherSecondaryButtonStyle())
                            .disabled(queued)
                            .confirmationDialog(text("install.remove_title"), isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                                Button(text("install.remove_confirm"), role: .destructive) { model.removeFromPhone(game) }
                                Button(loc.t("launch.done"), role: .cancel) {}
                            } message: {
                                Text(text("install.remove_body"))
                            }
                    }
                }
                .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section)
            }
            .onChange(of: model.pickDeviceFocus) { on in if on { withAnimation { proxy.scrollTo(Self.deviceRowID, anchor: .top) } } }
            .onAppear { if model.pickDeviceFocus { proxy.scrollTo(Self.deviceRowID, anchor: .top) } }
            }
            // 认得出的风险（会挤掉别处装的游戏 / 存档没能备份……）在结局页里问（PhoneJobPanel），不弹框
            }
            Divider().opacity(0.3)
            if let job = exportJob {
                HStack {
                    Spacer()
                    if case .finished = job.phase {
                        Button(loc.t("launch.done")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger, .back)
                    } else {
                        Button(loc.t("s2arm.job.cancel")) { model.stopPhone() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(job.phase == .stopping).controllerShortcut(.back)
                    }
                }
                .padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
            } else if model.installDone == gameID {
                HStack { Spacer(); Button(text("install.close")) { model.installDone = nil; dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger, .back) }
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
            } else if let job = installJob {
                HStack { Spacer(); Button(loc.t("s2arm.job.cancel")) { model.stopPhone() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(job.phase == .stopping).controllerShortcut(.back) }
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
            } else {
            HStack(spacing: 14) {
                // 已排队（手机上一个作业没完 / 这款正在出包）：说一句，出完 / 前一个装完自动接着装
                Text(queued ? text("install.queued") : loc.t("s2arm.install.note")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier(queued ? "install.queued" : "install.note")
                Spacer(minLength: 8)
                if let ipa = model.installReadiness?.ipaPath, !ipa.isEmpty {
                    Button(loc.t("s2arm.export.revealIpa")) { model.revealIpa(ipa) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.revealIpa").controllerShortcut(.secondary)
                }
                Button(loc.t("launch.done")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerShortcut(.rightTrigger, .back, focused: true)
                Button(queued ? text("install.start.queued") : loc.t("s2arm.install.start")) {
                    if let game { model.clearInlineFailure(); model.install(game) }
                }
                .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                // 不按清单置灰（维护者 11-11：玩家主动点装机不许前端挡）：清单可能是旧的（在外面登录好、插好线回来仍灰），
                // 真做不下去的（没出 iPhone 版、没连设备、签名失败）作业层开头自己判、回真实原因。
                // 别的作业在跑不挡（11-16 维护者「出包时也能装别的游戏」）：手机上一个作业没完 / 这款正在出包就排队，只有这款已排上时置灰
                .disabled(queued)
                .opacity(queued ? 0.45 : 1)
            }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
            }
        }
        .onExitCommand { dismiss() }
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
        .onAppear {
            if model.phoneResult?.gameID == gameID { model.phoneResult = nil }   // 回来看过结果，顶部胶囊收起
            model.installViewOpen = gameID
        }
        .onDisappear {
            if model.installViewOpen == gameID { model.installViewOpen = nil }
            model.installHelp = nil; model.pickDeviceFocus = false
            if model.appleLoginHost == "install" { model.closeAppleLogin() }
        }
        // 清单动作要离开装机窗（去出包页 / 去设置的证书一栏）：先关自己，再去；去设置的关掉后回到这里（同原先「去设置」）
        .onChange(of: model.installLeave) { leave in
            guard let leave else { return }
            if case .settings = leave { onOpenSettings?() }
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.applyInstallLeave(leave) }
        }
        // 信任 / 开发者模式怎么做：说明就是清单这一项的那句（作业层 S_TRUST / S_DEV_MODE）
        .alert(helpItem.map { loc.backend($0.title) } ?? "", isPresented: Binding(get: { model.installHelp != nil }, set: { if !$0 { model.installHelp = nil } })) {
            Button(text("install.help.ok")) { model.installHelp = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(helpItem.map { loc.backend($0.detail) } ?? "") }
        .appleLoginSheet(model, host: "install")
        .launcherSheet()
        .font(LauncherTheme.TypeStyle.detail)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    /// 这一款的「导出自签包」会话：在跑的那个，或刚结束的那个（结局卡按它画）
    private var exportJob: JobSession? {
        guard model.selfSigning else { return nil }
        if let s = model.phoneSession, s.kind == .install, s.gameID == gameID { return s }
        if let s = model.lastPhoneSession, s.kind == .install, s.gameID == gameID { return s }
        return nil
    }
    /// 这一款在手机槽里跑着的装机 / 删除 / 装回（别款的手机作业不画进这款的窗）
    private var installJob: JobSession? {
        guard let s = model.phoneSession, [.install, .installRemove, .installRestore].contains(s.kind), s.gameID == gameID else { return nil }
        return s
    }
    private var queued: Bool { model.phoneQueued(gameID) }
    private static let deviceRowID = "install.deviceRow"
    /// 说明弹窗对应的清单项（trustHelp → trusted，developerModeHelp → developerMode）
    private var helpItem: InstallItem? { model.installReadiness?.items.first { $0.action != nil && $0.action == model.installHelp } }
    /// 按钮文案：落点表给了共享文案键的用它（两端同一句）；表里写 null 的是 Mac 自画的这几个
    private func actionTitle(_ action: String) -> String {
        if let key = BackendText.installLandingActions[action] ?? nil { return text(key) }
        switch action {
        case "appleLogin": return text("install.login.open")
        case "pickDevice": return text("install.action.pickDevice")
        default: return text("install.action.howTo")   // trustHelp / developerModeHelp
        }
    }
    private func text(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }

    @ViewBuilder private var doneContent: some View {
        if let last = model.lastPhoneSession, last.phase == .finished(.completed), last.gameID == gameID {
            ScrollView {
                PhoneJobPanel(model: model, session: last, notes: doneNotes).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, LauncherTheme.Space.page).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { legacyDone }
    }

    /// 装好以后的附加提示：只传到手机、要打开 S2Arm 才装完 / 第一次打开前信任开发者 / 免费 Apple ID 7 天到期
    /// 信任开发者那一步：读到证书名就写「点「<名字>」→ 信任」，读不到退回原来不带名字的说法
    private var trustNote: String {
        model.installTrustName.isEmpty ? text("install.done.trust") : text("install.done.trustNamed").replacingOccurrences(of: "{0}", with: model.installTrustName)
    }

    private var doneNotes: [String] {
        // 更新 / 续签 S2Arm 重装了 App：只补信任那一句（换了团队要重新信任）
        if model.lastPhoneSession?.kind == .installUpdate, (model.phoneOutcome?.exportFolder ?? "").isEmpty, !model.installTrustName.isEmpty { return [trustNote] }
        guard model.lastPhoneSession?.kind == .install, (model.phoneOutcome?.exportFolder ?? "").isEmpty else { return [] }   // 导出的说明在成功页自己那几行
        var n: [String] = []
        if model.installOpenToFinish { n.append(text("install.done.open")) }
        n.append(trustNote)
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
            Text(trustNote).font(LauncherTheme.TypeStyle.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if game?.iphoneFree == true {
                Text(text("install.done.free")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
