// 起局自检不过时 iOS 屏上的标题与正文（玩家话术；实现 runtime/src/selfcheck.c s2a_selfcheck_screen，上屏 runtime/src/host_main.c）。
// 文案按启动器规矩登记在 launchers/shared/experience.v1.json 的 selfcheck_page，与本文件的宏逐字一致，launchers/shared/check_experience.py 比对；
//   改字面要同一提交改 selfcheck_page.items（revision + 1）。游戏进程不读那份 JSON，本头文件是实现来源。
// 上屏只放一句人话 + 下一步（11-02 维护者：内部词不上屏）；地址上限 / main.npdm / MB 这类细节只进 host.log 的「【红】自检不过」。
#pragma once
// 没签「提高内存上限」权限 → 重装
#define S2A_SELFCHECK_ENT_TITLE    "安装少了一项必要权限"
#define S2A_SELFCHECK_ENT_TITLE_EN "A required permission is missing"
#define S2A_SELFCHECK_ENT_BODY     "这款游戏要用「提高内存上限」权限。请用 电脑上的 S2Arm 点游戏库第一格「S2Arm」里的「续签 S2Arm」重新装一次，会自动带上它。"
#define S2A_SELFCHECK_ENT_BODY_EN  "This game needs the \"Increased Memory Limit\" permission. In S2Arm on your computer, click \"Renew S2Arm\" on the S2Arm card first in the library; it will be included automatically."
// 地址窗口占到、只是内存上限不够（没签权限）→ 让玩家自己选：先试着玩，或重装补权限（v0.3.1 装机原则：认得出的风险让玩家确认，不替他拒）
#define S2A_SELFCHECK_MEM_BODY     "这次安装没带上「提高内存上限」权限，系统给 S2Arm 的内存偏少。可以先点「仍要启动」试着玩，大游戏可能玩到一半被系统结束；想彻底解决，请用 电脑上的 S2Arm 点游戏库第一格「S2Arm」里的「续签 S2Arm」重新装一次，会自动带上它。"
#define S2A_SELFCHECK_MEM_BODY_EN  "This install is missing the \"Increased Memory Limit\" permission, so iOS gives S2Arm less memory. You can tap \"Start Anyway\" to try it; large games may be closed by iOS mid-play. To fix it for good, click \"Renew S2Arm\" on the S2Arm card first in the library in S2Arm on your computer; the permission will be included automatically."
// 独立 App（一 App 一游戏，0.6.4）没签「提高内存上限」：没有「续签 S2Arm」那一格，出路是给这款的 App ID 开权限或改用 Apple ID 签名后重推这款
#define S2A_SELFCHECK_ENT_BODY_APP    "这款游戏要用「提高内存上限」权限，这个 App 签名时没带上。请证书发放人在这款的 App ID 上开启它（通配 * 的描述文件开不了，要给这款单独建 App ID），或在 电脑上的 S2Arm 改用 Apple ID 签名，再对这款点「推到 iPhone」重新装一次。"
#define S2A_SELFCHECK_ENT_BODY_APP_EN "This game needs the \"Increased Memory Limit\" permission, and this app was signed without it. Ask whoever issued your certificate to turn it on for this game's App ID (a wildcard * profile can't have it, so the game needs its own App ID), or switch to Apple ID signing in S2Arm on your computer, then click \"Push to iPhone\" for this game again."
#define S2A_SELFCHECK_MEM_BODY_APP    "这次安装没带上「提高内存上限」权限，系统给这款游戏的内存偏少。可以先点「仍要启动」试着玩，大游戏可能玩到一半被系统结束；想彻底解决，请证书发放人在这款的 App ID 上开启它（通配 * 的描述文件开不了，要给这款单独建 App ID），或在 电脑上的 S2Arm 改用 Apple ID 签名，再对这款点「推到 iPhone」重新装一次。"
#define S2A_SELFCHECK_MEM_BODY_APP_EN "This install is missing the \"Increased Memory Limit\" permission, so iOS gives this game less memory. You can tap \"Start Anyway\" to try it; large games may be closed by iOS mid-play. To fix it for good, ask whoever issued your certificate to turn it on for this game's App ID (a wildcard * profile can't have it, so the game needs its own App ID), or switch to Apple ID signing in S2Arm on your computer, then click \"Push to iPhone\" for this game again."
// 地址空间不够这款（11-20 维护者定：静态大区末端顶到窗口末 = 游戏其余地址区必落远端、可能卡在开头）：不拦，「仍要启动」照常起局。
//   iOS 屏上按 S2ArmHost.strings 的 addrshort.* 出五语（ios/app.m host_text），这里的中英是实现来源与日志用
#define S2A_SELFCHECK_ADDR_TITLE    "这台设备的地址空间不够这款游戏"
#define S2A_SELFCHECK_ADDR_TITLE_EN "This device doesn't have enough address space for this game"
#define S2A_SELFCHECK_ADDR_BODY     "这款游戏开局要一整块很大的地址空间，这台设备给不了这么多：可能会非常卡，或一直停在开头。可以先点「仍要启动」试试；想正常玩，请换一台地址空间更大的设备（比如内存更大的 iPhone / iPad / Mac），或等后续版本改进。"
#define S2A_SELFCHECK_ADDR_BODY_EN  "This game needs one very large block of address space at startup, and this device can't provide that much: it may run very slowly or stay stuck at the start. You can tap \"Start Anyway\" to try; to play normally, use a device with more address space (such as an iPhone, iPad or Mac with more memory), or wait for a later version."
#define S2A_SELFCHECK_GO           "仍要启动"
#define S2A_SELFCHECK_GO_EN        "Start Anyway"
// 读不到本款要多大地址（包不完整）→ 重装补资源
#define S2A_SELFCHECK_PKG_TITLE    "游戏资源不完整"
#define S2A_SELFCHECK_PKG_TITLE_EN "Game files are incomplete"
#define S2A_SELFCHECK_PKG_BODY     "请在 电脑上的 S2Arm 里对这款游戏再点一次「推到 iPhone」，它会把缺的补上。"
#define S2A_SELFCHECK_PKG_BODY_EN  "In S2Arm on your computer, click \"Push to iPhone\" for this game again to add what's missing."
// 签了仍不够 → 本机型系统上限
#define S2A_SELFCHECK_DEVICE_TITLE "这台手机暂时玩不了这款游戏"
#define S2A_SELFCHECK_DEVICE_TITLE_EN "This iPhone can't run this game yet"
#define S2A_SELFCHECK_DEVICE_BODY  "这款游戏要的内存超过了这台手机的系统上限，重新安装也解决不了。换一台内存更大的 iPhone 就能玩。"
#define S2A_SELFCHECK_DEVICE_BODY_EN "This game needs more memory than this iPhone's system limit allows, and reinstalling won't help. It will run on an iPhone with more memory."
// 游戏要的地址空间宽度暂不支持（NPDM 地址空间类型 0 / 2 = 32 位；1 = 36 位、3 = 39 位支持，见 runtime/src/as_type.h）→ 与机型、安装无关
#define S2A_SELFCHECK_AS_TITLE     "暂不支持这款游戏"
#define S2A_SELFCHECK_AS_TITLE_EN  "This game isn't supported yet"
#define S2A_SELFCHECK_AS32_BODY    "这款游戏使用 32 位地址空间，S2Arm 暂不支持，重新安装或换手机都解决不了。"
#define S2A_SELFCHECK_AS32_BODY_EN "This game uses a 32-bit address space, which S2Arm doesn't support yet. Reinstalling or switching phones won't help."
