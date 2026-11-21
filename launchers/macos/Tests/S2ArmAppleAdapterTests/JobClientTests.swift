import Foundation
import XCTest
@testable import S2ArmAppleAdapter

final class JobClientTests: XCTestCase {
    func testRequestIsSchema1Private0600AndRunsIsolatedPython() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        let done = expectation(description: "finish")
        let handle = try client(box, runner).start(operation: "catalog", extra: ["gameId": "0100ABCD"], onFinish: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)

        let s = try XCTUnwrap(runner.starts.first)
        XCTAssertEqual(s.executable.path, box.resources.appendingPathComponent("Runtime/python/bin/python3").path)
        XCTAssertEqual(s.arguments, ["-B", "-I", box.resources.appendingPathComponent("Jobs/main.py").path, "run", "--request",
                                     box.privateRoot.appendingPathComponent("requests/\(handle.id).json").path])
        XCTAssertEqual(s.request["schema"] as? Int, 1)
        XCTAssertEqual(s.request["taskId"] as? String, handle.id)
        XCTAssertEqual(s.request["operation"] as? String, "catalog")
        XCTAssertEqual(s.request["gameId"] as? String, "0100ABCD")
        XCTAssertEqual(s.request["parentPid"] as? Int, 4242)
        XCTAssertEqual(s.request["privateRoot"] as? String, box.privateRoot.path)
        XCTAssertEqual(s.request["library"] as? String, box.root.appendingPathComponent("lib").path)
        XCTAssertEqual(s.request["libraryId"] as? String, "lib-1")
        XCTAssertEqual(s.environment["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(s.environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(s.environment["PYTHONUNBUFFERED"], "1")
        XCTAssertNil(s.environment["PYTHONPATH"])
        XCTAssertNil(s.environment["PYTHONHOME"])
        XCTAssertEqual(s.environment["PATH"], "/usr/bin")
        // 进程退出后请求文件删掉（同旧启动器）
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.requestPath))
    }

    func testUnconfiguredLibraryAndPreflightRules() throws {
        let box = try Sandbox(); defer { box.remove() }
        let c = client(box, FakeRunner(), env: box.environment(library: ""))
        XCTAssertEqual(c.request(id: "t", operation: "catalog")["library"] as? String, box.privateRoot.appendingPathComponent("unconfigured").path)
        let pre = c.request(id: "t", operation: "preflight")
        XCTAssertEqual(pre["libraryId"] as? String, "")
        XCTAssertEqual(pre["storageLibraryId"] as? String, "lib-1")
    }

    func testEngineBundleOverridesEngineDir() throws {
        let box = try Sandbox(engine: true); defer { box.remove() }
        var env = box.environment(); env.engineDir = "/src/S2Arm"
        let req = client(box, FakeRunner(), env: env).request(id: "t", operation: "launch")
        XCTAssertEqual(req["engineDir"] as? String, box.resources.appendingPathComponent("Engine").path)
        XCTAssertEqual(req["engineBundle"] as? String, box.resources.appendingPathComponent("Engine").path)
    }

    func testEventsArriveInOrderNormalizedAndFinishComesLast() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([
            eventLine("stage", message: "读取游戏库"),
            "not json",
            #"{"schema":2,"jobId":"$TASK","type":"progress"}"#,
            #"{"schema":1,"jobId":"someone-else","type":"progress"}"#,
            eventLine("progress", message: "1/2", extra: #","done":1,"total":2"#),
            eventLine("result", state: "succeeded", message: "操作完成", extra: #","result":{"games":[]}"#),
        ], 0, false) }
        var seen: [String] = []
        var order: [String] = []
        let done = expectation(description: "finish")
        var outcome: JobOutcome?
        try client(box, runner).start(operation: "catalog",
                                      onEvent: { seen.append("\($0.type):\($0.state ?? "")"); order.append("event"); XCTAssertEqual($0.taskId.isEmpty, false) },
                                      onFinish: { outcome = $0; order.append("finish"); done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(seen, ["stage:running", "progress:running", "result:completed"])
        XCTAssertEqual(order.last, "finish")
        XCTAssertEqual(order.filter { $0 == "finish" }.count, 1)
        XCTAssertEqual(outcome?.state, .completed)
        XCTAssertEqual(outcome?.message, "操作完成")
        XCTAssertNotNil(outcome?.result["games"])
        XCTAssertEqual(outcome?.stderr, "bootstrap noise\n")
    }

    func testExitWithoutResult130IsCancelledOtherIsInterruptedOrRejected() throws {
        let box = try Sandbox(); defer { box.remove() }
        for (lines, code, state, message) in [
            ([String](), Int32(130), JobOutcome.State.cancelled, "任务已取消。"),
            ([], 1, .interrupted, JobOutcome.interruptedMessage + "\nbootstrap noise"),
            ([#"{"error":"游戏库里没有这款游戏。","code":"input_missing"}"#], 2, .interrupted, "游戏库里没有这款游戏。"),
        ] {
            let runner = FakeRunner()
            runner.script = { _ in (lines, code, false) }
            let done = expectation(description: "finish \(code)")
            var outcome: JobOutcome?
            try client(box, runner).start(operation: "launch", onFinish: { outcome = $0; done.fulfill() })
            wait(for: [done], timeout: 5)
            XCTAssertEqual(outcome?.state, state)
            XCTAssertEqual(outcome?.exitCode, code)
            XCTAssertEqual(outcome?.message, message)
        }
    }

    func testFailedResultCarriesDiagnostics() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "failed", message: "这款游戏需要重新打包，完成后即可启动。",
                                           extra: #","diagnostics":[{"code":"runtime_invalid"}]"#)], 1, false) }
        let done = expectation(description: "finish")
        var outcome: JobOutcome?
        try client(box, runner).start(operation: "launch", onFinish: { outcome = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome?.state, .failed)
        XCTAssertEqual(outcome?.diagnostics.first?["code"] as? String, "runtime_invalid")
    }

    func testCancelTerminatesTheProcess() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("stage", message: "游戏运行中")], 0, true) }
        let done = expectation(description: "finish")
        var outcome: JobOutcome?
        let handle = try client(box, runner).start(operation: "launch", onFinish: { outcome = $0; done.fulfill() })
        handle.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertTrue(handle.cancelling)
        XCTAssertEqual(runner.handles.first?.terminated, 1)
        XCTAssertEqual(outcome?.state, .cancelled)
        XCTAssertEqual(outcome?.exitCode, 130)
    }

    func testPythonAndEntryResolution() throws {
        // 有内置引擎却缺内置 Python：安装不完整，不退到系统 Python
        let broken = try Sandbox(bundledPython: false, engine: true); defer { broken.remove() }
        XCTAssertThrowsError(try client(broken, FakeRunner()).pythonExecutable()) {
            XCTAssertEqual(($0 as? JobClientError)?.message, "应用内置 Python 缺失，请重新安装完整应用。")
            XCTAssertEqual(($0 as? JobClientError)?.code, JobClientError.bundleIncomplete)   // 界面据此给「下载完整安装包」按钮
        }
        // 玩家装的 App 缺作业入口：同样说包不完整、给重装，不说「选源码目录」（那是开发用源码树的话）
        let noJobs = try Sandbox(bundledPython: true, jobs: false, engine: true); defer { noJobs.remove() }
        XCTAssertThrowsError(try client(noJobs, FakeRunner()).jobEntry()) {
            XCTAssertEqual(($0 as? JobClientError)?.message, "应用不完整，请重新安装 S2Arm。")
            XCTAssertEqual(($0 as? JobClientError)?.code, JobClientError.bundleIncomplete)
        }
        // 源码树：设置里指定的 Python；入口退到 <engineDir>/pack/jobs/main.py
        let dev = try Sandbox(bundledPython: false, jobs: false); defer { dev.remove() }
        var env = dev.environment()
        env.pythonPath = "/bin/sh"
        let tree = dev.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data().write(to: tree.appendingPathComponent("pack/jobs/main.py"))
        env.engineDir = tree.path
        let c = client(dev, FakeRunner(), env: env)
        XCTAssertEqual(try c.pythonExecutable().path, "/bin/sh")
        XCTAssertEqual(try c.jobEntry().path, tree.appendingPathComponent("pack/jobs/main.py").path)
        env.engineDir = dev.root.appendingPathComponent("nowhere").path
        XCTAssertThrowsError(try client(dev, FakeRunner(), env: env).jobEntry())
        env.pythonPath = dev.root.appendingPathComponent("no-python").path
        XCTAssertThrowsError(try client(dev, FakeRunner(), env: env).pythonExecutable()) {
            XCTAssertEqual(($0 as? JobClientError)?.message, "设置中的 Python 不可执行，请重新选择。")
        }
    }

    func testStartFailureRemovesRequestAndThrows() throws {
        let box = try Sandbox(bundledPython: false, engine: true); defer { box.remove() }
        let runner = FakeRunner()
        XCTAssertThrowsError(try client(box, runner).start(operation: "catalog"))
        XCTAssertTrue(runner.starts.isEmpty)
    }

    func testEnvironmentLoadsPreferences() throws {
        let box = try Sandbox(); defer { box.remove() }
        let prefs: [String: Any] = ["library": "/L", "libraryId": "id-9", "developerDir": "/X", "engineDir": "/E", "docked": true,
                                    "devHud": true, "gameLanguage": "ja", "gameLanguages": ["A": "fr", "B": "xx"]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: box.privateRoot.appendingPathComponent("preferences.json"))
        let env = JobEnvironment.load(privateRoot: box.privateRoot, resources: box.resources, buildId: "b1")
        XCTAssertEqual(env.library, "/L"); XCTAssertEqual(env.libraryId, "id-9"); XCTAssertEqual(env.engineDir, "/E")
        XCTAssertTrue(env.devHud); XCTAssertFalse(env.metalHud)
        XCTAssertEqual(env.buildId, "b1")
    }

    func testLineSplitterKeepsWholeLinesAndTrailingHalf() {
        var s = LineSplitter()
        XCTAssertEqual(s.append(Data("a\nb".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["a"])
        XCTAssertEqual(s.append(Data("c\n\nd".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["bc"])
        XCTAssertEqual(s.finish().map { String(decoding: $0, as: UTF8.self) }, "d")
        XCTAssertNil(s.finish())
    }

    /// 真进程：作业跑着的时候持有一段防 App Nap 的活动，进程结束就收；起不来也要收（推送慢 11-17）。
    ///   期望手写：起一个作业 → 开 1 段、收 1 段，收在退出回调之前；起一个不存在的可执行文件 → 开 1 段、收 1 段，抛错
    func testSystemRunnerHoldsActivityWhileJobRuns() throws {
        final class Box { var begun = 0, ended = 0, endedBeforeExit = false }
        let box = Box(), token = NSObject()
        let runner = SystemJobProcessRunner(beginActivity: { box.begun += 1; return token },
                                            endActivity: { got in XCTAssertTrue(got === token); box.ended += 1 })
        let done = expectation(description: "exit")
        _ = try runner.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 0.2"], environment: [:],
                             onLine: { _ in }, onStderr: { _ in },
                             onExit: { _ in box.endedBeforeExit = box.ended == 1; done.fulfill() })
        XCTAssertEqual(box.begun, 1)
        wait(for: [done], timeout: 10)
        XCTAssertTrue(box.endedBeforeExit)
        XCTAssertThrowsError(try runner.start(executable: URL(fileURLWithPath: "/nonexistent/s2arm-job"), arguments: [], environment: [:],
                                              onLine: { _ in }, onStderr: { _ in }, onExit: { _ in }))
        XCTAssertEqual(box.begun, 2); XCTAssertEqual(box.ended, 2)
    }

    /// 自动起的后台任务（JobTrigger.automaticOperations）：不开防降级活动；玩家点的照开（11-17 维护者：自动任务让路）。期望手写
    func testAutomaticJobsDoNotHoldActivity() throws {
        final class Box { var begun = 0, ended = 0 }
        let box = Box(), token = NSObject()
        let runner = SystemJobProcessRunner(beginActivity: { box.begun += 1; return token }, endActivity: { _ in box.ended += 1 })
        let done = expectation(description: "exit")
        _ = try runner.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "true"], environment: [:], automatic: true,
                             onLine: { _ in }, onStderr: { _ in }, onExit: { _ in done.fulfill() })
        wait(for: [done], timeout: 10)
        XCTAssertEqual(box.begun, 0); XCTAssertEqual(box.ended, 0)
    }

    /// JobClient 按作业名认：只有作业层那两项自动重活算 automatic
    func testClientMarksOnlyAutomaticOperations() throws {
        final class Spy: JobProcessRunner {
            var seen: [Bool] = []
            final class H: JobProcessHandle { func terminate() {} }
            func start(executable: URL, arguments: [String], environment: [String: String],
                       onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
                try start(executable: executable, arguments: arguments, environment: environment, automatic: false, onLine: onLine, onStderr: onStderr, onExit: onExit)
            }
            func start(executable: URL, arguments: [String], environment: [String: String], automatic: Bool,
                       onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
                objc_sync_enter(self); defer { objc_sync_exit(self) }   // 作业客户端在并发线程池里同时调 start：替身状态串行改（无锁并发追加数组会 SIGSEGV 带崩整个测试进程）
                seen.append(automatic); return H()
            }
        }
        let box = try Sandbox(); defer { box.remove() }
        let spy = Spy()
        let client = JobClient(environment: box.environment(), runner: spy)
        for op in ["installUpdatePrepare", "sgradeMac", "install", "build"] { _ = try client.start(operation: op) }
        XCTAssertEqual(spy.seen, [true, false, false, false])   // sgradeMac 11-17 起玩家点了才做（S 级优化改手动），不算自动作业
        XCTAssertEqual(JobTrigger.automaticOperations, ["installUpdatePrepare"])
    }

    /// 真进程：行都到了才报退出（快结束的作业最后一条结果不能被退出抢先）。
    func testSystemRunnerDeliversAllLinesBeforeExit() throws {
        var lines: [String] = []
        var exitBeforeLines = false
        let done = expectation(description: "exit")
        _ = try SystemJobProcessRunner().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "for i in 1 2 3 4 5; do echo line$i; done; printf tail; echo err >&2; exit 3"],
            environment: [:],
            onLine: { lines.append(String(decoding: $0, as: UTF8.self)) },
            onStderr: { _ in },
            onExit: { code in exitBeforeLines = lines.count != 6; XCTAssertEqual(code, 3); done.fulfill() })
        wait(for: [done], timeout: 10)
        XCTAssertFalse(exitBeforeLines)
        XCTAssertEqual(lines, ["line1", "line2", "line3", "line4", "line5", "tail"])
    }
}
