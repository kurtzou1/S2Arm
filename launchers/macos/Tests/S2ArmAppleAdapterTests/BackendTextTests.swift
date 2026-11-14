import XCTest
@testable import S2ArmAppleAdapter

/// 作业层文字的翻译（BackendText）：真资源包（Localizable.json + 共享体验规格），期望值按对照表里的英文手写。
final class BackendTextTests: XCTestCase {
    func testWholeSentenceAndSharedLabels() {
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "en"), "Game stopped.")
        XCTAssertEqual(BackendText.translate("游戏库所在磁盘", language: "en"), "Library Drive")
        // 共享体验规格里的阶段名与状态名（不在 Localizable.json 里）
        XCTAssertEqual(BackendText.translate("解包", language: "en"), "Unpack")
        XCTAssertEqual(BackendText.translate("运行中", language: "en"), "Running")
    }

    func testIosPlatformItemAndStageHaveEnglish() {
        // 11-08：切到英文后作业页只剩大标题是英文，副标题与日志行还是中文——阶段原句没有对照；项名也漏了 components
        XCTAssertEqual(BackendText.translate("下载 Xcode 的 iOS 平台组件（约 8 GB）", language: "en"),
                       "Downloading Xcode's iOS Platform Components (about 8 GB)")
        XCTAssertEqual(BackendText.translate("iOS 平台组件", language: "en"), "iOS Platform Components")
    }

    func testCheckMessageWithSdkVersionTranslates() {
        // 11-08：环境检查里带版本号的整句原来是中文（模板 {0} 不在对照表里，回退原文）
        XCTAssertEqual(BackendText.translate("已装 Xcode 的 iOS 27.2 平台组件。", language: "en"),
                       "Xcode's iOS 27.2 Platform Components are installed.")
        XCTAssertEqual(BackendText.translate("Xcode 的 iOS 27.2 平台组件还没装（新装或刚升级的 Xcode 要另下）：打 iPhone 包、装到 iPhone 都要用它。点「一键下载」自动安装（苹果官方，约 8 GB，要些时间），下完自动重新检查。只在 Mac 上玩不需要它。", language: "en"),
                       "Xcode's iOS 27.2 Platform Components are not installed (a new or newly upgraded Xcode installs them separately): building iPhone packages and installing to iPhone need them. Click Download to install them automatically (from Apple, about 8 GB; it takes a while); the check runs again when it finishes. Not needed if you only play on this Mac.")
    }

    func testChineseInterfaceKeepsOriginalAndMapsEnglishBack() {
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "zh-Hans"), "游戏已停止。")
        XCTAssertEqual(BackendText.translate("Game stopped.", language: "zh-Hans"), "游戏已停止。")
        XCTAssertEqual(BackendText.translate("Some text nobody knows", language: "en"), "Some text nobody knows")
    }

    func testTemplatesAndJoinedSentences() {
        XCTAssertEqual(BackendText.translate("托管游戏文件缺失，请重新导入：0100535012974000", language: "en"),
                       "Managed game file is missing, import it again: 0100535012974000")
        // 新前端「这款还缺文件：」+ 作业层的缺件说明（多条用「；」连）
        XCTAssertEqual(BackendText.translate("这款还缺文件：缺游戏本体：只放了更新或 DLC，把本体的 NSP / XCI 也放进来；托管游戏文件缺失，请重新导入：0100", language: "en"),
                       "This game is missing files: Base game missing: only an update or DLC was added. Add the base game’s NSP / XCI too.; Managed game file is missing, import it again: 0100")
        // 准备运行页实测出现过的两行（出包进度计数、复用兄弟平台产物根，后者占位里还套一句定句）
        XCTAssertEqual(BackendText.translate("刷新各阶段 4/11", language: "en"), "Refresh stages 4/11")
        XCTAssertEqual(BackendText.translate("复用兄弟平台的产物根 0100535012974000@rx-9f61ea4e（提交 8607b717c；克隆路线：APFS 克隆 77 项）：平台无关阶段按键核对，键相同跳过、不同照常重做", language: "en"),
                       "Reused the sibling platform's build root 0100535012974000@rx-9f61ea4e (commit 8607b717c; clone route: APFS clone, 77 items): platform-independent stages are checked by key, skipped when equal and redone when different")
        // 占位里的值原样带过去（花括号、$ 不当模板）
        XCTAssertEqual(BackendText.translate("构建工具不可用：{x}$1", language: "en"), "Build tool unavailable: {x}$1")
        // #479：装机遇到带不进的款，作业层按行给固定句式（pack/jobs/ipa.py assemble），英文界面逐行翻、游戏名原样
        XCTAssertEqual(BackendText.translate("手机上有几款游戏这次放不进同一个 App。\n这台电脑上没有它们的 iPhone 版：「丙款」\n它们是旧版 S2Arm 出的 iPhone 版，新版认不得，要重新「打 iPhone 包」：「乙款」\n"
                                             + "确认继续的话，这次先不带它们照装，它们的存档和资源都留在手机上，之后给它们「打 iPhone 包」再装一次就回来。同意一次后，这台手机在这一版 S2Arm 上不再为它们问。", language: "en"),
                       "Some games on the phone can't go into the same app this time.\nThis computer has no iPhone build of: 「丙款」\nBuilt for iPhone by an older S2Arm, which this version can't use. Run \"Build for iPhone\" again for: 「乙款」\n"
                       + "Confirm to install without them this time. Their saves and resources stay on the phone, and they come back once you build them for iPhone and install again. "
                       + "After you agree once, this phone won't ask about them again on this S2Arm version.")
        // 装机遇到库里已删 / 别的电脑装的款（pack/jobs/install.py container_others）：同样按行给固定句式，英文界面逐行翻
        XCTAssertEqual(BackendText.translate("这次装完，手机上这几款游戏会打不开（存档和资源包都还在手机上）。\n它们已从这台电脑的游戏库删除，重新加回游戏库、「打 iPhone 包」再装一次就回来：「乙款」\n确认继续再点一次。", language: "en"),
                       "After this install, these games on the phone won't open (their saves and resources stay on the phone).\n"
                       + "Deleted from this computer's library; they come back once you add them again, \"Build for iPhone\" and install: 「乙款」\nConfirm and try again to continue.")
    }

    func testSharedEntriesComeFromTheSpecification() throws {
        let entries = try BackendText.sharedEntries(Data(contentsOf: BackendText.experienceURL()))
        XCTAssertTrue(entries.contains(BackendText.Entry(source: "解包", en: "Unpack")))
        XCTAssertTrue(entries.contains(BackendText.Entry(source: "运行中", en: "Running")))
        XCTAssertThrowsError(try BackendText.sharedEntries(Data(#"{"states":[{"id":"running","title":{"zh-Hans":"运行中"}}]}"#.utf8)))
    }
}
