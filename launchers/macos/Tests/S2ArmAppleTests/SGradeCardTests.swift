// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI

/// 出包页「S 级优化（Beta）」卡片：命中 / 只命中别的版本 / 加载中三态离屏渲染成 PNG（S2A_SGRADE_SHOT=<目录> 时存图看样子）。
/// 判据只核「画得出、命中态比别的态更亮（金色像素更多）」；文字与布局看存下的图
@MainActor final class SGradeCardTests: XCTestCase {
    static let texts = ["title": "S 级优化", "loading": "正在匹配社区补丁…", "hit.widescreen": "{0} 个满屏补丁，已打入并默认开启", "hit.fps": "{0} 个帧率补丁，已打入并默认开启",
                        "hit.cheat": "{0} 条金手指，已打入、默认关闭，进游戏后按需打开", "hit.note": "开着补丁如遇到不兼容导致游戏崩溃，下次启动会自动将崩溃补丁关掉以确保您正常游戏。",
                        "none": "你这份游戏是 {0} 版，补丁库里没有这个版本的补丁，这次不会打入。", "others": "补丁库里有补丁的其他版本（帧率、画面、金手指要版本一致，和你这份不同的不会打入）：",
                        "listed": "补丁库里有补丁的版本：", "later": "帧率补丁和金手指按游戏版本生效：出包时核对你这份游戏的版本，对得上的才打入。满屏补丁版本不同也会尝试移植。",
                        "port": "满屏：补丁库里是 {0} 版的，出包时尝试移植到你这份游戏，移植成功就打入并默认开启", "port.any": "其他",
                        "hit.version": "以上补丁对应你这份游戏的版本 {0}，打入前逐处核对原字节，对不上的那条不打入。", "cat.fps": "帧率", "cat.widescreen": "满屏", "cat.cheat": "金手指",
                        "toggle": "出包时打入", "off": "这次出包不带社区补丁和金手指，游戏按原生画面与帧率运行。重新勾上，下次出包再打入。"]
    func render(_ m: PatchMatch?, _ name: String, on: Binding<Bool>? = nil) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Branding/s-gold.png").standardized
        let img = try XCTUnwrap(NSImage(contentsOf: src))
        let view = SGradeCardView(match: m, failed: false, zh: true, on: on, x: { Self.texts[$0] ?? $0 }, sImage: img)
            .frame(width: 760).padding(28).background(Color(red: 0.055, green: 0.055, blue: 0.06)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation)))
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sgrade_\(name).png")) }
        return rep
    }
    // 金色像素：红高、绿居中、蓝低（与卡片金色同一色相）
    func goldPixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.75, c.greenComponent > 0.5, c.greenComponent < c.redComponent - 0.08, c.blueComponent < 0.5 { n += 1 } } }
        return n
    }
    func testThreeStatesRenderAndHitIsBrightest() throws {
        var hit = PatchMatch(); hit.build = "d95ec48ffe269b6e"; hit.version = "2.7.6"; hit.exact = ["widescreen": 1, "fps": 1, "cheat": 12]
        var others = PatchMatch(); others.build = "aa11bb22cc33dd44"; others.version = "2.7.4"; others.others = [("1.1.0", ["fps", "widescreen"]), ("1.0.0", ["cheat"])]
        var later = PatchMatch(); later.others = others.others   // 没解过包：不知道玩家是哪一版，只列补丁库里有补丁的版本
        _ = try render(later, "later")
        // 满屏跨版本：这份没有同版本的满屏，2.7.4 版的出包时尝试移植（单列一行、卡片点亮）；帧率在别的版本 → 列进「不会打入」
        var port = PatchMatch(); port.build = "aa11bb22cc33dd44"; port.version = "2.7.6"; port.port = true; port.portVersions = ["2.7.4"]; port.others = [("2.7.4", ["fps"])]
        var portLater = PatchMatch(); portLater.port = true; portLater.portVersions = ["2.7.4"]; portLater.others = [("2.7.4", ["fps", "cheat"])]
        XCTAssertGreaterThan(goldPixels(try render(port, "port")), goldPixels(try render(portLater.others.isEmpty ? nil : others, "others_cmp")), "可移植满屏的卡片应点亮（比没命中的亮）")
        _ = try render(portLater, "port_later")
        let h = goldPixels(try render(hit, "hit")), o = goldPixels(try render(others, "others")), l = goldPixels(try render(nil, "loading"))
        XCTAssertGreaterThan(h, 0); XCTAssertGreaterThan(h, o, "命中态应比只命中别的版本更亮（金色像素 \(h) 对 \(o)）"); XCTAssertGreaterThan(o, 0); XCTAssertGreaterThan(l, 0)
    }

    // 出包时打入（v0.4.0：默认勾上、玩家可取消）：勾着同命中态一样亮；取消后卡片不亮（金色像素明显少），内容换成「这次不带」一句
    func testUncheckedCardDims() throws {
        var hit = PatchMatch(); hit.build = "d95ec48ffe269b6e"; hit.exact = ["widescreen": 1, "fps": 1, "cheat": 12]
        let on = goldPixels(try render(hit, "hit_checked", on: .constant(true))), off = goldPixels(try render(hit, "hit_unchecked", on: .constant(false)))
        XCTAssertGreaterThan(on, off, "取消勾选应不亮（金色像素 \(on) 对 \(off)）"); XCTAssertGreaterThan(off, 0)
    }

    // 游戏库封面左上角金色 S（v0.4.0）：叠在一张亮色、一张暗色的「封面」上都画得出（金色像素 > 0），存图看样子
    func testCardBadgeOnLightAndDarkCovers() throws {
        _ = NSApplication.shared
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Branding/s-gold.png").standardized
        let img = try XCTUnwrap(NSImage(contentsOf: src))
        // 真封面看效果：S2A_SGRADE_COVERS=<目录>（放几张游戏横幅 PNG）时逐张叠上存图；单测本身用一亮一暗两种底色
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_COVERS"], let out = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".png") {
                guard let cover = NSImage(contentsOfFile: dir + "/" + f) else { continue }
                let v = Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill).frame(width: 300, height: 167).clipped()
                    .overlay(alignment: .topLeading) { SGradeBadge(size: 33, sImage: img) }
                let r = ImageRenderer(content: v); r.scale = 2
                try r.nsImage.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: out).appendingPathComponent("sgrade_cover_" + f))
            }
        }
        for (name, bg) in [("light", Color(red: 0.85, green: 0.9, blue: 1.0)), ("dark", Color(red: 0.08, green: 0.1, blue: 0.14))] {
            let view = Rectangle().fill(bg).frame(width: 300, height: 167).overlay(alignment: .topLeading) { SGradeBadge(size: 33, sImage: img) }
            let r = ImageRenderer(content: view); r.scale = 2
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation)))
            if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sgrade_badge_\(name).png")) }
            // 看得见 = 角上有足够多的像素和封面底色明显不同（只有 S、没有框和底色，v0.4.0 维护者）
            let bgc = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB)); var diff = 0
            for y in 0..<min(rep.pixelsHigh, 200) { for x in 0..<min(rep.pixelsWide, 200) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bgc.redComponent) + abs(c.greenComponent - bgc.greenComponent) + abs(c.blueComponent - bgc.blueComponent) > 0.35 { diff += 1 } } }
            XCTAssertGreaterThan(diff, 400, "\(name) 封面上 S 看得见（明显不同的像素 \(diff)）")
        }
    }

    // 启动设置里的「S 级优化」组：金色头 + 金色描边卡 + 真的小节与开关行（SGradeSettingsRows，同启动设置一份代码）。
    //   金手指 40 条：收起态只多一行汇总（框不随条数变长）；展开态列表限高 300 点、带搜索
    func renderGroup(open: Bool) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let cheats = (1...40).map { SGradeToggle(id: "a.txt/\($0)", label: "金手指第 \($0) 条", detail: $0 % 7 == 0 ? "来自社区库 · 地址写死，可能不生效" : "来自社区库", on: $0 <= 2) }
        let rows = SGradeSettingsRows(
            patchesTitle: "社区补丁", patchesNote: "出包时按这个版本匹配打入的社区补丁（满屏、帧率、画面）；同组只能开一个，下次启动生效。",
            patches: [SGradeToggle(id: "wsauto:1", label: "自适应满屏（13 种画幅合成）", detail: "已生效：上一局画面铺满", on: true),
                      SGradeToggle(id: "fps:1", label: "60 帧（FPSLocker）", detail: "已生效：上一局实测 60 帧", on: true)],
            cheatsTitle: "金手指", cheatsNote: "逐条开关，改完马上生效。", cheats: cheats, importTitle: "导入…", startOpen: open)
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Branding/s-gold.png").standardized
        let view = SGradeGroupCard("S 级优化", note: SGradeCardTests.texts["hit.note"] ?? "", sImage: try XCTUnwrap(NSImage(contentsOf: src))) { rows }
            .frame(width: 540).padding(30).background(Color(red: 0.055, green: 0.055, blue: 0.06)).environment(\.colorScheme, .dark)
        // 放进真的 AppKit 视图再截（ImageRenderer 画不了输入框 / 滚动区这类原生控件）
        let host = NSHostingView(rootView: view); host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); window.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sgrade_launch_group_\(open ? "open" : "closed").png")) }
        return rep
    }
    func testLaunchSettingsGroupStaysShortWithManyCheats() throws {
        let closed = try renderGroup(open: false), opened = try renderGroup(open: true)
        XCTAssertGreaterThan(goldPixels(closed), 0)
        // 期望（手算，2 倍图）：收起态 = 头 + 补丁两行 + 金手指小节 + 一行汇总，不到 1400 像素高；展开态多出搜索框 + 限高 300 点的列表（≤ 600 + 搜索约 80 像素）
        XCTAssertLessThan(closed.pixelsHigh, 1400, "收起态高 \(closed.pixelsHigh)")
        XCTAssertLessThan(opened.pixelsHigh - closed.pixelsHigh, 720, "展开只多出限高的列表：多了 \(opened.pixelsHigh - closed.pixelsHigh)")
    }
}
