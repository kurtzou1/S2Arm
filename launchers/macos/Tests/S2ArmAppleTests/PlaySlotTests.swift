// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 一局单独一个游戏槽（作业层执行锁读写化：起局拿执行锁共享 + 这款的按款锁，出包拿执行锁共享 + 出包锁 + 这款的按款锁）：
//   出包另一款时能开始玩、玩着时能给另一款出包；同一款不边玩边出包；全库独占动作（删除 / 清缓存 / 导入…）在跑时不开局；
//   手机作业对正在玩的那款排队；一局的事件只进游戏槽，终局收尾不动主槽的出包会话。期望值按上面的规则手写
@MainActor final class PlaySlotTests: XCTestCase {
    private var root: URL!
    private var runner: PlaySlotRunner!
    private var model: S2ArmLauncherModel!
    private let a = GameSummary(id: "0100A", name: "Alpha", ready: true)
    private let b = GameSummary(id: "0100B", name: "Beta", ready: true)

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-playslot-" + UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = PlaySlotRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
    }

    // 先关执行器再删目录（11-20 全套里偶发 XCTUnwrap 读不到请求文件、记在别的用例头上）：async tearDown 不在主线程，
    //   主线程上一单收尾后自动接起的作业（排队的装机、刷新）会和删目录同时进行——请求刚写进去就被删、假执行器读空。
    //   close 与读请求同一把锁：删目录一定排在进行中的读取之后；之后才到的作业按「空结果」结束，不属于任何用例
    override func tearDown() async throws { runner.close(); try? FileManager.default.removeItem(at: root) }

    func testExportingOtherGameAllowsPlay() {
        model.session = JobSession(kind: .export, gameID: a.id, name: a.name)
        XCTAssertTrue(model.canPlay(b.id), "主槽在出 A：B 照样能玩")
        XCTAssertFalse(model.canPlay(a.id), "主槽在出 A：A 不能玩")
        model.session = JobSession(kind: .prepare, gameID: a.id, name: a.name)
        XCTAssertTrue(model.canPlay(b.id), "准备运行（出 Mac 版）同出包")
        XCTAssertFalse(model.canPlay(a.id))
        model.session?.phase = .finished(.completed)
        XCTAssertTrue(model.canPlay(a.id), "出完了：A 能玩")
    }

    // #2191：启动设置（金手指 / mod / 补丁）只在这款的文件被别的作业占着时不让改；期望按 gameFilesHeld 注释里的冲突手写
    func testLaunchSettingsHeldOnlyForThisGame() {
        model.session = JobSession(kind: .export, gameID: a.id, name: a.name)
        XCTAssertFalse(model.gameFilesHeld(b.id), "出包 A：B 的金手指 / mod 照常能改")
        XCTAssertTrue(model.gameFilesHeld(a.id), "出包 A：A 自己的不能改（出包读它的 cheats / mods / launch.json）")
        for kind: JobSession.Kind in [.delete, .moveGame, .clearCache, .prepare] {
            model.session = JobSession(kind: kind, gameID: a.id, name: "x")
            XCTAssertFalse(model.gameFilesHeld(b.id), "\(kind) A：B 照常")
            XCTAssertTrue(model.gameFilesHeld(a.id), "\(kind) A：A 不能改")
        }
        for kind: JobSession.Kind in [.importGames, .setupLibrary] {
            model.session = JobSession(kind: kind, gameID: nil, name: "x")
            XCTAssertTrue(model.gameFilesHeld(b.id), "\(kind)（不带游戏号，可能动任何一款）：都不能改")
        }
        model.session = JobSession(kind: .keys, gameID: nil, name: "x")
        XCTAssertFalse(model.gameFilesHeld(b.id), "导入密钥不碰游戏文件夹：照常")
        model.session = nil
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertTrue(model.gameFilesHeld(a.id), "A 在玩：收局写 launch.json，不能改"); XCTAssertFalse(model.gameFilesHeld(b.id))
        model.playSession = nil
        model.phoneSession = JobSession(kind: .install, gameID: b.id, name: b.name)
        XCTAssertTrue(model.gameFilesHeld(b.id), "在推 B：推送读 mods"); XCTAssertFalse(model.gameFilesHeld(a.id))
        model.phoneSession = JobSession(kind: .pushSelected, gameID: nil, name: "x")
        XCTAssertTrue(model.gameFilesHeld(a.id), "推所选几款（不带游戏号）：都不能改")
    }

    // 主槽作业按款并发（维护者 11-16「纯属多余，要放开」）：后端删除 / 搬家拿执行锁共享 + 那款的按款锁 + 清单锁，出包拿执行锁共享 + 出包锁 + 那款的按款锁，
    //   只在同一款上相撞；清缓存拿执行锁独占、导入不知道碰哪款，整库排队。期望按这几把锁手写，看假执行器真收到了哪些作业
    private func exportingA() {
        var s = JobSession(kind: .export, gameID: a.id, name: a.name)
        s.export = ExportRun(platforms: [.mac]); s.stage = "翻译程序"; s.log = ["▸ 翻译程序"]
        model.session = s
    }
    private func waitOp(_ op: String) async throws {
        for _ in 0..<300 where !runner.ops.contains(op) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(runner.ops.contains(op), "后端收到了 \(op)（收到的：\(runner.ops)）")
    }

    func testDeleteOtherGameStartsWhileExporting() async throws {   // ①
        exportingA()
        model.deleteGame(b)
        try await waitOp("delete:" + b.id)
        XCTAssertEqual(model.libraryNotice?.key, "s2arm.notice.delete", "出包 A 时删 B：不排队、当场删")
        XCTAssertEqual(model.session?.gameID, a.id); XCTAssertEqual(model.session?.phase, .running, "A 的出包照旧在跑")
    }

    func testMoveOtherGameStartsWhileExporting() async throws {   // ②
        exportingA()
        model.moveGame(b, to: root.appendingPathComponent("elsewhere"))
        try await waitOp("moveGame:" + b.id)
        XCTAssertEqual(model.session?.gameID, a.id); XCTAssertEqual(model.session?.phase, .running)
    }

    func testSameGameAndLibraryWideJobsWaitWhileExporting() async throws {   // ③ ④
        exportingA()
        model.deleteGame(a)   // 出包 A 时删 A 排队等出完（下面几个用例），这里只核它没发给后端
        model.moveGame(a, to: root.appendingPathComponent("elsewhere"))
        model.libraryNotice = nil
        model.clearCache(b)
        XCTAssertEqual(model.libraryNotice?.key, "s2arm.notice.waitBusy", "出包 A 时清 B 的缓存：不起（执行锁独占 + 清共用编译缓存）")
        model.importGames([root.appendingPathComponent("new.nsp")], partialResults: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.ops.filter { !$0.hasPrefix("catalog") && !$0.hasPrefix("locations") }, [], "删 A / 搬 A / 清缓存 / 导入一个都没发给后端")
        XCTAssertEqual(model.session?.gameID, a.id); XCTAssertEqual(model.session?.phase, .running)
    }

    // 出包 A 时点删 A：不当场拒绝，排队等 A 出完再删（不阻断玩家主动操作），排队期间能取消。期望按「这款不再有出包在跑或排着就删」手写
    func testDeleteSameGameQueuesWhileExporting() async throws {   // 排队 ①
        exportingA()
        model.deleteGame(a)
        model.deleteGame(a)   // 再点一次不重复排
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(runner.ops.contains("delete:" + a.id), "A 在出包：删除先不发给后端")
        XCTAssertEqual(model.libraryNotice?.key, "s2arm.notice.delete"); XCTAssertEqual(model.libraryNotice?.kind, .queued, "提示说出完包就删（带取消）")
        XCTAssertEqual(model.libraryNotice?.gameID, a.id)
        XCTAssertEqual(Array(model.queuedDeletes.keys), [a.id], "同一款只排一次")
        XCTAssertEqual(model.session?.gameID, a.id); XCTAssertEqual(model.session?.phase, .running, "A 的出包照旧在跑")
    }

    func testQueuedDeleteRunsAfterExportEnds() async throws {   // 排队 ②
        exportingA()
        model.deleteGame(a)
        model.finish(.failed, message: "x", slot: .main)   // 出包没成也接着删
        try await waitOp("delete:" + a.id)
        XCTAssertEqual(model.libraryNotice?.key, "s2arm.notice.delete"); XCTAssertNotEqual(model.libraryNotice?.kind, .queued, "提示换成删除的进行中 / 结果")
        XCTAssertEqual(model.queuedDeletes.count, 0)
    }

    func testCancelledQueuedDeleteNeverRuns() async throws {   // 排队 ③
        exportingA()
        model.deleteGame(a)
        model.cancelQueuedDelete()
        XCTAssertNil(model.libraryNotice, "取消：提示消失")
        model.finish(.completed, message: "", slot: .main)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(runner.ops.contains("delete:" + a.id), "取消后 A 出完也不删（收到的：\(runner.ops)）")
    }

    func testQueuedDeleteWaitsForBatch() async throws {   // 排队：A 在正出的这批里还没出完
        model.batchState = ["batch": ["items": [["gameId": a.id, "platforms": ["mac"], "results": ["mac": ["state": "running"]]]]]]
        model.batchRunning = true
        model.deleteGame(a)
        XCTAssertEqual(model.libraryNotice?.kind, .queued)
        model.batchState = ["batch": ["items": [["gameId": a.id, "platforms": ["mac"], "results": ["mac": ["state": "pending"]]]]]]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(runner.ops.contains("delete:" + a.id), "这批里 A 还排着：不删")
        model.batchRunning = false
        try await waitOp("delete:" + a.id)
    }

    func testDeleteRefusedWhilePhoneBusy() async throws {   // 排队 ⑤：手机槽忙时删 A 照旧拒绝
        model.phoneSession = JobSession(kind: .install, gameID: b.id, name: b.name)
        model.deleteGame(a)
        XCTAssertEqual(model.libraryNotice?.key, "s2arm.notice.waitBusy", "手机槽在装 B：删 A 不排队、当场说在等谁")
        XCTAssertEqual(model.queuedDeletes.count, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(runner.ops.contains("delete:" + a.id))
    }

    func testConcurrentJobsFinishOnTheirOwn() async throws {   // ⑤
        runner.hold = ["moveGame"]   // 搬 B 扣住结局，先让主槽的出包结束
        exportingA()
        model.moveGame(b, to: root.appendingPathComponent("elsewhere"))
        try await waitOp("moveGame:" + b.id)
        for _ in 0..<300 where runner.heldCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))   // 搬 B 的阶段事件已发出
        XCTAssertEqual(model.session?.stage, "翻译程序", "搬 B 的事件不进 A 的出包会话"); XCTAssertEqual(model.session?.log, ["▸ 翻译程序"])
        model.finish(.completed, message: "", slot: .main)
        XCTAssertEqual(model.session?.phase, .finished(.completed), "A 出完")
        XCTAssertTrue(model.busy, "A 出完不清掉还在搬的 B")
        runner.releaseHeld()
        for _ in 0..<300 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy, "B 搬完也收尾")
        XCTAssertEqual(model.session?.gameID, a.id); XCTAssertEqual(model.session?.phase, .finished(.completed), "B 收尾不动 A 的结果页")
    }

    func testLibraryWideJobsBlockPlay() {
        let kinds: [JobSession.Kind] = [.delete, .clearCache, .importGames, .keys, .moveGame, .setupLibrary, .downloadMetal, .installDotnet, .diagnostics, .exportTV]
        for kind in kinds {
            model.session = JobSession(kind: kind, gameID: kind == .importGames ? nil : a.id, name: "x")
            XCTAssertFalse(model.canPlay(a.id), "\(kind) 在跑：A 不能玩")
            XCTAssertFalse(model.canPlay(b.id), "\(kind) 在跑：B 也不能玩（全库独占）")
        }
    }

    func testOnePlayAtATimeAndCloudSync() {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertFalse(model.canPlay(b.id), "游戏槽一次一局")
        XCTAssertFalse(model.canPlay(a.id))
        XCTAssertTrue(model.busy); XCTAssertFalse(model.mainBusy); XCTAssertTrue(model.playBusy)
        model.playSession = nil
        model.cloudSyncing = true
        XCTAssertFalse(model.canPlay(a.id), "在同步 iCloud 存档：不开局")
    }

    func testPlayingAllowsExportOfOtherGameOnly() {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertNil(model.exportBlocker(b, platforms: [.mac]), "玩 A 时出 B：不挡")
        XCTAssertEqual(model.exportBlocker(a, platforms: [.mac]), .busy, "玩 A 时出 A：挡")
        XCTAssertEqual(model.export(a, platforms: [.mac]), .busy)
        XCTAssertNil(model.session, "出 A 没起作业")
        XCTAssertNil(model.export(b, platforms: [.mac]))
        XCTAssertEqual(model.session?.kind, .export); XCTAssertEqual(model.session?.gameID, b.id, "出 B 进主槽")
        XCTAssertEqual(model.playSession?.gameID, a.id); XCTAssertEqual(model.playSession?.phase, .running, "一局不受影响")
    }

    func testBatchPendingGameCannotBePlayed() {
        model.batchState = ["batch": ["items": [
            ["gameId": a.id, "platforms": ["mac"], "results": ["mac": ["state": "pending"]]],
            ["gameId": b.id, "platforms": ["mac"], "results": ["mac": ["state": "completed"]]]]]]
        model.batchRunning = true
        XCTAssertFalse(model.canPlay(a.id), "这批里 A 还没出：不能玩")
        XCTAssertTrue(model.canPlay(b.id), "这批里 B 出好了：能玩")
        model.batchRunning = false
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertTrue(model.batchHoldsPlay(), "在玩 A、A 在这批里没出完：继续 / 重试先不开始")
        XCTAssertFalse(model.batchHoldsPlay([b.id]), "只重试 B：不挡")
    }

    func testPhoneJobForPlayingGameQueuesUntilPlayEnds() async {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertTrue(model.mainHolds(a.id), "正在玩的那款算被占着")
        XCTAssertFalse(model.mainHolds(b.id))
        model.install(a, device: "00008160-FIXTURE")
        XCTAssertEqual(model.phoneQueue.map(\.gameID), [a.id], "装正在玩的那款：排队")
        XCTAssertNil(model.phoneSession)
        model.finish(.completed, message: "", slot: .game)
        XCTAssertEqual(model.phoneQueue.count, 0, "一局结束：排着的装机接上")
        XCTAssertEqual(model.phoneSession?.kind, .install); XCTAssertEqual(model.phoneSession?.gameID, a.id)
    }

    func testPlayEventsGoToGameSlotAndLeaveExportAlone() async throws {
        model.session = JobSession(kind: .export, gameID: b.id, name: b.name)   // 主槽在出 B
        model.play(a, uiLanguage: nil)
        for _ in 0..<300 where model.playSession?.stage != "游戏运行中" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.playSession?.kind, .play); XCTAssertEqual(model.playSession?.gameID, a.id)
        XCTAssertEqual(model.playSession?.stage, "游戏运行中", "一局的阶段进游戏槽")
        XCTAssertEqual(model.session?.stage, "", "主槽的出包会话没收到一局的事件")
        XCTAssertEqual(model.session?.log, [])
        XCTAssertTrue(model.playSessionActive)

        runner.endLaunch()
        for _ in 0..<300 where model.playBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.playSession?.phase, .finished(.completed), "终局按游戏槽收尾")
        XCTAssertEqual(model.session?.kind, .export); XCTAssertEqual(model.session?.gameID, b.id)
        XCTAssertEqual(model.session?.phase, .running, "主槽的出包会话照旧在跑")
        XCTAssertTrue(model.canPlay(a.id), "一局结束：A 能再开（主槽出的是 B）")
    }

    func testStopPlayOnlyStopsGameSlot() {
        model.session = JobSession(kind: .export, gameID: b.id, name: b.name)
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        model.stopPlay()
        XCTAssertEqual(model.playSession?.phase, .stopping)
        XCTAssertEqual(model.session?.phase, .running, "停一局不停出包")
        model.stop()
        XCTAssertEqual(model.session?.phase, .stopping)
    }
}

/// 假作业执行器：launch 先发一条「游戏运行中」阶段事件、扣住结局（endLaunch 放出）；hold 里的作业先发一条阶段事件、扣住结局（releaseHeld 放出）；
///   别的作业当场回空结果。收到的每个作业记成「操作:游戏号」（ops）
private final class PlaySlotRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var held: (() -> Void)?
    private var heldOther: [() -> Void] = []
    private var closed = false
    private var seen: [String] = []
    var hold: Set<String> = []
    var ops: [String] { lock.withLock { seen } }
    var heldCount: Int { lock.withLock { heldOther.count } }
    func releaseHeld() { let fs = lock.withLock { () -> [() -> Void] in let fs = heldOther; heldOther = []; return fs }; fs.forEach { $0() } }

    /// 用例收尾：之后再起的作业不读请求文件（目录要删了），当场按空结果结束
    func close() { lock.withLock { closed = true } }

    func endLaunch() { let f = lock.withLock { () -> (() -> Void)? in let f = held; held = nil; return f }; f?() }

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let path = try XCTUnwrap(arguments.last)
        let read = try lock.withLock { () -> [String: Any]? in
            if closed { return nil }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        }
        guard let request = read else { DispatchQueue.main.async { onExit(0) }; return Handle() }
        let task = request["taskId"] ?? ""
        func line(_ e: [String: Any]) { onLine(try! JSONSerialization.data(withJSONObject: e)) }
        let op = request["operation"] as? String ?? ""
        lock.withLock { seen.append(op + ":" + (request["gameId"] as? String ?? "")) }
        if hold.contains(op) {
            DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "stage", "state": "running", "stage": "搬到新位置", "message": "搬到新位置"]) }
            lock.withLock {
                heldOther.append { DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "result", "state": "completed", "result": [:], "message": ""]); onExit(0) } }
            }
        } else if op == "launch" {
            DispatchQueue.main.async {
                line(["schema": 1, "taskId": task, "type": "stage", "state": "running", "stage": "游戏运行中", "message": "游戏运行中"])
            }
            lock.withLock {
                held = { DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "result", "state": "completed", "result": [:], "message": ""]); onExit(0) } }
            }
        } else {
            DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "result", "state": "completed", "result": ["crashed": []], "message": ""]); onExit(0) }
        }
        return Handle()
    }
}
