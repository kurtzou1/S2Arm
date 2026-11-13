// S2Arm（不是上游文件）：覆盖更新（11-08 维护者）。下载、校验、替换、回滚都在共用的 pack/jobs/updater.py，这里只管状态和按钮。
// 玩家的数据不在 App 里；出包等作业进行中不提示、不替换。
import AppKit
import Foundation
import S2ArmAppleAdapter

enum UpdateState: Equatable {
    case idle
    case working(String, Int?)   // 文案号，百分比
    case ready
    case failed(String)          // 错误码
}

extension S2ArmLauncherModel {
    /// 自动更新失败时「打开下载页」：官方下载页（用系统浏览器打开），手动下载新版
    static let downloadPage = URL(string: "https://jhaizhou-ops.github.io/S2Arm/")!

    /// 控制口用：{state, detail, percent}。
    var updateStatus: [String: Any] {
        switch updateState {
        case .idle: return ["state": "idle"]
        case .working(let id, let percent): return ["state": "working", "detail": id, "percent": percent ?? NSNull()]
        case .ready: return ["state": "ready", "detail": updateReady?["version"] ?? "", "via": updateReady?["via"] ?? ""]
        case .failed(let code): return ["state": "failed", "detail": code]
        }
    }

    private var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    private var updatesFolder: URL { provider.client.environment.privateRoot.appendingPathComponent("updates") }

    /// 启动时：告诉替换进程新版起来了；上一次更新失败要告诉玩家。
    func finishPendingUpdate() {
        let fm = FileManager.default
        if fm.fileExists(atPath: updatesFolder.appendingPathComponent("pending.json").path) {
            try? Data("ok".utf8).write(to: updatesFolder.appendingPathComponent("health.ok"))
        }
        let failure = updatesFolder.appendingPathComponent("last_failure.json")
        if let data = try? Data(contentsOf: failure), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let code = json["code"] as? String { updateState = .failed(code) }
            try? fm.removeItem(at: failure)
        }
    }

    /// 启动时一次：查版本 + 取公告，按「永远只给最新一期」算出弹窗 / 横幅 / 消息（pack/jobs/updater.py inbox）。有新版照旧在后台下好，不打断玩家；
    ///   查不到（没网、GitHub 不通）什么都不显示
    func loadInbox() {
        Task {
            guard let result = await provider.client.inbox(current: currentVersion) else { return }
            notice = result["banner"] as? [String: Any]
            messages = result["messages"] as? [[String: Any]] ?? []
            unreadMessages = result["unread"] as? Int ?? 0
            if let update = result["update"] as? [String: Any], update["available"] as? Bool == true { availableUpdate = update }
            updatePopup = result["popup"] as? [String: Any]
            if availableUpdate != nil, updateState == .idle { downloadUpdate() }
        }
    }

    /// 玩家点 ×：当场收起，再记下这条（比它旧的也都算看过）
    func dismissNotice() {
        guard let id = notice?["id"] as? String else { return }
        notice = nil
        if (messages.first?["id"] as? String) == id { unreadMessages = 0 }
        Task { await provider.client.inboxSeen(notice: id) }
    }

    /// 关掉弹窗（以后再说 / 知道了）：这一版不再弹
    func closeUpdatePopup() {
        updateGate = nil
        guard let popup = updatePopup, let version = popup["version"] as? String else { updatePopup = nil; return }
        updatePopup = nil
        let after = popup["kind"] as? String == "afterUpdate"
        Task { await provider.client.inboxSeen(update: after ? nil : version, after: after ? version : nil) }
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

    func downloadUpdate() {
        switch updateState { case .idle, .failed: break; default: return }
        updateState = .working("update.downloading", 0)
        let install = Bundle.main.bundlePath
        Task {
            let result = await provider.client.updatePrepare(current: currentVersion, install: install) { [weak self] event in
                let state = event["state"] as? String, done = event["done"] as? Double ?? (event["done"] as? Int).map(Double.init), total = event["total"] as? Double ?? (event["total"] as? Int).map(Double.init)
                Task { @MainActor in
                    switch state {
                    case "downloading": self?.updateState = .working("update.downloading", (done != nil && (total ?? 0) > 0) ? Int(done! * 100 / total!) : nil)
                    case "verifying": self?.updateState = .working("update.verifying", nil)
                    case "unpacking": self?.updateState = .working("update.unpacking", nil)
                    default: break
                    }
                }
            }
            guard let result, result["state"] as? String == "ready" else {
                updateState = .failed(result?["code"] as? String ?? "update_failed")
                return
            }
            updateReady = result
            updateState = .ready
        }
    }

    /// 只有玩家点了才重启。有局 / 任务在跑：先拦下说清（草图④：前置检查，不进换版；update_app_busy 是换版时旧 S2Arm 没退出，另说）
    func restartToUpdate() {
        if busy { updateGate = session?.kind == .play ? "update.gate.playing" : "update.gate.busy"; return }
        guard let ready = updateReady else { return }
        updatePopup = nil
        do {
            try provider.client.updateApply(ready: ready, install: Bundle.main.bundlePath, arguments: Array(CommandLine.arguments.dropFirst()))
            NSApp.terminate(nil)
        } catch {
            updateState = .failed("update_failed")
        }
    }
}
