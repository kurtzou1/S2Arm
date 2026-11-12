import XCTest
import SwiftUI
import AppKit
@testable import S2ArmLauncher

@MainActor final class BudgetTests: XCTestCase {
    // Same fields/units as #138; bytes and unknown overhead never become a total estimate.
    let budget: [String:Any] = [
        "gameBytes":6_000_000_000,
        "volumes":[
            ["role":"library", "volume":"系统盘", "needBytes":22_000_000_000,
             "freeBytes":80_000_000_000, "enough":true, "basis":"rule",
             "note":"游戏大小 × 2 + 10 GB 经验门槛（10-23 Spare-host 实测，偏保守）", "unknown":["shader_cache"]],
            ["role":"staging", "volume":"Fixture", "needBytes":6_000_000_000,
             "freeBytes":1_000_000_000, "enough":false, "basis":"exact",
             "note":"游戏库在另一块磁盘上，跨卷临时复制，按源文件实际字节", "unknown":[]]
        ],
        "unknown":[["id":"shader_cache", "role":"library", "label":"着色器缓存",
                    "note":"着色器缓存另占若干 GB，随游戏与设备而变，未量化，不计入门槛。"]]
    ]

    // 「仍然继续」只给空间预检拦下的出包：中途真写满（预检是过的）、已经继续过、别的失败码、非出包任务都不给
    func testContinueDespiteSpaceOnlyForPreflightRefusal() throws {
        func record(_ op:String, enough:Bool, override:Bool?, code:String="disk_full") throws -> TaskRecord {
            var space:[String:Any] = ["volumes":[["role":"library","volume":"NX","needBytes":48_718_726_651,"freeBytes":45_000_000_000,"enough":enough,"basis":"rule"]]]
            if let override { space["override"] = override }
            let obj:[String:Any] = ["id":"t","operation":op,"state":"failed","space":space,
                                    "diagnostics":[["code":code,"severity":"error","summary":"s","suggestion":"x","detail":""]]]
            return try JSONDecoder().decode(TaskRecord.self,from:JSONSerialization.data(withJSONObject:obj))
        }
        XCTAssertTrue(try record("build",enough:false,override:nil).spacePreflightBlocked)
        XCTAssertTrue(try record("ipa",enough:false,override:false).spacePreflightBlocked)
        XCTAssertFalse(try record("ipa",enough:true,override:nil).spacePreflightBlocked)
        XCTAssertFalse(try record("ipa",enough:false,override:true).spacePreflightBlocked)
        XCTAssertFalse(try record("ipa",enough:false,override:nil,code:"tool_exit").spacePreflightBlocked)
        XCTAssertFalse(try record("install",enough:false,override:nil).spacePreflightBlocked)
        XCTAssertEqual(SpaceVolume(role:"library",volume:"NX",basis:"measured").basisName,L("按实测"))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        let game=try JSONDecoder().decode(Game.self,from:JSONSerialization.data(withJSONObject:["id":"g","name":"G","display":"1.0","hidden":false,"packages":[]]))
        XCTAssertEqual(store.ipaRequest(game,target:nil,spaceOverride:true)["spaceOverride"] as? Bool,true)
        XCTAssertNil(store.ipaRequest(game,target:nil)["spaceOverride"])
    }

    func testSpaceAndEstimateSurviveLaterEventsTerminalFailureAndDiskRoundTrip() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.tasks=[.init(id:"fixture", operation:"ipa", state:"running")]
        func event(_ fields:[String:Any]) {
            store.event(["schema":1,"taskId":"fixture"].merging(fields,uniquingKeysWith:{$1}),visible:true)
        }
        event(["type":"space","space":budget])
        event(["type":"plan", "milestones":[
            ["id":"compile","label":"编译","purpose":"准备游戏","expected":120,
             "source":"history","samples":3,"basis":"本机最近准备记录的中位数"],
            ["id":"ipa","label":"签名","purpose":"打包","expected":20,
             "source":"default","samples":0,"basis":"缺省值来自 10-23 奥德赛实测（5.4 GB），不随体积变"]]])
        event(["type":"stage","message":"下一阶段","milestone":"compile"])
        event(["type":"result","state":"failed","message":"空间不足"])
        let task=try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(task.space?.volumes.map(\.status),[.sufficient,.insufficient])
        XCTAssertEqual(task.milestones?.map(\.source),["history","default"])
        XCTAssertEqual(task.milestones?.first?.samples,3)
        store.persistTask(task)
        let restored=try JSONDecoder().decode(TaskRecord.self,from:Data(contentsOf:root.appendingPathComponent("logs/jobs/fixture.json")))
        XCTAssertEqual(restored.space,task.space)
        XCTAssertEqual(restored.milestones,task.milestones)
        XCTAssertEqual(restored.state,"failed")
        XCTAssertEqual(restored.space?.unknown?.first?.id,"shader_cache")
    }

    func testOldUnknownAndInvalidDataNeverClaimBudgetPassedOrHistoricalEvidence() throws {
        let old=try JSONDecoder().decode(TaskRecord.self,from:Data(#"{"id":"old","operation":"build","state":"failed","milestones":[{"id":"a","label":"A","purpose":"","expected":100}]}"#.utf8))
        XCTAssertNil(old.space)
        XCTAssertEqual(old.milestones?.first?.estimateSource,L("估时来源未知"))
        var volume=SpaceVolume(role:"library",volume:"Fixture",needBytes:10,freeBytes:20)
        XCTAssertEqual(volume.status,.unknown)
        volume.enough=true;XCTAssertEqual(volume.status,.sufficient)
        volume.freeBytes=9;XCTAssertEqual(volume.status,.insufficient) // Inconsistent true cannot hide a shortage.
        volume.freeBytes = -1;XCTAssertEqual(volume.status,.unknown)
        volume.enough=false;XCTAssertEqual(volume.status,.insufficient)
        XCTAssertEqual(budgetBytes(-1),L("未测"))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.tasks=[.init(id:"fixture",operation:"build",state:"running",space:Store.decode(SpaceBudget.self,budget))]
        store.event(["schema":1,"taskId":"fixture","type":"space","space":["volumes":"invalid"]],visible:true)
        XCTAssertEqual(store.tasks.first?.space?.volumes,[])
        var milestone=Milestone(id:"a",label:"A",purpose:"",expected:1,source:"history",samples:0)
        XCTAssertEqual(milestone.estimateSource,L("估时来源未知"))
        milestone.source="future";milestone.samples=3
        XCTAssertEqual(milestone.estimateSource,L("估时来源未知"))
    }

    func testRealWorkerDiskRefusalAndCatalogueReloadKeepBudget() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=root.appendingPathComponent("library"), privateRoot=root.appendingPathComponent("private")
        let store=Store(privateRoot:privateRoot)
        let setup=expectation(description:"real library setup")
        store.worker("setup",extra:["library":library.path,"libraryId":""]) { result in
            store.preferences.library=result["library"] as? String ?? ""
            store.preferences.libraryId=result["libraryId"] as? String ?? ""
            setup.fulfill()
        }
        await fulfillment(of:[setup],timeout:15)
        let gid="0100000000000000", size=Int64(1)<<50
        let source=library.appendingPathComponent("sources/fixture.bin")
        try FileManager.default.createDirectory(at:source.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("synthetic input; never unpacked".utf8).write(to:source)
        // 加密原件出包开头要 prod.keys（作业层 library.require_game，v0.3.1）：玩家已导入
        let keys=privateRoot.appendingPathComponent("keys/prod.keys")
        try FileManager.default.createDirectory(at:keys.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("header_key = 00\n".utf8).write(to:keys)
        let game:[String:Any] = ["id":gid,"name":"Synthetic budget fixture","display":"1.0","hidden":false,
            "packages":[["titleId":gid,"baseId":gid,"version":0,"type":"base","name":"Fixture","display":"1.0",
                         "path":"sources/fixture.bin","size":size,"sha256":String(repeating:"a",count:64),"builds":[:],"guestIsa":"aarch64"]]]
        try JSONSerialization.data(withJSONObject:["schema":1,"games":[game]]).write(to:library.appendingPathComponent("catalog.json"))
        let id=store.worker("build",extra:["gameId":gid]) { _ in XCTFail("Disk refusal must not succeed") }
        for _ in 0..<400 {
            if store.tasks.first(where:{$0.id==id})?.state == "failed" { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        let task=try XCTUnwrap(store.tasks.first(where:{$0.id==id}))
        XCTAssertEqual(task.state,"failed")
        XCTAssertEqual(task.space?.gameBytes,size)
        XCTAssertEqual(task.space?.volumes.first?.status,.insufficient)
        XCTAssertEqual(task.diagnostics?.last?.code,"disk_full")
        XCTAssertTrue(task.spacePreflightBlocked)   // 真 worker 的空间预检拦下：失败页给「仍然继续」
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent("cache/\(gid)").path))
        // Reopen and read the actual worker catalogue, rather than reusing the live Store.
        store.savePreferences()
        let reopened=Store(privateRoot:privateRoot)
        let loaded=expectation(description:"actual catalogue after reopening")
        reopened.refresh { loaded.fulfill() }
        await fulfillment(of:[loaded],timeout:15)
        XCTAssertEqual(reopened.tasks.first(where:{$0.id==id})?.space,task.space)
        store.terminate();reopened.terminate()
    }

    func testBudgetRendersAcrossLanguageAndHighContrastAppearances() throws {
        let previous=Localization.preference
        defer {Localization.preference=previous}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        let task=TaskRecord(id:"render",operation:"ipa",state:"failed",space:Store.decode(SpaceBudget.self,budget),
                            milestones:[.init(id:"a",label:"编译",purpose:"",expected:120,source:"history",samples:3)])
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference=language
            for dark in [false,true] {
                let view=NSHostingView(rootView:TaskCard(task:task).environmentObject(store)
                    .environment(\.colorScheme,dark ? .dark : .light))
                view.appearance=NSAppearance(named:dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                view.frame=NSRect(x:0,y:0,width:560,height:880);view.layoutSubtreeIfNeeded()
                let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:bitmap)
                let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                if let directory=ProcessInfo.processInfo.environment["S2ARM_BUDGET_PREVIEWS"] {
                    let path=URL(fileURLWithPath:directory)
                    try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
                    try data.write(to:path.appendingPathComponent("\(language.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        Localization.preference = .english
        XCTAssertEqual(L("本机历史 · 3 次记录"),"Local history · 3 records")
        XCTAssertEqual(L("空间状态未知"),"Space status unknown")
        XCTAssertEqual(L("未量化，不计入门槛"),"Unquantified; excluded from the threshold")
    }
}
