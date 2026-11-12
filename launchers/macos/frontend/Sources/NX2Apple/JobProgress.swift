// S2Arm（不是上游文件）：作业页的进度（准备运行 / 打 iPhone 包 / 装机 / 导入……）。数据全来自作业事件（pack/jobs/core.py emit）：
// stageIndex / stageCount（第几步）、done / total / unit（本阶段计数：B = 字节，项 = 逐项计数）、elapsed（作业时钟，适配层 EngineEvent.t）。
// 剩余时间按本计数器的实测速率算（从它第一次读数到最新一次的平均速度），不编常数；没有总量的阶段只显示第几步。
// 显示沿用 NXCore BuildProgress（上游原样文件）：Stage.clock 给「本阶段已用 · 还剩」并在两次事件之间倒数，progressDetail 给计数。
import Foundation
import NXCore
import S2ArmAppleAdapter

struct JobProgress: Equatable {
    private(set) var stage = ""
    private(set) var index: Int?
    private(set) var count: Int?
    private(set) var done: Double?
    private(set) var total: Double?
    private(set) var unit = ""
    /// 本阶段可能弹钥匙串授权（作业事件 keychainPrompt，pack/jobs/core.py begin(keychain=)）：只在这时挂「请在钥匙串弹框里允许」的提示
    private(set) var keychainPrompt = false
    /// 整单进度（作业层每条事件的 overall，0–1，只增不减、成功才到 1；pack/jobs/overall.py）。作业页大百分比与分段条只显示它，不再按当前计数器自己拼
    ///   （11-11 维护者：「百分比反复到 91% 又跳回 40%」）。没有的作业（导入等）为 nil，照旧
    private(set) var overall: Double?
    /// 本阶段在这里开始的时刻（阶段时钟从它走）。
    private(set) var stageStarted: Date?
    /// 按实测速率算的剩余秒数，截至 etaAt。
    private(set) var eta: Double?
    private(set) var etaAt: Date?
    /// 本计数器实测速率（每秒完成量，单位同 unit：B/s 或项/s）。给「12.3 MB/s」用。
    private(set) var rate: Double?
    /// 本计数器第一次读数：作业时钟与已完成量（速率的起点）。
    private var origin: (t: Double, done: Double)?
    /// 出包 / 准备的里程碑（plan 事件 + 每条事件的当前 milestone）：步骤清单、每步实际用时、按本机历史的预计还需（适配层 MilestoneEstimate）。
    private(set) var track = MilestoneTrack()

    static func == (a: JobProgress, b: JobProgress) -> Bool {
        a.stage == b.stage && a.overall == b.overall && a.keychainPrompt == b.keychainPrompt && a.index == b.index && a.count == b.count && a.done == b.done && a.total == b.total && a.unit == b.unit
            && a.stageStarted == b.stageStarted && a.eta == b.eta && a.etaAt == b.etaAt && a.rate == b.rate
            && a.origin?.t == b.origin?.t && a.origin?.done == b.origin?.done && a.track == b.track
    }

    /// 速率至少要量这么久（作业时钟秒）才报剩余时间：头一两次读数的速度不稳。
    static let minimumSpan = 2.0

    mutating func ingest(_ e: EngineEvent, now: Date = Date()) {
        track.ingest(e, now: now.timeIntervalSince1970)
        if e.ev == "plan" { return }   // 计划不是阶段：不清本阶段计数
        let number = { (key: String) in (e.fields[key] as? NSNumber)?.doubleValue }
        let name = e.stage ?? stage
        let newIndex = number("stageIndex").map { Int($0) }
        if e.ev == "stage" || name != stage || (newIndex != nil && newIndex != index) {
            stage = name; stageStarted = now
            done = nil; total = nil; unit = ""; origin = nil; eta = nil; etaAt = nil; rate = nil; keychainPrompt = false
        }
        if let newIndex { index = newIndex }
        if let k = e.fields["keychainPrompt"] as? Bool { keychainPrompt = k }
        if let c = number("stageCount") { count = Int(c) }
        if let o = number("overall") { overall = max(overall ?? 0, min(1, o)) }
        guard let d = number("done"), let t = number("total"), t > 0 else { return }
        // 换了一个计数器（总量变了 / 从头数起）：速率从这一次读数重算
        if t != total || d < (done ?? 0) || origin == nil { origin = (e.t, d); eta = nil; etaAt = nil; rate = nil }
        done = min(d, t); total = t; unit = e.fields["unit"] as? String ?? ""
        if let origin, e.t - origin.t >= Self.minimumSpan, d > origin.done {
            let speed = (d - origin.done) / (e.t - origin.t)
            rate = speed
            eta = max(0, t - d) / speed; etaAt = now
        }
    }

    /// 作业结束：最后一步的用时到此为止。
    mutating func finish(at now: Date = Date()) { track.finish(at: now.timeIntervalSince1970) }

    /// 本阶段计数占比（没有总量为 nil）。
    var fraction: Double? { guard let done, let total, total > 0 else { return nil }; return min(1, done / total) }

    /// 「1.2 GB / 3.4 GB」「1,203 / 19,592」：字节按文件大小写，逐项计数只写数（单位「项」是作业层的中文，不上屏）。
    var countText: String {
        guard let done else { return "" }
        var e: [String: Any] = ["done": done]
        if let total { e["total"] = total }
        if unit == "B" { e["unit"] = "B" }
        return BuildProgress.progressDetail(e)
    }

    /// 「12.3 MB/s」：本计数器的实测速度（字节按文件大小写，其余写数字 + 单位）。量不够两秒时为空，不编数。
    var rateText: String {
        guard let rate, rate > 0 else { return "" }
        if unit == "B" { return ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s" }
        return String(format: "%.1f", rate) + (unit.isEmpty ? "/s" : " \(unit)/s")
    }

    /// 本步还需（实测速率，在两次事件之间倒数）：剩余时间只有这一套（剃刀 M20），作业页「还剩」与出包页「本步还需 / 预计还需」都从这里取
    func stepLeft(at now: Date) -> Double? {
        guard let eta, let etaAt else { return nil }
        return max(0, eta - now.timeIntervalSince(etaAt))
    }

    /// 出包页的时间推算：本步用上面的实测值，整单 = 本步 + 后面各步本机历史（没有实测时本步也按历史兜底）
    func estimate(at now: Date) -> MilestoneEstimate {
        track.estimate(fraction: fraction, measuredStep: stepLeft(at: now), now: now.timeIntervalSince1970)
    }

    /// 「已用 · 还剩」，left 是界面语言的「还剩 %@」。
    func clock(at now: Date, left: String) -> String {
        Stage(id: index ?? 0, name: stage, started: stageStarted, eta: eta, etaAt: etaAt).clock(at: now, left: left)
    }
}
