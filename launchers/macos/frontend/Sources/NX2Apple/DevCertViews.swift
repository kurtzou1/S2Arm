// S2Arm（不是上游文件）：出包页「签名方式」一栏 + 导入开发者证书弹窗（v0.2.4，作业层 pack/jobs/devcert.py）。
//   一栏：Apple ID 签名 / 我的开发者证书 二选一；选了证书，下面列团队、到期、包名、设备列表核对，问题黄字（不挡）、根本签不了红字。
//   弹窗：拖进或选 .p12 与 .mobileprovision，输密码，点导入；失败原因留在弹窗里，成了自动关。
//   描述文件缺权限（分发证书的 devcert_distribution 拒导入；只缺内核两项的 devcert_entitlements 照常导入）：逐条列缺项，同一页直接给
//   「复制给证书发放人的话」（作业层 requestText）和「改用 Apple ID 登录」（切到 Apple ID 签名并打开登录面板），不让玩家自己去找。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func sx(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText("export.sign." + id, language: loc.lang.sharedCode) }

struct DevCertRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    /// 标题与「不用证书」那一项的叫法：环境检查「装到 iPhone 的方式」里叫「签名身份」「Apple ID 签名」（0.6.0 起 Apple ID 在 S2Arm 里登录，不经 Xcode）
    var title: String? = nil
    var appleIdTitle: String? = nil
    var embedded = false
    /// 「改用 Apple ID 登录」打开的登录面板挂在哪一层（这一栏在设置里）
    var loginHost = "settings"
    @State private var confirmDelete = false
    /// 导入弹窗里点了「改用 Apple ID 登录」：等弹窗收起再开登录面板（同一层同一时刻只能弹一个）
    @State private var loginAfterSheet = false

    private var on: Bool { model.devCert?.active == true }
    /// 选了「我自己用 AltStore / SideStore 签」（自签走查结构 6）
    private var external: Bool { model.installMode.signChoice == "external" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !embedded { LauncherRowIcon("signature") }
                Text(title ?? sx(loc, "title")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                LauncherDropdown(options: [("xcode", appleIdTitle ?? sx(loc, "appleId")), ("certificate", sx(loc, "devcert")), ("external", sx(loc, "external"))],
                                 selection: external ? "external" : on ? "certificate" : "xcode", label: title ?? sx(loc, "title")) {
                    model.setSignChoice($0)
                }
                .launcherRowControls().controllerID("export.sign.mode")
            }
            if on && !external, let cert = model.devCert?.cert { details(cert) }
            if external { Text(sx(loc, "externalNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(sx(loc, "switchNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(embedded ? 0 : LauncherTheme.Metrics.cardInset)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius).fill(LauncherTheme.Colors.card)
                    .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius).strokeBorder(LauncherTheme.Colors.border))
            }
        }
        .onAppear { model.refreshDevCert(); model.refreshInstallMode(silent: true) }
        .onChange(of: model.selectedDevice?["udid"] as? String) { _ in model.refreshDevCert() }
        .sheet(isPresented: $model.showDevCertImport, onDismiss: {
            if loginAfterSheet { loginAfterSheet = false; model.switchToAppleIdLogin(host: loginHost) }
        }) {
            DevCertSheet(model: model, onAppleLogin: { loginAfterSheet = true }).environmentObject(loc)
        }
        .alert(sx(loc, "deleteConfirm"), isPresented: $confirmDelete) {
            Button(sx(loc, "delete"), role: .destructive) { model.deleteDevCert() }
            Button(sx(loc, "sheet.cancel"), role: .cancel) {}
        }
    }

    private func details(_ c: DevCertInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line(sx(loc, "team"), c.teamName.isEmpty ? c.teamId : "\(c.teamName)（\(c.teamId)）")
            line(sx(loc, "certExpires"), c.certExpires)
            line(sx(loc, "profileExpires"), c.profileExpires)
            line(sx(loc, "bundle"), c.bundleId)
            line(sx(loc, "devices"), devices(c))
            ForEach(c.blocking, id: \.self) { t in
                Label(loc.backend(t), systemImage: "xmark.octagon").font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(c.warnings, id: \.self) { t in
                Label(loc.backend(t), systemImage: "exclamationmark.triangle").font(LauncherTheme.TypeStyle.caption).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
            }
            if !c.requestText.isEmpty || c.distribution {
                DevCertFixActions(request: c.requestText, idPrefix: "export.sign") { model.switchToAppleIdLogin(host: loginHost) }
            }
            HStack(spacing: 10) {
                Button(sx(loc, "replace")) { model.showDevCertImport = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("export.sign.replace")
                Button(sx(loc, "delete")) { confirmDelete = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("export.sign.delete")
            }
            .padding(.top, 4)
        }
        .padding(.leading, 28)
        .accessibilityIdentifier("export.sign.details")
    }

    private func devices(_ c: DevCertInfo) -> String {
        if c.allDevices { return sx(loc, "devices.all") }
        let key = c.deviceListed == nil ? "devices.unknown" : c.deviceListed == true ? "devices.listed" : "devices.missing"
        return sx(loc, key).replacingOccurrences(of: "{0}", with: String(c.deviceCount))
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(v.isEmpty ? "-" : v).font(.manrope(12.5, .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DevCertSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    /// 失败是分发证书描述文件时「改用 Apple ID 登录」：告诉外层收起后开登录面板
    var onAppleLogin: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var p12 = ""
    @State private var profile = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: String?
    @State private var failureCode: String?
    @State private var failureRequest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LauncherSheetHeading(sx(loc, "sheet.title"))
            pick(sx(loc, "sheet.p12"), path: $p12, types: ["p12", "pfx"], id: "p12")
            pick(sx(loc, "sheet.profile"), path: $profile, types: ["mobileprovision"], id: "profile")
            VStack(alignment: .leading, spacing: 6) {
                Text(sx(loc, "sheet.password")).font(LauncherTheme.TypeStyle.section)
                SecureField("", text: $password).textFieldStyle(LauncherTextFieldStyle())
                    .accessibilityLabel(sx(loc, "sheet.password")).accessibilityIdentifier("export.sign.sheet.password")
                Text(sx(loc, "sheet.passwordNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(loc.backend(failure)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.sign.sheet.failure")
                if failureCode == "devcert_distribution" || !failureRequest.isEmpty {
                    DevCertFixActions(request: failureRequest, idPrefix: "export.sign.sheet") { password = ""; onAppleLogin(); dismiss() }
                }
            }
            Spacer(minLength: 0)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(sx(loc, "sheet.working")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                }
                Spacer()
                Button(sx(loc, "sheet.cancel")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction).controllerShortcut(.back)
                Button(sx(loc, "sheet.import")) { start() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                    .disabled(working || p12.isEmpty || profile.isEmpty)
                    .accessibilityIdentifier("export.sign.sheet.import")
            }
        }
        .padding(LauncherTheme.Space.page)
        .launcherSheet(.form, height: 520)
    }

    private func start() {
        working = true; failure = nil; failureCode = nil; failureRequest = ""
        Task {
            let why = await model.importDevCert(p12: p12, profile: profile, password: password)
            working = false
            if let why { failure = why.text; failureCode = why.code; failureRequest = why.request } else { password = ""; dismiss() }
        }
    }

    private func pick(_ title: String, path: Binding<String>, types: [String], id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LauncherTheme.TypeStyle.section)
            HStack(spacing: 10) {
                Text(path.wrappedValue.isEmpty ? sx(loc, "sheet.drop") : (path.wrappedValue as NSString).abbreviatingWithTildeInPath)
                    .font(LauncherTheme.TypeStyle.detail).foregroundStyle(path.wrappedValue.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(sx(loc, "sheet.choose")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
                    panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier("export.sign.sheet.choose." + id)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .launcherPanel()
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let item = providers.first else { return false }
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, types.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { path.wrappedValue = url.path }
                }
                return true
            }
        }
    }
}

/// 描述文件缺权限的两条出路（导入失败页、证书详情共用）：复制给证书发放人的话（按界面语言翻好再复制）/ 改用 Apple ID 登录
struct DevCertFixActions: View {
    let request: String
    let idPrefix: String
    let onAppleLogin: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if !request.isEmpty {
                Button(sx(loc, copied ? "copied" : "copyRequest")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(loc.backend(request), forType: .string); copied = true
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier(idPrefix + ".copyRequest")
            }
            Button(sx(loc, "useAppleId")) { onAppleLogin() }
                .controllerButtonStyle(LauncherPrimaryButtonStyle())
                .accessibilityIdentifier(idPrefix + ".useAppleId")
        }
        .onChange(of: request) { _ in copied = false }
    }
}
