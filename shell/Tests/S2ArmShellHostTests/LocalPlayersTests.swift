import Foundation
import Testing
import SaveSync
import ShellUI
@testable import S2ArmShellHost

// 本地玩家（#623）：玩家表存在 App 偏好里（临时 suite），期望值手写；用户号的期望由 Python hashlib 独立算出
//   （sha256("S2Arm local player\n" + 小写名字) 前 16 字节），不跑被测实现推

private func freshDefaults() throws -> (UserDefaults, String) {
    let name = "s2a.test.players." + UUID().uuidString
    return (try #require(UserDefaults(suiteName: name)), name)
}

@Test func noPlayersStoredMeansOnlyTheFirstPlayerAndNothingWritten() throws {
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(shellDefaults: d)
    #expect(store.all == [LocalPlayer(uid: "", name: "", folder: "SaveData")])
    #expect(store.current.isFirst)
    // 升级后什么都不选：偏好里不写任何东西，宿主（ios/settings.m）据此走旧行为
    #expect(d.object(forKey: LocalPlayers.listKey) == nil && d.object(forKey: LocalPlayers.currentKey) == nil)
}

@Test func addingAPlayerSelectsHerWithANameDerivedIDAndFolder() throws {
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(shellDefaults: d)
    let hong = try store.add("  Hong ")
    #expect(hong == LocalPlayer(uid: "d7a43a96495d0a594e615dd88587b6bf", name: "Hong", folder: "SaveData-Hong"))
    let xh = try store.add("小红")
    #expect(xh.uid == "382ddcdad6b762a7590fd9d3fcf74beb" && xh.folder == "SaveData-小红")
    #expect(store.current == xh)
    #expect(store.all.map(\.uid) == ["", "d7a43a96495d0a594e615dd88587b6bf", "382ddcdad6b762a7590fd9d3fcf74beb"])
    // 宿主读的就是这两项（ios/settings.m s2a_ios_local_player 的格式）
    let list = try #require(d.array(forKey: LocalPlayers.listKey) as? [[String: String]])
    #expect(list.first == ["uid": "", "name": "", "folder": "SaveData"])
    #expect(d.string(forKey: LocalPlayers.currentKey) == "382ddcdad6b762a7590fd9d3fcf74beb")
}

@Test func namesAreCheckedAndRenameKeepsTheSaves() throws {
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(shellDefaults: d)
    #expect(throws: LocalPlayers.NameError.empty) { try store.add("   ") }
    #expect(throws: LocalPlayers.NameError.taken) { try store.add("player 1") }   // 第一个玩家没改名时显示「Player 1」
    let hong = try store.add("Hong")
    #expect(throws: LocalPlayers.NameError.taken) { try store.add("HONG") }
    // 改名：用户号、存档位置不变（存档还是她的）
    try store.rename(hong.uid, to: "Hongxia")
    #expect(store.all[1] == LocalPlayer(uid: hong.uid, name: "Hongxia", folder: "SaveData-Hong"))
    try store.rename("", to: "Ming")
    #expect(store.all[0] == LocalPlayer(uid: "", name: "Ming", folder: "SaveData"))
    // 路径分隔符与开头的点不进文件夹名
    #expect(LocalPlayers.folder(for: "..a/b:c") == "SaveData-a-b-c")
}

@Test func removingKeepsTheFirstPlayerAndFallsBackToHer() throws {
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(shellDefaults: d)
    let hong = try store.add("Hong")
    store.remove("")   // 第一个玩家拿不掉
    #expect(store.all.count == 2)
    store.remove(hong.uid)
    #expect(store.all.map(\.uid) == [""] && store.current.isFirst)
    // 同名再建回来：同一个用户号、同一个存档位置（存档回来）
    #expect(try store.add("hong") == LocalPlayer(uid: hong.uid, name: "hong", folder: "SaveData-hong"))
    // 选一个表里没有的：不动
    store.select("ffffffffffffffffffffffffffffffff")
    #expect(store.current.uid == hong.uid)
    store.select("")
    #expect(store.current.isFirst)
}

// 「退出重开 App」：玩家表与当前玩家在偏好里，新建一个模型（= 重开后的库界面）读到的一样；切换页开着时手柄监听停着
@MainActor @Test func modelSwitchesPlayersAndASecondLaunchSeesTheSame() throws {
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: d)
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 })
    #expect(model.currentPlayer.displayName == "Player 1")
    model.openPlayers()
    #expect(model.playersOpen)
    #expect(model.addPlayer("Hong") == nil)
    #expect(model.addPlayer("hong") == "That name is already taken.")
    #expect(model.currentPlayer.name == "Hong")
    model.selectPlayer("")
    #expect(!model.playersOpen && model.currentPlayer.isFirst)
    model.selectPlayer("d7a43a96495d0a594e615dd88587b6bf")
    let reopened = S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 })
    #expect(reopened.players.map(\.displayName) == ["Player 1", "Hong"])
    #expect(reopened.currentPlayer.uid == "d7a43a96495d0a594e615dd88587b6bf")
}

@Test func longNamesAreAcceptedAndTheFolderFitsTheFileSystem() throws {
    // 11-13 不许堵门：名字不限长；文件夹名在整字处截到 200 字节（手算：「长」UTF-8 3 字节，300 个 = 900 字节 → 截到 66 个 = 198 字节，再加 9 字节前缀）
    let (d, name) = try freshDefaults(); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(shellDefaults: d)
    let long = try store.add(String(repeating: "长", count: 300))
    #expect(long.name.count == 300)
    #expect(long.folder == "SaveData-" + String(repeating: "长", count: 66))
    #expect(long.folder.utf8.count == 207)
}
