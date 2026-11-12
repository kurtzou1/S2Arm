import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 作业页的「12.3 MB/s」：速度来自本计数器的实测增量（11-08 iOS 平台组件改成按字节报进度）。
/// 期望值手算：1.00 GB → 1.03 GB，用了 3 秒 → 10 MB/s。
final class JobProgressTests: XCTestCase {
    private func progress(_ t: Double, done: Double, total: Double = 8_320_000_000) -> EngineEvent {
        EngineEvent(ev: "progress", t: t, code: nil, severity: .info,
                    fields: ["stage": "下载 Xcode 的 iOS 平台组件（约 8 GB）", "done": done, "total": total, "unit": "B"])
    }

    /// M9：钥匙串提示按后端的 keychainPrompt 挂，不按步骤号；字段走真实 JSON 解析（布尔解成 NSNumber），换阶段就清
    func test_keychain_prompt_follows_the_backend_flag_per_stage() throws {
        func stage(_ t: Double, _ json: String) throws -> EngineEvent {
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return EngineEvent(ev: "stage", t: t, code: nil, severity: .info, fields: fields)
        }
        var p = JobProgress()
        p.ingest(try stage(0, #"{"stage":"用你的 Apple ID 签名","stageIndex":4,"stageCount":6,"keychainPrompt":true,"stageKey":null}"#))
        XCTAssertTrue(p.keychainPrompt)
        p.ingest(try stage(1, #"{"stage":"装到 iPhone","stageIndex":5,"stageCount":6,"keychainPrompt":false,"stageKey":null}"#))
        XCTAssertFalse(p.keychainPrompt)
        p.ingest(try stage(2, #"{"stage":"用你的开发者证书签名","stageIndex":4,"stageCount":6}"#))   // 没带字段的阶段：不沿用上一阶段
        XCTAssertFalse(p.keychainPrompt)
    }

    func test_rate_appears_after_two_seconds_and_is_bytes_per_second() {
        var p = JobProgress()
        p.ingest(progress(0, done: 1_000_000_000))
        XCTAssertEqual(p.rateText, "")                       // 量不够两秒：不编数
        p.ingest(progress(3, done: 1_030_000_000))
        XCTAssertEqual(p.rate ?? 0, 10_000_000, accuracy: 1)
        XCTAssertTrue(p.rateText.hasSuffix("/s"))
        XCTAssertTrue(p.rateText.hasPrefix("10"))
        XCTAssertEqual(p.fraction ?? 0, 1_030_000_000 / 8_320_000_000, accuracy: 1e-9)
    }

    func test_rate_resets_when_the_counter_restarts() {
        var p = JobProgress()
        p.ingest(progress(0, done: 1_000_000_000))
        p.ingest(progress(3, done: 1_030_000_000))
        p.ingest(progress(4, done: 10_000_000))               // 换了个从头数起的计数器
        XCTAssertNil(p.rate)
        XCTAssertEqual(p.rateText, "")
    }

    // 剃刀 M20：剩余时间只有一套。期望手算：总量 100、t=0 完成 10、t=4 完成 30 → 速率 5/秒，剩 70 → 14 秒（etaAt = 第二次读数时刻）；
    //   再过 4 秒倒数到 10。出包页的本步还需（estimate.stepRemainingByRate）是同一个数
    func test_export_step_left_is_the_same_measured_value() {
        var p = JobProgress()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let ev = { (t: Double, d: Double) in EngineEvent(ev: "progress", t: t, code: nil, severity: .info,
                                                       fields: ["stage": "s", "milestone": "m1", "done": d, "total": 100.0, "unit": "项"]) }
        p.ingest(EngineEvent(ev: "plan", t: 0, code: nil, severity: .info,
                             fields: ["milestones": [["id": "m1", "label": "M1", "purpose": ""]]]), now: t0)
        p.ingest(ev(0, 10), now: t0)
        p.ingest(ev(4, 30), now: t0.addingTimeInterval(4))
        let at = t0.addingTimeInterval(8)
        XCTAssertEqual(p.stepLeft(at: at) ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(p.estimate(at: at).stepRemainingByRate ?? -1, 10, accuracy: 1e-9)
    }

    /// 整单进度只认作业层的 overall、只增不减（11-11「91% 又跳回 40%」）：中间夹一个更小的值，读数不回退；成功结果到 1。期望手算 = 到目前为止的最大值
    func test_overall_reading_never_goes_back() {
        var p = JobProgress()
        XCTAssertNil(p.overall)
        let sent = [0.12, 0.40, 0.35, 0.91, 1.0], expected = [0.12, 0.40, 0.40, 0.91, 1.0]
        for (i, v) in sent.enumerated() {
            p.ingest(EngineEvent(ev: "progress", t: Double(i), code: nil, severity: .info,
                                 fields: ["stage": "编译着色器库", "stageIndex": 3, "stageCount": 4, "done": 1, "total": 5, "overall": v]))
            XCTAssertEqual(p.overall, expected[i], "发 \(v) 之后读数")
        }
    }
}
