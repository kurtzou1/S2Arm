import Foundation
import Testing
@testable import SaveSync

/// 两台假设备共用一个本地临时目录当「云盘文件夹」（普通目录，没有 iCloud 占位）。
/// 假存档 = 文件名 → 内容的字典；导出写成 JSON，检查按「文件名 + 内容」给出清单，恢复把字典换掉。期望全部手推。
final class FakeDevice: @unchecked Sendable {
    let id: String
    var save: [String: String]?
    var base: String?
    var restores = 0
    let work: URL
    init(_ id: String, save: [String: String]?, work: URL) { self.id = id; self.save = save; self.work = work }

    var ports: SaveSyncPorts {
        SaveSyncPorts(
            export: { [self] url in
                guard let save else { return false }
                try JSONEncoder().encode(save).write(to: url); return true
            },
            inspect: { url in
                let files = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
                return files.map { SaveFile(path: $0.key, sha256: $0.value) }
            },
            restore: { [self] url in
                save = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)); restores += 1
            })
    }

    func engine(_ root: URL, clock: Double) -> SaveSyncEngine {
        SaveSyncEngine(folder: CloudSaveFolder(root: root, gameID: "0100000000000001"), device: id, deviceName: id, work: work, ports: ports,
                       loadBase: { [self] in base }, storeBase: { [self] in base = $0 }, now: { Date(timeIntervalSince1970: clock) })
    }
}

private func scratch() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("savesync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
private func gameDir(_ root: URL) -> URL { root.appendingPathComponent("S2Arm Saves/0100000000000001") }
private func files(_ root: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: gameDir(root).path)) ?? []).sorted() }

@Test func macToPhoneAndBack() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: nil, work: work)
    // Mac 首次：云上什么都没有 → 上传；手机没有存档 → 下载，进度和 Mac 相同
    #expect(try await mac.engine(root, clock: 1).sync { _ in nil } == .uploaded)
    #expect(try await phone.engine(root, clock: 2).sync { _ in nil } == .downloaded(from: "mac"))
    #expect(phone.save == ["a": "1"])
    #expect(try await phone.engine(root, clock: 3).sync { _ in nil } == .upToDate)
    // 手机上玩了 → 上传；Mac 没动 → 下载
    phone.save = ["a": "2"]
    #expect(try await phone.engine(root, clock: 4).sync { _ in nil } == .uploaded)
    #expect(try await mac.engine(root, clock: 5).sync { _ in nil } == .downloaded(from: "phone"))
    #expect(mac.save == ["a": "2"])
    #expect(try await mac.engine(root, clock: 6).sync { _ in nil } == .upToDate)
    #expect(try await phone.engine(root, clock: 7).sync { _ in nil } == .upToDate)
}

@Test func conflictKeepLocalThenOtherSideFollows() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: nil, work: work)
    _ = try await mac.engine(root, clock: 1).sync { _ in nil }
    _ = try await phone.engine(root, clock: 2).sync { _ in nil }
    // 两边各自玩了：Mac 先同步（云上仍是基线）→ 上传；手机再同步 → 冲突，候选 = 本机 + Mac
    mac.save = ["a": "M"]; phone.save = ["a": "P"]
    #expect(try await mac.engine(root, clock: 3).sync { _ in nil } == .uploaded)
    let seen = Box<[SaveSyncChoice]>([])
    #expect(try await phone.engine(root, clock: 4).sync { c in seen.value = c; return c.first { $0.isLocal } } == .keptLocal)
    #expect(seen.value.map(\.deviceName) == ["phone", "mac"])
    // 选了本机：Mac 下次同步拿到手机这份，之后两边都无事
    #expect(try await mac.engine(root, clock: 5).sync { _ in nil } == .downloaded(from: "phone"))
    #expect(mac.save == ["a": "P"])
    #expect(try await phone.engine(root, clock: 6).sync { _ in nil } == .upToDate)
    #expect(try await mac.engine(root, clock: 7).sync { _ in nil } == .upToDate)
}

@Test func conflictTakeRemoteThenNoMoreConflict() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: nil, work: work)
    _ = try await mac.engine(root, clock: 1).sync { _ in nil }
    _ = try await phone.engine(root, clock: 2).sync { _ in nil }
    mac.save = ["a": "M"]; phone.save = ["a": "P"]
    _ = try await mac.engine(root, clock: 3).sync { _ in nil }
    #expect(try await phone.engine(root, clock: 4).sync { c in c.first { !$0.isLocal } } == .tookRemote(from: "mac"))
    #expect(phone.save == ["a": "M"])
    // 手机落选的 P 记进了历史：Mac 不会再被问，两边都无事
    #expect(try await mac.engine(root, clock: 5).sync { _ in nil } == .upToDate)
    #expect(try await phone.engine(root, clock: 6).sync { _ in nil } == .upToDate)
}

@Test func conflictSkippedTouchesNothing() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: ["a": "P"], work: work)
    _ = try await mac.engine(root, clock: 1).sync { _ in nil }
    let before = files(root)
    #expect(try await phone.engine(root, clock: 2).sync { _ in nil } == .conflictSkipped)
    #expect(phone.save == ["a": "P"] && phone.base == nil && phone.restores == 0 && files(root) == before)
}

@Test func corruptSnapshotLeavesLocalAndBaseAlone() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: ["a": "0"], work: work)
    _ = try await mac.engine(root, clock: 1).sync { _ in nil }
    phone.save = nil; phone.base = nil
    let snap = files(root).first { $0.hasPrefix("snap-") }!
    try Data("broken".utf8).write(to: gameDir(root).appendingPathComponent(snap))
    await #expect(throws: SaveSyncError.corrupt(snap)) { try await phone.engine(root, clock: 2).sync { _ in nil } }
    #expect(phone.save == nil && phone.base == nil && phone.restores == 0)
}

@Test func interruptedPublishIsInvisible() async throws {
    // 发布到一半（快照写了、head 没写）：别的设备看不到这份，照旧
    let root = try scratch(), work = try scratch()
    let folder = CloudSaveFolder(root: root, gameID: "0100000000000001")
    let archive = work.appendingPathComponent("x.s2asave"); try Data("{}".utf8).write(to: archive)
    try folder.putSnapshot(archive, as: "snap-mac-1.s2asave", sha256: try sha256File(archive))
    #expect(try folder.heads().isEmpty)
    let phone = FakeDevice("phone", save: ["a": "P"], work: work)
    #expect(try await phone.engine(root, clock: 1).sync { _ in nil } == .uploaded)
    #expect(phone.restores == 0)
}

@Test func longSilentDeviceStaysBuried() async throws {   // 11-09 审查复现：手机只上传过一次，Mac 之后上传 40 次，旧方案第 33 次起手机旧档复活成冲突
    let root = try scratch(), work = try scratch()
    let phone = FakeDevice("phone", save: ["a": "P0"], work: work), mac = FakeDevice("mac", save: nil, work: work)
    #expect(try await phone.engine(root, clock: 1).sync { _ in nil } == .uploaded)
    #expect(try await mac.engine(root, clock: 2).sync { _ in nil } == .downloaded(from: "phone"))
    for i in 1...40 {
        mac.save = ["a": "M\(i)"]
        #expect(try await mac.engine(root, clock: Double(2 + i)).sync { _ in nil } == .uploaded)
    }
    let asked = Box(false)
    #expect(try await mac.engine(root, clock: 50).sync { _ in asked.value = true; return nil } == .upToDate)
    #expect(!asked.value)
    #expect(try await phone.engine(root, clock: 51).sync { _ in asked.value = true; return nil } == .downloaded(from: "mac"))
    #expect(phone.save == ["a": "M40"] && !asked.value)
}

@Test func takeRemoteThenOwnStaleHeadIsNotOffered() async throws {   // 只下载过的设备，自己的旧 head 不会以「另一台设备」出现在候选里
    let root = try scratch(), work = try scratch()
    let phone = FakeDevice("phone", save: ["a": "P"], work: work), mac = FakeDevice("mac", save: nil, work: work)
    _ = try await phone.engine(root, clock: 1).sync { _ in nil }
    _ = try await mac.engine(root, clock: 2).sync { _ in nil }
    mac.save = ["a": "M"]; _ = try await mac.engine(root, clock: 3).sync { _ in nil }
    #expect(try await phone.engine(root, clock: 4).sync { _ in nil } == .downloaded(from: "mac"))
    phone.save = ["a": "P2"]; mac.save = ["a": "M2"]
    _ = try await mac.engine(root, clock: 5).sync { _ in nil }
    let offered = Box<[String]>([])
    #expect(try await phone.engine(root, clock: 6).sync { c in offered.value = c.map(\.deviceName); return nil } == .conflictSkipped)
    #expect(offered.value == ["phone", "mac"])   // 本机 + Mac，没有 phone 自己那份旧 head
}

@Test func pruneKeepsThreeOwnSnapshots() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "0"], work: work)
    for i in 1...6 {
        mac.save = ["a": "\(i)"]
        #expect(try await mac.engine(root, clock: Double(i)).sync { _ in nil } == .uploaded)
    }
    #expect(files(root).filter { $0.hasPrefix("snap-mac-") }.count == 3)
    #expect(files(root).filter { $0.hasPrefix("head-") } == ["head-mac.json"])
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

// 切后台只上传（uploadIfAhead）：本机领先 → 上传、另一台随后下载到同样进度；云端更新 / 冲突 → 回 nil，本机存档、云端文件、基线都不动
@Test func backgroundUploadOnlyWhenAhead() async throws {
    let root = try scratch(), work = try scratch()
    let mac = FakeDevice("mac", save: ["a": "1"], work: work), phone = FakeDevice("phone", save: nil, work: work)
    #expect(try await mac.engine(root, clock: 1).sync { _ in nil } == .uploaded)
    #expect(try await phone.engine(root, clock: 2).sync { _ in nil } == .downloaded(from: "mac"))
    // 手机游戏中存了一档、切后台 → 上传；Mac 随后同步拿到它
    phone.save = ["a": "2"]
    #expect(try await phone.engine(root, clock: 3).uploadIfAhead() == .uploaded)
    #expect(try await phone.engine(root, clock: 4).uploadIfAhead() == .upToDate)
    #expect(try await mac.engine(root, clock: 5).sync { _ in nil } == .downloaded(from: "phone"))
    #expect(mac.save == ["a": "2"])
    // Mac 又玩了并上传；手机没动、切后台：云端更新 → 不下载、不恢复，回 nil
    mac.save = ["a": "3"]
    #expect(try await mac.engine(root, clock: 6).sync { _ in nil } == .uploaded)
    let restores = phone.restores, before = files(root), baseBefore = phone.base
    #expect(try await phone.engine(root, clock: 7).uploadIfAhead() == nil)
    #expect(phone.save == ["a": "2"] && phone.restores == restores && files(root) == before && phone.base == baseBefore)
    // 两边都改了（冲突）：切后台也不动
    phone.save = ["a": "4"]
    #expect(try await phone.engine(root, clock: 8).uploadIfAhead() == nil)
    #expect(phone.save == ["a": "4"] && files(root) == before && phone.base == baseBefore)
}
