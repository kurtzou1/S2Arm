// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 0.6.0 iPhone 总控台的界面（通用壳开关后面；《0.6.0 极简流程》界面一节）：游戏库首位固定「S2Arm」卡 + 选中它时下方整页。
///   开关关着（model.phoneOverview == nil）这里什么都不出，首页就是 0.5.x 的样子。
///   本段接了 ① 手机与 App、② 游戏同步、⑥ 帮助；③ 自签和证书、④ 空间、⑤ 存档与快照等对应作业进 main 后接。
extension LauncherView {
    private func sx(_ key: String) -> String { BackendText.launcherText(key, language: loc.lang.sharedCode) }
    private func sx(_ key: String, _ args: CustomStringConvertible...) -> String {
        args.enumerated().reduce(sx(key)) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element.description) }
    }

    var consoleEnabled: Bool { model.phoneOverview != nil }

    /// 首位卡状态行（随手机实时变；流程稿表格取第一条成立的）
    func consoleStatusText(_ s: S2ArmLauncherModel.ConsoleStatus) -> String {
        switch s {
        case .introduce: return sx("console.status.introduce")
        case .updating(let done, let total): return sx("console.status.updating", done + 1 > total ? total : done + 1, total)
        case .notConnected(let seen):   // 写这台的类型（#1962：iPad 不写 iPhone），读不到写「iPhone / iPad」
            let kind = BackendText.deviceKind(model.consolePhone?.kind)
            return seen.map { sx("console.status.notConnected", $0.formatted(.relative(presentation: .named)), kind) } ?? sx("console.status.notConnectedNever", kind)
        case .chooseApp: return sx("console.status.chooseApp")
        case .externalApp: return sx("console.status.externalApp")
        case .notInstalled: return sx("console.status.notInstalled")
        case .appOutdated: return sx("console.status.appOutdated")
        case .expired: return sx("console.status.expired")
        case .expiring(let d): return sx("console.status.expiring", d)
        case .suggested(let n): return sx("console.status.suggested", n)
        case .ok(let d): return d.map { sx("console.status.ok", $0) } ?? sx("console.status.okNoDays")
        }
    }

    /// 游戏库首位「S2Arm」卡：S2Arm 图标叠手机轮廓，下面两行（手机名 / 状态）
    func consoleCard(side: CGFloat) -> some View {
        let selected = model.consoleSelected
        let focused = navigation.visible && navigation.focusedID == "card." + S2ArmLauncherModel.consoleID
        let artworkSide = selected ? side * 1.36 : side
        let status = model.consoleStatus()
        // 手机图标同一时刻只画一个（动画 1：选中时从卡片升到下方页顶）。原先卡片里那个一直在、只把 isSource 让给页顶，
        //   matchedGeometryEffect 就把它摆到页顶图标的位置：面板一滚动，它压在卡片边框上或飘到卡片外（玩家录屏 0.6.2）
        let headerShown = selected && status != .introduce && model.consolePhone != nil
        return Button {
            // 鼠标点进总控台也现查一次连着的手机（同键盘 / 手柄把焦点移过来，LauncherView+Home 焦点变化那条；同 Windows library.select）：
            //   原先只改选中，随后的焦点变化因已选中不再查，鼠标玩家的总控台永远按设备记录显示，装着多个 S2Arm 时也出不来选择
            let was = model.selectedID
            model.selectedID = S2ArmLauncherModel.consoleID
            if was != S2ArmLauncherModel.consoleID { model.refreshPhoneOverview(probe: true) }
            navigation.focus("card." + S2ArmLauncherModel.consoleID)
        } label: {
            HomeCardSurface(selected: selected, focused: focused) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                    // 图标在上、字在下（#1967：原先「S2Arm」叠在轮廓正中，比手机屏宽，两边压在边框上看不清）；只挪位置不改视图结构（套 VStack 离屏渲染崩在 HomeCardSurface）
                    if !headerShown {
                        Image(systemName: S2ArmLauncherModel.deviceSymbol(model.consolePhone?.kind)).font(.system(size: artworkSide * 0.34, weight: .thin)).foregroundStyle(.white.opacity(0.9))
                            .matchedGeometryEffect(id: "console.phone", in: consoleSpace).offset(y: -artworkSide * 0.08)
                    } else {   // #1967：设备图标升到页顶后卡片不空着，放 S2Arm 的 App 图标
                        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                            .frame(width: artworkSide * 0.4, height: artworkSide * 0.4).offset(y: -artworkSide * 0.08).accessibilityHidden(true)
                    }
                    Text("S2Arm").font(.manrope(artworkSide * 0.1, .bold)).foregroundStyle(.white).offset(y: artworkSide * 0.25)
                    if case .updating(let done, let total) = status {   // 动画 3 / 4：外圈进度环（更新所选 / 装 App 时）
                        Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1))).stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(artworkSide * 0.12)
                    }
                }
                .frame(width: artworkSide, height: artworkSide)
                .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.84), value: selected)
            }
        }.controllerButtonStyle(.plain)
            .help((model.consolePhone?.name ?? "S2Arm") + " · " + consoleStatusText(status))
            .accessibilityLabel("S2Arm").accessibilityValue((model.consolePhone?.name ?? "") + " · " + consoleStatusText(status))
            .accessibilityAddTraits(selected ? .isSelected : []).controllerID("card." + S2ArmLauncherModel.consoleID)
    }

    /// 选中首位卡时下方整页
    @ViewBuilder func consolePanel(size: CGSize) -> some View {
        let status = model.consoleStatus()
        if status == .introduce {
            consoleIntro
        } else if let phone = model.consolePhone {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    consoleHeader(phone, status: status)
                    consolePhoneSection(phone, status: status)
                    if !phone.apps.isEmpty { consoleAppsSection(phone) }
                    consoleSyncSection(phone)
                    consoleHelpSection
                }.frame(maxWidth: 860, alignment: .leading)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .accessibilityIdentifier("console.panel")
        }
    }

    /// 只在 Mac 上玩的人：三句介绍 +「连上 iPhone 开始」，不出空表、不出灰按钮墙
    private var consoleIntro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sx("console.status.introduce")).font(.manrope(30, .bold))
            Text(sx("console.intro.body")).font(.manrope(14)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
            Button { model.consoleIntroStart(language: loc.lang.sharedCode) } label: { Label(sx("console.intro.start"), systemImage: "iphone") }
                .controllerButtonStyle(ConsolePlayButtonStyle()).controllerID("console.intro.start")
        }.accessibilityIdentifier("console.intro")
    }

    /// 页顶：手机切换 + 大手机轮廓（动画 1：从封面升上来）+ 全部最新（动画 5）
    private func consoleHeader(_ phone: PhoneOverview.Phone, status: S2ArmLauncherModel.ConsoleStatus) -> some View {
        let phones = model.phoneOverview?.phones ?? []
        let allLatest = phone.installed && phone.shellCurrent && !phone.games.isEmpty && phone.games.allSatisfy { $0.state == .latest }
        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                Image(systemName: S2ArmLauncherModel.deviceSymbol(phone.kind)).font(.system(size: 64, weight: .thin)).foregroundStyle(.white)
                    .matchedGeometryEffect(id: "console.phone", in: consoleSpace)
                if allLatest {
                    Text(sx("console.allLatest")).font(.manrope(9, .bold)).foregroundStyle(.green).shadow(color: .green.opacity(0.7), radius: 6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if phones.count > 1 {
                    Picker("", selection: Binding(get: { phone.device }, set: {   // 换了一台：现查它装了哪些 S2Arm
                        model.consoleDevice = $0; model.consoleRechoose = false; model.consoleChooseError = nil; model.seedConsoleSelection(); model.refreshPhoneOverview(probe: true) })) {
                        ForEach(phones, id: \.device) { Text($0.name.isEmpty ? $0.device : $0.name).tag($0.device) }
                    }.labelsHidden().frame(maxWidth: 260).accessibilityIdentifier("console.phonePicker")
                } else {
                    Text(phone.name.isEmpty ? phone.device : phone.name).font(.manrope(22, .bold))
                }
                Text(consoleStatusText(status)).font(.manrope(13)).foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func consoleSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(12, .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var consoleOffline: Bool { if case .some(.none) = model.consolePhone?.online { return true }; return false }
    private func offlineReason(_ phone: PhoneOverview.Phone) -> some View {
        Text(sx("console.offline", phone.name.isEmpty ? BackendText.deviceKind(phone.kind) : phone.name, BackendText.deviceKind(phone.kind))).font(.manrope(12)).foregroundStyle(.orange)
    }

    /// 按钮文案键（动作名 → 共享文案；动作集合与控制口 phoneConsole 同一个来源 model.consoleActions）
    private func consoleActionTitle(_ a: S2ArmLauncherModel.ConsoleAction) -> String {
        switch a {
        case .installShell: return sx("console.button.install")
        case .updateShell: return sx("console.button.update")
        case .renewShell: return sx("console.button.renew")
        case .exportShellIpa: return sx("console.button.exportShellIpa")
        case .handOverIdentity: return sx("console.button.identity")
        case .updateSelected: return sx("console.updateSelected", model.consoleSelection.count)
        case .pushS2arm: return sx("console.button.pushS2arm", model.consoleSelection.count)
        case .exportS2arm: return sx("console.button.exportS2arm", model.consoleSelection.count)
        case .chooseApp: return sx("console.choose.change")
        }
    }

    /// ① 手机与 App：App 状态 + 一个随状态变的按钮（启动器装的：安装 / 续签 / 更新 S2Arm；别的工具装的：导出 S2Arm.ipa）+ 签名方式
    private func consolePhoneSection(_ phone: PhoneOverview.Phone, status: S2ArmLauncherModel.ConsoleStatus) -> some View {
        let actions = model.consoleActions(phone)
        let app = actions.first { [.installShell, .updateShell, .renewShell, .exportShellIpa].contains($0) }
        return consoleSection(sx("console.section.phone")) {
            Text(consoleStatusText(status) + (phone.signMode.map { " · " + sx("console.sign." + $0.rawValue) } ?? "")).font(.manrope(14))
            if phone.needsChoice || (model.consoleRechoose && phone.candidates.count > 1) {
                consoleChooser(phone)
            } else if phone.candidates.count > 1 {   // 选过了、装着不止一个：写正在用哪个 + 「换一个」
                HStack(spacing: 10) {
                    Text(sx("console.choose.current", phone.bundleId)).font(.manrope(12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    Button(sx("console.choose.change")) { model.consoleChooseError = nil; model.consoleRechoose = true }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("console.chooseApp.change")
                }
            }
            if phone.installedBy == .external {
                Text(sx("console.external.note")).font(.manrope(12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            if let app {
                HStack(spacing: 12) {
                    // 导出 S2Arm.ipa 不连手机，没连也能点
                    Button { model.runConsoleAction(app, device: phone.device, language: loc.lang.sharedCode) } label: {
                        Label(consoleActionTitle(app), systemImage: app == .exportShellIpa ? "square.and.arrow.up" : "iphone.and.arrow.forward") }
                        .controllerButtonStyle(ConsolePillButtonStyle()).controllerID("console.app").disabled(consoleOffline && app != .exportShellIpa)
                    if consoleOffline && app != .exportShellIpa { offlineReason(phone) }
                }
            }
            if actions.contains(.handOverIdentity) { consoleIdentity(phone) }
        }.accessibilityIdentifier("console.section.phone")
    }

    /// 独立 App（一 App 一游戏，0.6.4）：每款一行——封面、游戏名、签名还剩几天 / 已到期、壳有新版时提示去「更新 iPhone 上的 S2Arm」（那一下逐个重签）
    private func consoleAppsSection(_ phone: PhoneOverview.Phone) -> some View {
        consoleSection(sx("console.section.apps")) {
            ForEach(phone.apps, id: \.gameId) { app in
                let game = model.games.first { $0.id.uppercased() == app.gameId }
                HStack(spacing: 10) {
                    GameArtwork(covers: covers, cover: game?.cover).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game?.name ?? app.gameId).font(.manrope(13, .medium)).lineLimit(1)
                        Text(app.bundleId).font(.manrope(11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }.frame(minWidth: 160, alignment: .leading)
                    Text(consoleAppText(app)).font(.manrope(12.5)).foregroundStyle(app.shellCurrent && !consoleAppExpired(app) ? Color.green : Color.orange).lineLimit(2)
                    Spacer(minLength: 0)
                    // 续签（0.6.4）= 这款再「推到 iPhone」一次：重签重装、资源只推变了的；打开这款的装机页看进度与结局（成功页 A / 失败页）
                    if let game {
                        Button(sx("console.app.renew")) { installFor = game.id; model.install(game, device: phone.device) }
                            .controllerButtonStyle(ConsolePillButtonStyle()).controllerID("console.app.renew." + app.gameId)
                            .disabled(consoleOffline || model.phonePushing(game.id) || model.phoneQueued(game.id))
                            .accessibilityIdentifier("console.app.renew." + app.gameId)
                    }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("console.app." + app.gameId)
            }
        }.accessibilityIdentifier("console.section.apps")
    }

    private func consoleAppExpired(_ app: PhoneOverview.App) -> Bool { app.expiresAtEstimate.map { $0 <= Date() } ?? false }
    private func consoleAppText(_ app: PhoneOverview.App) -> String {
        if consoleAppExpired(app) { return sx("console.status.expired") }
        if !app.shellCurrent { return sx("console.app.outdated") }
        guard let end = app.expiresAtEstimate else { return sx("console.status.okNoDays") }
        let days = Int((end.timeIntervalSinceNow / 86400).rounded(.up))
        return days <= 2 ? sx("console.status.expiring", days) : sx("console.status.ok", days)
    }

    /// 「选用哪个 S2Arm」：同一台手机上装着不止一个时，按作业给的顺序（包名排序）列出每一个，每个一颗按钮；只写事实（谁装的、证书导没导、团队号），不推荐。
    ///   点了跑作业 phoneChooseApp，记住后刷新总览；选过的再点「换一个」也到这里
    @ViewBuilder private func consoleChooser(_ phone: PhoneOverview.Phone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sx("console.choose.title", BackendText.deviceKind(phone.kind))).font(.manrope(12.5)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            ForEach(phone.candidates, id: \.bundleId) { c in
                let label = S2ArmLauncherModel.candidateLabelKeys(c).map { sx($0) }.joined(separator: " · ")
                Button { model.runConsoleAction(.chooseApp, device: phone.device, bundleId: c.bundleId, language: loc.lang.sharedCode) } label: {
                    HStack(spacing: 10) {
                        if model.consoleChoosing == c.bundleId { ProgressView().controlSize(.small) } else { Image(systemName: "app.badge.checkmark") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.manrope(13, .medium))
                            Text((c.displayName ?? c.bundleId) + (c.team.isEmpty ? "" : " · " + sx("console.choose.team", c.team))).font(.manrope(11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("console.chooseApp." + c.bundleId)
                .disabled(consoleOffline || model.consoleChoosing != nil || model.phoneBusy)
                .accessibilityIdentifier("console.chooseApp." + c.bundleId)
            }
            if consoleOffline { offlineReason(phone) }
            if let why = model.consoleChooseError {
                Text(BackendText.translate(why, language: loc.lang.sharedCode)).font(.manrope(12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !phone.needsChoice {
                Button(sx("console.choose.cancel")) { model.consoleRechoose = false; model.consoleChooseError = nil }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("console.chooseApp.cancel")
            }
        }.padding(.top, 4).accessibilityIdentifier("console.chooseApp")
    }

    /// 「把签名身份交给手机」（次要按钮）：AltStore / SideStore / 证书 App 装的 S2Arm 交一次签名身份，以后放进「放这里导入」就能玩。
    ///   进行中一行状态；成功一句完成提示（交好了 / 已经有了）；失败用手机作业的失败页（原因 + 下一步 + 复制错误摘要）
    @ViewBuilder private func consoleIdentity(_ phone: PhoneOverview.Phone) -> some View {
        let running = model.phoneBusy && model.phoneSession?.kind == .phoneIdentity
        VStack(alignment: .leading, spacing: 6) {
            Button { model.phoneIdentity(device: phone.device) } label: { Label(sx("console.button.identity"), systemImage: "person.badge.key") }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("console.identity").disabled(consoleOffline || running)
            Text(sx("console.identity.note")).font(.manrope(12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(sx("phone.status.running.phoneIdentity")).font(.manrope(12.5)).foregroundStyle(.white.opacity(0.8))
                }
            } else if let last = model.lastPhoneSession, last.kind == .phoneIdentity {
                if last.phase == .finished(.completed), let delivered = model.identityDelivered {
                    Text(sx(delivered ? "console.identity.done" : "console.identity.already")).font(.manrope(13)).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("console.identity.result")
                } else if last.phase != .finished(.completed) {
                    PhoneJobPanel(model: model, session: last, showsOperation: false).padding(.top, 6)
                }
            }
        }.padding(.top, 6).accessibilityIdentifier("console.identity")
    }

    /// ② 游戏同步：每款一行写这台手机上的状态，可勾选；「更新所选」一款款推，有总进度、能停
    private func consoleSyncSection(_ phone: PhoneOverview.Phone) -> some View {
        consoleSection(sx("console.section.sync")) {
            ForEach(consoleOrdered) { game in
                let g = model.consoleGame(game)
                let id = game.id.uppercased()
                let pushing = model.consoleUpdating && model.consolePushing == id
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { model.consoleSelection.contains(id) },
                                             set: { if $0 { model.consoleSelection.insert(id) } else { model.consoleSelection.remove(id) } }))
                        .toggleStyle(PadToggleStyle(.checkbox)).labelsHidden().disabled(model.consoleUpdating)
                    GameArtwork(covers: covers, cover: game.cover).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay { if pushing { Circle().stroke(.orange, lineWidth: 2).padding(-3) } }
                    Text(game.name).font(.manrope(13, .medium)).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                    if phone.apps.contains(where: { $0.gameId == id }) && g.state == .notPushed {   // 装成了独立 App（见上一节），不说「还没推」
                        Text(sx("console.game.standalone")).font(.manrope(12.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                    } else {
                        Text(consoleGameText(g)).font(.manrope(12.5, g.isLegacy ? .bold : .regular)).foregroundStyle(consoleGameColor(g)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("console.game." + id)
            }
            HStack(spacing: 12) {
                if !model.consoleUpdating {
                    // 启动器装的：更新所选；别的工具装的：推所选到 iPhone + 导出所选 .s2arm（导出不连手机，没连也能点）
                    ForEach(model.consoleActions(phone).filter { [.updateSelected, .pushS2arm, .exportS2arm].contains($0) }, id: \.self) { a in
                        let push = a != .exportS2arm
                        let button = Button { model.runConsoleAction(a, device: phone.device, language: loc.lang.sharedCode) } label: {
                            Label(consoleActionTitle(a), systemImage: push ? "arrow.down.to.line" : "square.and.arrow.up") }
                            .controllerID("console." + a.rawValue).disabled(model.consoleSelection.isEmpty || (push && consoleOffline))
                        if push { button.controllerButtonStyle(ConsolePlayButtonStyle()) } else { button.controllerButtonStyle(LauncherSecondaryButtonStyle()) }
                    }
                    if consoleOffline { offlineReason(phone) }
                } else {
                    let p = model.consoleProgress, total = max(p.total, 1)
                    let current = model.consolePushing.flatMap { id in model.games.first { $0.id.uppercased() == id }?.name }
                    ProgressView(value: Double(p.done), total: Double(total)).frame(maxWidth: 260)
                    Text(sx("console.progress", min(p.done + 1, total), total) + (current.map { " · " + $0 } ?? ""))
                        .font(.manrope(12.5)).foregroundStyle(.white.opacity(0.8))
                    Button(sx("console.stop")) { model.stopUpdateSelected() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.stop")
                }
            }
        }.accessibilityIdentifier("console.section.sync")
    }

    /// 0.5 → 0.6 升级后的老款（资源在、程序包不在）排最上面、醒目标出，直到更新完（更新完状态变了就回到游戏库顺序）
    private var consoleOrdered: [GameSummary] {
        let legacy = model.games.filter { model.consoleGame($0).isLegacy }
        return legacy + model.games.filter { !model.consoleGame($0).isLegacy }
    }

    private func consoleGameText(_ g: PhoneOverview.Game) -> String {
        if g.isLegacy { return sx("console.legacy.badge") }
        switch g.state {
        case .latest: return sx("console.game.latest")
        case .suggested: return sx("update.hint.badge") + " · " + g.reasons.compactMap(S2ArmLauncherModel.updateReasonKey).map(sx).joined(separator: " ")
        case .notPushed:
            if g.reasons.contains("removed") { return sx("console.game.removed") }
            return sx(g.dataOnComputer == false ? "console.game.notPushedNoData" : "console.game.notPushed")
        case .needsData: return sx(g.dataOnComputer == false ? "console.game.needsDataOriginal" : "console.game.needsData")
        case .present: return sx("console.game.present")
        case .unknown: return sx("console.game.unknown")
        case .pending: return sx("console.game.pending")
        }
    }
    private func consoleGameColor(_ g: PhoneOverview.Game) -> Color {
        if g.isLegacy { return LauncherPalette.building }
        switch g.state {
        case .latest, .present: return .green
        case .suggested, .pending: return .orange
        case .notPushed, .unknown: return .white.opacity(0.6)
        case .needsData: return .yellow
        }
    }

    /// ⑥ 帮助：重看第一次的引导（欢迎页）、故障报修（同顶栏那颗：全局「上传给开发者」）
    private var consoleHelpSection: some View {
        consoleSection(sx("console.section.help")) {
            HStack(spacing: 12) {
                Button(sx("console.help.guide")) { model.welcomeHome = true }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.help.guide")
                Button(sx("console.help.report")) { model.diagUploadFor = "" }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.help.report")
            }
        }
    }
}

extension PhoneOverview.Game {
    /// 0.5.x 整包装的老款：资源推过、程序包不在（作业层 host_update.phone_overview suggested + missing）
    var isLegacy: Bool { state == .suggested && reasons.contains("missing") }
}
