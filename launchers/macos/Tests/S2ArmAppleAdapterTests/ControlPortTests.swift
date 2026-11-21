import XCTest
@testable import S2ArmAppleAdapter

// 本机控制口传输层（11-07：从旧启动器抽出，两个前端共用）。期望按协议手写：只听 127.0.0.1、令牌不对 401、
//   control.json 0600 带 port / token / pid、写不上不算开、GET /state 回缓存快照、其余交处理函数；作业记录当 tasks 只取玩家看得见的作业
@MainActor final class ControlPortTests: XCTestCase {
    private func root() -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-port-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true); return r
    }
    private func waitFor(_ cond: () -> Bool) { let end = Date().addingTimeInterval(5); while Date() < end && !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }

    func testTokenFailureThrowsInsteadOfZeros() throws {
        XCTAssertThrowsError(try ControlPort.makeToken { _ in errSecAllocate })
        XCTAssertEqual(try ControlPort.makeToken { b in for i in b.indices { b[i] = UInt8(i + 1) }; return errSecSuccess }, "0102030405060708090a0b0c0d0e0f10")
    }

    func testServesLoopbackWithTokenAndWritesPrivateControlFile() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        var seen: [String] = []
        let port = try ControlPort(privateRoot: r, state: { ["hello": "state"] }, handle: { req in seen.append(req.method + " " + req.path); return .ok(["echo": req.body["x"] ?? NSNull()]) },
                                   failed: { XCTFail($0) })
        defer { port.stop() }
        waitFor { port.port != 0 && FileManager.default.fileExists(atPath: port.controlFile.path) }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: port.controlFile)) as? [String: Any]
        XCTAssertEqual(info?["port"] as? Int, Int(port.port)); XCTAssertEqual(info?["token"] as? String, port.token)
        XCTAssertEqual(info?["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        func call(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port.port)\(path)")!); req.httpMethod = method
            if let token { req.setValue(token, forHTTPHeaderField: "X-S2Arm-Token") }
            if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
            var out: (Int, [String: Any]) = (0, [:]); let done = expectation(description: path)
            URLSession.shared.dataTask(with: req) { d, resp, _ in
                out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]); done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5); return out
        }
        XCTAssertEqual(call("GET", "/state", token: nil).0, 401)
        XCTAssertEqual(call("GET", "/state", token: "0000").0, 401)
        let st = call("GET", "/state", token: port.token); XCTAssertEqual(st.0, 200); XCTAssertEqual(st.1["hello"] as? String, "state")
        let p = call("POST", "/do", token: port.token, body: ["x": 7]); XCTAssertEqual(p.0, 200); XCTAssertEqual(p.1["echo"] as? Int, 7)
        XCTAssertEqual(seen, ["POST /do"])   // GET /state 不经处理函数
        port.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: port.controlFile.path), "停了就删 control.json")
    }

    func testStartFailureIsWrittenAndClearedOnSuccess() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let error = r.appendingPathComponent("control.error")
        ControlPort.reportStartFailure(privateRoot: r, why: "端口被占用")
        XCTAssertEqual(try String(contentsOf: error, encoding: .utf8), "端口被占用")
        let port = try ControlPort(privateRoot: r, state: { [:] }, handle: { _ in .ok() }, failed: { XCTFail($0) })
        defer { port.stop() }
        waitFor { port.port != 0 && !FileManager.default.fileExists(atPath: error.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: error.path), "起来了就清掉旧原因")
    }

    func testControlFileWriteFailureIsNotOpen() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        try FileManager.default.createDirectory(at: r.appendingPathComponent("control.json"), withIntermediateDirectories: true)
        var why: String?
        let port = try ControlPort(privateRoot: r, state: { [:] }, handle: { _ in .ok() }, failed: { why = $0 })
        waitFor { why != nil }
        XCTAssertTrue(why?.contains("control.json") == true, why ?? "没报")
        port.stop()
    }

    func testJournalTasksAreVisibleJobsOldestFirst() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let jobs = r.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        func put(_ name: String, _ o: [String: Any]) throws { try JSONSerialization.data(withJSONObject: o).write(to: jobs.appendingPathComponent(name)) }
        try put("b.json", ["id": "b", "operation": "ipa", "state": "running", "started": 20.0])
        try put("a.json", ["id": "a", "operation": "import", "state": "completed", "started": 10.0])
        try put("c.json", ["id": "c", "operation": "catalog", "state": "completed", "started": 30.0])      // 后台小作业不进
        try put("b.request.json", ["id": "b", "operation": "ipa"])                                           // 请求文件不进
        try Data("not json".utf8).write(to: jobs.appendingPathComponent("d.json"))                          // 坏文件跳过
        XCTAssertEqual(ControlJournal.tasks(privateRoot: r).compactMap { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual(ControlJournal.tasks(privateRoot: r, limit: 1).compactMap { $0["id"] as? String }, ["b"])
    }

    /// #1946：/retry 照原请求回填 device / teamId / mode——读得到原请求；不在、坏文件、带路径的任务号都给 nil
    func testJournalRequestReadsOriginalRequest() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let jobs = r.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": "t1", "operation": "install", "gameId": "G", "device": "UDID-2", "teamId": "TEAM", "mode": "export"])
            .write(to: jobs.appendingPathComponent("t1.request.json"))
        try Data("not json".utf8).write(to: jobs.appendingPathComponent("t2.request.json"))
        let req = ControlJournal.request(privateRoot: r, id: "t1")
        XCTAssertEqual([req?["device"] as? String, req?["teamId"] as? String, req?["mode"] as? String], ["UDID-2", "TEAM", "export"])
        XCTAssertNil(ControlJournal.request(privateRoot: r, id: "t2"))
        XCTAssertNil(ControlJournal.request(privateRoot: r, id: "nope"))
        XCTAssertNil(ControlJournal.request(privateRoot: r, id: "../t1"))
    }

    /// 任务列表有缓存（控制口每秒刷一次，原先每次全量重读）：新增、删除、原子改名更新、正在跑的任务原地改写，都要当场反映出来
    func testJournalTasksCacheFollowsEveryKindOfChange() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let jobs = r.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)   // 还没建库：任务记录在 <私有目录>/logs/jobs（S2ArmPaths.jobsDir）
        func put(_ name: String, _ o: [String: Any]) throws {   // 原子写（同 pack/jobs/core.py atomic：临时文件再改名）
            let tmp = jobs.appendingPathComponent(name + ".tmp")
            try JSONSerialization.data(withJSONObject: o).write(to: tmp)
            _ = try FileManager.default.replaceItemAt(jobs.appendingPathComponent(name), withItemAt: tmp)
        }
        func states() -> [String] { ControlJournal.tasks(privateRoot: r).map { "\($0["id"]!):\($0["state"]!)" } }
        try put("a.json", ["id": "a", "operation": "ipa", "state": "running", "started": 1.0])
        XCTAssertEqual(states(), ["a:running"])
        XCTAssertEqual(states(), ["a:running"])                                   // 没变：走缓存，结果一样
        try put("b.json", ["id": "b", "operation": "build", "state": "running", "started": 2.0])
        XCTAssertEqual(states(), ["a:running", "b:running"])                      // 新增
        try put("a.json", ["id": "a", "operation": "ipa", "state": "completed", "started": 1.0, "ended": 3.0])
        XCTAssertEqual(states(), ["a:completed", "b:running"])                    // 原子改名更新
        try JSONSerialization.data(withJSONObject: ["id": "b", "operation": "build", "state": "failed", "started": 2.0, "message": "x"])
            .write(to: jobs.appendingPathComponent("b.json"))                     // 正在跑的任务被原地改写（目录修改时间不变）
        XCTAssertEqual(states(), ["a:completed", "b:failed"])
        try FileManager.default.removeItem(at: jobs.appendingPathComponent("a.json"))
        XCTAssertEqual(states(), ["b:failed"])                                    // 删除
    }

    /// #642：作业进程被强杀、来不及写终态，记录一直停在 running。快照里进程不在就报 interrupted（缓存命中时也核），进程在就照报 running
    func testJournalReportsRunningJobWhoseProcessIsGoneAsInterrupted() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let jobs = r.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()   // 已退出并收尸的进程号
        func put(_ name: String, _ o: [String: Any]) throws { try JSONSerialization.data(withJSONObject: o).write(to: jobs.appendingPathComponent(name)) }
        try put("live.json", ["id": "live", "operation": "install", "state": "running", "started": 1.0, "pid": Int(getpid())])
        try put("dead.json", ["id": "dead", "operation": "install", "state": "running", "started": 2.0, "pid": Int(gone.processIdentifier)])
        try put("nopid.json", ["id": "nopid", "operation": "install", "state": "queued", "started": 3.0])
        try put("done.json", ["id": "done", "operation": "install", "state": "completed", "started": 4.0, "pid": Int(gone.processIdentifier)])
        func states() -> [String] { ControlJournal.tasks(privateRoot: r).map { "\($0["id"]!):\($0["state"]!)" } }
        let want = ["live:running", "dead:interrupted", "nopid:queued", "done:completed"]
        XCTAssertEqual(states(), want)
        XCTAssertEqual(states(), want)   // 第二次走缓存，照样核
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: jobs.appendingPathComponent("dead.json"))) as? [String: Any]
        XCTAssertEqual(raw?["state"] as? String, "running")   // 作业记录本身不改
    }
}
