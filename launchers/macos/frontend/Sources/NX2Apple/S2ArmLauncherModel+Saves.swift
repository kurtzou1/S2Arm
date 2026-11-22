// S2Arm（不是上游文件）：存档管理（SaveManageSheet）调的四个作业（pack/jobs/saves.py）：saveStatus 读当前存档、saveBackup 备份到玩家选的位置、
// saveInspect 检查一份备份（我方 .s2asave，或 JKSV / Checkpoint / yuzu / Ryujinx 的存档文件夹 / zip）、saveRestore 用检查过的备份覆盖当前存档。
// 作业自己拿游戏库的执行锁：游戏在跑或别的任务在用游戏库时作业层拒绝，原话由弹窗显示。结果按作业层字段解成下面几个结构，字段缺了算读不全。
import Foundation
import S2ArmAppleAdapter

/// saveStatus 的结果。
struct SaveStatusInfo: Equatable {
    let hasSave: Bool
    let fileCount: Int
    let totalBytes: Int64
    /// 上一次恢复前自动保留的存档（before-restore.s2asave）；没有为空。
    let previousBackup: String
    /// 这次读状态时把一次没做完的恢复撤回了。
    let recovered: Bool
    /// 没做完的恢复自动撤回失败时的记录位置；没有为空。
    let recoveryFailed: String
    /// 待放区里等着的存档文件数（没在这台 Mac 上玩过的这款，恢复先放进待放区、第一次启动时灌入；#2066）；没有为 nil。
    let pendingFiles: Int?

    init?(_ r: [String: Any]) {
        guard let has = r["hasSave"] as? Bool else { return nil }
        hasSave = has
        fileCount = (r["fileCount"] as? NSNumber)?.intValue ?? 0
        totalBytes = (r["totalBytes"] as? NSNumber)?.int64Value ?? 0
        previousBackup = r["previousBackup"] as? String ?? ""
        recovered = r["recovered"] as? Bool ?? false
        recoveryFailed = r["recoveryFailed"] as? String ?? ""
        pendingFiles = ((r["pendingSeed"] as? [String: Any])?["fileCount"] as? NSNumber)?.intValue
    }
}

/// saveInspect 的结果：给玩家看的几项，加恢复时要原样带回去的三个校验值（备份与当前存档在检查后没变才恢复）。
struct SavePreviewInfo: Equatable {
    let source: URL
    let gameName: String
    let gameVersion: Int64
    let createdAt: Date?
    let fileCount: Int
    let totalBytes: Int64
    /// 社区存档目录结构存疑时作业层的一句提示（STRUCTURE_NOTICE）；正常为空。
    let notice: String
    let archiveSha256: String
    let targetFingerprint: String
    let previewLibraryId: String

    init?(_ r: [String: Any], source: URL) {
        guard let manifest = r["manifest"] as? [String: Any], let game = manifest["game"] as? [String: Any],
              let sha = r["archiveSha256"] as? String, let target = r["targetFingerprint"] as? String,
              let library = r["previewLibraryId"] as? String else { return nil }
        self.source = source
        gameName = game["name"] as? String ?? ""
        gameVersion = (game["version"] as? NSNumber)?.int64Value ?? 0
        createdAt = (manifest["createdAt"] as? String).flatMap(Self.parseDate)
        fileCount = (r["fileCount"] as? NSNumber)?.intValue ?? 0
        totalBytes = (r["totalBytes"] as? NSNumber)?.int64Value ?? 0
        notice = r["notice"] as? String ?? ""
        archiveSha256 = sha; targetFingerprint = target; previewLibraryId = library
    }

    /// 作业层写的是 datetime.isoformat()（带微秒、带时区）：先按带小数秒解，不行再按不带的解。
    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

/// saveRestore 的结果。
struct SaveRestoreInfo: Equatable {
    let hadOriginal: Bool
    let previousBackup: String
    /// 存档已恢复但事务记录没清完时作业层的原话；正常为空。
    let cleanupWarning: String
    /// 只是放进了待放区（这款在这台 Mac 上还没玩过），第一次启动时才进存档（#2066）
    let pending: Bool

    init(_ r: [String: Any]) {
        hadOriginal = r["hadOriginal"] as? Bool ?? false
        pending = r["pending"] as? Bool ?? false
        previousBackup = r["previousBackup"] as? String ?? ""
        cleanupWarning = r["cleanupWarning"] as? String ?? ""
    }
}

/// 存档作业的结果字段缺了（作业层版本不对）。
struct SaveResultIncomplete: Error {}

extension S2ArmLauncherModel {
    /// 交一个存档作业并等它结束，回作业结果。没配游戏库不起作业；失败抛 JobFailure（message 是作业层原话）。
    func saveJob(_ operation: String, gameID: String, extra: [String: Any] = [:], events: EventSink? = nil) async throws -> [String: Any] {
        let client = provider.client
        defer { lockWaitNote = nil }
        let lock = lockWaitSink()   // 等锁原句另外显示（剃刀 M3）；调用方的去处（存档弹窗的进度）照收
        let sink = EventSink { e in events?.emit(e); lock.emit(e) }
        guard !client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        var request = extra
        request["gameId"] = gameID
        return try await client.perform(operation, extra: request, events: sink).result
    }

    func saveStatus(_ gameID: String, events: EventSink? = nil) async throws -> SaveStatusInfo {
        guard let info = SaveStatusInfo(try await saveJob("saveStatus", gameID: gameID, events: events)) else { throw SaveResultIncomplete() }
        return info
    }

    /// 存档页「不要了」：删掉待放区里这款等着的存档（saveDiscardSeed，#2066）
    func saveDiscardSeed(_ gameID: String, events: EventSink? = nil) async throws {
        _ = try await saveJob("saveDiscardSeed", gameID: gameID, events: events)
    }

    /// 备份到 destination（玩家在保存面板里选的文件）；回作业层实际写下的路径。
    func saveBackup(_ gameID: String, to destination: URL, events: EventSink? = nil) async throws -> String {
        let r = try await saveJob("saveBackup", gameID: gameID, extra: ["path": destination.path], events: events)
        return r["outputPath"] as? String ?? destination.path
    }

    /// sync：云存档自动同步调用（没人看提示、不经玩家确认）——版本 / DLC 组合、用户归属对不上时作业层照旧拒绝；玩家手动恢复不带，只提示、照常恢复
    func saveInspect(_ gameID: String, source: URL, sync: Bool = false, events: EventSink? = nil) async throws -> SavePreviewInfo {
        var extra: [String: Any] = ["path": source.path]
        if sync { extra["sync"] = true }
        // 本地玩家（#623）：社区存档导进当前玩家的账号存档（pack/jobs/saves.py external_archive）；恢复时带同一个玩家
        if let player = S2ArmLauncherModel.playerRequest() { extra["player"] = player }
        let r = try await saveJob("saveInspect", gameID: gameID, extra: extra, events: events)
        guard let preview = SavePreviewInfo(r, source: source) else { throw SaveResultIncomplete() }
        return preview
    }

    /// 用检查过的备份覆盖当前存档：带回检查时的三个校验值，备份或当前存档变了作业层拒绝（save_changed）。
    func saveRestore(_ gameID: String, preview: SavePreviewInfo, sync: Bool = false, events: EventSink? = nil) async throws -> SaveRestoreInfo {
        var extra: [String: Any] = ["path": preview.source.path, "archiveSha256": preview.archiveSha256,
                                    "targetFingerprint": preview.targetFingerprint, "previewLibraryId": preview.previewLibraryId]
        if sync { extra["sync"] = true }
        if let player = S2ArmLauncherModel.playerRequest() { extra["player"] = player }
        return SaveRestoreInfo(try await saveJob("saveRestore", gameID: gameID, extra: extra, events: events))
    }
}
