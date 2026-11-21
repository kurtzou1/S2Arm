// S2Arm（不是上游文件）：覆盖更新。下载、验签、替换、回滚、重启交给 Sparkle 2（SparkleUpdate.swift），这里只管状态和按钮；
// 有没有新版、更新说明、公告仍由 pack/jobs/updater.py inbox 给。玩家的数据不在 App 里。
// SimulatedUpdateDriver 只在没有更新源的构建里接管，发行版一律走 Sparkle。
import AppKit
import Foundation
import S2ArmAppleAdapter

enum UpdateState: Equatable {
    case idle
    case working(String, Int?)
    case ready
    case failed(String)

    var popupActions: (secondary: String, primary: String, showsAutoRestart: Bool, primaryEnabled: Bool) {
        switch self {
        case .idle: return ("update.popup.later", "update.popup.updateNow", true, true)
        case .working: return ("update.popup.close", "update.popup.downloadingBtn", true, false)
        case .ready: return ("update.popup.later", "update.popup.restartNow", false, true)
        case .failed: return ("update.popup.later", "update.popup.retryNow", true, true)
        }
    }
}

@MainActor protocol LauncherUpdateDriver: AnyObject {
    var downloadBytes: (received: UInt64, expected: UInt64) { get }
    var readyToInstall: Bool { get }
    func check(current: String, fresh: Bool) async -> [String: Any]?
    func startDownload()
    func installNow()
}

extension S2ArmLauncherModel {
    static let downloadPage = URL(string: "https://jhaizhou-ops.github.io/S2Arm/")!

    /// 控制口用：{state, detail, percent}。
    var updateStatus: [String: Any] {
        switch updateState {
        case .idle: return ["state": "idle"]
        case .working(let id, let percent): return ["state": "working", "detail": id, "percent": percent ?? NSNull()]
        case .ready: return ["state": "ready", "detail": updateVersion, "via": updateSimulationEnabled ? "simulation" : "sparkle"]
        case .failed(let code): return ["state": "failed", "detail": code, "reason": updateFailure ?? ""]
        }
    }

    // 交给更新器的本机版本：S2AVersion（build_app.py 写，含预发布段，测试版 0.6.0-test.1 才收得到同号正式版）；老包没有它就退回短版本号
    private var currentVersion: String { (Bundle.main.object(forInfoDictionaryKey: "S2AVersion") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var updateVersion: String { availableUpdate?["version"] as? String ?? "" }
    var updateDownloadBytes: (received: UInt64, expected: UInt64) { updateDriver.downloadBytes }
    var showRestartUpdateButton: Bool { updateState == .ready && !updateRestarting }
    var simulatedUpdate: SimulatedUpdateDriver? { updateSimulationEnabled ? updateDriver as? SimulatedUpdateDriver : nil }
    var updateBusy: Bool { busy || simulatedUpdate?.pretendBusy == true }

    func updateMenuTitle(language: String) -> String {
        func t(_ id: String, _ value: String = "") -> String {
            BackendText.launcherText(id, language: language).replacingOccurrences(of: "{0}", with: value)
        }
        if isCheckingForUpdates { return t("update.menu.checking") }
        switch updateState {
        case .working:
            // 菜单标题不带百分比：进度一变菜单就重建，展开着的子菜单会被关掉、选不到其他项；进度看顶栏的环
            return t("update.menu.downloadingPlain")
        case .ready: return t("update.menu.ready", updateVersion)
        case .idle, .failed:
            return availableUpdate == nil ? t("update.menu.check") : t("update.menu.available", updateVersion)
        }
    }

    func openUpdateMenuItem(activateWindow: @escaping () -> Void) {
        if availableUpdate != nil {
            activateWindow()
            showEnvironment = false
            showUpdatePopup()
        } else {
            checkForUpdatesManually(activateWindow: activateWindow)
        }
    }

    /// 启动 Sparkle 以完成上次换版的收尾；模拟模式只建立模拟驱动。
    func finishPendingUpdate() {
        _ = updateDriver
    }

    func loadInbox() {
        let simulation = simulatedUpdate
        if let popup = simulation?.consumeAfterUpdate() { updatePopup = popup }
        Task {
            guard let result = await provider.client.inbox(current: currentVersion, noticesOnly: simulation != nil) else { return }
            notice = result["banner"] as? [String: Any]
            messages = result["messages"] as? [[String: Any]] ?? []
            unreadMessages = result["unread"] as? Int ?? 0
            guard updatePopup == nil, checkError == nil else { return }
            applyStartupUpdate(result, allowUpdateOffer: !didStartManualUpdateCheck)
        }
    }

    func applyStartupUpdate(_ result: [String: Any], allowUpdateOffer: Bool = true) {
        let popup = result["popup"] as? [String: Any]
        let update = result["update"] as? [String: Any]
        if let kind = popup?["kind"] as? String, kind != "update" { updatePopup = popup }
        guard allowUpdateOffer, autoCheckUpdates, let update, update["available"] as? Bool == true,
              let version = update["version"] as? String else { return }
        availableUpdate = update
        guard popup?["kind"] as? String == "update" else { return }
        // 认得旧版「跳过此版本」留下的偏好；新弹窗统一记录 inboxSeen。
        guard simulatedUpdate != nil || updateDefaults.string(forKey: "S2ASkippedUpdateVersion") != version else { return }
        updatePopup = popup
        if autoDownloadUpdates, simulatedUpdate == nil { downloadUpdate() }
    }

    func checkForUpdatesManually(activateWindow: (() -> Void)? = nil) {
        guard !isCheckingForUpdates else { return }
        didStartManualUpdateCheck = true
        checkError = nil
        isCheckingForUpdates = true
        updateCheckTask = Task {
            let result = await updateDriver.check(current: currentVersion, fresh: true)
            guard !Task.isCancelled else { return }
            updateCheckTask = nil
            isCheckingForUpdates = false
            if let result, result["error"] == nil, let available = result["available"] as? Bool {
                if !available {
                    let version = result["version"] as? String ?? currentVersion
                    activateWindow?()
                    updatePopup = ["kind": "upToDate", "version": version]
                    return
                }
                if let version = result["version"] as? String, !version.isEmpty {
                    availableUpdate = result
                    activateWindow?()
                    showUpdatePopup()
                    return
                }
            }
            let code = result?["error"] as? String ?? ""
            checkError = ["update_network", "update_rate_limited", "update_server"].contains(code) ? code : "update_failed"
            activateWindow?()
        }
    }

    /// 玩家点 ×：当场收起，再记下这条（比它旧的也都算看过）
    func dismissNotice() {
        guard let id = notice?["id"] as? String else { return }
        notice = nil
        if (messages.first?["id"] as? String) == id { unreadMessages = 0 }
        Task { await provider.client.inboxSeen(notice: id) }
    }

    /// 关掉弹窗（以后再说 / 知道了 / 新功能大窗的关闭、跳过、去出包）：这一版 / 这一期不再弹
    /// 「消息」里点「再看一遍」：把这一期新功能大窗再打开（关掉照常记看过，不影响别的弹窗）
    func reopenFeature(_ feature: [String: Any]) {
        guard feature["kind"] as? String == "feature" else { return }
        updatePopup = feature
    }

    func closeUpdatePopup() {
        updateGate = nil
        if updatePopup?["kind"] as? String == "feature", let id = updatePopup?["id"] as? String {
            updatePopup = nil
            Task { await provider.client.inboxSeen(feature: id) }
            return
        }
        guard let popup = updatePopup, let version = popup["version"] as? String else { updatePopup = nil; return }
        updatePopup = nil
        let kind = popup["kind"] as? String
        let after = kind == "afterUpdate"
        guard after || (kind == "update" && updateState == .idle) else { return }
        if let simulatedUpdate {
            if !after { simulatedUpdate.markPromptSeen() }
            return
        }
        Task { await provider.client.inboxSeen(update: after ? nil : version, after: after ? version : nil) }
    }

    /// 新功能大窗最后一页「去出包」：记看过、回游戏库；库里还没有游戏就直接打开「添加游戏」
    func closeFeatureAndExport() {
        closeUpdatePopup()
        showEnvironment = false; exportFor = nil
        if games.isEmpty { showAddGames = true }
    }

    /// 顶栏「有新版 vX」：回到弹窗①
    func showUpdatePopup() {
        guard let update = availableUpdate, let version = update["version"] as? String else { return }
        updatePopup = ["kind": "update", "version": version, "notes": update["notes"] ?? NSNull()]
    }

    /// 打开「消息」：看过最新那条公告，未读清零（更旧的本来就不算未读）
    func openMessages() {
        unreadMessages = 0
        if let id = messages.first(where: { $0["kind"] as? String == "notice" })?["id"] as? String {
            Task { await provider.client.inboxSeen(notice: id) }
        }
    }

    /// 下载新版：交给 Sparkle（SparkleUpdate）查 appcast、下载、验签；进度映射到 updateState
    func downloadUpdate() {
        switch updateState { case .idle, .failed: break; default: return }
        updateFailure = nil
        updateRestarting = false
        updateState = .working("update.downloading", nil)
        updateDriver.startDownload()
    }

    func updateDownloadFound(version: String) {
        if version == updateVersion {
            saveUpdateNotes()
        } else {
            availableUpdate = ["version": version]
            if updatePopup?["kind"] as? String == "update" { showUpdatePopup() }
        }
    }

    /// 换上新版后第一次打开要弹「这版更新了什么」（updater.py inbox 读 updates/notes/<版本>.json）：说明随查到的新版记在本机，换完不再联网
    private func saveUpdateNotes() {
        guard let update = availableUpdate, let version = update["version"] as? String, let notes = update["notes"], !(notes is NSNull),
              JSONSerialization.isValidJSONObject(notes), let data = try? JSONSerialization.data(withJSONObject: notes) else { return }
        let folder = provider.client.environment.privateRoot.appendingPathComponent("updates/notes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(version).json"))
    }

    /// 重启以更新会打断什么：正在玩的那款、正在跑的任务（出包被打断可以接着做：已做完的阶段与缓存保留）
    struct UpdateRestartImpact: Equatable { var game: String?; var task: String?; var taskResumes = false }
    var updateRestartImpact: UpdateRestartImpact {
        var r = UpdateRestartImpact()
        if playBusy, let p = playSession { r.game = p.name }   // 一局在游戏槽，可以和出包同时在跑：两样都列
        if mainBusy, let s = session { r.task = s.name; r.taskResumes = s.kind == .export }
        if r.task == nil, phoneBusy, let p = phoneSession { r.task = p.name }
        return r
    }

    /// 确认框的说明：会关掉哪款、会中断哪个任务、重启后能不能接着做（t = 按界面语言取文案）
    func updateRestartImpactText(_ t: (String) -> String) -> String {
        let i = updateRestartImpact
        var lines: [String] = []
        if let g = i.game { lines.append(t("update.gate.confirm.game").replacingOccurrences(of: "{0}", with: g)) }
        if let k = i.task { lines.append(t(i.taskResumes ? "update.gate.confirm.taskResume" : "update.gate.confirm.taskRestart").replacingOccurrences(of: "{0}", with: k)) }
        if lines.isEmpty, simulatedUpdate?.pretendBusy == true {
            lines.append(t("update.gate.confirm.taskResume").replacingOccurrences(of: "{0}", with: t("update.gate.task.pack")))
        }
        return lines.joined(separator: "\n")
    }

    func updateDidBecomeReady() {
        updateState = .ready
        guard autoRestartWhenReady else { return }
        // 只有更新弹窗开着（玩家正看着）才自动重启；弹窗关了就不打断，顶栏留「重启以更新」让玩家自己点
        guard updatePopup?["kind"] as? String == "update" else {
            logUpdate("更新弹窗已关闭，略过自动重启")
            return
        }
        if updateBusy {
            logUpdate("有任务在跑，略过自动重启")
        } else {
            installReadyUpdate()
        }
    }

    func restartToUpdate(confirmed: Bool = false) {
        guard updateDriver.readyToInstall else { return }
        if updateBusy && !confirmed {
            updateGate = "update.gate.confirm"
            return
        }
        if busy {
            stop()
            stopPlay()
            stopPhone()
        }
        installReadyUpdate()
    }

    private func installReadyUpdate() {
        updateRestarting = true
        updateGate = nil
        updatePopup = nil
        updateDriver.installNow()
    }

    func logUpdate(_ message: String) {
        let dir = provider.client.environment.privateRoot.appendingPathComponent("logs")
        let file = dir.appendingPathComponent("update.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}

/// 退出 App，先等窗口上的 sheet 摘掉。窗口挂着 sheet 时 `NSApp.terminate` 被 AppKit 忽略、不报错（macOS 27.0.1 实测）：
/// 更新弹窗里点「现在更新」，替换进程起来了、S2Arm 没退，等满 120 秒记 update_app_busy，界面上什么都没发生。
/// 每 `pollSeconds` 看一次：没有 sheet 了就退；到 `forcePolls` 次还挂着就主动摘；到 `maxPolls` 次照旧调一次退出、不再等。
@MainActor enum QuitAfterSheets {
    static let pollSeconds = 0.05, forcePolls = 20, maxPolls = 100

    static func run(windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }, polls: Int = 0,
                    terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        let attached = windows().filter { $0.attachedSheet != nil }
        if attached.isEmpty || polls >= maxPolls { terminate(); return }
        if polls >= forcePolls { for window in attached { if let sheet = window.attachedSheet { window.endSheet(sheet) } } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            run(windows: windows, polls: polls + 1, terminate: terminate)
        }
    }
}
