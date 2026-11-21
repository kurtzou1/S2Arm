// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI

// 装到哪台由玩家选（11-11 玩家实报：续签时选的 iPhone 拔了线，同网的 iPad 被装上，完成页还写「已推到 iPhone」）：
// 前端只认选过的那台（按 devicectl 标识或 UDID），它不在线时不替玩家换成别的；没选过时用界面上显示的那台（有线优先）
final class DeviceTargetTests: XCTestCase {
    private let phone: [String: Any] = ["id": "D1", "udid": "PHONE-UDID", "name": "我的手机", "productType": "iPhone17,1", "wired": false]
    private let pad: [String: Any] = ["id": "D2", "udid": "PAD-UDID", "name": "小平板", "productType": "iPad16,3", "wired": false]
    private let wiredPad: [String: Any] = ["id": "D3", "udid": "WPAD", "name": "线连的", "productType": "iPad16,3", "wired": true]

    func testChosenDeviceOfflineDoesNotFallBackToAnother() {
        XCTAssertNil(S2ArmLauncherModel.pickDevice([pad], chosen: "PHONE-UDID"), "选的 iPhone 不在：不拿同网的 iPad 顶替")
        XCTAssertNil(S2ArmLauncherModel.pickDevice([wiredPad, pad], chosen: "D1"))
    }

    func testChosenDeviceMatchedByIdentifierOrUDID() {
        XCTAssertEqual(S2ArmLauncherModel.pickDevice([phone, pad], chosen: "PAD-UDID")?["id"] as? String, "D2", "续签记录里存的是 UDID")
        XCTAssertEqual(S2ArmLauncherModel.pickDevice([phone, pad], chosen: "D1")?["id"] as? String, "D1", "选择器里存的是 devicectl 标识")
    }

    func testNothingChosenShowsTheWiredOne() {
        XCTAssertEqual(S2ArmLauncherModel.pickDevice([pad, wiredPad], chosen: nil)?["id"] as? String, "D3")
        XCTAssertNil(S2ArmLauncherModel.pickDevice([], chosen: nil))
    }

    func testDeviceLabelUsesRealKindAndName() {
        XCTAssertEqual(S2ArmLauncherModel.deviceLabel(kind: "iPad", name: "小平板", language: "zh-Hans"), "iPad「小平板」")
        // 英文译文核对：英文界面不出中文直角引号，空一格用弯引号（同英文文案里设备名的写法）；日文同中文
        XCTAssertEqual(S2ArmLauncherModel.deviceLabel(kind: "iPhone", name: "My iPhone", language: "en"), "iPhone “My iPhone”")
        XCTAssertEqual(S2ArmLauncherModel.deviceLabel(kind: "iPad", name: "居間", language: "ja"), "iPad「居間」")
        XCTAssertEqual(ExportSheetView.deviceLabel(kind: nil, name: "Spare", language: "en"), "Device “Spare”", "导出页设备行同一取法；类型读不到写「设备」")
        XCTAssertEqual(S2ArmLauncherModel.deviceLabel(kind: "", name: ""), "iPhone / iPad")
    }

    @MainActor func testInstallTargetsTheChosenDeviceEvenWhenOffline() {
        let model = S2ArmLauncherModel(client: .init(environment: .init(privateRoot: FileManager.default.temporaryDirectory, resources: FileManager.default.temporaryDirectory, library: "", libraryId: "")))
        let saved = model.chosenDevice
        defer { model.chosenDevice = saved }
        model.chosenDevice = "PHONE-UDID"
        XCTAssertEqual(model.installDeviceID, "PHONE-UDID", "不在线也照样带上：作业层如实说「iPhone「我的手机」不在线」，不换别的")
        XCTAssertTrue(model.chosenDeviceOffline)
    }
}
