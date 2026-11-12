import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 收 EventSink 的事件（回调在 testQueue 上，测试线程读：过锁）。
final class EventLog {
    private let lock = NSLock()
    private var items: [EngineEvent] = []
    lazy var sink = EventSink { [unowned self] e in self.lock.lock(); self.items.append(e); self.lock.unlock() }
    var events: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return items }
    var kinds: [String] { events.map(\.ev) }
}

private func result(_ json: String, state: String = "succeeded", message: String = "操作完成") -> String {
    eventLine("result", state: state, message: message, extra: #","result":"# + json)
}

private let catalogResult = result(#"{"games":[{"id":"0100A","name":"Alpha","display":"1.2.0","ready":true},{"id":"0100B","name":"Beta","ready":false,"needsPreparation":true},{"id":"0100C","name":"Gamma"}]}"#)

private func ops(_ runner: FakeRunner) -> [String] { runner.starts.map { $0.request["operation"] as? String ?? "" } }

final class EngineProviderInspectTests: XCTestCase {
    func testInspectIsImportThenCatalogInImportOrder() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { req in
            switch req["operation"] as? String {
            case "import": return ([eventLine("stage", message: "读取游戏信息"),
                                    result(#"{"imports":[{"id":"0100B","name":"b.nsp","duplicate":false},{"id":"0100A","name":"a.nsp","duplicate":true},{"id":"0100B","name":"b-upd.nsp","duplicate":false}]}"#)], 0, false)
            default: return ([catalogResult], 0, false)
            }
        }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        let infos = try await provider.importGames(GameInputs(paths: [URL(fileURLWithPath: "/g/b.nsp"), URL(fileURLWithPath: "/g/a.nsp")]), events: log.sink)
        XCTAssertEqual(ops(runner), ["import", "catalog"])
        XCTAssertEqual(runner.starts[0].request["paths"] as? [String], ["/g/b.nsp", "/g/a.nsp"])
        XCTAssertEqual(infos.map(\.titleId), ["0100B", "0100A"])   // 去重、按导入顺序，已在库里的也算
        XCTAssertEqual(infos[1].version, "1.2.0")
        XCTAssertEqual(infos[1].profileState, .provisional)
        XCTAssertFalse(infos[0].summary.playable)
        XCTAssertEqual(log.kinds, ["stage", "result"])   // 作业层的结果行不转、由适配层补一条在最后

        let one = try await provider.inspect(GameInputs(paths: [URL(fileURLWithPath: "/g/b.nsp")]))
        XCTAssertEqual(one.titleId, "0100B")
    }

    func testInspectWithoutInputsStartsNothing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        let noLibrary = S2ArmEngineProvider(client: client(box, runner, env: box.environment(library: "")), xcodeLocator: { nil })
        do { _ = try await noLibrary.inspect(GameInputs(paths: [])); XCTFail("空输入也导入了") }
        catch { XCTAssertEqual((error as? JobClientError)?.message, S2ArmEngineProvider.nothingImported) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        do { _ = try await provider.inspect(GameInputs(paths: [])); XCTFail("空输入也导入了") }
        catch { XCTAssertEqual((error as? JobClientError)?.message, S2ArmEngineProvider.nothingImported) }
        XCTAssertTrue(runner.starts.isEmpty)
    }

    func testImportWithoutLibraryBuildsDefaultLibraryFirst() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        let noLibrary = S2ArmEngineProvider(client: client(box, runner, env: box.environment(library: "")), xcodeLocator: { nil })
        _ = try? await noLibrary.importGames(GameInputs(paths: [URL(fileURLWithPath: "/g/a.nsp")]))
        XCTAssertEqual(ops(runner).first, "setup")   // 新玩家不用选库，放游戏前先建默认游戏库
    }

    func testFailedImportCarriesStateAndCode() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "failed", message: "请先导入 prod.keys。", extra: #","result":{},"diagnostics":[{"code":"keys_missing"}]"#)], 1, false) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        do { _ = try await provider.importGames(GameInputs(paths: [URL(fileURLWithPath: "/g/a.nsp")]), events: log.sink); XCTFail("失败没抛") }
        catch let f as JobFailure {
            XCTAssertEqual(f.state, .failed)
            XCTAssertEqual(f.code, "keys_missing")
            XCTAssertEqual(f.errorDescription, "请先导入 prod.keys。")
        }
        XCTAssertEqual(ops(runner), ["import"])   // 失败不读 catalog
        XCTAssertEqual(log.events.last?.severity, .error)
        XCTAssertEqual(log.events.last?.code, "keys_missing")
    }
}

final class EngineProviderBuildTests: XCTestCase {
    func testMacBuildIsTheBuildJob() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("stage", message: "翻译着色器"), result(#"{"gameId":"0100A","outputPath":"/L/games/0100A/current","target":"macos-arm64"}"#)], 0, false) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        let r = try await provider.build(BuildJob(gameId: "0100A", target: .mac), events: log.sink)
        XCTAssertEqual(ops(runner), ["build"])
        XCTAssertEqual(runner.starts[0].request["gameId"] as? String, "0100A")
        XCTAssertEqual(r.outputPath, "/L/games/0100A/current")
        XCTAssertNil(r.ipa)
        XCTAssertEqual(log.kinds, ["stage", "result"])
        XCTAssertEqual(log.events[0].message, "翻译着色器")
    }

    /// 缺 .NET SDK：先 installDotnet、再 preflight 复查、再 ipa（玩家只点一次）。检查前跟到找到的 Xcode。
    func testIPhoneBuildInstallsDotnetFirstWhenTheLastCheckSaidMissing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        var preflights = 0
        runner.script = { req in
            switch req["operation"] as? String {
            case "preflight":
                preflights += 1
                let ok = preflights > 1 ? "true" : "false"
                return ([result(#"{"checks":[{"id":"xcode","name":"Xcode","ok":true,"requiredFor":["prepare"],"action":"appStoreXcode"},{"id":"dotnet_sdk","name":".NET SDK（打 iPhone 包）","ok":\#(ok),"requiredFor":["ipa"],"action":"installDotnet"}]}"#)], 0, false)
            case "installDotnet": return ([result("{}")], 0, false)
            default: return ([result(#"{"outputPath":"/out/A","ipa":"/out/A/A.ipa","buildId":"abc"}"#)], 0, false)
            }
        }
        let dev = "/Applications/Xcode-27.app/Contents/Developer"
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { dev })
        let checks = try await provider.environment.check()
        XCTAssertEqual(runner.starts[0].request["developerDir"] as? String, dev)
        XCTAssertFalse(provider.environment.ready(for: "ipa"))
        XCTAssertTrue(provider.environment.ready(for: "ipa", ignoring: ["installDotnet"]))
        XCTAssertTrue(provider.environment.ready(for: "prepare"))
        XCTAssertEqual(checks.map(\.ok), [true, false])
        let r = try await provider.build(BuildJob(gameId: "0100A", target: .iPhone), events: .discard)
        XCTAssertEqual(ops(runner), ["preflight", "installDotnet", "preflight", "ipa"])
        let ipa = runner.starts[3].request
        XCTAssertEqual(ipa["gameId"] as? String, "0100A")
        XCTAssertNil(ipa["target"])          // 一包通用：不要求目标设备
        XCTAssertNil(ipa["graphicsMode"])
        XCTAssertEqual(r.ipa, "/out/A/A.ipa")
        XCTAssertEqual(r.outputPath, "/out/A")
        XCTAssertEqual(r.raw["buildId"] as? String, "abc")
    }

    func testIPhoneBuildStopsWhenDotnetStillMissingAfterInstall() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { req in
            req["operation"] as? String == "preflight"
                ? ([result(#"{"checks":[{"id":"dotnet_sdk","name":".NET SDK（打 iPhone 包）","ok":false,"requiredFor":["ipa"],"action":"installDotnet"}]}"#)], 0, false)
                : ([result("{}")], 0, false)
        }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        _ = try await provider.environment.check()
        do { _ = try await provider.build(BuildJob(gameId: "0100A", target: .iPhone), events: .discard); XCTFail("没装上也出包了") }
        catch { XCTAssertEqual((error as? JobClientError)?.message, S2ArmEngineProvider.dotnetRecheckFailed) }
        XCTAssertEqual(ops(runner), ["preflight", "installDotnet", "preflight"])
    }

    func testDeviceTargetIsPassedThrough() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result(#"{"ipa":"/o/x.ipa"}"#)], 0, false) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        _ = try await provider.build(BuildJob(gameId: "0100A", target: .iPhone,
                                              deviceTarget: ["gpuArch": "applegpu_g14p", "os": 26]), events: .discard)
        let req = runner.starts[0].request
        XCTAssertNil(req["graphicsMode"])
        XCTAssertEqual((req["target"] as? [String: Any])?["gpuArch"] as? String, "applegpu_g14p")
        XCTAssertEqual((req["target"] as? [String: Any])?["os"] as? Int, 26)
    }

    /// 外层 Task 取消 = 请作业停：SIGTERM 一次，作业层记取消（130），抛 cancelled。
    func testCancellingTheTaskStopsTheJob() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("stage", message: "出运行文件")], 0, true) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        let task = Task { try await provider.build(BuildJob(gameId: "0100A", target: .mac), events: log.sink) }
        while log.events.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消了还成功") }
        catch let f as JobFailure { XCTAssertEqual(f.state, .cancelled) }
        XCTAssertEqual(runner.handles.first?.terminated, 1)
        XCTAssertEqual(log.kinds, ["stage", "result"])
        XCTAssertEqual(log.events.last?.fields["state"] as? String, "cancelled")
    }
}

final class EngineProviderSettingsAndRunTests: XCTestCase {
    func testSettingsSchemaIsEmpty() throws {
        // 11-07 维护者 删游戏选项：语言跟系统、Mac 主机模式、60 帧 / 满屏缺省开 + 自动降级，都由作业层定，没有可选的行，也不起作业
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let schema = provider.settingsSchema(for: GameInfo(summary: GameSummary(id: "0100A", name: "Alpha")))
        XCTAssertEqual(schema.schema, 1)
        XCTAssertEqual(schema.rows, [])
        XCTAssertTrue(runner.starts.isEmpty)
    }

    func testRunFreezesSettingsAndControlStopsOnlyThatGame() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("stage", message: "游戏运行中")], 0, true) }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        let finished = expectation(description: "result")
        let sink = EventSink { e in log.sink.emit(e); if e.isFinal { finished.fulfill() } }
        let running = try provider.run(InstalledGame(gameId: "0100A", name: "Alpha"),
                                       settings: Settings(values: ["gameLanguage": "ja", "docked": "1", "widescreen": "0"], uiLanguage: "en"),
                                       events: sink)
        XCTAssertThrowsError(try provider.run(InstalledGame(gameId: "0100B", name: "Beta"), settings: Settings(), events: .discard))
        let req = try XCTUnwrap(runner.starts.first?.request)
        XCTAssertEqual(runner.starts.count, 1)
        XCTAssertEqual(req["operation"] as? String, "launch")
        XCTAssertEqual(req["taskId"] as? String, running.taskId)
        XCTAssertEqual(req["gameId"] as? String, "0100A")
        XCTAssertNil(req["gameLanguage"])   // settings.values 不读：游戏语言跟 Mac 系统、主机模式、宽屏 / 60 帧都由作业层定
        XCTAssertNil(req["docked"])
        XCTAssertEqual(req["uiLanguage"] as? String, "en")
        XCTAssertNil(req["widescreen"])
        testQueue.sync {}
        provider.control(RunningGame(gameId: "0100A", taskId: "not-this-one"), .stop)
        XCTAssertEqual(runner.handles[0].terminated, 0)
        provider.control(running, .stop)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(runner.handles[0].terminated, 1)
        XCTAssertEqual(log.kinds, ["stage", "result"])
        XCTAssertEqual(log.events.last?.fields["state"] as? String, "cancelled")
    }

    func testCapabilitiesDeclareBothTargets() throws {
        let box = try Sandbox(); defer { box.remove() }
        let provider = S2ArmEngineProvider(client: client(box, FakeRunner()), xcodeLocator: { nil })
        XCTAssertEqual(provider.id.rawValue, "s2arm")
        XCTAssertEqual(provider.capabilities.targets, [.mac, .iPhone])
        XCTAssertFalse(provider.capabilities.cheats)
        XCTAssertFalse(provider.capabilities.cloudSaves)
    }
}

final class EnvironmentAndInstallTests: XCTestCase {
    func testRepairSteps() throws {
        let box = try Sandbox(); defer { box.remove() }
        var env = box.environment(); env.developerDir = "/Applications/Xcode.app/Contents/Developer"
        let service = EnvironmentService(client: client(box, FakeRunner(), env: env), xcodeLocator: { nil })
        XCTAssertEqual(service.repairStep(for: "appStoreXcode"), .open(URL(string: "macappstore://apps.apple.com/app/id497799835")!))
        XCTAssertEqual(service.repairStep(for: "openXcode"), .open(URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true)))   // 不依赖宿主装没装这个路径的 Xcode
        XCTAssertEqual(service.repairStep(for: "downloadMetal"), .job("downloadMetal"))
        XCTAssertEqual(service.repairStep(for: "downloadIosPlatform"), .job("downloadIosPlatform"))   // 11-07：缺 Xcode 的 iOS 平台组件 → 一键下载作业
        XCTAssertEqual(service.repairStep(for: "installDotnet"), .job("installDotnet"))
        XCTAssertEqual(service.repairStep(for: "library"), .chooseLibrary)   // 游戏库在云盘 / 不支持的盘格式：换游戏库
        XCTAssertEqual(service.repairStep(for: "prepareEngine"), .unavailable)
        XCTAssertFalse(service.ready(for: "prepare"))   // 还没查过算没齐
        // 没找到 Xcode 时「打开 Xcode」退成去 App Store
        var bare = box.environment(); bare.developerDir = ""
        XCTAssertEqual(EnvironmentService(client: client(box, FakeRunner(), env: bare), xcodeLocator: { nil }).repairStep(for: "openXcode"),
                       .open(EnvironmentService.appStoreXcode))
    }

    func testDownloadIosPlatformRunsTheJobThenUnblocksIpa() async throws {
        // 11-07：iOS 平台组件只挡「打 iPhone 包」（requiredFor ipa），不挡准备 / 启动；一键下载作业跑完重新检查，ipa 就绪
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        var downloaded = false
        runner.script = { req in
            if req["operation"] as? String == "downloadIosPlatform" { downloaded = true; return ([eventLine("progress", message: "下载 Xcode 的 iOS 平台组件"), result("{}")], 0, false) }
            let ok = downloaded ? "true" : "false"
            return ([result(#"{"checks":[{"id":"ios_platform","name":"iOS 平台组件","ok":"# + ok + #","requiredFor":["ipa"],"group":"system","action":"downloadIosPlatform"}]}"#)], 0, false)
        }
        let service = EnvironmentService(client: client(box, runner), xcodeLocator: { nil })
        _ = try await service.check()
        XCTAssertFalse(service.ready(for: "ipa")); XCTAssertTrue(service.ready(for: "prepare"))
        let log = EventLog()
        _ = try await service.repair("downloadIosPlatform", events: log.sink)
        XCTAssertEqual(ops(runner), ["preflight", "downloadIosPlatform", "preflight"])
        XCTAssertTrue(service.ready(for: "ipa"))
    }

    func testDownloadMetalRunsTheJobThenRechecks() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { req in
            req["operation"] as? String == "preflight"
                ? ([result(#"{"checks":[{"id":"metal","name":"Metal 编译组件","ok":true,"requiredFor":["prepare"],"group":"system"}]}"#)], 0, false)
                : ([eventLine("progress", message: "下载 Metal 组件"), result("{}")], 0, false)
        }
        let service = EnvironmentService(client: client(box, runner), xcodeLocator: { nil })
        let log = EventLog()
        let checks = try await service.repair("downloadMetal", events: log.sink)
        XCTAssertEqual(ops(runner), ["downloadMetal", "preflight"])
        XCTAssertEqual(runner.starts[1].request["libraryId"] as? String, "")   // 环境准备不依赖游戏库
        XCTAssertEqual(checks, [ToolCheck(id: "metal", name: "Metal 编译组件", ok: true, message: "", group: "system", requiredFor: ["prepare"])])
        XCTAssertTrue(service.ready(for: "prepare"))
        XCTAssertEqual(log.kinds, ["progress", "result"])
        do { _ = try await service.repair("library"); XCTFail() } catch { XCTAssertTrue(error is JobClientError) }
    }

    func testInstallReadinessAndInstall() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        var ready = false
        runner.script = { req in
            switch req["operation"] as? String {
            case "installCheck":
                // 作业层说 ready，没好的是提示项：听作业层的，不把「开始装」关掉
                return ([result(#"{"gameId":"0100A","ready":true,"device":"维护者 的 iPhone","account":"Team","items":[{"id":"package","ok":true,"waiting":false,"title":"这款游戏的 iPhone 版已经做好","detail":"","who":"app"},{"id":"developerMode","ok":\#(ready),"waiting":false,"title":"iPhone 已打开开发者模式","detail":"在 iPhone 上打开","who":"human"}]}"#)], 0, false)
            default:
                return ([result(#"{"device":"维护者 的 iPhone","packFiles":12,"outputPath":"/out/A"}"#)], 0, false)
            }
        }
        let provider = S2ArmEngineProvider(client: client(box, runner), xcodeLocator: { nil })
        let first = try await provider.installReadiness(gameId: "0100A")
        XCTAssertTrue(first.ready)
        XCTAssertEqual(first.items.map(\.id), ["package", "developerMode"])
        XCTAssertEqual(first.items[1].detail, "在 iPhone 上打开")
        XCTAssertEqual(first.device, "维护者 的 iPhone")
        ready = true
        let second = try await provider.installReadiness(gameId: "0100A")
        XCTAssertTrue(second.ready)
        let installed = try await provider.install(gameId: "0100A")
        XCTAssertEqual(ops(runner), ["installCheck", "installCheck", "install"])
        XCTAssertEqual(runner.starts[2].request["gameId"] as? String, "0100A")
        XCTAssertEqual(installed, InstallResult(device: "维护者 的 iPhone", packFiles: 12, outputPath: "/out/A"))
        XCTAssertNil(runner.starts[2].request["device"])
        _ = try await provider.install(gameId: "0100A", teamId: "ABCDE12345", device: "测试 iPhone")
        XCTAssertEqual(runner.starts[3].request["device"] as? String, "测试 iPhone")
        XCTAssertEqual(runner.starts[3].request["teamId"] as? String, "ABCDE12345")
    }
}
