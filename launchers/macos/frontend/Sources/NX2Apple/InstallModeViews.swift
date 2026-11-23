// S2Arm（不是上游文件）：一键装到 iPhone 的签名身份（v0.3.0；11-15 维护者：导出不再是装法，游戏库「导出自签包」按钮常驻，设置里没有切换）。
//   InstallModeCard：设置里的一张卡——一键装到 iPhone 用谁签名（Apple ID / 我的开发者证书）。0.6.0 Mac 的 Apple ID 是 S2Arm 自己登录的（AppleIdRow → 登录面板），不看 Xcode。
//   AppleTVXcodeTeam：Apple TV 用的 Xcode 团队（引导项目 + 手填团队号），放在出包页 Apple TV 那一行下面。
//   InstallModeLine：出包页一行只读签名身份 + 「更改」（打开设置）。
//   PhoneUpdateButton：游戏库右上角「更新 iPhone 上的 S2Arm」（壳比本版旧才出现），有要重新出包的款先三选一。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func ix(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }

struct InstallModeCard: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardGroup(ix(loc, "install.mode.device"), footnote: ix(loc, "install.mode.device_note")) {
            identity.padding(LauncherTheme.Metrics.cardInset)
            CardDivider()
            InstallLayoutRow(model: model).padding(LauncherTheme.Metrics.cardInset)
        }
        .onAppear { model.refreshInstallMode(); model.refreshDevCert() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("env.installMode")
    }

    /// 一键装时的签名身份：开发者证书一栏照用出包页原来那套（导入 / 换 / 删、体检）；不用证书时登录 Apple ID 在这里（不讲 Xcode）
    @ViewBuilder private var identity: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
            DevCertRow(model: model, title: ix(loc, "install.mode.identity"), appleIdTitle: ix(loc, "export.sign.appleId"), embedded: true)
            if model.devCert?.active != true { AppleIdRow(model: model, host: "settings") }
        }
    }
}

/// 出法（0.6.3 维护者定，两种并存、玩家自选；0.6.2 起做成两张并排卡片）：独立 App（每款一个 App，点开直接进这款）/ 通用 S2Arm（一个 App 装整个游戏库）。
///   gameId 为空 = 设置里的缺省；给了 gameId = 出包页 / 装机页单款覆盖（单独选过时右上给「跟随设置（当前：…）」撤掉）。
///   推荐按签名带不带调试权限（作业层 install.layout_recommend，#1760）：推荐那张底部「✓ 根据你的…推荐」；选了不推荐那张，卡片下方一行橙字说后果，不弹窗、不拦
struct InstallLayoutRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    var gameId: String? = nil
    /// 出现时读一次装机方式（按款选过的、证书换过）；离屏截图测试关掉它（测试环境没有作业入口，读失败会弹真的报错框）
    var refreshOnAppear = true
    /// 导出确认页 ② 出法（0.6.4）：点卡片只改这里，「开始」时才 layoutSet 记下（取消就不改）；nil = 照旧点了就记
    var selection: Binding<String>? = nil
    /// 导出确认页 ① 当前选的签名方式（appleId / devCert / none）：给了就按它取独立 App 那句提示（InstallModeInfo.standaloneHints），
    ///   不再用设置里签名方式那句（两句会打架）；设置页不给，照旧按设置
    var exportSign: String? = nil
    @State private var showWhy = false

    static let gold = Color(red: 0.93, green: 0.77, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    /// 卡片下方那一行（只出一行，按顺序取第一个）：(文字, 颜色)
    static func note(now: String, why: String, hint: String?) -> (String, String)? {
        if now == "shell" && why == "distribution" { return ("layout.card.warn.distShell", "orange") }
        if now == "standalone" && why == "appleId" { return ("layout.card.warn.freeStandalone", "orange") }
        if now == "standalone" && why == "external" { return ("install.layout.hint.external", "orange") }
        if now == "standalone" && hint == "wildcard" { return ("install.layout.hint.wildcard", "yellow") }
        if why == "unknown" { return ("layout.card.unknown", "gray") }
        return nil
    }

    /// 导出确认页那一行：选独立 App → 按这次的签名方式取作业层给的码（显式 / 通配描述文件黄字，自签、免费 Apple ID 橙字）；
    ///   选通用 S2Arm → 只留「分发证书选了通用 S2Arm」那句（和签名方式无关的那条照旧）
    static func exportNote(now: String, sign: String, hints: [String: String], why: String) -> (String, String)? {
        guard now == "standalone" else { return now == "shell" && why == "distribution" ? ("layout.card.warn.distShell", "orange") : nil }
        guard let code = hints[sign] else { return nil }
        return ("install.layout.hint." + code, ["explicit", "wildcard"].contains(code) ? "yellow" : "orange")
    }

    var body: some View {
        let m = model.installMode
        let name = { (v: String) in ix(loc, v == "standalone" ? "install.layout.standalone" : "install.layout.shell") }
        let own = gameId.flatMap { m.layoutGames[$0.uppercased()] }
        let now = selection?.wrappedValue ?? gameId.map { m.layout(for: $0) } ?? m.layout
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if gameId == nil { LauncherRowIcon("square.stack.3d.up") }
                Text(ix(loc, gameId == nil ? "install.layout.title" : "install.layout.game")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { showWhy.toggle() } label: { Label(ix(loc, "layout.card.whyLabel"), systemImage: "questionmark.circle").font(LauncherTheme.TypeStyle.caption) }
                    .controllerButtonStyle(.plain).foregroundStyle(.secondary).help(ix(loc, "layout.card.why"))
                    .popover(isPresented: $showWhy, arrowEdge: .bottom) {
                        Text(ix(loc, "layout.card.why")).font(.manrope(13)).fixedSize(horizontal: false, vertical: true).frame(width: 360).padding(16)
                            .controllerBackAction("install.layout.why.close") { showWhy = false }
                    }
                    .controllerID("install.layout.why")
                if let gameId, own != nil, selection == nil {
                    Button(ix(loc, "install.layout.follow").replacingOccurrences(of: "{0}", with: name(m.layout))) { model.setLayout(nil, gameId: gameId) }
                        .controllerButtonStyle(.plain).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).underline()
                        .controllerID("install.layout.follow")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                card("standalone", name("standalone"), "layout.card.standalone.body", "layout.card.standalone.badge", gold: true, now: now, m: m)
                card("shell", name("shell"), "layout.card.shell.body", "layout.card.shell.badge", gold: false, now: now, m: m)
            }
            .fixedSize(horizontal: false, vertical: true)
            // 导出确认页只按这次的签名方式给（没有就不出），不退回设置那句
            if let (key, tone) = exportSign.map({ Self.exportNote(now: now, sign: $0, hints: m.standaloneHints, why: m.recommendWhy) }) ?? (exportSign == nil ? Self.note(now: now, why: m.recommendWhy, hint: m.standaloneHint) : nil) {
                Text(ix(loc, key)).font(LauncherTheme.TypeStyle.caption)
                    .foregroundStyle(tone == "orange" ? Self.orange : tone == "yellow" ? Color.yellow : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("install.layout.note")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(gameId == nil ? "env.installLayout" : "install.layout")
        .onAppear { if gameId != nil && refreshOnAppear { model.refreshInstallMode() } }   // 设置卡自己已刷新；装机页 / 出包页打开时读一次（按款选过的、证书换过）
    }

    private func card(_ value: String, _ title: String, _ body: String, _ badge: String, gold: Bool, now: String, m: InstallModeInfo) -> some View {
        let on = (m.loaded || selection != nil || gameId.flatMap { m.layoutGames[$0.uppercased()] } != nil) && now == value   // 没读回不画选中（InstallModeInfo.loaded）
        let recommended = m.recommend == value
        return Button { if let selection { selection.wrappedValue = value } else if !on { model.setLayout(value, gameId: gameId) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(ix(loc, badge)).font(.manrope(11, .bold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(gold ? Color.black : Color.white)
                    .background(gold ? Self.gold : Color.white.opacity(0.18), in: Capsule())
                HStack(spacing: 8) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Self.gold : .secondary)
                    Text(title).font(.manrope(16, .bold))
                }
                Text(ix(loc, body)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if recommended {
                    Label(ix(loc, ["distribution", "devCertDebug"].contains(m.recommendWhy) ? "layout.card.recommendCert" : "layout.card.recommendSign"), systemImage: "checkmark")
                        .font(.manrope(12, .semibold)).foregroundStyle(Self.gold).accessibilityIdentifier("install.layout.recommended." + value)
                }
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(on ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Self.gold : Color.white.opacity(0.14), lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .controllerButtonStyle(.plain).controllerRingRadius(12)
        .controllerID((gameId == nil ? "install.layout." : "install.layout.game.") + value)
        .accessibilityIdentifier("install.layout.card." + value)
    }
}

/// Apple TV 用的 Xcode 团队（出包页 Apple TV 那一行下面）：Apple TV 装机（tvos.install_tv）仍用 Xcode 账号的团队（install.pick_team(xcode_teams, teamId)），
///   推到 iPhone 用不到，所以不放在「一键装到 iPhone」卡里。引导项目（Personal Team 运行一次）+ 手填团队号，平时收起；手填过团队号的展开着
struct AppleTVXcodeTeam: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @AppStorage(S2ArmLauncherModel.teamCodeKey) private var enteredTeamCode = ""
    @State private var showTeam = false
    @State private var openingGuide = false
    @State private var guideFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
            Button { showTeam.toggle() } label: {
                HStack(spacing: 6) {
                    Text(loc.t("s2arm.install.teamManual")).font(.manrope(12.5, .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(showTeam ? 90 : 0))
                }
                .foregroundStyle(LauncherPalette.cream.opacity(0.85))
            }
            .controllerButtonStyle(.plain).controllerID("env.teamManual")
            if showTeam {
            VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
                VStack(alignment: .leading, spacing: LauncherTheme.Space.medium) {
                    Text(loc.t("s2arm.install.teamGuide.intro")).font(LauncherTheme.TypeStyle.detail)
                    ForEach(1...3, id: \.self) { step in
                        LauncherGuideStep(step, loc.t("s2arm.install.teamGuide.step\(step)"))
                    }
                    Button {
                        openingGuide = true; guideFailure = nil
                        model.openSigningProject { error in
                            openingGuide = false
                            guideFailure = error.map { loc.backend($0.localizedDescription) }
                        }
                    } label: {
                        HStack(spacing: LauncherTheme.Space.small) {
                            if openingGuide { ProgressView().controlSize(.small).frame(width: LauncherTheme.Metrics.icon) }
                            Text(loc.t("s2arm.install.teamGuideOpen"))
                        }
                    }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("env.teamGuideOpen")
                        .disabled(openingGuide)
                        .padding(.leading, 22 + LauncherTheme.Space.medium)
                    if let guideFailure {
                        Text(loc.t("s2arm.install.teamGuide.failed").replacingOccurrences(of: "{0}", with: guideFailure))
                            .font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("env.teamGuide.failure")
                    }
                }
                CardDivider()
                VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
                    Text("Team ID").font(LauncherTheme.TypeStyle.section)
                    Text(loc.t("s2arm.install.teamManualHelp")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(loc.t("s2arm.install.teamManualField"), text: $enteredTeamCode,
                              prompt: Text(loc.t("s2arm.install.teamManualField")).foregroundColor(LauncherTheme.Colors.secondary))
                        .textFieldStyle(LauncherTextFieldStyle()).font(.mono(13)).frame(maxWidth: 300)
                        .accessibilityLabel("Team ID").accessibilityIdentifier("env.teamId")
                }
            }
            .padding(LauncherTheme.Space.large).launcherPanel()
            }
        }
        .onAppear { showTeam = !enteredTeamCode.isEmpty }
    }
}

/// 出包页：一键装用谁签名 + 「更改」（打开设置那张卡）
struct InstallModeLine: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 12) {
            LauncherRowIcon("signature")
            Text(ix(loc, "install.mode.summary").replacingOccurrences(of: "{0}", with: summary)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(ix(loc, "install.mode.change")) { model.showEnvironment = true }
                .controllerButtonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                .controllerID("export.installMode.change")
                .accessibilityIdentifier("export.installMode.change")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherTheme.Colors.border, lineWidth: 1))
        .padding(.top, 4)
        .onAppear { model.refreshInstallMode(); model.refreshDevCert() }
    }

    private var summary: String {
        model.signIdentity == "devcert" ? ix(loc, "export.sign.devcert") : ix(loc, "export.sign.appleId")
    }
}

/// 游戏库右上角：壳比本版旧才出现，「更新 iPhone 上的 S2Arm」（自签的玩家点游戏的「导出自签包」导出新版）。
///   放在标题栏那一排（同 batchPill）：那里拿不到 Localizer 环境对象（真机起局实测取它即崩），文字按调用方给的界面语言从共用规格取
struct PhoneUpdateButton: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        if model.phoneUpdate != nil || model.updateConfirm != nil {
            Button { model.requestPhoneUpdate(language: language) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.circle")
                    Text(t("update.button.device")).font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy || model.phoneUpdate == nil)
            .controllerID("top.phoneUpdate").controllerShortcut(.rightTrigger, focused: true)
            .alert(t("update.confirm.title"), isPresented: Binding(get: { model.updateConfirm != nil }, set: { if !$0 { model.updateConfirm = nil } }),
                   presenting: model.updateConfirm) { u in
                Button(t("update.confirm.repack")) { model.updatePhone(acceptStale: true, repack: u.stale.map(\.id), language: language, device: u.device) }
                Button(t("update.confirm.later")) { model.updatePhone(acceptStale: true, repack: [], language: language, device: u.device) }
                Button(t("update.confirm.cancel"), role: .cancel) {}
            } message: { u in
                Text(t("update.confirm.body").replacingOccurrences(of: "{0}", with: u.stale.map(\.name).joined(separator: "」「"))
                        .replacingOccurrences(of: "{1}", with: "\(u.games.count - u.stale.count)"))
            }
            // 更新会让手机上别的电脑装的游戏暂时不能玩：在更新页里问（PhoneJobPanel.dropAsk），不在这里弹框
        }
    }
}
