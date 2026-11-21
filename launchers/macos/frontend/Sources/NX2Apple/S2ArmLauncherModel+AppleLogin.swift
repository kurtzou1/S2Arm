// S2Arm（不是上游文件）：0.6.0 Mac 的 Apple ID 登录（作业层 pack/jobs/apple_login.py：随包 plumesign 自己登录，不看 Xcode），
//   与装机前清单的动作派发（落点表唯一来源：共享规格 install_landing，作业层每项没好时带一个 action，清单按钮、控制口 /install-action 都走 performInstallAction）。
//   登录面板（AppleLoginViews.swift）只有一个：装机清单、设置「签名身份」、环境检查、欢迎页、装机失败页都打开它。
//   密码只在面板的输入框里、只经环境变量交给登录那一次作业；验证码 / 改短信经适配层写进作业在等的文件。
import Foundation
import S2ArmAppleAdapter

/// 登录面板进行到哪
enum AppleLoginPhase: Equatable {
    case idle
    case signingIn
    /// 作业在等验证码（prompt.canSms：能改用短信接收；prompt.sms：这次是短信方式）
    case needCode(AppleLoginPrompt)
    case done(AppleAccount)
    case failed(message: String, suggestion: String)
}

/// 装机清单里要离开装机窗去的地方（装机窗先关自己，再由模型打开目标）
enum InstallLeave: Equatable {
    case export(String)
    case settings(String)
}

extension S2ArmLauncherModel {
    /// 落点表里的动作（共享规格 install_landing.actions；只认表里的，别的不派发）
    static var installActions: Set<String> { Set(BackendText.installLandingActions.keys) }

    /// 当前呈现的弹窗 / 面板（控制口 GET /state 的 presented，取值同清单动作名）；什么都没开 = nil
    var presented: String? {
        if appleLoginHost != nil { return "appleLogin" }
        if let help = installHelp { return help }
        if pickDeviceFocus { return "pickDevice" }
        if showEnvironment, settingsFocus == "devCertSettings" { return "devCertSettings" }
        if exportFor != nil { return "openExport" }
        return nil
    }

    /// 收起清单动作打开的东西（控制口 /dismiss、/show 换页：同 Windows 的 presented 语义，换页 / 关提示就清空）
    func clearPresented() {
        if appleLoginHost != nil { closeAppleLogin() }
        installHelp = nil; pickDeviceFocus = false; settingsFocus = nil
    }

    // MARK: 清单动作

    /// 装机前清单一项的动作（清单按钮与控制口 /install-action 同一个入口）：要在装机窗里做的先确保这款的装机窗开着
    func performInstallAction(_ action: String, gameId: String) {
        switch action {
        case "openExport": leaveInstall(.export(gameId))
        case "devCertSettings": leaveInstall(.settings(gameId))
        case "appleLogin": showInstall(gameId); openAppleLogin(host: "install")
        case "pickDevice": showInstall(gameId); pickDeviceFocus = true
        case "trustHelp", "developerModeHelp": showInstall(gameId); installHelp = action
        default: break
        }
    }

    private func showInstall(_ gameId: String) {
        if installViewOpen != gameId { showInstallFor = gameId }
    }

    /// 离开装机窗：开着就交给它先关自己（InstallView 收到 installLeave 后 dismiss 再调 applyInstallLeave）；没开直接去
    private func leaveInstall(_ to: InstallLeave) {
        if installViewOpen != nil { installLeave = to } else { applyInstallLeave(to) }
    }

    func applyInstallLeave(_ to: InstallLeave) {
        installLeave = nil
        switch to {
        case .export(let id): showEnvironment = false; exportFor = id
        case .settings: settingsFocus = "devCertSettings"; showEnvironment = true
        }
    }

    // MARK: Apple ID 登录

    /// 读当前账号（设置、装机清单出现时）；读失败保留原值并报一次原因（剃刀 M12）
    func refreshAppleAccount() {
        Task {
            do { appleAccount = try await provider.appleAccount(); readOK("s2arm.fail.appleAccount") }
            catch { reportFailure("s2arm.fail.appleAccount", error, passive: true) }
        }
    }

    /// 打开登录面板（host：挂在哪一层弹出——install 装机窗 / settings 设置 / main 主窗口；reason：expired = 登录过期）；上一次的结局清掉，重新填。
    ///   顺手重读当前账号：面板邮箱框带上原来的邮箱
    func openAppleLogin(host: String, reason: String? = nil) {
        if case .needCode = appleLoginPhase {} else if appleLoginPhase != .signingIn { appleLoginPhase = .idle }
        appleLoginReason = reason
        appleLoginHost = host
        refreshAppleAccount()
    }

    /// 装机 / 推送失败的码要落到登录面板的（失败页「登录 Apple ID」按钮）：没登录、登录过期
    /// 作业层等冷却的阶段（pack/jobs/apple_login.py _cool_wait；progress 带 wait = 还要等几秒）
    static let appleLoginWaitKey = "appleLogin.wait"
    static let appleLoginCodes: [String: String?] = ["apple_not_signed_in": nil, "apple_session_expired": "expired"]

    /// 关面板：在登录的那一次作业一并停掉（作业层照取消收尾）
    func closeAppleLogin() {
        appleLoginTask?.cancel(); appleLoginTask = nil; appleLoginWait = nil
        if case .done = appleLoginPhase {} else { appleLoginPhase = .idle }
        appleLoginHost = nil; appleLoginReason = nil
    }

    /// 登录成功页点「换一个 Apple ID」：面板不关，回到输入页（邮箱框清空，填新账号）；同设置里「换一个 Apple ID」
    func switchAppleLogin() {
        appleLoginTask?.cancel(); appleLoginTask = nil
        appleLoginReason = nil
        appleLoginPhase = .idle
    }

    /// 登录（「没收到？再发一次」也走这里：先停掉在等验证码的那次，再起一次）
    func startAppleLogin(account: String, password: String) {
        appleLoginTask?.cancel()
        appleLoginPhase = .signingIn
        appleLoginWait = nil
        let sink = EventSink { [weak self] e in
            if let key = e.fields["stageKey"] as? String, key.hasPrefix("appleLogin") {   // 冷却等完、开始连苹果：倒计时收起
                let left = key == Self.appleLoginWaitKey ? (e.fields["wait"] as? NSNumber)?.intValue : nil
                if key != Self.appleLoginWaitKey || left != nil { Task { @MainActor in self?.appleLoginWait = left } }
            }
            guard let prompt = AppleLoginPrompt(event: e) else { return }
            Task { @MainActor in self?.appleLoginPhase = .needCode(prompt) }
        }
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        appleLoginTask = Task { [weak self] in
            defer { self?.appleLoginWait = nil }
            do {
                guard let got = try await self?.provider.appleLogin(account: trimmed, password: password, events: sink) else { return }
                if Task.isCancelled { return }
                self?.appleAccount = got
                self?.appleLoginReason = nil
                self?.appleLoginPhase = .done(got)
                self?.afterAppleLogin()
            } catch {
                if Task.isCancelled { return }
                let suggestion = (error as? JobFailure)?.outcome.failureDiagnostic?["suggestion"] as? String ?? ""
                if (error as? JobFailure)?.code == "apple_session_expired" { self?.appleLoginReason = "expired" }
                self?.appleLoginPhase = .failed(message: error.localizedDescription, suggestion: suggestion)
            }
        }
    }

    /// 交验证码（6 位数字）或改用短信（sms）：写进作业在等的文件；交了验证码回到「正在登录」，改短信等作业再要一次码
    func submitAppleLoginCode(_ code: String) -> String? {
        guard case .needCode(let prompt) = appleLoginPhase else { return nil }
        do { try provider.appleLoginCode(code, taskId: prompt.taskId) } catch { return error.localizedDescription }
        appleLoginPhase = .signingIn
        return nil
    }

    /// 登录成功：清单、环境检查里 Apple ID 那一项跟着变（不等下一轮轮询）
    private func afterAppleLogin() {
        if let id = installGameID { checkInstall(id) }
        if !checks.isEmpty { checkEnvironment() }
    }
}
