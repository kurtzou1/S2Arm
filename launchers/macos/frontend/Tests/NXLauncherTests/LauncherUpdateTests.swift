// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Sparkle
import XCTest
import S2ArmAppleAdapter
@testable import NX2AppleUI

@MainActor final class LauncherUpdateTests: XCTestCase {
    private var defaultSuite: String!
    private var defaults: UserDefaults!
    private var model: S2ArmLauncherModel!
    private var sim: SimulatedUpdateDriver!

    override func setUp() async throws {
        defaultSuite = "s2arm-update-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultSuite))
        defaults.set(true, forKey: SimulatedUpdateDriver.enabledKey)
        model = makeModel()
        sim = SimulatedUpdateDriver(model: model, defaults: defaults, sleep: { _ in try Task.checkCancellation() })
        model.updateDriver = sim
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: model.provider.client.environment.privateRoot)
        defaults.removePersistentDomain(forName: defaultSuite)
    }

    private func makeModel() -> S2ArmLauncherModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(defaultSuite)
        let client = JobClient(environment: JobEnvironment(privateRoot: root, resources: root))
        return S2ArmLauncherModel(client: client, updateDefaults: defaults)
    }

    func testUpdateNotesUseSimplifiedChineseForBothChineseLanguagesAndEnglishOtherwise() {
        let item = ["zh-Hans": "修复启动问题。", "en": "Fixed startup."]
        for language in ["zh-Hans", "zh-Hant"] {
            XCTAssertEqual(UpdateNoteCopy.text(item, language: language), "修复启动问题", language)
            XCTAssertEqual(UpdateNoteCopy.heading("修复", language: language), "修复", language)
        }
        for language in ["en", "ja", "fr", ""] {
            XCTAssertEqual(UpdateNoteCopy.text(item, language: language), "Fixed startup", language)
            XCTAssertEqual(UpdateNoteCopy.heading("修复", language: language), "Fixes", language)
        }
    }

    func testUpdateNotesPreserveUntranslatedContent() {
        XCTAssertEqual(UpdateNoteCopy.text(["zh-Hans": "修复启动问题"], language: "ja"), "修复启动问题")
        XCTAssertEqual(UpdateNoteCopy.heading("Compatibility", language: "en"), "Compatibility")
    }

    func testManualCheckReopensASeenOffer() async {
        sim.simulateStartupCheck(failed: false)
        XCTAssertEqual(model.updatePopup?["version"] as? String, "9.9.9")
        model.closeUpdatePopup()
        sim.simulateStartupCheck(failed: false)
        XCTAssertNil(model.updatePopup)
        var activated = false
        model.checkForUpdatesManually { activated = true }
        XCTAssertTrue(model.isCheckingForUpdates)
        XCTAssertEqual(model.updateMenuTitle(language: "en"), "Checking for Updates")
        await model.updateCheckTask?.value
        XCTAssertFalse(model.isCheckingForUpdates)
        XCTAssertTrue(activated)
        XCTAssertEqual(model.updatePopup?["version"] as? String, "9.9.9")
        XCTAssertNil(model.checkError)
    }

    func testManualCheckUpToDatePresentsConfirmationWithoutMarkingAnOfferSeen() async {
        sim.checkResult = .upToDate
        var activated = false
        model.checkForUpdatesManually { activated = true }
        await model.updateCheckTask?.value
        XCTAssertTrue(activated)
        XCTAssertEqual(model.updateMenuTitle(language: "en"), "Check for Updates")
        XCTAssertNil(model.availableUpdate)
        XCTAssertEqual(model.updatePopup?["kind"] as? String, "upToDate")
        XCTAssertNil(model.checkError)
        XCTAssertEqual(model.updateState, .idle)

        model.closeUpdatePopup()
        XCTAssertNil(model.updatePopup)
        sim.simulateStartupCheck(failed: false)
        XCTAssertEqual(model.updatePopup?["kind"] as? String, "update")
    }

    /// 查得慢时玩家在设置里打开了 Apple ID 登录：查完不能收起设置页和登录面板，结果留着等它们关了再弹
    func testManualCheckResultKeepsSettingsAndAppleLoginOpen() async {
        for result in [SimulatedUpdateDriver.CheckResult.upToDate, .network] {
            sim.checkResult = result
            model.showEnvironment = true
            model.checkForUpdatesManually()
            model.appleLoginHost = "settings"
            await model.updateCheckTask?.value
            XCTAssertTrue(model.showEnvironment)
            XCTAssertEqual(model.appleLoginHost, "settings")
            XCTAssertTrue(model.updatePopup != nil || model.checkError != nil)
            model.appleLoginHost = nil; model.showEnvironment = false; model.updatePopup = nil; model.checkError = nil
        }
        sim.simulateStartupCheck(failed: false)
        model.closeUpdatePopup()
        model.showEnvironment = true
        sim.checkResult = .available
        model.appleLoginHost = "settings"
        model.checkForUpdatesManually()
        await model.updateCheckTask?.value
        XCTAssertTrue(model.showEnvironment)
        XCTAssertEqual(model.appleLoginHost, "settings")
        XCTAssertEqual(model.updatePopup?["version"] as? String, "9.9.9")
    }

    func testManualFailuresUseCheckErrorAndStartupFailureIsSilent() async {
        sim.simulateStartupCheck(failed: true)
        XCTAssertNil(model.checkError)
        XCTAssertNil(model.updatePopup)
        for (result, code) in [(SimulatedUpdateDriver.CheckResult.network, "update_network"),
                               (.rateLimited, "update_rate_limited"), (.server, "update_server")] {
            var activated = false
            sim.checkResult = result
            model.checkForUpdatesManually { activated = true }
            XCTAssertNil(model.checkError)
            await model.updateCheckTask?.value
            XCTAssertTrue(activated)
            XCTAssertEqual(model.checkError, code)
            XCTAssertEqual(model.updateState, .idle)
            XCTAssertNil(model.updatePopup)
        }
        let driver = ReadyDriver(result: ["available": false, "error": "update_bad_signature"])
        model.updateDriver = driver
        model.checkForUpdatesManually()
        await model.updateCheckTask?.value
        XCTAssertEqual(model.checkError, "update_failed")
        XCTAssertEqual(driver.freshValues, [true])
    }

    func testPopupActionsAndMenuStates() {
        sim.simulateStartupCheck(failed: false)
        let rows: [(UpdateState, String, String, Bool, Bool, String)] = [
            (.idle, "update.popup.later", "update.popup.updateNow", true, true, "Update Available (v9.9.9)"),
            (.working("update.downloading", nil), "update.popup.close", "update.popup.downloadingBtn", true, false, "Downloading Update"),
            (.working("update.downloading", 9), "update.popup.close", "update.popup.downloadingBtn", true, false, "Downloading Update"),
            (.ready, "update.popup.later", "update.popup.restartNow", false, true, "Ready to Update (v9.9.9)"),
            (.failed("update_failed"), "update.popup.later", "update.popup.retryNow", true, true, "Update Available (v9.9.9)"),
        ]
        for (state, secondary, primary, checkbox, enabled, menu) in rows {
            let actions = state.popupActions
            XCTAssertEqual(actions.secondary, secondary)
            XCTAssertEqual(actions.primary, primary)
            XCTAssertEqual(actions.showsAutoRestart, checkbox)
            XCTAssertEqual(actions.primaryEnabled, enabled)
            model.updateState = state
            XCTAssertEqual(model.updateMenuTitle(language: "en"), menu)
        }
    }

    func testSimulatedDownloadsCanCloseAndRetry() async {
        model.downloadUpdate() // 控制口可在没有更新提议时直接启动。
        await sim.downloadTask?.value
        XCTAssertEqual(model.updateVersion, "9.9.9")
        sim.reset()
        sim.simulateStartupCheck(failed: false)
        for (result, state, bytes) in [
            (SimulatedUpdateDriver.DownloadResult.interrupted, UpdateState.failed("update_download_failed"), UInt64(55_200_000)),
            (.signature, .failed("update_bad_signature"), 138_000_000),
            (.diskFull, .failed("update_disk_full"), 138_000_000),
            (.noPermission, .failed("update_no_permission"), 138_000_000),
            (.success, .ready, 138_000_000),
        ] {
            sim.downloadResult = result
            model.showUpdatePopup()
            model.downloadUpdate()
            model.closeUpdatePopup()
            await sim.downloadTask?.value
            XCTAssertNil(model.updatePopup)
            XCTAssertEqual(model.updateState, state)
            XCTAssertEqual(sim.readyToInstall, state == .ready)
            XCTAssertEqual(model.updateDownloadBytes.received, bytes)
        }
    }

    func testAutoRestartOptInPersistenceBusyAndIdle() async {
        let driver = ReadyDriver()
        model.updateDriver = driver
        XCTAssertFalse(model.autoRestartWhenReady)
        model.updateDidBecomeReady()
        XCTAssertEqual(driver.installCount, 0)
        XCTAssertNil(model.updatePopup)
        XCTAssertTrue(model.showRestartUpdateButton)
        model.autoRestartWhenReady = true
        XCTAssertTrue(makeModel().autoRestartWhenReady)
        model.updateState = .idle
        model.downloadUpdate()
        XCTAssertEqual(driver.downloadCount, 1)
        XCTAssertEqual(driver.installCount, 0)
        // 勾了自动重启但弹窗已关：不自动重启，顶栏留「重启以更新」
        XCTAssertNil(model.updatePopup)
        model.updateDidBecomeReady()
        XCTAssertEqual(driver.installCount, 0)
        XCTAssertTrue(model.showRestartUpdateButton)
        // 弹窗开着下载完：自动重启
        model.updateState = .idle
        model.availableUpdate = ["version": "9.9.9"]
        model.showUpdatePopup()
        model.updateDidBecomeReady()
        XCTAssertEqual(driver.installCount, 1)
        XCTAssertFalse(model.showRestartUpdateButton)

        let busyModel = makeModel()
        let busyDriver = SimulatedUpdateDriver(model: busyModel, defaults: defaults, sleep: { _ in })
        busyModel.updateDriver = busyDriver
        busyDriver.pretendBusy = true
        busyDriver.simulateStartupCheck(failed: false)
        busyDriver.downloadResult = .signature
        busyModel.downloadUpdate()
        await busyDriver.downloadTask?.value
        XCTAssertTrue(busyModel.autoRestartWhenReady)
        busyDriver.downloadResult = .success
        busyModel.downloadUpdate()
        await busyDriver.downloadTask?.value
        XCTAssertTrue(busyDriver.readyToInstall)
        XCTAssertTrue(busyModel.showRestartUpdateButton)
        XCTAssertNil(busyModel.updateGate)
        busyModel.restartToUpdate()
        XCTAssertEqual(busyModel.updateGate, "update.gate.confirm")
        XCTAssertEqual(busyModel.updateRestartImpactText { BackendText.launcherText($0, language: "en") },
                       "\"Export\" will be interrupted; you can pick it up after the restart, and finished parts are kept.")
    }

    func testResetClearsSimulationStateAndKeepsPreferences() async {
        model.autoRestartWhenReady = true
        sim.checkResult = .rateLimited
        sim.downloadResult = .signature
        sim.speed = .slow
        sim.pretendBusy = true
        sim.simulateStartupCheck(failed: false)
        model.closeUpdatePopup() // 记录已提示
        model.showUpdatePopup()
        model.downloadUpdate()
        let download = sim.downloadTask
        model.checkForUpdatesManually()
        let check = model.updateCheckTask
        sim.reset()
        await download?.value
        await check?.value
        XCTAssertEqual(model.updateState, .idle)
        XCTAssertFalse(model.isCheckingForUpdates)
        XCTAssertNil(model.checkError)
        XCTAssertNil(model.availableUpdate)
        XCTAssertNil(model.updatePopup)
        XCTAssertFalse(sim.readyToInstall)
        XCTAssertEqual(model.updateDownloadBytes.received, 0)
        XCTAssertTrue(model.autoRestartWhenReady)
        sim.simulateStartupCheck(failed: false)
        XCTAssertNotNil(model.updatePopup)

        let reopened = makeModel().simulatedUpdate
        XCTAssertEqual(reopened?.checkResult, .rateLimited)
        XCTAssertEqual(reopened?.downloadResult, .signature)
        XCTAssertEqual(reopened?.speed, .slow)
        XCTAssertEqual(reopened?.pretendBusy, true)
    }

    func testSimulationIsOptIn() {
        XCTAssertNotNil(model.simulatedUpdate)
        defaults.removeObject(forKey: SimulatedUpdateDriver.enabledKey)
        let normal = makeModel()
        XCTAssertFalse(normal.updateSimulationEnabled)
        XCTAssertNil(normal.simulatedUpdate)
    }

    func testReleaseBuildWithFeedIgnoresSimulationPreference() {
        let feed: [String: Any] = ["SUFeedURL": "https://example.test/appcast.xml"]
        XCTAssertFalse(SimulatedUpdateDriver.isAllowed(preference: true, info: feed))
        XCTAssertFalse(SimulatedUpdateDriver.isAllowed(preference: false, info: [:]))
        XCTAssertTrue(SimulatedUpdateDriver.isAllowed(preference: true, info: [:]))
        XCTAssertTrue(SimulatedUpdateDriver.isAllowed(preference: true, info: nil))
    }

    func testSparkleDownloaderStatusUsesItsPinnedErrorFormat() {
        for status in [404, 503, 403] {
            let underlying = NSError(
                domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "A network error occurred while downloading https://example.test/update. Response (\(status))"]
            )
            let outer = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                                userInfo: [NSUnderlyingErrorKey: underlying])
            XCTAssertEqual(SparkleUpdate.updateErrorCode(outer), status == 403 ? "update_download_failed" : "update_server")
            XCTAssertEqual(SparkleUpdate.updateErrorCode(outer, fetchingAppcast: true), "update_network")
        }
    }

    func testSparkleErrorMapping() throws {
        func wrapped(_ code: SUError, _ cause: NSError? = nil) -> NSError {
            NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue),
                    userInfo: cause.map { [NSUnderlyingErrorKey: $0] })
        }
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let permission = NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))
        let outOfSpace = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let nested = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSUnderlyingErrorKey: outOfSpace])
        for (error, code) in [
            (wrapped(.downloadError, offline), "update_download_failed"),
            (wrapped(.appcastError, offline), "update_network"),
            (wrapped(.appcastParseError), "update_network"),
            (wrapped(.signatureError), "update_bad_signature"),
            (wrapped(.validationError), "update_bad_signature"),
            (wrapped(.unarchivingError), "update_unpack_failed"),
            (wrapped(.downloadError, nested), "update_disk_full"),
            (wrapped(.fileCopyFailure, permission), "update_no_permission"),
            (wrapped(.authenticationFailure), "update_no_permission"),
            (wrapped(.installationWriteNoPermissionError), "update_no_permission"),
            (wrapped(.installationError), "update_swap_failed"),
            (wrapped(.relaunchError), "update_swap_failed"),
            (wrapped(.fileCopyFailure), "update_swap_failed"),
            (NSError(domain: "unknown", code: Int(SUError.signatureError.rawValue)), "update_failed"),
        ] { XCTAssertEqual(SparkleUpdate.updateErrorCode(error), code) }
        let url = try XCTUnwrap(URL(string: "https://example.test/update"))
        for status in [404, 503] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: ["response": response])
            XCTAssertEqual(SparkleUpdate.updateErrorCode(wrapped(.downloadError, error)), "update_server")
        }
    }
}

@MainActor private final class ReadyDriver: LauncherUpdateDriver {
    var downloadBytes: (received: UInt64, expected: UInt64) { (0, 0) }
    var readyToInstall = true
    var downloadCount = 0
    var installCount = 0
    var freshValues: [Bool] = []
    var result: [String: Any]?

    init(result: [String: Any]? = nil) { self.result = result }
    func check(current: String, fresh: Bool) async -> [String: Any]? {
        freshValues.append(fresh)
        return result
    }
    func startDownload() { downloadCount += 1 }
    func installNow() { installCount += 1 }
}
