// S2Arm（不是上游文件）：「装到 iPhone 的方式」（v0.3.0，维护者 11-11 定「怎么签、怎么装收成一套」，不加顶层入口）。
//   InstallModeCard：环境检查里的一张卡——一键装到 iPhone（签名身份：Xcode 账号 / 我的开发者证书；Xcode 团队号手填与引导项目从装机页挪来）
//     或导出、自己签名安装（导出作业合入前置灰写「下一版提供」）。
//   InstallModeLine：出包页原来的「签名方式」二选一换成这一行只读 + 「更改」（打开环境检查）。
//   PhoneUpdateButton：游戏库右上角「更新 iPhone 上的 S2Arm」（壳比本版旧才出现），有要重新出包的款先三选一。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func ix(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText(id, language: loc.lang == .zh ? "zh-Hans" : "en") }

struct InstallModeCard: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @AppStorage(S2ArmLauncherModel.teamCodeKey) private var enteredTeamCode = ""
    @State private var showTeam = false

    var body: some View {
        CardGroup(ix(loc, "install.mode.title"), footnote: ix(loc, "install.mode.note")) {
            VStack(alignment: .leading, spacing: 10) {
                option("device", ix(loc, "install.mode.device"), ix(loc, "install.mode.device_note"), enabled: true)
                if model.installMode.mode == "device" { identity.padding(.leading, 28) }
                option("export", ix(loc, "install.mode.export"),
                       ix(loc, "install.mode.export_note") + (model.installMode.exportAvailable ? "" : "\n" + ix(loc, "install.mode.export_soon")),
                       enabled: model.installMode.exportAvailable)
            }
            .padding(14)
        }
        .onAppear { model.refreshInstallMode(); model.refreshDevCert() }
        .accessibilityIdentifier("env.installMode")
    }

    private func option(_ mode: String, _ title: String, _ note: String, enabled: Bool) -> some View {
        let on = model.installMode.mode == mode
        return Button { if enabled, !on { model.setInstallMode(mode) } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 15)).foregroundStyle(on ? LauncherPalette.cream : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.manrope(14, .semibold))
                    Text(note).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12).contentShape(Rectangle())
            .background(on ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? LauncherPalette.cream.opacity(0.7) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier("env.installMode." + mode)
    }

    /// 一键装时的签名身份：开发者证书一栏照用出包页原来那套（导入 / 换 / 删、体检）；不用证书时 Xcode 团队号与引导项目在这里
    @ViewBuilder private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            DevCertRow(model: model, title: ix(loc, "install.mode.identity"), appleIdTitle: ix(loc, "install.mode.identity_xcode"))
            if model.devCert?.active != true {
                // Xcode 里还没有团队 / 签不成时的解决办法（引导项目 + 手填团队号）：平时收起，签名身份一栏保持紧凑；手填过团队号的展开着
                Button { showTeam.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(loc.t("s2arm.install.teamManual")).font(.manrope(12.5, .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(showTeam || !enteredTeamCode.isEmpty ? 90 : 0))
                    }
                    .foregroundStyle(LauncherPalette.cream.opacity(0.85))
                }
                .buttonStyle(.plain).padding(.horizontal, 14).accessibilityIdentifier("env.teamManual")
                if showTeam || !enteredTeamCode.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc.t("s2arm.install.teamGuide")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(loc.t("s2arm.install.teamGuideOpen")) { model.openSigningProject() }
                            .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("env.teamGuideOpen")
                        TextField(loc.t("s2arm.install.teamManualField"), text: $enteredTeamCode).textFieldStyle(.roundedBorder).font(.mono(12)).frame(width: 180)
                            .accessibilityIdentifier("env.teamId")
                    }
                    Text(loc.t("s2arm.install.teamManualHelp")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                }
            }
        }
    }
}

/// 出包页：现在按哪种方式装 + 「更改」（打开环境检查那张卡）
struct InstallModeLine: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 12) {
            LauncherRowIcon("signature")
            Text(ix(loc, "install.mode.summary").replacingOccurrences(of: "{0}", with: summary)).font(.manrope(13)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(ix(loc, "install.mode.change")) { model.showEnvironment = true }
                .buttonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                .accessibilityIdentifier("export.installMode.change")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
        .onAppear { model.refreshInstallMode(); model.refreshDevCert() }
    }

    private var summary: String {
        if model.installMode.mode == "export" { return ix(loc, "install.mode.export") }
        let who = model.signIdentity == "devcert" ? ix(loc, "export.sign.devcert") : ix(loc, "install.mode.identity_xcode")
        return ix(loc, "install.mode.device") + "（" + who + "）"
    }
}

/// 游戏库右上角：壳比本版旧才出现；一键装叫「更新 iPhone 上的 S2Arm」，导出模式叫「导出新版 S2Arm」。
///   放在标题栏那一排（同 batchPill）：那里拿不到 Localizer 环境对象（真机起局实测取它即崩），文字按调用方给的界面语言从共用规格取
struct PhoneUpdateButton: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        if model.phoneUpdate != nil {
            Button { model.requestPhoneUpdate(language: language) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.circle")
                    Text(t(model.installMode.mode == "export" ? "update.button.export" : "update.button.device")).font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
            .accessibilityIdentifier("top.phoneUpdate")
            .alert(t("update.confirm.title"), isPresented: Binding(get: { model.updateConfirm != nil }, set: { if !$0 { model.updateConfirm = nil } }),
                   presenting: model.updateConfirm) { u in
                Button(t("update.confirm.repack")) { model.updatePhone(acceptStale: true, repack: u.stale.map(\.id), language: language) }
                Button(t("update.confirm.later")) { model.updatePhone(acceptStale: true, repack: [], language: language) }
                Button(t("update.confirm.cancel"), role: .cancel) {}
            } message: { u in
                Text(t("update.confirm.body").replacingOccurrences(of: "{0}", with: u.stale.map(\.name).joined(separator: "」「"))
                        .replacingOccurrences(of: "{1}", with: "\(u.games.count - u.stale.count)"))
            }
            // 更新会让手机上别的电脑装的游戏暂时不能玩：在更新页里问（PhoneJobPanel.dropAsk），不在这里弹框
        }
    }
}
