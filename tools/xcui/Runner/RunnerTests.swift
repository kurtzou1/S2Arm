// 照计划附着别的 App 点按（只点不判：判据看宿主日志 / devicectl 截屏）。每步打一行「[xcui] …」到输出，tools/xcui/run.sh 收进日志
import XCTest

final class RunnerTests: XCTestCase {
    func testRunPlan() throws {
        // 计划优先取环境变量（模拟器 / 以后 xcodebuild 支持时），没有就用构建时写进来的 XCUIEmbeddedPlan（build/xcui/gen/PlanData.swift）
        let env = ProcessInfo.processInfo.environment
        let plan = try XCUIPlan.fromEnvironment(["S2A_XCUI_PLAN": env["S2A_XCUI_PLAN"] ?? XCUIEmbeddedPlan])
        let app = XCUIApplication(bundleIdentifier: plan.bundle)
        app.activate()   // 附着正在跑的那一个（不重启它：局里的状态要留着）
        print("[xcui] 附着 \(plan.bundle)，\(plan.steps.count) 步")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for (i, step) in plan.steps.enumerated() {
            switch step {
            case .tap(let id, let timeout):
                // 标识 / 标签整段相等的找不到时，退一步找标签以它开头的第一个：带副标题的菜单项（UIAction subtitle）标签是「标题, 副标题」，
                //   整段写进计划又长又随文案变（11-11 真机实测「手柄按键：Xbox 布局」就这样找不到）
                var e = app.descendants(matching: .any)[id]
                if !e.waitForExistence(timeout: timeout) {
                    e = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", id)).firstMatch
                    if e.exists { print("[xcui] \(i + 1) 按开头文字认出：\(e.label)") }
                }
                XCTAssertTrue(e.exists, "第 \(i + 1) 步：\(timeout) 秒没等到控件 \(id)")
                e.tap(); print("[xcui] \(i + 1) 点控件 \(id)")
            case .slider(let id, let v, let timeout):
                let e = app.descendants(matching: .any)[id]
                XCTAssertTrue(e.waitForExistence(timeout: timeout), "第 \(i + 1) 步：\(timeout) 秒没等到滑条 \(id)")
                e.adjust(toNormalizedSliderPosition: CGFloat(v)); print("[xcui] \(i + 1) 滑条 \(id) 拖到 \(v)")
            case .tapXY(let x, let y):
                origin.withOffset(CGVector(dx: x, dy: y)).tap(); print("[xcui] \(i + 1) 点坐标 \(x),\(y)")
            case .press(let x, let y, let s):
                origin.withOffset(CGVector(dx: x, dy: y)).press(forDuration: s); print("[xcui] \(i + 1) 按住 \(x),\(y) \(s) 秒")
            case .wait(let s):
                Thread.sleep(forTimeInterval: s); print("[xcui] \(i + 1) 等 \(s) 秒")
            case .typeText(let id, let text, let timeout):
                let e = app.descendants(matching: .any)[id]
                XCTAssertTrue(e.waitForExistence(timeout: timeout), "第 \(i + 1) 步：\(timeout) 秒没等到输入框 \(id)")
                e.tap(); e.typeText(text); print("[xcui] \(i + 1) 在 \(id) 打字 \(text.count) 个")
            }
        }
        print("[xcui] 完")
    }
}
