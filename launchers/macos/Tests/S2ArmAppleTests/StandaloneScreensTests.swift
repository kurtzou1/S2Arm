// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 独立 App（0.6.4）几页离屏渲染：出法行（单款，选了独立 App 时的提示）、成功页 A（直装）、成功页 B（导出）、失败页（重试）。
/// 结果字段取一次真实作业的读数（杀戮尖塔：直装到手机、证书签导出、删了游戏文件夹再推）。S2A_STANDALONE_SHOT=<目录> 时存 PNG 看样子（不给也照跑：纯离屏、不开窗口，约 1 秒；门禁把「跳过」算红）；
/// 判据只核画得出、页面上有该有的那几句（按钮 / 标题），排版看存下的图
@MainActor final class StandaloneScreensTests: XCTestCase {
    let gid = "010026300BA4A000"

    func model() -> S2ArmLauncherModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-shots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.path, libraryId: "x")))
    }

    /// 离屏出图：视图不放进任何窗口、不上屏（11-20：截图测试在维护者桌面上开过窗口、弹过报错框）；直接让 NSHostingView 排版后画进位图。
    ///   核图里确实画出了东西（非背景像素够多），免得白图当成功
    func shot<V: View>(_ view: V, _ name: String, width: CGFloat = 600, height: CGFloat = 700) throws -> NSBitmapImageRep {
        let root = view.s2aLocalized().frame(width: width, height: height, alignment: .topLeading).padding(32)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width + 64, height: height + 64)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent + c.greenComponent + c.blueComponent > 0.9 { ink += 1 } } }
        XCTAssertGreaterThan(ink, 200, "\(name)：离屏画出来是空的")
        if let dir = ProcessInfo.processInfo.environment["S2A_STANDALONE_SHOT"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    func finished(_ state: JobOutcome.State) -> JobSession {
        var s = JobSession(kind: .install, gameID: gid, name: "Slay the Spire")
        s.phase = .finished(state); s.started = Date().addingTimeInterval(-30); s.ended = Date()
        return s
    }


    /// 出法卡片三种状态（0.6.2）：推荐的被选中 / 不推荐的被选中（橙字）/ 识别不了签名方式（灰字、不挂推荐标）
    func testLayoutCards() throws {
        let states: [(String, [String: Any])] = [
            ("1a_出法卡片_推荐被选中", ["signMode": "devcert", "layout": "standalone", "distribution": true, "recommend": "standalone", "recommendWhy": "distribution"]),
            ("1b_出法卡片_不推荐被选中", ["signMode": "devcert", "layout": "standalone", "distribution": true, "recommend": "standalone", "recommendWhy": "distribution",
                                     "layoutChoice": ["games": [gid: "shell"]]]),
            ("1c_出法卡片_识别不了", ["signMode": "appleId", "layout": "shell", "recommendWhy": "unknown"]),
        ]
        for (name, r) in states {
            let m = model()
            m.installMode = InstallModeInfo(result: r)
            let rep = try shot(VStack(alignment: .leading) { InstallLayoutRow(model: m, gameId: gid, refreshOnAppear: false) }, name, height: 300)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
        }
        // 1d 没读回（启动器刚开 / installMode 作业失败）：两张都不画选中（0.6.2 前端走查：原先先把缺省「通用 S2Arm」画成选中，读失败就一直错）
        let m = model()
        XCTAssertFalse(m.installMode.loaded)
        _ = try shot(VStack(alignment: .leading) { InstallLayoutRow(model: m, gameId: gid, refreshOnAppear: false) }, "1d_出法卡片_没读回", height: 300)
    }

    func testSuccessInstalled() throws {
        let m = model()
        let app = StandaloneApp(["appName": "Slay the Spire", "ipaPath": "/Users/player/S2Arm 游戏库/games/Slay the Spire/Slay the Spire v1.0.ipa",
                                 "gameFolder": "/Users/player/S2Arm 游戏库/games/Slay the Spire", "signMode": "devCert",
                                 "expiresAt": NSNumber(value: Date().addingTimeInterval(361 * 86400).timeIntervalSince1970), "expiresKnown": true])
        m.phoneOutcome = PhoneOutcome(device: "iPhone「我的 iPhone」", packFiles: 753, packBytes: 396_361_728, app: app)
        let notes = ["第一次打开前：在 iPhone「设置 → 通用 → VPN 与设备管理」里点开发者「iPhone Developer: …」→「信任」。"]
        _ = try shot(PhoneJobPanel(model: m, session: finished(.completed), notes: notes), "2_成功页A_直装")
    }

    func testSuccessExported() throws {
        let m = model()
        let folder = "/Users/player/S2Arm 游戏库/games/Slay the Spire"
        let app = StandaloneApp(["appName": "Slay the Spire", "exported": true, "gameFolder": folder, "ipaPath": folder + "/Slay the Spire v1.0.ipa", "ipaBytes": NSNumber(value: 200_530_283),
                                 "s2armPath": folder + "/Slay the Spire.s2arm", "s2armBytes": NSNumber(value: 31_897_038), "resourcePath": folder + "/Slay the Spire.img",
                                 "resourceLinked": true, "resourceBytes": NSNumber(value: 408_833_955), "readmePath": folder + "/请先读我.txt", "signMode": "external", "signedWith": ["mode": "none", "name": ""],
                                 "nextSteps": ["AltStore / SideStore：用它们打开 Slay the Spire v1.0.ipa 安装（它们用自己的账号签名）。",
                                               "只导出、没连手机推的，还要做一步：装好后先打开一次「Slay the Spire」，再把这个文件夹里的 Slay the Spire.s2arm 和 Slay the Spire.img 放进 iPhone「文件」App →「我的 iPhone」→「Slay the Spire」→「放这里导入」，回到「Slay the Spire」点「我已放好，重新检查」，它会自动导入。"]])
        m.phoneOutcome = PhoneOutcome(app: app)
        _ = try shot(PhoneJobPanel(model: m, session: finished(.completed)), "3_成功页B_导出", height: 860)
    }

    func testFailureWithRetry() throws {
        let m = model()
        var s = finished(.failed)
        s.message = "这款在电脑上的游戏文件夹不在了（被删或挪走），没有装到 iPhone。"
        s.suggestion = "在启动器里重新添加这款游戏、打一次 iPhone 包，再装到 iPhone 或续签；手机上已装的 App 和存档不受影响。"
        s.failureCode = "game_folder_missing"
        m.lastInstallRetry = {}
        _ = try shot(PhoneJobPanel(model: m, session: s), "4_失败页", height: 520)
    }
}
