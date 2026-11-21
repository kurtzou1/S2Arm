// 本机控制口的传输层（两个 Mac 前端共用一份：旧启动器 S2ArmLauncher/ControlServer.swift、新前端 NX2Apple/S2ArmControl.swift）。
// 用户体验线 10-23（维护者：玩家用自己的 AI 完成移植）：只听 127.0.0.1；每次启动随机令牌；端口与令牌写 <私有目录>/control.json（0600），
//   客户端 launchers/macos/s2armctl.py 读它连进来。命令怎么做由各前端的处理函数定（调界面按钮背后的同一个模型方法），这里只管收发。
// 11-07 启动器线：新前端成了发版缺省却没有控制口，App 自带的 s2armctl / skill 全部连不上——传输层从旧启动器抽到这里，两个前端同一份。
import Foundation
import Network
import Security

/// 一个请求：极简 HTTP/1.1，头 + Content-Length 个字节的 JSON 正文。
public struct ControlRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: [String: Any]

    public init(method: String, path: String, headers: [String: String], body: [String: Any]) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }

    /// 头没收全或正文不够 Content-Length → nil（继续收）。
    public static func parse(_ d: Data) -> ControlRequest? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)), let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n"); let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let n = Int(h["content-length"] ?? "0") ?? 0
        let bodyData = d[end.upperBound...]
        guard bodyData.count >= n else { return nil }
        let body = n > 0 ? ((try? JSONSerialization.jsonObject(with: bodyData.prefix(n))) as? [String: Any] ?? [:]) : [:]
        return ControlRequest(method: String(first[0]), path: String(first[1].split(separator: "?")[0]), headers: h, body: body)
    }
}

/// 一个回答：状态码、类型、正文。
public struct ControlReply {
    public var code: Int
    public var type: String
    public var body: Data

    public init(code: Int, type: String = "application/json", body: Data) { self.code = code; self.type = type; self.body = body }
    public static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8) }
    public static func ok(_ extra: [String: Any] = [:]) -> ControlReply { ControlReply(code: 200, body: json(extra.merging(["ok": true]) { a, _ in a })) }
    public static func bad(_ msg: String, code: Int = 400) -> ControlReply { ControlReply(code: code, body: json(["error": msg])) }
    public static func object(_ o: Any) -> ControlReply { ControlReply(code: 200, body: json(o)) }
}

/// /state 快照缓存：主线程每秒写一次，控制口队列直接读（主线程卡住时照样答，cachedAt 告诉客户端快照有多旧）。
final class ControlStateCache: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data("{}".utf8)
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

@MainActor public final class ControlPort {
    /// 带 --control 启动或 S2ARM_CONTROL=1：强制开，不看也不写玩家的开关（测试 / s2armctl start 用）。
    public static var forced: Bool { CommandLine.arguments.contains("--control") || ProcessInfo.processInfo.environment["S2ARM_CONTROL"] == "1" }

    /// 令牌（审计 18:00 P2-35）：系统随机数失败时不能退成 32 个 0，抛错由调用方报出。
    public static func makeToken(_ random: (inout [UInt8]) -> OSStatus = { SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0) }) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = random(&bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "系统随机数生成失败（\(status)）"])
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated let token: String
    public private(set) var port: UInt16 = 0
    public var controlFile: URL { privateRoot.appendingPathComponent("control.json") }

    /// 控制口起不来时也就没有 /state：把原因写进数据目录，s2armctl start 读它报给用户。写不上不影响启动器本身。
    public nonisolated static func reportStartFailure(privateRoot: URL, why: String) {
        try? FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try? Data(why.utf8).write(to: errorFile(privateRoot))
    }
    private nonisolated static func errorFile(_ root: URL) -> URL { root.appendingPathComponent("control.error") }
    private let privateRoot: URL
    private let listener: NWListener
    private let state: @MainActor () -> [String: Any]
    private let handle: @MainActor (ControlRequest) async -> ControlReply
    private let failed: @MainActor (String) -> Void
    private let readied: @MainActor (UInt16) -> Void
    // 监听与连接都在独立队列（10-26 Spare-host：内存吃紧主线程卡住，控制口跟着不应答，s2armctl wait 判失败、出包作业跟着丢）；
    //   GET /state 在这个队列上回缓存快照，要动界面的命令切回主线程
    nonisolated private let queue = DispatchQueue(label: "s2arm.control")
    nonisolated private let cache = ControlStateCache()
    private var cacheTimer: Timer?
    private var stopped = false

    /// state：GET /state 的快照（主线程每秒取一次进缓存）；handle：其余命令；failed：起不来 / control.json 写不上（不算已开）；ready：已在听（端口）。
    public init(privateRoot: URL, state: @escaping @MainActor () -> [String: Any],
                handle: @escaping @MainActor (ControlRequest) async -> ControlReply,
                failed: @escaping @MainActor (String) -> Void, ready: @escaping @MainActor (UInt16) -> Void = { _ in },
                random: (inout [UInt8]) -> OSStatus = { SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0) }) throws {
        self.privateRoot = privateRoot; self.state = state; self.handle = handle; self.failed = failed; self.readied = ready
        token = try Self.makeToken(random)
        let params = NWParameters.tcp; params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any); params.acceptLocalOnly = true
        listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: Task { @MainActor in self?.becameReady() }
            case .failed(let error): Task { @MainActor in self?.fail("控制口监听失败：\(error.localizedDescription)") }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        refreshCache()
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshCache() } }
    }

    /// 停听、删 control.json（AI 立刻连不上）。
    public func stop() {
        guard !stopped else { return }
        stopped = true
        listener.cancel(); cacheTimer?.invalidate(); cacheTimer = nil
        try? FileManager.default.removeItem(at: controlFile)
    }

    public func refreshCache() { cache.set(ControlReply.json(state())) }

    private func fail(_ why: String) {
        guard !stopped else { return }
        stopped = true
        listener.cancel(); cacheTimer?.invalidate(); cacheTimer = nil
        failed(why)
    }

    private func becameReady() {
        guard !stopped else { return }
        port = listener.port?.rawValue ?? 0
        let info: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        try? FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: info),
              FileManager.default.createFile(atPath: controlFile.path, contents: d) else {
            // 写不上 = AI 客户端连不进来（审计 18:00 P2-35）：停听，不当作已开
            fail("写不了 " + controlFile.path)
            return
        }
        try? FileManager.default.removeItem(at: Self.errorFile(privateRoot))
        NSLog("S2Arm 控制口：127.0.0.1:\(port)（\(controlFile.path)）")
        readied(port)
    }

    nonisolated private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    nonisolated private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var b = buf; if let data { b.append(data) }
            if let req = ControlRequest.parse(b) {
                if req.headers["x-s2arm-token"] != self.token { Self.send(c, .bad("令牌不对", code: 401)); return }
                if req.method == "GET" && req.path == "/state" { Self.send(c, ControlReply(code: 200, body: self.cache.get())); return }   // 不经主线程
                Task { @MainActor in
                    let reply = await self.handle(req)
                    self.refreshCache()   // 客户端接着读 /state，不能读到命令之前的状态
                    Self.send(c, reply)
                }
                return
            }
            if done || err != nil || b.count > (8 << 20) { c.cancel(); return }
            self.receive(c, b)
        }
    }

    nonisolated static func send(_ c: NWConnection, _ r: ControlReply) {
        let type = r.type.hasPrefix("application/json") ? "application/json; charset=utf-8" : r.type
        let head = "HTTP/1.1 \(r.code) \(r.code == 200 ? "OK" : "ERR")\r\nContent-Type: \(type)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// 作业层自己写的作业记录（pack/jobs/core.py：<私有目录>/logs/jobs/<任务>.json，库没建好时 <私有目录>/logs/jobs，见 S2ArmPaths.jobsDir，字段 id / operation / gameId / state / stage / milestone / milestones /
///   done / total / unit / message / started / ended / diagnostics / ipaPath / outputPath / pid / pidStart）当 GET /state 的 tasks：
///   作业是独立进程，界面没有任务表也照样有据（s2armctl wait / errors / logs 读的就是这些字段；控制口不应答时 s2armctl 本来就读同一份文件）。
public enum ControlJournal {
    /// 玩家看得见的作业（同旧启动器 Store.visibleOperations）；查环境、读游戏库这类后台小作业不进。
    public static let visibleOperations: Set<String> = ["install", "installRemove", "installRestore", "installUpdate", "build", "moveGame", "import", "keys", "downloadMetal", "downloadIosPlatform", "launch", "clean",
                                                        "remove", "delete", "diagnostics", "prepareEngine", "pullDiagnostics", "ipa", "installDotnet", "setup", "spaceFree"]

    /// 这条任务的原请求（<任务目录>/<任务号>.request.json）：控制口 /retry 照它回填装到哪台、团队、方式（#1946）；不在 / 读不了 → nil
    public static func request(privateRoot: URL, id: String) -> [String: Any]? {
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let url = S2ArmPaths.jobsDir(privateRoot: privateRoot).appendingPathComponent(id + ".request.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// 最近的 limit 条，按开始时间从旧到新。
    /// 控制口每秒刷一次状态快照（ControlPort.refreshCache）都会调这里。原先每次把任务目录里所有记录重读、重解析一遍：
    ///   任务多了（11-09 维护者机器 45207 条、290 MB）闲置也占 30–90% CPU、风扇狂转。记录都是先写临时文件再改名（pack/jobs/core.py atomic），
    ///   每次更新都会改目录的修改时间：目录没变就直接用上次结果；变了只重新解析大小或修改时间变过的文件。没结束的任务每次单独再核一遍
    public static func tasks(privateRoot: URL, limit: Int = 60) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let dir = S2ArmPaths.jobsDir(privateRoot: privateRoot)
        let stamp = stat(dir.path)
        if let stamp, cache.dir == dir.path, cache.stamp == stamp, cache.limit == limit, !cache.hasLiveTaskChanged(dir: dir) {
            return cache.result.map(orphanChecked)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if cache.dir != dir.path { cache.files = [:] }
        var files: [String: JournalCache.Entry] = [:]
        var out: [[String: Any]] = []
        for n in names where n.hasSuffix(".json") && !n.hasSuffix(".request.json") {
            guard let st = stat(dir.appendingPathComponent(n).path) else { continue }
            let entry: JournalCache.Entry
            if let old = cache.files[n], old.stat == st {
                entry = old
            } else {
                var record: [String: Any]?
                if let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                   let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   j["id"] is String, let op = j["operation"] as? String, visibleOperations.contains(op) { record = j }
                entry = JournalCache.Entry(stat: st, record: record)
            }
            files[n] = entry
            if let j = entry.record { out.append(j) }
        }
        out.sort { ($0["started"] as? Double ?? 0) < ($1["started"] as? Double ?? 0) }
        let result = Array(out.suffix(limit))
        cache.dir = dir.path; cache.stamp = stamp; cache.limit = limit; cache.files = files; cache.result = result
        cache.live = files.filter { _, e in e.record.map { !terminalStates.contains($0["state"] as? String ?? "") } ?? false }.mapValues(\.stat)
        return result.map(orphanChecked)
    }

    /// 没到终态、可作业进程已经不在了（被强杀 / 崩溃，来不及写终态）：快照里按「中断」报，不再一直报在跑（#642：
    ///   装机进程没了，next 还说 install 正在进行、cancel 又说没有在跑的作业）。只改报出去的这份，不改作业记录；
    ///   每次快照都核（缓存命中时记录文件没变，进程却可能刚没）。没记 pid 的（还没起来）照原样
    static func orphanChecked(_ j: [String: Any]) -> [String: Any] {
        guard !terminalStates.contains(j["state"] as? String ?? ""), j["state"] as? String != "interrupted",
              let pid = (j["pid"] as? NSNumber)?.int32Value, pid > 0, !processAlive(pid) else { return j }
        var out = j
        out["state"] = "interrupted"
        out["message"] = "作业进程已经退出、没来得及写完结果（被中断）：可以重试，已做完的阶段会先核再用。"
        return out
    }

    static func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static let terminalStates: Set<String> = ["completed", "failed", "cancelled"]
    private static let lock = NSLock()
    private static let cache = JournalCache()

    /// 修改时间（纳秒）+ 大小：判断一个文件 / 目录变没变
    fileprivate struct FileStamp: Equatable { let mtime: Int64; let size: Int64 }
    fileprivate static func stat(_ path: String) -> FileStamp? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileStamp(mtime: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), size: Int64(st.st_size))
    }

    private final class JournalCache {
        struct Entry { let stat: FileStamp; let record: [String: Any]? }
        var dir = ""
        var stamp: FileStamp?
        var limit = 0
        var files: [String: Entry] = [:]
        var result: [[String: Any]] = []
        var live: [String: FileStamp] = [:]   // 还没结束的任务：原地改写不会动目录的修改时间，每次单独核
        func hasLiveTaskChanged(dir: URL) -> Bool {
            live.contains { n, st in ControlJournal.stat(dir.appendingPathComponent(n).path) != st }
        }
    }
}
