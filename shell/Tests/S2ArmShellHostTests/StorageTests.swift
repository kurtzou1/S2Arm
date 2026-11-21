// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 设置 →「存储」总览（#1606）：分类按宿主真实位置、硬链接只算一次、每款合成一行。期望按规则手写，不跑被测实现推
import Foundation
import Testing
@testable import S2ArmShellHost

private let G = "0100000000010000"

@Test func storageCategoriesFollowRealLocations() {
    func c(_ p: String) -> String { S2ArmStorage.category(p.split(separator: "/").map(String.init)) }
    // 资源包：新位置、备用位置、旧位置都算这款的游戏数据；.incoming 是推进来还没解开的
    #expect(c("Library/Application Support/S2Arm/games/\(G)/资源包/game.img") == "game:\(G)")
    #expect(c("Library/Application Support/S2Arm/games/\(G)/program/catalogue.json") == "game:\(G)")
    #expect(c("Library/Application Support/S2Arm/games/\(G)/资源包/.incoming/game.img.0123.0000.zst") == "upload:\(G)")
    #expect(c("Library/S2Arm/games/\(G)/资源包/game.img") == "game:\(G)")
    #expect(c("Documents/games/\(G)/资源包/romfs/a.bin") == "game:\(G)")
    #expect(c("Documents/games/\(G)/资源包/.incoming/001_000.tar") == "upload:\(G)")
    // 存档：S2A 与 SaveData / SaveData-<玩家>
    #expect(c("Documents/games/\(G)/S2A/ryujinx/bis/user/save/0000000000000001/0/a") == "save:\(G)")
    #expect(c("Documents/games/\(G)/SaveData/x.sav") == "save:\(G)")
    #expect(c("Documents/games/\(G)/SaveData-2/x.sav") == "save:\(G)")
    #expect(c("Documents/games/\(G)/unpack.log") == "game:\(G)")
    // 其余
    #expect(c("Documents/games/.deleting/\(G)-abc/资源包/game.img") == "deleting")
    #expect(c("Library/Caches/com.apple.metal/x.data") == "cache")
    #expect(c("Library/Preferences/x.plist") == "application")
    #expect(c("Library/Application Support/S2Arm/other.json") == "application")
    #expect(c("tmp/x") == "systemTemporary")
    #expect(c("Documents/.Trash/x") == "trash")
    #expect(c("Documents/Import Here/x.s2arm") == "documentsOther")
    #expect(c("Documents/games/x.json") == "documentsOther")
}

@Test func storageScanCountsHardLinkOnceAndSkipsLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-storage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("Library/Application Support/S2Arm/games/\(G)/资源包")
    let save = root.appendingPathComponent("Documents/games/\(G)/SaveData")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
    let img = pack.appendingPathComponent("game.img")
    try Data(count: 64 * 1024).write(to: img)
    try FileManager.default.linkItem(at: img, to: pack.appendingPathComponent("game.img.link"))   // 硬链接：逻辑大小算两次，占用只算一次
    try Data(count: 1000).write(to: save.appendingPathComponent("x.sav"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents/out"), withDestinationURL: URL(fileURLWithPath: "/"))   // 链接不顺着走
    let report = try S2ArmStorage.scan(root: root)
    let game = try #require(report.items.first { $0.id == "game:\(G)" })
    let saves = try #require(report.items.first { $0.id == "save:\(G)" })
    #expect(game.files == 2 && game.logicalBytes == 2 * 64 * 1024)
    #expect(game.allocatedBytes >= 64 * 1024 && game.allocatedBytes < 2 * 64 * 1024)
    #expect(saves.files == 1 && saves.logicalBytes == 1000)
    #expect(report.items.map(\.id).sorted() == ["game:\(G)", "save:\(G)"])
}

@Test func storageRowsMergeOneLinePerGame() {
    let report = S2ArmStorage.Report(items: [
        .init(id: "game:A", logicalBytes: 0, allocatedBytes: 100, files: 1), .init(id: "save:A", logicalBytes: 0, allocatedBytes: 5, files: 1),
        .init(id: "upload:A", logicalBytes: 0, allocatedBytes: 7, files: 1), .init(id: "game:B", logicalBytes: 0, allocatedBytes: 500, files: 1),
        .init(id: "cache", logicalBytes: 0, allocatedBytes: 9, files: 1), .init(id: "application", logicalBytes: 0, allocatedBytes: 30, files: 1),
    ], incomplete: false)
    let (games, others) = S2ArmStorage.rows(report)
    #expect(games.map(\.id) == ["B", "A"])   // 按总占用从大到小：B 500 > A 112
    #expect(games.last.map { [$0.game, $0.saves, $0.incoming] } == [100, 5, 7])
    #expect(others.map(\.id) == ["application", "cache"])
}
