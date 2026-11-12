// S2Arm（不是上游文件）：批量出包（v0.2.4，维护者批）。一次放进多款 → 识别完列成清单，每款勾 iPhone / Mac（可以同时勾）→
// 一批共用一个存放位置 → 一款接一款地出；同一款的两个平台连着出，解包等平台无关阶段作业层本来就共用。
// 清单、状态和规则（下一个出谁、磁盘满暂停、继续 / 重试 / 取消、汇总）在共用后端 pack/jobs/batch.py，执行在 pack/jobs/export_plan.py（剃刀 H13），
// Windows 同一份；这里只发起作业、画状态。
import Foundation
import S2ArmAppleAdapter

/// 出包前清单里的一行：识别出来的一款游戏，勾了哪些平台；不能出的写原因（缺密钥、缺文件），勾选置灰、不进批次
struct BatchRow: Identifiable, Equatable {
    let id: String
    let name: String
    var iphone: Bool
    var mac: Bool
    var problem: String?
    var platforms: [String] { (iphone ? ["iphone"] : []) + (mac ? ["mac"] : []) }
}

extension S2ArmLauncherModel {
    static func batchPlatform(_ p: ExportPlatform) -> String? { p == .ios ? "iphone" : p == .mac ? "mac" : nil }
    static func exportPlatform(_ p: String) -> ExportPlatform? { p == "iphone" ? .ios : p == "mac" ? .mac : nil }

    /// 后端批次里的各款（show 的 batch.items）
    var batchItems: [[String: Any]] { (batchState?["batch"] as? [String: Any])?["items"] as? [[String: Any]] ?? [] }
    var batchSummary: [String: Any] { batchState?["summary"] as? [String: Any] ?? [:] }
    var batchPaused: String? { (batchState?["batch"] as? [String: Any])?["paused"] as? String }
    /// 有批次、还有没出完的（还有平台没出的、取消的；暂停着时失败的也算，等「重试」）：库页顶部提示「上次还有 N 款没出完」（审计 P1-168）
    var batchUnfinished: Int {
        guard batchState != nil else { return 0 }
        return (batchSummary["pending"] as? Int ?? 0) + (batchSummary["cancelled"] as? Int ?? 0) + (batchPaused != nil ? batchSummary["failed"] as? Int ?? 0 : 0)
    }

    /// 重开启动器后说「上次停在第几款」（从 1 数）：被打断的那款（启动器退出时正在出、作业层重新排队并记 interrupted）；
    /// 没有被打断的就是第一款还有平台排着队的；都没有是 0（同 Windows BatchState.StoppedAt）
    var batchStoppedAt: Int {
        func first(_ hit: ([String: Any]) -> Bool) -> Int {
            for (n, item) in batchItems.enumerated() {
                let results = item["results"] as? [String: [String: Any]] ?? [:]
                if (item["platforms"] as? [String] ?? []).contains(where: { results[$0].map(hit) ?? false }) { return n + 1 }
            }
            return 0
        }
        let interrupted = first { $0["state"] as? String == "pending" && $0["interrupted"] as? Bool == true }
        return interrupted > 0 ? interrupted : first { ["pending", "running"].contains($0["state"] as? String ?? "") }
    }

    /// 放进来的几款列成清单（导入完调；从游戏库多选也走这里）：勾选默认跟着出包页上次勾的平台；缺东西的款写原因
    func openBatch(_ ids: [String], unrecognized: [ImportSource] = []) {
        let picked = Set(exportTargets.compactMap(Self.batchPlatform))
        batchDraft = ids.compactMap { id in
            guard let g = games.first(where: { $0.id == id }) else { return nil }
            let problem = !g.buildable ? Self.requirementsText(g) : (g.needsKeys && provider.library.keysReady == false) ? "keys" : nil
            // 缺东西的款也照勾（只写原因，v0.3.1 不预先挡）：出包作业开头核实，真缺就这一款报失败、不挡后面的款
            return BatchRow(id: g.id, name: g.name, iphone: picked.contains("iphone"), mac: picked.contains("mac"), problem: problem)
        }
        batchUnrecognized = unrecognized
        if batchLocation.isEmpty, let first = ids.compactMap({ id in games.first { $0.id == id } }).first { batchLocation = defaultLocation(for: first) }
        exportFor = nil
        batchShown = true
    }

    /// 全选某个平台：没问题的款全勾上；已全勾就全取消
    func batchToggleAll(_ platform: String) {
        let ok = Array(batchDraft.indices)
        let all = ok.allSatisfy { platform == "iphone" ? batchDraft[$0].iphone : batchDraft[$0].mac }
        for i in ok { if platform == "iphone" { batchDraft[i].iphone = !all } else { batchDraft[i].mac = !all } }
    }

    /// 点「出包（N 款）」：后端建批次，起出包编排作业
    func startBatch() { Task { _ = await createBatch() } }

    /// 建批次并开始出 → nil；没建成 → 原因（控制口 POST /batch 据此回 409，不先回成功，审计 P1-166）
    func createBatch() async -> String? {
        let items = batchDraft.filter { !$0.platforms.isEmpty }.map { ["gameId": $0.id, "name": $0.name, "platforms": $0.platforms] as [String: Any] }
        guard !items.isEmpty else { return "没有能出的游戏" }
        guard !busy, !batchRunning else { return "正在出包" }
        guard let data = try? JSONSerialization.data(withJSONObject: ["items": items, "location": batchLocation.isEmpty ? NSNull() : batchLocation] as [String: Any]),
              let json = String(data: data, encoding: .utf8) else { return "批次清单组不出来" }
        guard let state = await provider.client.batch("create", ["--json", json]) else { return "批次脚本起不来" }
        guard state["batch"] != nil else { return state["error"] as? String ?? "建批次失败" }
        batchState = state
        batchDraft = []
        runBatchExport()
        return nil
    }

    /// 按批次文件起出包编排作业（剃刀 H13，pack/jobs/export_plan.py）：下一个出谁、记账、磁盘满暂停、这台电脑出不了的平台都在作业层；
    /// 这里只按它的事件一款换一个出包会话（exportSink → batchStepStarted），留在清单页看整批进度（单款运行页可从顶部胶囊打开）
    func runBatchExport() {
        batchRunning = true; batchError = nil; batchShown = true
        let hasIPhone = batchItems.contains { ($0["platforms"] as? [String] ?? []).contains("iphone") }
        batchWork = Task { [weak self] in
            guard let self else { return }
            let sink = self.exportSink(EventSink { [weak self] e in self?.ingest(e) })
            var failure: JobFailure?, other: Error?
            do { _ = try await self.provider.export(plan: ["source": "batch"], hasIPhone: hasIPhone, events: sink) }
            catch let f as JobFailure { failure = f } catch { other = error }
            self.finishBatchGame()   // 最后一款的会话收尾（取消时正在出的那个平台由作业层记成已取消）
            self.batchRunning = false
            if let s = await self.provider.client.batch("show"), s["batch"] != nil { self.batchState = s }
            // 编排作业自己没成（批次记录写不进、已有一个在出、起不来）：原因写在清单页。暂停（磁盘满 / 启动器退出）与取消看批次状态
            if let failure, failure.state == .failed || failure.state == .interrupted { self.batchError = failure.errorDescription ?? "" }
            else if let other { self.batchError = other.localizedDescription }
            self.batchFinished()
            self.pumpQueue()
        }
    }

    /// 编排作业开始出某一款：换到这一款的出包会话（上一款的按它各平台的结局收尾）
    func batchStepStarted(_ gid: String) {
        guard batchRunning, session?.gameID != gid || session.map({ if case .finished = $0.phase { return true }; return false }) == true else { return }
        finishBatchGame()
        guard let item = batchItems.first(where: { $0["gameId"] as? String == gid }) else { return }
        var s = JobSession(kind: .export, gameID: gid, name: item["name"] as? String ?? gid)
        s.export = ExportRun(platforms: (item["platforms"] as? [String] ?? []).compactMap(Self.exportPlatform))
        session = s
        sessionHidden = true
    }

    /// 一个平台出完：重读批次（清单页各款的状态）
    func batchStepEnded() {
        Task { if let s = await provider.client.batch("show"), s["batch"] != nil { batchState = s } }
    }

    /// 当前这一款的会话收尾：有平台被取消 = 已取消；有平台没成 = 失败；否则完成
    private func finishBatchGame() {
        guard let s = session, s.kind == .export, !{ if case .finished = s.phase { return true }; return false }() else { return }
        let outcomes = s.export?.outcomes.values.map(\.state) ?? []
        finish(outcomes.contains(.cancelled) ? .cancelled : (s.export?.failed.isEmpty == false ? .failed : .completed), message: "")
    }

    /// 批次脚本的回复：有 batch 就收下；没有（脚本起不来 / 报错，如另一个进程正改着批次）就记原因、不往下出
    private func accept(_ reply: [String: Any]?) -> Bool {
        if let reply, reply["batch"] != nil { batchState = reply; batchError = nil; return true }
        batchError = reply?["error"] as? String ?? "批次脚本没有回应"
        batchRunning = false
        return false
    }

    /// 继续出剩下的（取消后 / 启动器退出后重开）；重试失败的（给游戏号只重试这一款，磁盘满那款释放空间后也走这里）：
    /// 后端改好批次再起编排作业，只出还没出的
    func resumeBatch() { batchCommand("resume") }
    func retryBatch(_ gid: String? = nil) { batchCommand("retry", gid.map { ["--game", $0] } ?? []) }

    private func batchCommand(_ command: String, _ args: [String] = []) {
        guard !busy, !batchRunning else { return }
        Task {
            guard accept(await provider.client.batch(command, args)) else { batchShown = true; return }   // 「重试 / 继续」没成：批量页说清原因
            runBatchExport()
        }
    }

    /// 这批的结果看完了：清掉批次（不影响已出好的包）
    func closeBatch() {
        guard !batchRunning else { batchShown = false; return }
        batchShown = false; batchDraft = []; batchUnrecognized = []
        Task { _ = await provider.client.batch("clear"); batchState = nil }
    }

    /// 启动器刚打开：上次没出完的批次读回来（正在出的那款记成被打断、重新排队），出包页顶部提示继续
    func recoverBatch(_ done: @escaping () -> Void = {}) {
        Task {
            defer { done() }
            guard let s = await provider.client.batch("recover"), s["batch"] != nil else { return }
            batchState = s
        }
    }
}
