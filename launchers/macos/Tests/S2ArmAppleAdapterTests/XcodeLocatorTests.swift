import XCTest
@testable import S2ArmAppleAdapter

/// 自动找 Xcode 的目录：只看 /Applications、~/Applications，不翻 /Volumes（列外接卷会弹系统隐私窗「想访问可移除卷上的文件」，
///   接着外接盘的玩家一开启动器就弹）；Xcode 装在外接盘上的由玩家在设置页自己选。与作业层 pack/jobs/toolchain.py default_app_dirs 同一组目录
final class XcodeLocatorTests: XCTestCase {
    func testSearchDirsAreInternalOnly() {
        XCTAssertEqual(XcodeLocator.searchDirs(), ["/Applications", NSHomeDirectory() + "/Applications"])
    }
}
