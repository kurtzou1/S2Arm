// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

/// 下游深度方案在发版前端的流程（不起窗口、不碰屏幕）：假的作业执行器回一款带方案的游戏，
/// 导出 iPhone → 模型要求弹确认页、先不出包 → 选方案 → downstreamChoice 记下选择 → 读库后接着发 export（请求不带 scheme，作业层按记下的选择分流）。
/// 另把确认页离屏渲染成 PNG（版本对得上 / 对不上两种），环境变量 S2A_DOWNSTREAM_SHOTS=<目录> 时存进那个目录，供报告附图。期望值手写。
@MainActor final class DownstreamFlowTests: XCTestCase {
    private var root: URL!
    private var runner: DownstreamRunner!
    private var model: S2ArmLauncherModel!
    private let gid = "0100000000010000"

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = DownstreamRunner(gid: gid)
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"),
            runner: runner))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func until(_ what: String, _ ok: () -> Bool) async {
        for _ in 0..<200 { if ok() { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("等不到：\(what)")
    }

    private func loaded() async -> GameSummary? {
        model.refresh()
        await until("读库") { model.games.contains { $0.id == gid } }
        return model.games.first { $0.id == gid }
    }

    func testExportAsksFirstThenRecordsChoiceThenExports() async throws {
        let loadedGame = await loaded(); let game = try XCTUnwrap(loadedGame)
        XCTAssertNil(game.downstream?.choice)
        XCTAssertNil(model.export(game, platforms: [.ios]))
        XCTAssertEqual(model.downstreamPromptFor, gid)                       // 前端给出确认
        XCTAssertTrue(runner.requests.filter { $0["operation"] as? String == "export" }.isEmpty)   // 先不出包
        model.chooseDownstream(gid, scheme: "demo")
        XCTAssertNil(model.downstreamPromptFor)
        await until("接着导出") { runner.requests.contains { $0["operation"] as? String == "export" } }
        let choice = try XCTUnwrap(runner.requests.first { $0["operation"] as? String == "downstreamChoice" })
        XCTAssertEqual(choice["gameId"] as? String, gid)
        XCTAssertEqual(choice["scheme"] as? String, "demo")                    // 选择被记下
        let export = try XCTUnwrap(runner.requests.first { $0["operation"] as? String == "export" })
        XCTAssertNil(export["scheme"])                                          // 出包请求不带 scheme：作业层按记下的选择分流
        let items = (export["plan"] as? [String: Any])?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["gameId"] as? String, gid)
        XCTAssertEqual(items?.first?["platforms"] as? [String], ["iphone"])
    }

    func testAlreadyChosenOrMacOnlyDoesNotAsk() async throws {
        runner.choice = ""                                                      // 选过「仍用原版方案」
        let loadedGame = await loaded(); let game = try XCTUnwrap(loadedGame)
        XCTAssertNil(model.export(game, platforms: [.ios]))
        XCTAssertNil(model.downstreamPromptFor)
        await until("直接导出") { runner.requests.contains { $0["operation"] as? String == "export" } }
    }

    func testMacOnlyExportDoesNotAsk() async throws {
        let loadedGame = await loaded(); let game = try XCTUnwrap(loadedGame)
        XCTAssertNil(model.export(game, platforms: [.mac]))
        XCTAssertNil(model.downstreamPromptFor)
    }

    func testConfirmSheetRendersBothStates() async throws {
        for (state, eligible) in [("eligible", true), ("ineligible", false)] {
            runner.eligible = eligible
            _ = await loaded()
            await until("读到 \(state)") { model.games.first { $0.id == gid }?.downstream?.eligible == eligible }
            let view = DownstreamConfirmSheet(model: model, gameID: gid, zh: true).background(Color(white: 0.1)).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, state)
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)).flatMap { $0.representation(using: .png, properties: [:]) })
            XCTAssertGreaterThan(png.count, 10_000, state)                     // 真画出了内容（不是空白页）
            if let dir = ProcessInfo.processInfo.environment["S2A_DOWNSTREAM_SHOTS"] {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("downstream_confirm_\(state).png"))
            }
        }
    }
}

/// 假作业执行器：catalog 回一款带下游方案的游戏（choice / eligible 可调）；downstreamChoice 记下选择；export 直接成功。所有请求都记下
private final class DownstreamRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    let gid: String
    var requests: [[String: Any]] = []
    var choice: String?
    var eligible = true
    init(gid: String) { self.gid = gid }

    private func offer() -> [String: Any] {
        var d: [String: Any] = ["id": "demo", "name": "Demo-Port", "eligible": eligible,
                                "reason": ["zh": "Demo-Port 只支持 1.2.3 更新，你导入的是 1.2.4。导入 1.2.3 更新后可选", "en": "Demo-Port supports update 1.2.3 only"],
                                "copy": ["zh": ["title": "这款有专门的深度优化方案", "body": "用原版方案出的包，这款会停在联网验证，进不了主菜单。推荐用 Demo-Port 方案：离线单机、60 帧、整套触屏操作。",
                                                "points": ["只支持 1.2.3 更新", "手机要 iOS 26 及以上", "手机上会多一个独立 App"],
                                                "recommend": "用 Demo-Port 方案（推荐）", "original": "仍用原版方案"],
                                         "en": ["title": "Title", "body": "Body", "points": [], "recommend": "Use", "original": "Keep"]]]
        if let choice { d["choice"] = choice }
        return d
    }

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let url = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let op = request["operation"] as? String ?? ""
        DispatchQueue.main.async { [self] in
            requests.append(request)
            if op == "downstreamChoice" { choice = request["scheme"] as? String }
            let result: [String: Any] = op == "catalog"
                ? ["games": [["id": gid, "name": "Fixture Game", "display": "1.2.3", "compatibility": "experimental", "downstream": offer()]]]
                : [:]
            let event: [String: Any] = ["schema": 1, "taskId": request["taskId"]!, "type": "result", "state": "succeeded", "result": result, "message": ""]
            onLine(try! JSONSerialization.data(withJSONObject: event))
            onExit(0)
        }
        return Handle()
    }
}
