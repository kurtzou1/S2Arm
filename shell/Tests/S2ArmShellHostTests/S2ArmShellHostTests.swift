import Foundation
import Testing
import S2ArmShellBridge
@testable import ShellUI
@testable import S2ArmShellHost

// 期望值按 Fixtures/catalogue.json 手算：8 条里重复的 Alpha 丢弃 → 7 条；状态按字段逐条对位
@Test func catalogueFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "catalogue", withExtension: "json", subdirectory: "Fixtures"))
    let c = Catalogue.load(path: url.path)
    #expect(c.tiles.map(\.id) == ["0100000000010000", "0100000000020000", "0100000000030000", "0100000000040000",
                                  "0100000000050000", "bad", "0100000000060000"])
    #expect(c.tiles[0].title == "Alpha" && c.tiles[0].subtitle == "1.2.0" && c.tiles[0].banner == nil)
    #expect(c.tiles[0].state == .playable)
    #expect(c.tiles[1].state == .needsGameData)
    #expect(c.tiles[2].state == .needsAppUpdate)
    #expect(c.tiles[3].state == .broken(reason: "R", detail: "D"))
    // technical 一行按 App 语言取 ShellUI 文字表（#316）：中文系统是原句，其余是英文原文（期望两种都手写）
    #expect([GameState.broken(reason: "", detail: "", technical: "未知状态 \"flying\""), .broken(reason: "", detail: "", technical: "Unknown state \"flying\"")].contains(c.tiles[4].state))
    if case .broken = c.tiles[5].state {} else { Issue.record("非法 title_id 应显示为不可用") }
    #expect(c.tiles[6].state == .playable)   // 缺 state 按可运行
    #expect(c.problems.count == 2)           // 重复 1 + 非法 id 1
}

@Test func catalogueBadInputs() {
    let base = URL(fileURLWithPath: "/")
    #expect(Catalogue.parse(Data("not json".utf8), baseDirectory: base).tiles.isEmpty)
    #expect(Catalogue.parse(Data(#"{"schema":2,"games":[]}"#.utf8), baseDirectory: base).problems.count == 1)
    #expect(Catalogue.load(path: "/nonexistent/s2a.json").problems.count == 1)
}

/// 宿主没接的功能必须是 nil：界面据此不显示按钮。接上一项，就把它从这张表挪走，入口自动出现。
@MainActor @Test func unwiredActionsStayNilSoTheirButtonsAreHidden() throws {
    let data = Data(#"{"games":[]}"#.utf8)
    let a = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/"))).actions
    #expect(a.onUseAppData == nil && a.onPickCloudSaves == nil && a.onDisableCloudSaves == nil && a.onUseShellCloud == nil)
    #expect(a.onResetDefaults == nil && a.onShowLog == nil && a.onAppUpdate == nil)
    #expect(a.onPickShellData == nil && a.onClearShellData == nil && a.onPickShellCloud == nil && a.onClearShellCloud == nil)
    #expect(a.onGlobalPadMapChange == nil && a.onGlobalPadMapReset == nil)
}

// 删除游戏（#227 iPad 点了没反应：宿主从没给 onDeleteGame 实现）：不勾存档 → 数据根下只留 S2A/（存档），勾了 → 整个删；删完库里不再显示。期望按目录手写
@MainActor @Test func deleteGameRemovesDataAndKeepsSavesUnlessAsked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-del-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = ("0100000000010000", "0100000000020000")
    for id in [a, b] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(id)/资源包"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(id)/S2A/ryujinx/bis/user/save"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("\(id)/identity.json"))
    }
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    installState: { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) ? 1 : 0 }, gamesRoot: root)
    #expect(model.games.map(\.id) == [a, b])
    let delete = try #require(model.actions.onDeleteGame)
    delete(a, false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(a).path) == ["S2A"])
    delete(b, true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(b).path))
    #expect(model.games.isEmpty)
}

// v0.3.0 资源包挪出 Documents：游戏根是 <家>/Documents/games 时资源包在 <家>/Library/Application Support/S2Arm/games/<游戏号>/资源包（同宿主 s2a_pack_root）。
//   只在新位置的别处电脑款照样认出；还没迁的老位置照样认；删除（不留存档）把新位置的资源包一起挪走、存档留在 Documents。期望按目录手写
@MainActor @Test func packInLibraryIsFoundAndDeleted() throws {
    let fm = FileManager.default, home = fm.temporaryDirectory.appendingPathComponent("s2a-home-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    let games = home.appendingPathComponent("Documents/games"), packs = home.appendingPathComponent("Library/Application Support/S2Arm/games")
    let derived = S2ArmShellHostModel.packGamesRoot(for: games, home: home)?.standardizedFileURL.path
    #expect(derived == packs.standardizedFileURL.path)
    #expect(S2ArmShellHostModel.packGamesRoot(for: home.appendingPathComponent("x"), home: home) == nil)
    let (a, newStray, oldStray) = ("0100000000010000", "0100000000060000", "0100000000070000")
    let placed: [(URL, String)] = [(packs, a), (packs, newStray), (games, oldStray)]
    for item in placed {
        let pack = item.0.appendingPathComponent(item.1).appendingPathComponent("资源包")
        try fm.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("sha".utf8).write(to: pack.appendingPathComponent(".applied"))
    }
    try fm.createDirectory(at: games.appendingPathComponent("\(a)/S2A/ryujinx/bis/user/save"), withIntermediateDirectories: true)
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), installState: { _ in 1 }, gamesRoot: games, packGamesRoot: packs)
    #expect(model.games.map(\.id) == [a, newStray, oldStray])
    let oldDir: String = S2ArmShellHostModel.packDir(oldStray, games: games, packs: packs).path
    let newDir: String = S2ArmShellHostModel.packDir(a, games: games, packs: packs).path
    #expect(oldDir == games.appendingPathComponent(oldStray).appendingPathComponent("资源包").path)
    #expect(newDir == packs.appendingPathComponent(a).appendingPathComponent("资源包").path)
    let delete = try #require(model.actions.onDeleteGame)
    delete(a, false)
    #expect(!fm.fileExists(atPath: packs.appendingPathComponent(a).path))
    #expect(try fm.contentsOfDirectory(atPath: games.appendingPathComponent(a).path) == ["S2A"])
}

// v0.2.6「点删除没反应」：删除不在主线程同步做，点下当场离开列表、提示「正在删除」，后台删完提示释放了多少；挪不动提示原因、游戏留着；
//   上次删到一半留下的 .deleting 下次打开时清掉。释放量期望手算：资源包 10 个 8192 字节 + 1 个 16384 字节文件 = 98304（APFS 按 4096 对齐，正好整块）
@MainActor @Test func deleteGameIsInstantThenReportsFreedSpace() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-del2-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let id = "0100000000010000", pack = root.appendingPathComponent("\(id)/资源包")
    try fm.createDirectory(at: pack.appendingPathComponent("romfs"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("\(id)/S2A"), withIntermediateDirectories: true)
    for i in 0..<10 { try Data(count: 8192).write(to: pack.appendingPathComponent("romfs/\(i).bin")) }
    try Data(count: 16384).write(to: pack.appendingPathComponent("main"))
    try fm.createDirectory(at: root.appendingPathComponent(".deleting/old"), withIntermediateDirectories: true)   // 上次没删完的
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    installState: { fm.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) ? 1 : 0 }, gamesRoot: root)
    model.actions.onDeleteGame?(id, false)
    #expect(model.games.isEmpty)                                    // 当场离开列表
    #expect(model.deleteNotice?.phase == .deleting)
    #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent(id).path) == ["S2A"])
    for _ in 0..<200 where model.deleteNotice?.phase == .deleting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.deleteNotice == .init(gameID: id, title: "A", phase: .done(freed: 98304)))
    for _ in 0..<200 where !((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(".deleting").path)) ?? []).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent(".deleting").path).isEmpty)   // 这次的和上次留下的都删光
}
@MainActor @Test func deleteGameThatCannotMoveSaysWhyAndStays() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-del3-\(UUID().uuidString)")
    let id = "0100000000010000"
    try fm.createDirectory(at: root.appendingPathComponent("\(id)/资源包"), withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)       // 游戏根不可写：待删目录建不出来
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); try? fm.removeItem(at: root) }
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    installState: { fm.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) ? 1 : 0 }, gamesRoot: root)
    model.actions.onDeleteGame?(id, true)
    guard case .failed(let why)? = model.deleteNotice?.phase else { Issue.record("应提示失败：\(String(describing: model.deleteNotice))"); return }
    #expect(!why.isEmpty)
    #expect(model.games.map(\.id) == [id])                         // 没删成就还在列表里
}

@MainActor @Test func playOnlyForPlayable() {
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B","state":"needs_game_data"}]}"#.utf8)
    var played: [String] = []
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) })
    model.actions.onPlay("0100000000010000")
    model.actions.onPlay("0100000000020000")
    model.actions.onPlay("FFFFFFFFFFFFFFFF")
    #expect(played == ["0100000000010000"])
}

// 资源包不在机上（11-07 Duo「游戏没能启动」）：清单写 playable 也显示需要游戏数据、Play 不放行而是要导入说明；放好后重判 → 可运行、放行。
//   清单本来写 needs_game_data 的款不因资源包在就变可运行（以清单为底）
@MainActor @Test func gameDataMissingBlocksPlay() {
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B","state":"needs_game_data"}]}"#.utf8)
    var ready: Set<String> = ["0100000000020000"]
    var played: [String] = [], picked: [String] = []
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) },
                                    installState: { ready.contains($0) ? 1 : 0 }, pickGameData: { picked.append($0) })
    // 审计 P1-155：资源没到位、玩家也没删过的款留在库里，显示「需要游戏数据」，点进去看说明
    #expect(model.games.map(\.id) == ["0100000000010000", "0100000000020000"] && model.games.map(\.game.state) == [.needsGameData, .needsGameData])
    model.actions.onPlay("0100000000010000")
    #expect(played.isEmpty && picked == ["0100000000010000"])
    model.actions.onPickGameData("0100000000010000")
    #expect(picked == ["0100000000010000", "0100000000010000"])
    ready.insert("0100000000010000"); model.refreshGameData()
    #expect(model.games.map(\.id) == ["0100000000010000", "0100000000020000"] && model.games.map(\.game.state) == [.playable, .needsGameData])   // 再推一款，刷新后多一款
    model.actions.onPlay("0100000000010000")
    #expect(played == ["0100000000010000"])
    ready.remove("0100000000010000")              // 库开着时资源包被拿走：Play 当场重判、不放行
    model.actions.onPlay("0100000000010000")
    #expect(played == ["0100000000010000"] && picked.count == 3)
    #expect(model.games.map(\.game.state) == [.needsGameData, .needsGameData])   // 资源被拿走（不是玩家删的）：留在库里、回到「需要游戏数据」
}

// 审计 P1-155：玩家在这台设备上删掉的款，资源不在时不再显示（删除名单 .s2a-removed.txt 跨重开有效）；电脑重新装过来、资源回来就又显示
@MainActor @Test func deletedGameStaysHiddenUntilItsDataReturns() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("s2a-removed-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let (a, b) = ("0100000000010000", "0100000000020000")
    try fm.createDirectory(at: root.appendingPathComponent("\(a)/资源包"), withIntermediateDirectories: true)
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"}]}"#.utf8)
    let state: (String) -> Int32 = { fm.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) ? 1 : 0 }
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { _ in },
                                    installState: state, gamesRoot: root)
    #expect(model.games.map(\.id) == [a, b] && model.games.map(\.game.state) == [.playable, .needsGameData])
    model.deleteGame(a, saves: true)
    #expect(model.games.map(\.id) == [b])                          // 删掉的当场离开列表，没删的 B 照旧在
    let again = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { _ in },
                                    installState: state, gamesRoot: root)
    #expect(again.games.map(\.id) == [b])                          // 重开 App 仍不显示
    try fm.createDirectory(at: root.appendingPathComponent("\(a)/资源包"), withIntermediateDirectories: true)
    again.refreshGameData()
    #expect(again.games.map(\.id) == [a, b])                       // 电脑重新装过来：又显示
    let third = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { _ in },
                                    installState: { $0 == a ? 0 : 0 }, gamesRoot: root)
    #expect(third.games.map(\.id) == [a, b])                       // 已从删除名单摘掉：资源再不在也显示「需要游戏数据」
}

// 宿主「重新检查」→ s2a_shell_refresh → 登记的处理函数
nonisolated(unsafe) private var refreshed = 0
@Test func cBridgeRefresh() {
    s2a_shell_set_refresh_handler(nil, nil); s2a_shell_refresh(); #expect(refreshed == 0)
    s2a_shell_set_refresh_handler({ _ in refreshed += 1 }, nil); s2a_shell_refresh(); #expect(refreshed == 1)
    s2a_shell_set_refresh_handler(nil, nil)
    #expect(s2a_shell_game_install_state("0100000000010000") == 1)   // 不链宿主时弱定义缺省：按就绪
    var d: Int32 = 0, t: Int32 = 0
    #expect(s2a_shell_install_game("0100000000010000") == 0 && s2a_shell_install_progress("0100000000010000", &d, &t) == 0)   // 不链宿主：不解、没进度
}

// C 出口：没登记 → 0；登记后 → 1 且处理函数拿到同一个 id
nonisolated(unsafe) private var lastPlayed = ""
@Test func cBridgeForwards() {
    s2a_shell_set_play_handler(nil, nil)
    #expect(s2a_shell_play("0100000000010000") == 0)
    s2a_shell_set_play_handler({ id, _ in lastPlayed = String(cString: id!) }, nil)
    #expect(s2a_shell_play("0100000000020000") == 1)
    #expect(lastPlayed == "0100000000020000")
    s2a_shell_set_play_handler(nil, nil)
}

// 每款游戏的设置行（S2ArmGameSettings，11-07 维护者）：临时偏好，期望值手算
@MainActor @Test func gameSettingsRows() throws {
    let tag = UUID().uuidString
    let app = try #require(UserDefaults(suiteName: "s2a.test.app." + tag))
    var games: [String: UserDefaults] = [:]
    let stores = S2ArmGameSettings.Stores(game: { id in
        if let d = games[id] { return d }
        let d = UserDefaults(suiteName: "s2a.test.game.\(tag).\(id)"); games[id] = d; return d }, app: app)
    defer { app.removePersistentDomain(forName: "s2a.test.app." + tag); for (id, _) in games { UserDefaults().removePersistentDomain(forName: "s2a.test.game.\(tag).\(id)") } }
    func row(_ s: [SettingSection], _ id: String) -> SettingRow? { s.flatMap(\.rows).first { $0.id == id } }
    // 缺省：60 帧开、宽屏强制关、透明度 100、布局默认，没有「我的布局」时选项 = 默认 + 调整位置
    var s = S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "default", hasMine: false))
    #expect(row(s, "fps60")?.value == "on" && row(s, "widenForce")?.value == "off" && row(s, "vpadOpacity")?.value == "100")
    #expect(row(s, "vpadHoldLock")?.value == "on")
    #expect(row(s, "splitScreen")?.value == "auto" && row(s, "screenOrientation")?.value == "auto")
    S2ArmGameSettings.apply(id: "G1", setting: "splitScreen", value: "on", stores: stores)
    S2ArmGameSettings.apply(id: "G1", setting: "screenOrientation", value: "portrait", stores: stores)
    let sharedScreen = S2ArmGameSettings.sections(for: "G2", stores: stores, state: .init(selected: "default", hasMine: false))
    #expect(row(sharedScreen, "splitScreen")?.value == "on" && row(sharedScreen, "screenOrientation")?.value == "portrait")
    S2ArmGameSettings.apply(id: "G1", setting: "splitScreen", value: "invalid", stores: stores)
    #expect(app.string(forKey: "splitScreen") == "on")
    #expect(row(S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "default", hasMine: false, holdLock: false)), "vpadHoldLock")?.value == "off")
    if case .choice(let o) = row(s, "vpadLayout")?.kind { #expect(o.map(\.id) == ["default", "edit"]) } else { Issue.record("布局行应是多选") }
    // 改：G1 关 60 帧、开宽屏强制、透明度 40 → G1 两项变了、G2 不变；透明度全局 0.4
    #expect(!S2ArmGameSettings.apply(id: "G1", setting: "fps60", value: "off", stores: stores))
    S2ArmGameSettings.apply(id: "G1", setting: "widenForce", value: "on", stores: stores)
    S2ArmGameSettings.apply(id: "G1", setting: "vpadOpacity", value: "40.0", stores: stores)
    s = S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "mine", hasMine: true))
    #expect(row(s, "fps60")?.value == "off" && row(s, "widenForce")?.value == "on" && row(s, "vpadOpacity")?.value == "40")
    #expect(games["G1"]?.object(forKey: "S2AFps60") as? Bool == false && games["G1"]?.bool(forKey: "S2AWidenForce") == true)
    #expect(abs((app.object(forKey: "S2AVPadOpacity") as? Double ?? 0) - 0.4) < 1e-9)
    if case .choice(let o) = row(s, "vpadLayout")?.kind { #expect(o.map(\.id) == ["default", "mine", "edit"]) }
    #expect(row(s, "vpadLayout")?.value == "mine")
    let s2 = S2ArmGameSettings.sections(for: "G2", stores: stores, state: .init(selected: "default", hasMine: false))
    #expect(row(s2, "fps60")?.value == "on" && row(s2, "widenForce")?.value == "off" && row(s2, "vpadOpacity")?.value == "40")
    // 透明度钳在 10–100：给 5 存成 0.1
    S2ArmGameSettings.apply(id: "G1", setting: "vpadOpacity", value: "5", stores: stores)
    #expect(abs((app.object(forKey: "S2AVPadOpacity") as? Double ?? 0) - 0.1) < 1e-9)
    // 选「调整位置…」= 打开编辑页，不存值
    #expect(S2ArmGameSettings.apply(id: "G1", setting: "vpadLayout", value: "edit", stores: stores))
}

// 这台 iPhone 上的名字和封面：叠在清单上、可恢复默认，不影响别的款。期望值手写
@MainActor @Test func gameIdentityOverridesCatalogue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"schema":1,"games":[{"title_id":"0100000000000001","name":"原名一"},{"title_id":"0100000000000002","name":"原名二"}]}"#
    let catalogue = Catalogue.parse(Data(json.utf8), baseDirectory: root)
    let store = GameIdentityStore(root: root)
    let model = S2ArmShellHostModel(catalogue: catalogue, installState: { _ in 1 }, pickGameData: { _ in }, identityStore: store)
    let a = "0100000000000001", b = "0100000000000002"
    #expect(model.games.map(\.game.title) == ["原名一", "原名二"] && !model.hasCustomIdentity(a))
    model.change(a, S2ArmGameSettings.identity, S2ArmGameSettings.editIdentity)
    #expect(model.editingIdentity == a)
    model.saveIdentity(a, name: "  我的游戏  ", cover: nil)
    #expect(model.editingIdentity == nil && model.games[0].game.title == "我的游戏" && model.games[1].game.title == "原名二")
    #expect(store.load(a)?.name == "我的游戏" && store.load(b) == nil)
    // 下次启动：从磁盘读回
    let again = S2ArmShellHostModel(catalogue: catalogue, installState: { _ in 1 }, pickGameData: { _ in }, identityStore: store)
    #expect(again.games[0].game.title == "我的游戏")
    // 名字没改：不算自定义
    model.saveIdentity(b, name: "原名二", cover: nil)
    #expect(store.load(b) == nil && !model.hasCustomIdentity(b))
    model.resetIdentity(a)
    #expect(model.games[0].game.title == "原名一" && store.load(a) == nil)
}

// 名字和封面一次提交（审计 P2-221）：提交点失败时两样都不变、编辑页不关并给原因；存成后旧封面才删。期望值手写
@MainActor @Test func gameIdentitySaveIsAllOrNothing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"schema":1,"games":[{"title_id":"0100000000000001","name":"原名一"}]}"#
    let catalogue = Catalogue.parse(Data(json.utf8), baseDirectory: root)
    let store = GameIdentityStore(root: root)
    let a = "0100000000000001"
    let folder = root.appendingPathComponent("games/\(a)", isDirectory: true)
    func covers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("identity-cover") }.sorted() }

    // 早先版本留下的固定名封面照样认；换新封面后它被删、只剩一份
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("identity-cover.jpg"))
    #expect(store.load(a)?.cover?.lastPathComponent == "identity-cover.jpg")
    try store.save(a, name: "名一", cover: Data([4, 5]))
    #expect(covers().count == 1 && covers() != ["identity-cover.jpg"])
    #expect(store.load(a)?.name == "名一" && store.load(a)?.cover.flatMap { try? Data(contentsOf: $0) } == Data([4, 5]))
    // 只改名字：封面沿用
    try store.save(a, name: "名二", cover: nil)
    #expect(store.load(a)?.name == "名二" && store.load(a)?.cover.flatMap { try? Data(contentsOf: $0) } == Data([4, 5]) && covers().count == 1)

    // 提交点失败：identity.json 的位置被一个非空目录占着，原子替换必然失败
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("identity.json/x", isDirectory: true), withIntermediateDirectories: true)
    let model = S2ArmShellHostModel(catalogue: catalogue, installState: { _ in 1 }, pickGameData: { _ in }, identityStore: store)
    model.change(a, S2ArmGameSettings.identity, S2ArmGameSettings.editIdentity)
    model.saveIdentity(a, name: "新名", cover: Data([9]))
    #expect(model.editingIdentity == a, "没存成：编辑页不关")
    #expect(model.identityError?.isEmpty == false, "给编辑页显示原因")
    #expect(covers().isEmpty, "新封面没留下半套")
    #expect(store.load(a) == nil && model.games[0].game.title == "原名一", "名字也没变")
    // 负对照：挡路的东西挪走后同样的保存成功、关页、清掉原因
    try FileManager.default.removeItem(at: folder.appendingPathComponent("identity.json"))
    model.saveIdentity(a, name: "新名", cover: Data([9]))
    #expect(model.editingIdentity == nil && model.identityError == nil && model.games[0].game.title == "新名" && covers().count == 1)
    model.resetIdentity(a)
    #expect(covers().isEmpty && store.load(a) == nil)
}

// 两端混装：手机上有、清单里没有的款（另一台电脑装的）显示成不可玩并提示回原来那台电脑重装，不给 Play。
//   只认 16 位游戏号目录 + 资源包/.applied；没解开的、别的名字跳过。名字取资源包 ctl/control.nacp（期望按手写的 NACP 字节）
@MainActor @Test func gamesFromAnotherComputerShowAsReinstall() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-stray-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let (a, c, d) = ("0100000000010000", "0100000000030000", "0100000000040000")
    for id in [a, c, d, "notes", "0100000000050000x"] {
        try fm.createDirectory(at: root.appendingPathComponent("\(id)/资源包/ctl"), withIntermediateDirectories: true)
    }
    for id in [a, c, "notes"] { try Data("sha".utf8).write(to: root.appendingPathComponent("\(id)/资源包/.applied")) }
    var nacp = Data(count: 0x4000)
    nacp.replaceSubrange(0 ..< 5, with: Data("Gamma".utf8))
    nacp.replaceSubrange(14 * 0x300 ..< 14 * 0x300 + 9, with: Data("丙游戏".utf8))
    try nacp.write(to: root.appendingPathComponent("\(c)/资源包/ctl/control.nacp"))
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    var played: [String] = []
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) },
                                    installState: { _ in 1 }, gamesRoot: root)
    #expect(model.games.map(\.id) == [a, c])
    let stray = try #require(model.games.last?.game)
    #expect(["丙游戏", "Gamma"].contains(stray.title))
    #expect([GameState.broken(reason: "需要在原来那台电脑上重装", detail: "这款是在另一台电脑上装的，存档和游戏资源都还在这台 iPhone 上；到那台电脑上再点一次「装到 iPhone」就能回来。"),
             .broken(reason: "Reinstall from the original computer", detail: "This game was installed from another computer. Its saves and game data are still on this iPhone; on that computer, choose “Install to iPhone” again to bring it back.")].contains(stray.state))
    model.actions.onPlay(c)
    #expect(played.isEmpty)
}

// 装机蒙版（v0.2.3）：传着按电脑写的传输清单画进度、久不动报传输中断；传完后台解开、画解包进度；没解成点重试；装好了可玩。
//   期望按手写夹具算：清单 total 300，romfs.img 要 200 已到 120、第 0 包要 100 已到 30 → 150/300 = 0.5
@MainActor @Test func arrivingGameShowsProgressThenBecomesPlayable() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-arrive-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let id = "0100000000010000", pack = root.appendingPathComponent("\(id)/资源包")
    try fm.createDirectory(at: pack.appendingPathComponent(".incoming"), withIntermediateDirectories: true)
    try Data(#"{"schema":1,"total":300,"started":1,"files":[["romfs.img",200],[".incoming/1_000.tar",100],["../escape",50]]}"#.utf8).write(to: pack.appendingPathComponent(".transfer"))
    try Data(count: 120).write(to: pack.appendingPathComponent("romfs.img"))
    try Data(count: 30).write(to: pack.appendingPathComponent(".incoming/1_000.tar"))
    var stage: Int32 = 3, clock = Date(), installs: [String] = [], progress: (Int, Int)? = nil, played: [String] = []
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) },
                                    installState: { _ in stage }, installGame: { installs.append($0); return true }, installProgress: { _ in progress },
                                    now: { clock }, gamesRoot: root)
    #expect(model.games.first?.game.state == .installing(InstallStage(.transferring, fraction: 0.5)))
    model.actions.onPlay(id); #expect(played.isEmpty)                                    // 传着不给开始
    clock = clock.addingTimeInterval(S2ArmShellHostModel.transferStall + 5); model.refreshGameData()
    #expect(model.games.first?.game.state.installPhase == .interrupted)                  // 文件都没动过了 90 秒 → 传断了
    try Data(count: 200).write(to: pack.appendingPathComponent("romfs.img")); try Data(count: 100).write(to: pack.appendingPathComponent(".incoming/1_000.tar"))
    clock = Date(); model.refreshGameData()
    #expect(model.games.first?.game.state == .installing(InstallStage(.transferring, fraction: 1)))   // 重新插上续传：接着涨
    stage = 2; model.refreshGameData()
    #expect(installs == [id] && model.games.first?.game.state == .installing(InstallStage(.installing, fraction: 0)))   // 传完：起后台解开
    progress = (3, 4); model.refreshGameData()
    #expect(installs == [id] && model.games.first?.game.state == .installing(InstallStage(.installing, fraction: 0.75)))   // 不重复起
    progress = nil; model.refreshGameData()
    #expect(model.games.first?.game.state.installPhase == .failed && installs == [id])   // 宿主说不在解了、还是阶段 2 → 没解成，不自动再解
    model.actions.onPlay(id)
    #expect(installs == [id, id] && played.isEmpty)                                      // 点重试：再解一次
    stage = 1; model.refreshGameData()
    #expect(model.games.first?.game.state == .playable)
    model.actions.onPlay(id); #expect(played == [id])
    // 续传：电脑写的 base = 已在手机上的 600 字节，这次 total 300 已到 150 → (600 + 150) / 900
    try Data(#"{"schema":1,"total":300,"base":600,"files":[["romfs.img",200],[".incoming/1_000.tar",100]]}"#.utf8).write(to: pack.appendingPathComponent(".transfer"))
    try Data(count: 120).write(to: pack.appendingPathComponent("romfs.img")); try Data(count: 30).write(to: pack.appendingPathComponent(".incoming/1_000.tar"))
    stage = 3; clock = Date(); model.refreshGameData()
    #expect(model.games.first?.game.state == .installing(InstallStage(.transferring, fraction: 750.0 / 900)))
}

// iOS 装机剃刀 #41：没有传输清单（老电脑端推的）也要能判传断了。夹具：资源包里只有一个没写完的包，宿主报阶段 3。
//   期望按时钟手写：刚改过 → 传输中；过了 transferStall + 5 秒没动 → 传输中断（原先永远「传输中」）；包又长了、时钟回到现在 → 又是传输中
@MainActor @Test func transferWithoutListStillDetectsStall() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-nolist-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let id = "0100000000010000", pack = root.appendingPathComponent("\(id)/资源包")
    try fm.createDirectory(at: pack.appendingPathComponent(".incoming"), withIntermediateDirectories: true)
    try Data(count: 30).write(to: pack.appendingPathComponent(".incoming/1_000.tar"))
    var clock = Date()
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), installState: { _ in 3 },
                                    now: { clock }, gamesRoot: root)
    #expect(model.games.first?.game.state.installPhase == .transferring)
    clock = clock.addingTimeInterval(S2ArmShellHostModel.transferStall + 5); model.refreshGameData()
    #expect(model.games.first?.game.state.installPhase == .interrupted)
    try Data(count: 60).write(to: pack.appendingPathComponent(".incoming/1_000.tar"))
    clock = Date(); model.refreshGameData()
    #expect(model.games.first?.game.state.installPhase == .transferring)
}

// 正在解别的款（宿主拒绝起第二个）：这款排着，卡片说在等什么（iOS 装机剃刀 #46 / #47：宿主答 1 另一款在解 → 第 4 步「等另一款装完」，
//   2 在整理游戏目录 → 第 5 步；原先一律只写「安装中」），不算没解成，下一次刷新再试
@MainActor @Test func secondUnpackWaitsItsTurn() {
    var accept = false, installs = 0, wait: Int32 = 1
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    installState: { _ in 2 }, installGame: { _ in installs += 1; return accept }, installProgress: { _ in nil },
                                    installWait: { wait })
    #expect(model.games.first?.game.state == .installing(InstallStage(.installing, step: 4)) && installs == 1)
    wait = 2; model.refreshGameData()
    #expect(model.games.first?.game.state == .installing(InstallStage(.installing, step: 5)) && installs == 2)
    wait = 0; model.refreshGameData()
    #expect(model.games.first?.game.state == .installing(InstallStage(.installing)) && installs == 3)
    accept = true; model.refreshGameData()
    #expect(model.games.first?.game.state == .installing(InstallStage(.installing, fraction: 0)) && installs == 4)
}

// 开着库时电脑才开始推（真机实测：库里一直看不到这款）：每秒重判，它一开始传就出现；全都能玩了也不停——
//   已装好的款被重推 / 装更新（#399 真机验收：原先停了，整个推送过程一直显示可玩）下一秒就画上蒙版
@MainActor @Test func libraryKeepsWatchingForGamesThatStartArriving() {
    var stage: Int32 = 0
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), installState: { _ in stage },
                                    gamesRoot: URL(fileURLWithPath: "/nonexistent"))
    #expect(model.games.map(\.game.state) == [.needsGameData] && model.watching)   // 审计 P1-155：还没推过来也留在库里，显示「需要游戏数据」
    stage = 3; model.refreshGameData()
    #expect(model.games.first?.game.state.installPhase == .transferring && model.watching)
    stage = 1; model.refreshGameData()
    #expect(model.games.first?.game.state == .playable && model.watching)
    stage = 3; model.refreshGameData()   // 已能玩的款又开始传：计时器还在，下一次重判就是「传输中」
    #expect(model.games.first?.game.state.installPhase == .transferring && model.watching)
}

// 装好后第一次点开之前名字前亮蓝点（同 iOS 新装 App）：期望按文件时间手写——.applied 比 .played 新 = 新装；点开始写 .played → 灭；
//   再装一版（.applied 更新）→ 又亮；升级前就玩过的款（有存档目录 S2A/、没有 .played）不亮
@MainActor @Test func newlyInstalledGameShowsBlueDotUntilFirstPlay() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("s2a-new-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let (a, b) = ("0100000000010000", "0100000000020000")
    for id in [a, b] { try fm.createDirectory(at: root.appendingPathComponent("\(id)/资源包"), withIntermediateDirectories: true); try Data("x".utf8).write(to: root.appendingPathComponent("\(id)/资源包/.applied")) }
    try fm.createDirectory(at: root.appendingPathComponent("\(b)/S2A"), withIntermediateDirectories: true)
    var played: [String] = []
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) },
                                    installState: { _ in 1 }, gamesRoot: root)
    #expect(model.games.map(\.game.isNew) == [true, false])
    model.actions.onPlay(a)
    #expect(played == [a] && model.games.map(\.game.isNew) == [false, false])
    model.refreshGameData(); #expect(model.games.first?.game.isNew == false)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root.appendingPathComponent("\(a)/资源包/.applied").path)
    model.refreshGameData(); #expect(model.games.first?.game.isNew == true)   // 再装一版
}


// 单一 IMG 的「安装中」蒙版（v0.3.0）：解开时宿主报阶段 1 / 2 / 3 与这一段比例，卡片写正在做哪一步、圈按这一段画；
//   解完仍是阶段 2（没解成）→「安装没完成」，说明里带宿主给的那句原因。期望按 ShellUI 文案手写（英文界面）
@MainActor @Test func imgInstallShowsStepAndFailureReason() {
    var phase: (Int, Double?)? = (2, 0.37), installs = 0
    let why = "Unpacking small files from game.img (unknown format, please update S2Arm)"
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    installState: { _ in 2 }, installGame: { _ in installs += 1; return true }, installProgress: { _ in nil },
                                    installPhase: { _ in phase }, installFailure: { _ in why }, gamesRoot: URL(fileURLWithPath: "/nonexistent"))
    #expect(model.games.first?.game.state == .installing(InstallStage(.installing, fraction: 0.37, step: 2)))
    #expect(["Unpacking small files… 37%", "解出小文件… 37%"].contains(model.games.first?.game.state.title ?? ""))
    phase = nil; model.refreshGameData()   // 第一次刷新时宿主已在解（报了阶段），这里不再起：installTried 里没有它 → 起一次
    phase = nil; model.refreshGameData()   // 起过、宿主说已不在解、还是阶段 2 → 没解成
    let state = model.games.first?.game.state
    #expect(state == .installing(InstallStage(.failed, reason: why)))
    #expect(state?.explanation.hasPrefix(why + "\n") == true)
}

// 共享表 app scope 的规范 id，与原生 / 设置 App 共用；旧键只迁移一次。
@MainActor @Test func playSettingsCanonicalMigration() throws {
    let suite = "s2a.test.play." + UUID().uuidString
    let app = try #require(UserDefaults(suiteName: suite))
    defer { app.removePersistentDomain(forName: suite) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: app)
    func value(_ key: String, game: String = "G1") -> String? {
        S2ArmGameSettings.sections(for: game, stores: stores, state: .init(selected: "default", hasMine: false)).flatMap(\.rows).first { $0.id == key }?.value
    }
    #expect(value("splitScreen") == "auto" && value("screenOrientation") == "auto")
    #expect((app.persistentDomain(forName: suite) ?? [:]).isEmpty)
    app.set("on", forKey: "S2ASplitScreen"); app.set("portrait", forKey: "S2AScreenOrientation")
    #expect(value("splitScreen") == "on" && value("screenOrientation") == "portrait")
    #expect(app.string(forKey: "splitScreen") == "on" && app.string(forKey: "screenOrientation") == "portrait")
    #expect(app.object(forKey: "S2ASplitScreen") == nil && app.object(forKey: "S2AScreenOrientation") == nil)
    app.set("off", forKey: "splitScreen"); app.set("landscape", forKey: "screenOrientation")
    app.set("on", forKey: "S2ASplitScreen"); app.set("portrait", forKey: "S2AScreenOrientation")
    #expect(value("splitScreen", game: "G2") == "off" && value("screenOrientation", game: "G2") == "landscape")
    #expect(app.object(forKey: "S2ASplitScreen") == nil && app.object(forKey: "S2AScreenOrientation") == nil)
    app.register(defaults: ["splitScreen": "auto", "screenOrientation": "auto"])
    #expect(value("splitScreen") == "off" && value("screenOrientation") == "landscape")
    app.set(42, forKey: "splitScreen"); app.set([], forKey: "screenOrientation")
    app.set("on", forKey: "S2ASplitScreen"); app.set("portrait", forKey: "S2AScreenOrientation")
    #expect(value("splitScreen") == "auto" && value("screenOrientation") == "auto")
    #expect((app.persistentDomain(forName: suite) ?? [:]).isEmpty)
    for (key, values) in [("splitScreen", ["auto", "on", "off"]), ("screenOrientation", ["auto", "landscape", "portrait"])] {
        for selected in values {
            S2ArmGameSettings.apply(id: "G1", setting: key, value: selected, stores: stores)
            #expect(app.string(forKey: key) == selected && value(key, game: "G2") == selected)
        }
        S2ArmGameSettings.apply(id: "G1", setting: key, value: "invalid", stores: stores)
        #expect(app.string(forKey: key) == values.last)
    }
    #expect(app.object(forKey: "S2ASplitScreen") == nil && app.object(forKey: "S2AScreenOrientation") == nil)
}
