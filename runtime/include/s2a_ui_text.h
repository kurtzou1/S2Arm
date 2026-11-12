// 跨平台 C 层（runtime/src）递给宿主界面显示的文字（#316）：中文原宏 + 英文 <宏>_EN，显示处用 S2A_UI(宏) 按界面语言取一种。
//   界面语言由平台给：s2a_ui_zh() 1 = 中文。iOS 强定义在 ios/app.m（同 ios/s2a_l10n.h s2a_l10n_zh：主 bundle 首选本地化以 zh 开头）、
//   Mac 在 macos/front_mac.m（Mac 宿主不带 .lproj，按系统首选语言）；用到它的 .c 各自带一份返回 1 的弱缺省（同 dm_thermal_now 的写法），别的平台 / 只链单个 .c 的单测保持中文。
//   日志、诊断里给开发者看的串不进这里。每个文案宏都要有 _EN、显示处只许经 S2A_UI 取，由 tests/ios_l10n_test.sh 核
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int s2a_ui_zh(void);
#define S2A_UI(macro) (s2a_ui_zh() ? (macro) : (macro##_EN))

// ---------- 资源导入提示页（runtime/src/pack_apply.c → ios/app.m s2a_ios_show_notice） ----------
#define S2A_UI_IMPORT_WAIT_TITLE        "游戏资源还没传完"
#define S2A_UI_IMPORT_WAIT_TITLE_EN     "Game resources are still transferring"
#define S2A_UI_IMPORT_WAIT_BODY         "传完会自动开始导入，不用做任何操作。请让本 App 留在前台、不要锁屏。"
#define S2A_UI_IMPORT_WAIT_BODY_EN      "Importing starts automatically when the transfer finishes — no need to do anything. Keep this app open and don’t lock the screen."
#define S2A_UI_IMPORT_STALLED_TITLE     "游戏资源传到一半停住了"
#define S2A_UI_IMPORT_STALLED_TITLE_EN  "The game resource transfer stopped partway"
#define S2A_UI_IMPORT_STALLED_BODY      "请在 电脑上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，会接着传完；传完这里会自动继续。"
#define S2A_UI_IMPORT_STALLED_BODY_EN   "In S2Arm on your computer, click “Install on iPhone” for this game again to finish the transfer. This continues automatically when it’s done."
#define S2A_UI_IMPORT_DONE_TITLE        "游戏资源导入完成"
#define S2A_UI_IMPORT_DONE_TITLE_EN     "Game resources imported"
#define S2A_UI_IMPORT_REOPEN_BODY       "请从后台划掉本 App，再重新打开就能进入游戏。"
#define S2A_UI_IMPORT_REOPEN_BODY_EN    "Swipe this app away in the app switcher and open it again to start the game."
#define S2A_UI_IMPORT_ENTERING_BODY     "正在进入游戏…"
#define S2A_UI_IMPORT_ENTERING_BODY_EN  "Starting the game…"
#define S2A_UI_IMPORT_READY_TITLE       "游戏资源已经放好"
#define S2A_UI_IMPORT_READY_TITLE_EN    "Game resources are in place"
#define S2A_UI_IMPORT_FAIL_TITLE        "游戏资源没导入成功"
#define S2A_UI_IMPORT_FAIL_TITLE_EN     "Game resources couldn’t be imported"
#define S2A_UI_IMPORT_FAIL_BODY         "请在 电脑上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，它会把缺的补上。还是不行的话，点下面「导出诊断包」发给我们。"
#define S2A_UI_IMPORT_FAIL_BODY_EN      "In S2Arm on your computer, click “Install on iPhone” for this game again to add what’s missing. If it still doesn’t work, tap “Export diagnostics” below and send it to us."
#define S2A_UI_IMPORT_PROGRESS_TITLE    "正在导入游戏资源"
#define S2A_UI_IMPORT_PROGRESS_TITLE_EN "Importing game resources"
#define S2A_UI_IMPORT_PROGRESS_BODY     "第一次要几分钟，请让本 App 留在前台、不要锁屏。"
#define S2A_UI_IMPORT_PROGRESS_BODY_EN  "The first time takes a few minutes. Keep this app open and don’t lock the screen."
// ---------- 缺资源包说明页（pack_apply.c s2a_pack_help_detail / s2a_ios_show_pack_help；标题「游戏资源不完整」复用 s2a_selfcheck_page.h 的 S2A_SELFCHECK_PKG_TITLE） ----------
//   只教两条路：电脑上「装到 iPhone」、「文件」App 里放 game.img（11-11 维护者拍板；原先的「拷『<游戏名>资源包』文件夹」那条已删）
#define S2A_UI_PACK_MISSING_TITLE       "还缺游戏资源"
#define S2A_UI_PACK_MISSING_TITLE_EN    "Game resources are missing"
#define S2A_UI_PACK_AGAIN               "刚刚查过，还是没有完整的资源包。\n\n"
#define S2A_UI_PACK_AGAIN_EN            "Checked just now — the complete resources still aren’t there.\n\n"
// 只缺非核心文件（v0.3.1 缺件照玩）：起局前问一次；玩到一半真读到缺的文件、游戏 Break 时的说明页正文（pack_apply.c）
#define S2A_UI_PACK_PARTIAL_TITLE       "游戏资源缺了几个文件"
#define S2A_UI_PACK_PARTIAL_TITLE_EN    "A few game files are missing"
#define S2A_UI_PACK_PARTIAL_ASK         "这款游戏的资源缺了几个文件，多半是上次传到一半断了。可以先点「仍要启动」玩，玩到用到它们的地方可能会停；在电脑上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，会把缺的补上。"
#define S2A_UI_PACK_PARTIAL_ASK_EN      "A few of this game’s files are missing — the last transfer was probably interrupted. You can tap “Start Anyway” to play; it may stop when the game needs one of them. In S2Arm on your computer, click “Install on iPhone” for this game again to add what’s missing."
#define S2A_UI_PACK_PARTIAL_GO          "仍要启动"
#define S2A_UI_PACK_PARTIAL_GO_EN       "Start Anyway"
#define S2A_UI_PACK_PARTIAL_DETAIL      "游戏刚才要读的资源文件不在手机上（这款的资源缺了几个文件）。请在电脑上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，补上后重新打开就能接着玩。"
#define S2A_UI_PACK_PARTIAL_DETAIL_EN   "The game just needed a file that isn’t on this iPhone (a few of this game’s files are missing). In S2Arm on your computer, click “Install on iPhone” for this game again, then reopen it to keep playing."
#define S2A_UI_PACK_BROKEN_DETAIL       "游戏数据有一部分没传全，多半是传到一半断了。请在电脑上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，它会把缺的补上，补好后这里会自动继续。"
#define S2A_UI_PACK_BROKEN_DETAIL_EN    "Some of the game’s data didn’t finish copying — the transfer was probably interrupted. In S2Arm on your computer, click “Install on iPhone” for this game again to add what’s missing. This continues automatically once it’s done."
#define S2A_UI_PACK_NONE_DETAIL         "这个 App 只是游戏的「外壳」，游戏本身的数据还不在手机上。照下面任选一种做。"
#define S2A_UI_PACK_NONE_DETAIL_EN      "This app is only the game’s “shell”; the game’s data isn’t on the phone yet. Do either of the steps below."

// ---------- 画面停住提示（runtime/src/ap_host.c → ios/app.m s2a_ios_show_message：第一段当标题） ----------
#define S2A_UI_STALL_EXIT               "游戏画面卡住了\n\n请从后台划掉本 App，再重新打开。还是卡住的话，四指长按屏幕打开设置，导出诊断包发给我们。"
#define S2A_UI_STALL_EXIT_EN            "The game picture is stuck\n\nSwipe this app away in the app switcher and open it again. If it’s still stuck, hold four fingers on the screen to open Settings, then export diagnostics and send them to us."
#define S2A_UI_STALL_WAIT               "游戏画面卡住了\n\n可能还在加载，可以再等一会儿；一直不动的话，请从后台划掉本 App，再重新打开。"
#define S2A_UI_STALL_WAIT_EN            "The game picture is stuck\n\nIt may still be loading, so you can wait a little longer. If nothing changes, swipe this app away in the app switcher and open it again."

// ---------- 齿轮菜单「性能浮层」那一行（runtime/src/hud.c s2a_hud_brief → ios/hud.m） ----------
#define S2A_UI_HUD_BRIEF                "%llu 帧 · %s"
#define S2A_UI_HUD_BRIEF_EN             "%llu FPS · %s"
#define S2A_UI_HUD_MEM_FAIL             "内存读取失败"
#define S2A_UI_HUD_MEM_FAIL_EN          "Memory unavailable"
// 两本账一起写（11-13 玩家复盘：GPU 已分配撞上系统上限报 OutOfMemory，浮层只写进程实占 0.9 GB，看着像内存没吃多少）
#define S2A_UI_HUD_MEM_GPU              "进程 %.1f GB · GPU %.1f GB"
#define S2A_UI_HUD_MEM_GPU_EN           "App %.1f GB · GPU %.1f GB"
#ifdef __cplusplus
}
#endif
