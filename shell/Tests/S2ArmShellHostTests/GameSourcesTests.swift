import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 外部游戏来源（11-22）：期望按规则手写。宿主装机状态 5（本体是指向来源文件夹的软链接、打不开）→ 库里留着这款、状态「没有找到游戏所在位置」、
//   状态回 1（外接盘插回、重扫接上）→ 可以玩；离线的款记「在」，不会因为离线从库里消失
@MainActor @Test func sourceOfflineStaysListedAndRecovers() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("s2a-src-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let (a, b) = ("0100000000010000", "0100000000020000")
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"}]}"#.utf8)
    var hostState: [String: Int32] = [a: 5, b: 1]
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { _ in },
                                    installState: { hostState[$0] ?? 0 }, gamesRoot: root)
    #expect(model.games.map(\.id) == [a, b], "离线的 A 仍在库里")
    #expect(model.games.first { $0.id == a }?.game.state == .sourceOffline)
    #expect(model.games.first { $0.id == b }?.game.state == .playable)
    hostState[a] = 1
    model.refreshGameData()
    #expect(model.games.first { $0.id == a }?.game.state == .playable, "插回、接上：回到可以玩")
}

// 来源列表存取：存进去的 id / 名字 / 书签原样读回；坏条目（缺字段）跳过
@Test func gameSourcesRoundTrip() throws {
    let suite = "s2a-src-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ShellSettingsStore(defaults: defaults)
    #expect(store.gameSources.isEmpty)
    let list = [ShellSettingsStore.GameSource(id: "s1", name: "ExternalSSD", bookmark: Data([1, 2, 3])),
                ShellSettingsStore.GameSource(id: "s2", name: "游戏", bookmark: Data([4]))]
    store.storeGameSources(list)
    #expect(store.gameSources == list)
    defaults.set((defaults.array(forKey: ShellSettingsStore.gameSourcesKey) ?? []) + [["id": "s3"]], forKey: ShellSettingsStore.gameSourcesKey)
    #expect(store.gameSources == list, "缺名字 / 书签的条目跳过")
}
