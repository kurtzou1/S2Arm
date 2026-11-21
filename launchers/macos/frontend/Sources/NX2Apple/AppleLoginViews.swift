// S2Arm（不是上游文件）：0.6.0 Mac「用 Apple ID 签名」登录面板（作业层 pack/jobs/apple_login.py，模型 S2ArmLauncherModel+AppleLogin.swift）。
//   一个面板走到底：邮箱 + 密码 →（要两步验证时）同一面板里填 6 位验证码，能改短信就给「改用短信接收」，「没收到？再发一次」= 停掉这次重起 →
//   成功写「已登录：账号（团队 名）」；失败写原因和下一步（作业层 RECOVERY）。不拦、不加确认：免费号这里不新建证书，签名时的确认照旧在装机流程里。
//   AppleIdRow：设置「签名身份」下面一行，没登录给「登录 Apple ID」，登录了写账号并给「换一个 Apple ID」。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func lx(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText("install.login." + id, language: loc.lang.sharedCode) }

/// 「已登录：账号（团队 名）」
func appleAccountLine(_ loc: Localizer, _ a: AppleAccount) -> String {
    lx(loc, "done").replacingOccurrences(of: "{0}", with: a.account).replacingOccurrences(of: "{1}", with: a.teamName.isEmpty ? a.team : a.teamName)
}

struct AppleLoginSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var codeError: String?

    private var working: Bool { model.appleLoginPhase == .signingIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LauncherSheetHeading(lx(loc, "title"), note: lx(loc, "note"))
            if model.appleLoginReason == "expired", !isDone {   // 装机报登录过期：说清是过期、邮箱已带上，重新登录一次
                Label(lx(loc, "expired"), systemImage: "clock.badge.exclamationmark").font(LauncherTheme.TypeStyle.detail)
                    .foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("appleLogin.expired")
            }
            if let a = model.appleAccount, a.signedIn, !isDone {
                Text(appleAccountLine(loc, a)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                    .accessibilityIdentifier("appleLogin.current")
            }
            switch model.appleLoginPhase {
            case .needCode(let prompt): codeForm(prompt)
            case .done(let a):
                Label(appleAccountLine(loc, a), systemImage: "checkmark.circle.fill").font(LauncherTheme.TypeStyle.section)
                    .foregroundStyle(LauncherPalette.ready).accessibilityIdentifier("appleLogin.done")
            default: signInForm
            }
            if case .failed(let message, let suggestion) = model.appleLoginPhase {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.backend(message)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(LauncherPalette.danger)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("appleLogin.failure")
                    if !suggestion.isEmpty, suggestion != message {
                        PhoneJobFact(label: BackendText.launcherText("phone.next", language: loc.lang.sharedCode), text: loc.backend(suggestion))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    if let left = model.appleLoginWait {   // 苹果刚拒收过：作业层先等冷却再连，说清在等什么、还要多久
                        Text(lx(loc, "wait").replacingOccurrences(of: "{0}", with: "\(left)")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("appleLogin.wait")
                    } else {
                        Text(lx(loc, "working")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isDone {   // 登录成功页发现登错了号：就地回到输入页换一个（同设置里「换一个 Apple ID」打开的是同一个面板），不用先关掉再去设置里找
                    Button(lx(loc, "switch")) { model.switchAppleLogin() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("appleLogin.switch")
                }
                Button(lx(loc, isDone ? "close" : "cancel")) { model.closeAppleLogin() }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction).controllerShortcut(.back)
                    .controllerID("appleLogin.close")
                if !isDone, !isCode {
                    Button(lx(loc, "signIn")) { signIn() }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                        .disabled(working || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                        .controllerID("appleLogin.signIn")
                }
            }
        }
        .padding(LauncherTheme.Space.page)
        .onAppear { if email.isEmpty { email = model.appleAccount?.account ?? "" } }
        .onChange(of: model.appleAccount) { a in if email.isEmpty, let a, a.signedIn { email = a.account } }   // 重读账号回来晚于面板出现：补上原来的邮箱
        .onChange(of: model.appleLoginPhase) { phase in
            if case .done = phase { password = "" }
            if phase == .idle { email = ""; password = "" }   // 成功页点了「换一个 Apple ID」：清空重填新账号
            if case .needCode = phase { code = ""; codeError = nil }
        }
        .onDisappear { password = "" }
        .launcherSheet(.form, height: 520)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    private var isDone: Bool { if case .done = model.appleLoginPhase { return true }; return false }
    private var isCode: Bool { if case .needCode = model.appleLoginPhase { return true }; return false }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lx(loc, "email")).font(LauncherTheme.TypeStyle.section)
                TextField("", text: $email).textFieldStyle(LauncherTextFieldStyle()).textContentType(.username)
                    .disabled(working).accessibilityLabel(lx(loc, "email")).accessibilityIdentifier("appleLogin.email")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(lx(loc, "password")).font(LauncherTheme.TypeStyle.section)
                SecureField("", text: $password).textFieldStyle(LauncherTextFieldStyle()).textContentType(.password)
                    .disabled(working).onSubmit { signIn() }
                    .accessibilityLabel(lx(loc, "password")).accessibilityIdentifier("appleLogin.password")
            }
        }
    }

    private func codeForm(_ prompt: AppleLoginPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lx(loc, prompt.sms ? "codeSms" : "code")).font(LauncherTheme.TypeStyle.section)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("appleLogin.codePrompt")
            HStack(spacing: 10) {
                TextField("", text: $code).textFieldStyle(LauncherTextFieldStyle()).font(.mono(16)).frame(width: 160)
                    .textContentType(.oneTimeCode).onSubmit { submit(code) }
                    .accessibilityLabel(lx(loc, prompt.sms ? "codeSms" : "code")).accessibilityIdentifier("appleLogin.code")
                Button(lx(loc, "confirm")) { submit(code) }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                    .disabled(code.filter(\.isNumber).count != 6).controllerID("appleLogin.confirm")
            }
            if let codeError {
                Text(loc.backend(codeError)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
            }
            HStack(spacing: 10) {
                if prompt.canSms, !prompt.sms {
                    Button(lx(loc, "useSms")) { submit("sms") }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("appleLogin.sms")
                }
                Button(lx(loc, "resend")) { signIn() }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("appleLogin.resend")
            }
        }
    }

    private func signIn() {
        guard !working, !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        model.startAppleLogin(account: email, password: password)
    }

    private func submit(_ text: String) {
        let value = text == "sms" ? text : text.filter(\.isNumber)
        codeError = model.submitAppleLoginCode(value)
    }
}

/// 设置「签名身份」下面一行（不用自己的开发者证书时）：没登录 → 「登录 Apple ID」；登录了 → 账号 + 「换一个 Apple ID」
struct AppleIdRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let host: String

    var body: some View {
        HStack(spacing: 12) {
            let signedIn = model.appleAccount?.signedIn == true
            Text(signedIn ? appleAccountLine(loc, model.appleAccount!) : lx(loc, "none"))
                .font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("env.appleAccount")
            Button(lx(loc, signedIn ? "switch" : "open")) { model.openAppleLogin(host: host) }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("env.appleLogin")
        }
        .onAppear { model.refreshAppleAccount() }
    }
}

/// 登录面板挂在哪一层弹：同一时刻只有 appleLoginHost 指的那一层弹（装机窗、设置都是 sheet，从被盖住的那层弹不出来）
private struct AppleLoginSheetHost: ViewModifier {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let host: String
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.appleLoginHost == host }, set: { if !$0, model.appleLoginHost == host { model.closeAppleLogin() } })) {
            AppleLoginSheet(model: model).environmentObject(loc)
        }
    }
}

extension View {
    func appleLoginSheet(_ model: S2ArmLauncherModel, host: String) -> some View { modifier(AppleLoginSheetHost(model: model, host: host)) }
}
