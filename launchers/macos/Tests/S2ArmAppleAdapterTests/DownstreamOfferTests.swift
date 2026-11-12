import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 下游深度方案（pack/jobs/downstream.py describe → catalog 的 downstream 字段）：解码、按界面语言挑文案、选择状态。期望值手写。
final class DownstreamOfferTests: XCTestCase {
    private func catalog(choice: Any? = nil, eligible: Bool = true) -> [String: Any] {
        var d: [String: Any] = ["id": "demo", "name": "Demo", "eligible": eligible,
                                "reason": ["zh": "只支持 1.2.3", "en": "1.2.3 only"],
                                "copy": ["zh": ["title": "标题", "body": "正文", "points": ["一", "二"], "recommend": "用 Demo", "original": "仍用原版"],
                                         "en": ["title": "Title", "body": "Body", "points": ["one"], "recommend": "Use Demo", "original": "Keep standard"]]]
        if let choice { d["choice"] = choice }
        return ["id": "0100000000010000", "name": "Game", "downstream": d]
    }

    func testDecodedFromCatalog() {
        let g = GameSummary(catalog: catalog())
        XCTAssertEqual(g?.downstream?.id, "demo")
        XCTAssertEqual(g?.downstream?.text("zh")?.points, ["一", "二"])
        XCTAssertEqual(g?.downstream?.text("en")?.recommend, "Use Demo")
        XCTAssertNil(g?.downstream?.choice)   // 没选过：导出 iPhone 前弹确认页
        XCTAssertNil(GameSummary(catalog: ["id": "0100000000020000", "name": "Other"])?.downstream)
    }

    func testLanguageFallsBackToChinese() {
        let o = GameSummary(catalog: catalog())?.downstream
        XCTAssertEqual(o?.text("zh-Hans")?.title, "标题")
        XCTAssertEqual(o?.text("es")?.title, "标题")
        XCTAssertEqual(o?.why("en"), "1.2.3 only")
    }

    func testChosenNeedsEligibleAndASchemeId() {
        XCTAssertEqual(GameSummary(catalog: catalog(choice: "demo"))?.downstream?.chosen, true)
        XCTAssertEqual(GameSummary(catalog: catalog(choice: ""))?.downstream?.chosen, false)        // 选了原版
        XCTAssertEqual(GameSummary(catalog: catalog(choice: "demo", eligible: false))?.downstream?.chosen, false)
    }
}
