// 一次同步：导出本地存档 → 算内容标识 → 读所有 head → decideSaveSync → 上传 / 下载恢复 / 让玩家选。
//   导出、检查、恢复都走各端现成的存档作业（iOS 服务层 S2A_SaveTransfer、Mac pack/jobs/saves.py），这里不碰存档目录。
//   任何一步失败：本地存档不动（恢复本身是事务，失败回滚），基线不前进，下次再试。
import Foundation

/// 各端接的三个存档作业。archive 都在 work 临时目录里，不在存档目录和事务目录里
public struct SaveSyncPorts: Sendable {
    /// 本地存档导出成 .s2asave；没有存档回 false、不写文件
    public var export: @Sendable (URL) async throws -> Bool
    /// 读一份 .s2asave 的清单（白名单文件路径 + sha256），用来算内容标识
    public var inspect: @Sendable (URL) async throws -> [SaveFile]
    /// 用这份 .s2asave 覆盖本地存档（现成作业：先检查、恢复前自动留备份）
    public var restore: @Sendable (URL) async throws -> Void

    public init(export: @escaping @Sendable (URL) async throws -> Bool, inspect: @escaping @Sendable (URL) async throws -> [SaveFile],
                restore: @escaping @Sendable (URL) async throws -> Void) {
        self.export = export; self.inspect = inspect; self.restore = restore
    }
}

/// 冲突时给玩家看的一项：本机（head 为空）或某台设备的云端版本
public struct SaveSyncChoice: Equatable, Sendable {
    public let head: SaveHead?
    public let deviceName: String
    public let savedAt: Date?
    public let bytes: Int64
    /// mac / iphone / ipad；不知道为 nil
    public let platform: String?
    public var isLocal: Bool { head == nil }
}

public enum SaveSyncOutcome: Equatable, Sendable {
    case upToDate
    case uploaded
    case downloaded(from: String)
    case keptLocal
    case tookRemote(from: String)
    /// 有冲突、玩家没选：两边都不动
    case conflictSkipped
}

public final class SaveSyncEngine: Sendable {
    public static let keepOwnSnapshots = 3
    let folder: CloudSaveFolder
    let device: String
    let deviceName: String
    let platform: String?
    let work: URL
    let ports: SaveSyncPorts
    let loadBase: @Sendable () -> String?
    let storeBase: @Sendable (String) -> Void
    let now: @Sendable () -> Date

    /// device：本设备固定的 uuid；work：本次可用的临时目录（同步完删掉）；loadBase / storeBase：这款这个文件夹上次同步后的状态（SaveBase 的 JSON）
    public init(folder: CloudSaveFolder, device: String, deviceName: String, platform: String? = nil, work: URL, ports: SaveSyncPorts,
                loadBase: @escaping @Sendable () -> String?, storeBase: @escaping @Sendable (String) -> Void,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.folder = folder; self.device = device; self.deviceName = deviceName; self.platform = platform; self.work = work; self.ports = ports
        self.loadBase = loadBase; self.storeBase = storeBase; self.now = now
    }

    /// 基线存成 JSON 字符串（各端只管存取，不解析）；读不懂当没同步过
    static func decodeBase(_ text: String?) -> SaveBase? { text.flatMap { try? JSONDecoder().decode(SaveBase.self, from: Data($0.utf8)) } }
    static func encodeBase(_ base: SaveBase) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: (try? e.encode(base)) ?? Data(), as: UTF8.self)
    }
    func store(_ base: SaveBase) { storeBase(Self.encodeBase(base)) }
    func bump(_ clock: SaveClock) -> SaveClock { var c = clock; c[device, default: 0] += 1; return c }

    /// choose：冲突时让玩家选（候选里本机在前，云端按时间新的在前）；回 nil = 这次先不处理。
    ///   外层 Task 取消（玩家点「跳过」）：在下一个检查点抛 CancellationError，本地存档不动；恢复已经开始的那一步会做完
    public func sync(choose: @Sendable ([SaveSyncChoice]) async -> SaveSyncChoice?) async throws -> SaveSyncOutcome {
        let fm = FileManager.default
        let scratch = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let localArchive = scratch.appendingPathComponent("local.s2asave")
        let hasLocal = try await ports.export(localArchive)
        let local = hasLocal ? saveContentID(try await ports.inspect(localArchive)) : nil
        let base = Self.decodeBase(loadBase())
        let seen = base?.clock ?? [:]
        try Task.checkCancellation()
        let heads = try folder.heads()
        try Task.checkCancellation()

        switch decideSaveSync(local: local, base: base, heads: heads, device: device) {
        case .upToDate:
            return .upToDate
        case .adopt(let same):
            store(SaveBase(content: local!, clock: saveClockMerged([seen] + same.map(\.clock))))
            return .upToDate
        case .upload:
            try publish(localArchive, content: local!, clock: bump(seen), heads: heads)
            return .uploaded
        case .download(let remote):
            try await take(remote, scratch: scratch, seen: seen)
            return .downloaded(from: remote.deviceName)
        case .conflict(let remotes):
            var choices = remotes.map { SaveSyncChoice(head: $0, deviceName: $0.deviceName, savedAt: $0.savedAt, bytes: $0.bytes, platform: $0.platform) }
            if local != nil {
                let size = (try? fm.attributesOfItem(atPath: localArchive.path)[.size] as? NSNumber)?.int64Value ?? 0
                choices.insert(SaveSyncChoice(head: nil, deviceName: deviceName, savedAt: nil, bytes: size, platform: platform), at: 0)
            }
            guard let picked = await choose(choices) else { return .conflictSkipped }
            try Task.checkCancellation()
            // 选定后发布的新版本覆盖所有候选的向量：别的设备不再把落选的版本当新版本；两台设备同时各自选定，向量互不覆盖，仍会再问
            let all = saveClockMerged([seen] + remotes.map(\.clock))
            if let remote = picked.head {
                try await take(remote, scratch: scratch, seen: all)
                let clock = bump(all)
                do {
                    try folder.putHead(SaveHead(device: device, deviceName: deviceName, snapshot: remote.snapshot, archiveSha256: remote.archiveSha256,
                                                content: remote.content, clock: clock, savedAt: now(), bytes: remote.bytes, platform: platform))
                } catch {
                    throw SaveSyncError.cloudWriteAfterRestore(remote.deviceName, error.localizedDescription)
                }
                store(SaveBase(content: remote.content, clock: clock))
                return .tookRemote(from: remote.deviceName)
            }
            try publish(localArchive, content: local!, clock: bump(all), heads: heads)
            return .keptLocal
        }
    }

    /// 只上传（游戏进行中切到后台时用）：本机比基线新、云端没有更新的版本才发布；云端有更新或有冲突时什么都不动，回 nil，
    ///   留给下次起局前的完整同步（游戏在跑，不能把存档换掉，也没有页面让玩家选）
    public func uploadIfAhead() async throws -> SaveSyncOutcome? {
        let fm = FileManager.default
        let scratch = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let localArchive = scratch.appendingPathComponent("local.s2asave")
        let hasLocal = try await ports.export(localArchive)
        let local = hasLocal ? saveContentID(try await ports.inspect(localArchive)) : nil
        let base = Self.decodeBase(loadBase())
        let seen = base?.clock ?? [:]
        let heads = try folder.heads()

        switch decideSaveSync(local: local, base: base, heads: heads, device: device) {
        case .upToDate:
            return .upToDate
        case .adopt(let same):
            store(SaveBase(content: local!, clock: saveClockMerged([seen] + same.map(\.clock))))
            return .upToDate
        case .upload:
            try publish(localArchive, content: local!, clock: bump(seen), heads: heads)
            return .uploaded
        case .download, .conflict:
            return nil
        }
    }

    /// 下载 remote、核 sha256、走现成恢复；成功后基线 = remote（见过的向量合进它的）
    func take(_ remote: SaveHead, scratch: URL, seen: SaveClock) async throws {
        let incoming = scratch.appendingPathComponent("incoming.s2asave")
        try folder.download(remote, to: incoming)
        try Task.checkCancellation()
        try await ports.restore(incoming)
        store(SaveBase(content: remote.content, clock: saveClockMerged([seen, remote.clock])))
    }

    /// 发布本地快照：先快照后 head；成功后基线 = 本地内容 + 新向量，再清本设备旧快照
    func publish(_ archive: URL, content: String, clock: SaveClock, heads: [SaveHead]) throws {
        let snapshot = "snap-\(device)-\(UUID().uuidString.lowercased()).s2asave"
        let sha = try sha256File(archive)
        let bytes = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        try folder.putSnapshot(archive, as: snapshot, sha256: sha)
        let head = SaveHead(device: device, deviceName: deviceName, snapshot: snapshot, archiveSha256: sha, content: content,
                            clock: clock, savedAt: now(), bytes: bytes, platform: platform)
        try folder.putHead(head)
        store(SaveBase(content: content, clock: clock))
        folder.prune(device: device, keep: Self.keepOwnSnapshots, heads: heads.filter { $0.device != device } + [head])
    }
}
