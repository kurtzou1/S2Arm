// S2Arm（不是上游文件）：应用内更新交给 Sparkle 2（v0.3.10 维护者拍板「换」：不再修补自写的 pack/jobs/updater.py 换版，#931 / #965）。
// Sparkle 负责查 appcast、下载、EdDSA 验签、整包替换、失败回滚、重启；这里只把它的每一步映射到启动器原有的状态与按钮（UpdateState），
// 不用 Sparkle 自带窗口：玩家看到的还是「有新版 → 下载中 → 现在更新并重启」，控制口 /update 照旧能驱动。
import AppKit
import Foundation
import Sparkle

@MainActor final class SparkleUpdate: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    weak var model: S2ArmLauncherModel?
    private(set) var updater: SPUUpdater!
    private var expected: UInt64 = 0, received: UInt64 = 0
    /// 下载解开好、等玩家点「现在更新并重启」时 Sparkle 给的回复
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private(set) var foundVersion: String?

    init(model: S2ArmLauncherModel) {
        self.model = model
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try updater.start() } catch { log("Sparkle 起不来：\(error.localizedDescription)") }
    }

    /// 验收 / 内部联调用的假 appcast（S2A_UPDATE_FEED），没设就用 Info.plist 的 SUFeedURL（dl.s2arm.com/appcast/mac.xml）
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["S2A_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 玩家点了才下载（同原流程：有新版就后台下好，换版要玩家点）
    func checkAndDownload() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    var readyToInstall: Bool { installReply != nil }

    /// 「现在更新并重启」：先摘掉窗口上的弹窗（挂着 sheet 时 NSApp.terminate 会被忽略，见 QuitAfterSheets），再让 Sparkle 退出、替换、重启
    func installNow() {
        guard let reply = installReply else { return }
        installReply = nil
        log("玩家点了更新并重启：交给 Sparkle 替换 \(foundVersion ?? "?")")
        QuitAfterSheets.run(terminate: { reply(.install) })
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 定时自动检查不开（Info.plist SUEnableAutomaticChecks = NO）：查新版走启动时的公告 / 消息，这里不再问玩家
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { model?.updateState = .working("update.downloading", nil) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundVersion = appcastItem.displayVersionString
        log("发现新版 \(appcastItem.displayVersionString)（构建号 \(appcastItem.versionString)），开始下载")
        if state.stage == .installing { model?.updateState = .ready; installReply = reply; return }
        reply(.install)   // 下载：真正换版仍等玩家点
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log("没有新版：\(error.localizedDescription)")
        model?.updateState = .idle
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        log("更新失败（Sparkle \(ns.domain) \(ns.code)）：\(ns.localizedDescription)\(ns.localizedFailureReason.map { "；" + $0 } ?? "")")
        model?.updateFailure = ns.localizedDescription
        model?.updateState = .failed("update_failed")
        installReply = nil
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { expected = 0; received = 0; model?.updateState = .working("update.downloading", 0) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        model?.updateState = .working("update.downloading", expected > 0 ? Int(min(received, expected) * 100 / expected) : nil)
    }
    func showDownloadDidStartExtractingUpdate() { model?.updateState = .working("update.verifying", nil) }
    func showExtractionReceivedProgress(_ progress: Double) { model?.updateState = .working("update.unpacking", Int(progress * 100)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("新版 \(foundVersion ?? "?") 已下载并验签，等玩家点更新并重启")
        installReply = reply
        model?.updateState = .ready
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("Sparkle 正在替换（App 已退出：\(applicationTerminated)）")
        if !applicationTerminated { QuitAfterSheets.run(terminate: retryTerminatingApplication) }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("已换上新版（重启：\(relaunched)）")
        acknowledgement()
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {
        if case .working = model?.updateState { model?.updateState = .idle }
    }

    /// 每一步记进 <私有目录>/logs/update.log（诊断包会收）：玩家反馈「更新没反应」时靠它定位
    func log(_ text: String) {
        guard let root = model?.provider.client.environment.privateRoot else { return }
        let dir = root.appendingPathComponent("logs"), file = dir.appendingPathComponent("update.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) [Sparkle] \(text)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: file) }
    }
}
