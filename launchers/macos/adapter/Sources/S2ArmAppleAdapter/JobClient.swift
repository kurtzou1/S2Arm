import Foundation

/// 作业请求里每次都要带的那部分（旧 Store.worker 的固定字段）。数据目录、游戏库、引擎位置都在这里定，界面不拼路径。
public struct JobEnvironment: Equatable {
    public var privateRoot: URL
    /// 应用资源目录：.app 里是 Contents/Resources（带 Runtime/python、Jobs、Engine）；源码树里跑时是 launchers/macos。
    public var resources: URL
    public var engineDir: String?
    public var library: String
    public var libraryId: String
    public var developerDir: String
    public var fontsDir: String?
    public var devHud: Bool
    public var metalHud: Bool
    public var buildId: String
    /// 设置里指定的 Python（只在没有内置 Python、也没有内置引擎时用，同旧启动器）。
    public var pythonPath: String?
    /// 旧启动器导出页记住的平台勾选（preferences.exportTargets）：新前端还没存过自己的勾选时接着用它。
    public var exportTargets: [String]?

    public init(privateRoot: URL, resources: URL, engineDir: String? = nil, library: String = "", libraryId: String = "",
                developerDir: String = "", fontsDir: String? = nil, devHud: Bool = false, metalHud: Bool = false,
                buildId: String = "", pythonPath: String? = nil) {
        self.privateRoot = privateRoot; self.resources = resources; self.engineDir = engineDir; self.library = library
        self.libraryId = libraryId; self.developerDir = developerDir; self.fontsDir = fontsDir
        self.devHud = devHud; self.metalHud = metalHud; self.buildId = buildId; self.pythonPath = pythonPath
    }

    /// 随应用带的引擎（Resources/Engine/engine.json 在才算）。
    public var engineBundle: URL? {
        let path = resources.appendingPathComponent("Engine")
        return FileManager.default.fileExists(atPath: path.appendingPathComponent("engine.json").path) ? path : nil
    }

    /// 读 S2Arm 数据目录里的 preferences.json（旧启动器写的那份，Mac 只有这一套权威库）。本适配层只回写游戏库两项（saveLibrary，换游戏库时），
    /// 其余字段只读，避免两个前端各写各的。
    public static func load(privateRoot: URL, resources: URL, buildId: String = "") -> JobEnvironment {
        var env = JobEnvironment(privateRoot: privateRoot, resources: resources, buildId: buildId)
        guard let data = try? Data(contentsOf: privateRoot.appendingPathComponent("preferences.json")),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return env }
        env.library = S2ArmPaths.library(privateRoot: privateRoot, saved: p["library"] as? String ?? "")   // 旧默认库已搬到 ~/S2Arm 时用新位置
        env.libraryId = p["libraryId"] as? String ?? ""
        env.developerDir = p["developerDir"] as? String ?? ""
        env.engineDir = p["engineDir"] as? String
        env.fontsDir = p["fontsDir"] as? String
        env.devHud = p["devHud"] as? Bool ?? false
        env.metalHud = p["metalHud"] as? Bool ?? false
        env.pythonPath = p["pythonPath"] as? String
        env.exportTargets = p["exportTargets"] as? [String]
        return env
    }

    /// 换游戏库后把 library / libraryId 写回 preferences.json（同旧启动器 setupLibrary → savePreferences）：只改这两项，别的字段原样保留；
    /// 原子写、0600。旧启动器与本前端读同一份，换过去两边一致。
    public static func saveLibrary(privateRoot: URL, library: String, libraryId: String) throws {
        let file = privateRoot.appendingPathComponent("preferences.json")
        var p: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw JobClientError("设置文件 preferences.json 读不懂，没有改动它。")
            }
            p = object
        }
        p["library"] = library
        p["libraryId"] = libraryId
        do {
            try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: p, options: [.sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw JobClientError("游戏库已建好，但设置没能写进磁盘（\(error.localizedDescription)）：请检查磁盘空间和权限后再换一次。")
        }
    }
}

public struct JobClientError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 作业层的一行事件（pack/jobs/core.py emit）。schema 不是 1 的行不认。
public struct JobEvent {
    public let fields: [String: Any]

    /// 同旧 Store.event：taskId 缺了取 jobId；state succeeded 统一叫 completed。
    public init?(json: [String: Any]) {
        var e = json
        if e["taskId"] == nil { e["taskId"] = e["jobId"] }
        if e["state"] as? String == "succeeded" { e["state"] = "completed" }
        guard e["schema"] as? Int == 1, e["taskId"] is String else { return nil }
        fields = e
    }

    public var taskId: String { fields["taskId"] as? String ?? "" }
    public var type: String { fields["type"] as? String ?? "" }
    public var state: String? { fields["state"] as? String }
    public var operation: String? { fields["operation"] as? String }
    public var stage: String? { fields["stage"] as? String }
    public var message: String { fields["message"] as? String ?? "" }
    public var gameId: String? { fields["gameId"] as? String }
    public var done: Double? { (fields["done"] as? NSNumber)?.doubleValue }
    public var total: Double? { (fields["total"] as? NSNumber)?.doubleValue }
    public var result: [String: Any] { fields["result"] as? [String: Any] ?? [:] }
    public var isFinal: Bool { type == "result" }
}

/// 一次作业的结局。
public struct JobOutcome {
    /// paused：出包编排停在要玩家处理的点上（磁盘满 / 启动器退出，剃刀 H13 pack/jobs/export_plan.py），不算完成也不算失败
    public enum State: String { case completed, failed, cancelled, interrupted, paused }
    public let taskId: String
    public let state: State
    public let exitCode: Int32
    public let message: String
    public let result: [String: Any]
    public let diagnostics: [[String: Any]]
    /// 作业进程的标准错误（中断时给诊断用）。
    public let stderr: String

    public static let interruptedMessage = "工作进程已退出。可重试并验证完成阶段。"
}

/// 一次在跑的作业。
public final class JobHandle {
    public let id: String
    public let operation: String
    private let process: JobProcessHandle
    public private(set) var cancelling = false

    init(id: String, operation: String, process: JobProcessHandle) {
        self.id = id; self.operation = operation; self.process = process
    }

    /// 请作业停：SIGTERM，作业层记取消并以 130 退出（同旧 Store.cancel）。
    public func cancel() {
        cancelling = true
        process.terminate()
    }
}

/// S2Arm 作业层的客户端：写请求（schema 1、0600）、用隔离的 Python 起 `Jobs/main.py run --request`、按行读 NDJSON、取消、收结局。
/// 从旧 launchers/macos/Sources/S2ArmLauncher/Store.swift（worker / pythonExecutable / jobEngineURL / cancel）迁出的等价逻辑，不带界面状态。
public final class JobClient {
    public var environment: JobEnvironment
    private let runner: JobProcessRunner
    private let callbackQueue: DispatchQueue
    private let fileManager: FileManager
    private let pid: Int32
    private let baseEnvironment: [String: String]

    public init(environment: JobEnvironment, runner: JobProcessRunner = SystemJobProcessRunner(),
                callbackQueue: DispatchQueue = .main, fileManager: FileManager = .default,
                parentPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment; self.runner = runner; self.callbackQueue = callbackQueue
        self.fileManager = fileManager; self.pid = parentPid; self.baseEnvironment = processEnvironment
    }

    /// 起作业用的 Python：先认应用内置的 Runtime/python；有内置引擎却缺内置 Python = 安装不完整，直接报错；源码树里才退到设置 / 系统 Python。
    public func pythonExecutable() throws -> URL {
        let bundled = environment.resources.appendingPathComponent("Runtime/python/bin/python3")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        if environment.engineBundle != nil { throw JobClientError("应用内置 Python 缺失，请重新安装完整应用。") }
        if let selected = environment.pythonPath, !selected.isEmpty {
            guard fileManager.isExecutableFile(atPath: selected) else { throw JobClientError("设置中的 Python 不可执行，请重新选择。") }
            return URL(fileURLWithPath: selected)
        }
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw JobClientError("找不到 Python，请在设置中指定 Python 3.11 或更新版本。")
    }

    /// 作业入口：应用里是 Resources/Jobs/main.py，源码树里是 <engineDir>/pack/jobs/main.py。
    public func jobEntry() throws -> URL {
        let bundled = environment.resources.appendingPathComponent("Jobs/main.py")
        if fileManager.fileExists(atPath: bundled.path) { return bundled }
        let checkout = URL(fileURLWithPath: environment.engineDir ?? "").appendingPathComponent("pack/jobs/main.py")
        guard fileManager.fileExists(atPath: checkout.path) else { throw JobClientError("请选择包含 pack/jobs 的 S2Arm 源码目录。") }
        return checkout
    }

    /// 请求体（schema 1）：字段与旧 Store.worker 一一对应；extra 覆盖同名字段。不带 gameLanguage / docked（11-07 维护者 删游戏选项）：
    /// 作业层起局跟 Mac 系统首选语言、主机模式（pack/jobs/build.py runtime_env）。
    public func request(id: String, operation: String, extra: [String: Any] = [:]) -> [String: Any] {
        let env = environment
        var req: [String: Any] = [
            "schema": 1, "taskId": id, "operation": operation,
            "privateRoot": env.privateRoot.path, "resources": env.resources.path, "engineDir": env.engineDir ?? "",
            "library": env.library.isEmpty ? env.privateRoot.appendingPathComponent("unconfigured").path : env.library,
            "libraryId": env.libraryId, "developerDir": env.developerDir, "fontsDir": env.fontsDir ?? "",
            "devHud": env.devHud, "metalHud": env.metalHud, "buildId": env.buildId,
            "parentPid": Int(pid),
        ]
        extra.forEach { req[$0] = $1 }
        if let bundle = env.engineBundle { req["engineBundle"] = bundle.path; req["engineDir"] = bundle.path }
        // 环境准备不依赖游戏库：旧游戏库所在盘没插着时也要能跑
        if ["preflight", "prepareEngine"].contains(operation) {
            req["libraryId"] = ""
            req["storageLibraryId"] = env.libraryId
        }
        return req
    }

    /// 子进程环境：去掉 PYTHONPATH / PYTHONHOME，不写字节码、不读用户 site（同旧启动器；配合 -B -I）。
    public func processEnvironment() -> [String: String] {
        var env = baseEnvironment
        env["PYTHONUNBUFFERED"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"; env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
        return env
    }

    private func updaterEntry() throws -> URL { try jobEntry().deletingLastPathComponent().appendingPathComponent("updater.py") }

    /// 跑 updater.py 的一条命令，逐行交 JSON；结束时返回最后一行。
    private func runUpdater(_ command: [String], onEvent: @escaping @Sendable ([String: Any]) -> Void = { _ in }) async -> [String: Any]? {
        await runJobsScript("updater.py", command, onEvent: onEvent)
    }

    /// 批量出包的批次（pack/jobs/batch.py，Mac / Windows 共用）：show / create / mark / recover / cancel / resume / retry / clear，
    ///   返回 {batch, next, summary}（没有批次 → 空字典）；起不来返回 nil
    public func batch(_ command: String, _ arguments: [String] = []) async -> [String: Any]? {
        await runJobsScript("batch.py", [command, "--private-root", environment.privateRoot.path] + arguments)
    }

    /// 跑 pack/jobs 下的一个小脚本（updater.py / batch.py），逐行交 JSON；结束时返回最后一行
    private func runJobsScript(_ script: String, _ command: [String], onEvent: @escaping @Sendable ([String: Any]) -> Void = { _ in }) async -> [String: Any]? {
        guard let python = try? pythonExecutable(), let entry = try? jobEntry().deletingLastPathComponent().appendingPathComponent(script) else { return nil }
        final class Last: @unchecked Sendable { let lock = NSLock(); var value: [String: Any]? }
        let last = Last()
        return await withCheckedContinuation { continuation in
            do {
                _ = try runner.start(executable: python, arguments: ["-B", "-I", entry.path] + command, environment: processEnvironment(),
                                     onLine: { line in
                                         guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                                         last.lock.lock(); last.value = object; last.lock.unlock()
                                         onEvent(object)
                                     }, onStderr: { _ in },
                                     onExit: { _ in last.lock.lock(); let value = last.value; last.lock.unlock(); continuation.resume(returning: value) })
            } catch { continuation.resume(returning: nil) }
        }
    }

    /// 启动器顶部公告条（pack/jobs/updater.py notice）：{id, text: {zh-Hans, en}, url?}；没有要显示的、取不到、起不来都返回 nil，不打扰玩家
    public func notice() async -> [String: Any]? {
        let result = await runUpdater(["notice", "--private-root", environment.privateRoot.path])
        return result?["id"] is String ? result : nil
    }

    /// 玩家关掉公告：记下它的号，同一条不再出现（换了新号的公告照常出现）
    public func noticeDismiss(id: String) async {
        _ = await runUpdater(["notice-dismiss", "--private-root", environment.privateRoot.path, "--id", id])
    }

    /// 有比 current 高的正式版就返回版本号；查不到（没网、GitHub 不通）返回 nil，不打扰玩家。
    public func updateCheck(current: String) async -> String? {
        let result = await runUpdater(["check", "--platform", "mac", "--current", current])
        return result?["available"] as? Bool == true ? result?["version"] as? String : nil
    }

    /// 下载、校验、解开新版（不碰正在用的安装目录）。最后一行 state = ready 或 failed。
    public func updatePrepare(current: String, install: String, onEvent: @escaping @Sendable ([String: Any]) -> Void) async -> [String: Any]? {
        var command = ["prepare", "--platform", "mac", "--current", current, "--private-root", environment.privateRoot.path, "--install", install]
        if !environment.library.isEmpty { command += ["--protect", environment.library] }
        return await runUpdater(command, onEvent: onEvent)
    }

    /// 起独立的替换进程：它等本进程退出后换掉 App 并重启，用的是 updates/ 里的 Python，不依赖安装目录。
    public func updateApply(ready: [String: Any], install: String, arguments: [String]) throws {
        guard let python = ready["python"] as? String, let updater = ready["updater"] as? String, let staged = ready["staged"] as? String else {
            throw JobClientError("更新数据不完整。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", "-I", updater, "apply", "--staged", staged, "--install", install, "--pid", String(ProcessInfo.processInfo.processIdentifier),
                             "--private-root", environment.privateRoot.path] + arguments.map { "--arg=" + $0 }
        process.environment = processEnvironment()
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    /// 最近一次失败作业的错误摘要（作业层 report.py，Mac / Windows 共用）。没有作业记录时返回 nil，由界面退回基本信息。
    public func errorReport(gameID: String?, operations: [String], extra: [String: Any]) async -> String? {
        guard let python = try? pythonExecutable(), let entry = try? jobEntry() else { return nil }
        var arguments = ["-B", "-I", entry.path, "report", "--private-root", environment.privateRoot.path]
        if let gameID { arguments += ["--game", gameID] }
        if !operations.isEmpty { arguments += ["--operations", operations.joined(separator: ",")] }
        var env = processEnvironment()
        if let data = try? JSONSerialization.data(withJSONObject: extra) { env["S2A_REPORT_EXTRA"] = String(decoding: data, as: UTF8.self) }
        final class Output: @unchecked Sendable {
            private let lock = NSLock(); private var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
        }
        let output = Output()
        return await withCheckedContinuation { continuation in
            do {
                _ = try runner.start(executable: python, arguments: arguments, environment: env,
                                     onLine: { output.add(String(decoding: $0, as: UTF8.self)) }, onStderr: { _ in },
                                     onExit: { continuation.resume(returning: $0 == 0 ? output.text : nil) })
            } catch { continuation.resume(returning: nil) }
        }
    }

    /// 交一个作业。onEvent / onFinish 都在 callbackQueue 上、按作业输出顺序到达；onFinish 只来一次、在最后。
    /// 起不来（缺 Python / 入口 / 写不进请求）直接抛错，不回调。
    @discardableResult
    /// secrets：只给这一个作业进程的环境变量（开发者证书密码，pack/jobs/devcert.py ⑤）；不进请求文件，作业层一起来就从环境摘掉
    public func start(operation: String, extra: [String: Any] = [:], id: String = UUID().uuidString.lowercased(), secrets: [String: String] = [:],
                      onEvent: @escaping (JobEvent) -> Void = { _ in },
                      onFinish: @escaping (JobOutcome) -> Void = { _ in }) throws -> JobHandle {
        let python = try pythonExecutable()
        let entry = try jobEntry()
        let dir = environment.privateRoot.appendingPathComponent("requests")
        let file = dir.appendingPathComponent(id + ".json")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: request(id: id, operation: operation, extra: extra))
            try data.write(to: file, options: .atomic)
            // 作业层只认本人所有、0600 的请求（winproc.request_is_private）
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw JobClientError("无法写入任务请求：\(error.localizedDescription)")
        }
        let collector = Collector(id: id)
        let queue = callbackQueue
        let fm = fileManager
        let process: JobProcessHandle
        do {
            process = try runner.start(
                executable: python, arguments: ["-B", "-I", entry.path, "run", "--request", file.path],
                environment: processEnvironment().merging(secrets) { _, s in s },
                onLine: { line in
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                    guard let event = JobEvent(json: object) else {
                        // 校验阶段拒收（main.py 打印 {"error", "code"} 后退出 2）：不是事件，留作结局说明
                        if let message = object["error"] as? String { collector.rejection = message }
                        return
                    }
                    guard event.taskId == id else { return }
                    if event.isFinal { collector.final = event }
                    queue.async { onEvent(event) }
                },
                onStderr: { chunk in collector.stderr.append(chunk) },
                onExit: { status in
                    try? fm.removeItem(at: file)
                    let outcome = collector.outcome(exitCode: status)
                    queue.async { onFinish(outcome) }
                })
        } catch {
            try? fileManager.removeItem(at: file)
            throw JobClientError("无法启动本地组件：\(error.localizedDescription)")
        }
        return JobHandle(id: id, operation: operation, process: process)
    }

    /// 只在 runner 的串行队列上读写。
    private final class Collector {
        let id: String
        var final: JobEvent?
        var rejection: String?
        var stderr = Data()
        init(id: String) { self.id = id }

        func outcome(exitCode: Int32) -> JobOutcome {
            let errorText = String(decoding: stderr, as: UTF8.self)
            if let final, let state = JobOutcome.State(rawValue: final.state ?? "") {
                let diagnostics = final.fields["diagnostics"] as? [[String: Any]] ?? []
                return JobOutcome(taskId: id, state: state, exitCode: exitCode, message: final.message,
                                  result: final.result, diagnostics: diagnostics, stderr: errorText)
            }
            // 没有结果事件：130 = 作业层收到 SIGTERM 记的取消；其他 = 进程中途没了
            if exitCode == 130 {
                return JobOutcome(taskId: id, state: .cancelled, exitCode: exitCode, message: "任务已取消。",
                                  result: [:], diagnostics: [], stderr: errorText)
            }
            // 进程一启动就退出时没有日志可看：把错误输出的末尾带上，玩家和错误摘要才有线索
            let tail = errorText.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
            let interrupted = tail.isEmpty ? JobOutcome.interruptedMessage : JobOutcome.interruptedMessage + "\n" + tail
            return JobOutcome(taskId: id, state: .interrupted, exitCode: exitCode, message: rejection ?? interrupted,
                              result: [:], diagnostics: [], stderr: errorText)
        }
    }
}
