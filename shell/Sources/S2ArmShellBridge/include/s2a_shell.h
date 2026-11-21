// S2Arm iOS 游戏库界面的 C 边界（app.m / 宿主 C 侧只包含这一个头文件）。
//   库界面：s2a_shell_library_vc 返回一个 UIHostingController（SwiftUI 游戏库），由 app.m 挂到自己的 Scene / 根窗口，
//     不另起 UIApplicationMain、不接管生命周期。
//   Play：界面上点 Play（可运行的那款）→ s2a_shell_play(gameId) → 登记的处理函数；没登记时只记一行日志。宿主侧 ios/app.m（多款容器）登记，处理函数里选游戏、起宿主。
// 线程：两样都只在主线程调；处理函数也在主线程被回调。
#ifndef S2A_SHELL_H
#define S2A_SHELL_H

#ifdef __cplusplus
extern "C" {
#endif

// Play 处理函数：game_id 只在回调期间有效（要留就拷一份）；ctx 原样回传
typedef void (*s2a_shell_play_fn)(const char *game_id, void *ctx);

// 登记 / 换掉 Play 处理函数；传 NULL 取消登记（回到只记日志）
void s2a_shell_set_play_handler(s2a_shell_play_fn fn, void *ctx);

// 界面 Play 的出口（S2ArmShellHost 调它）：有处理函数就转给它并返回 1；没有只记日志并返回 0
int s2a_shell_play(const char *game_id);

// 库界面控制器（实现在 S2ArmShellHost，Swift @_cdecl；只在 iOS 有）：
//   catalogue_json_path = 游戏目录清单 JSON 的绝对路径（格式见 shell/UPSTREAM.md「catalogue」）；
//   返回 +1 的 UIViewController（ARC 下 (__bridge_transfer UIViewController *)s2a_shell_library_vc(p)），失败不返回 NULL：
//   清单读不了时界面照出、列表为空并记日志。
void *s2a_shell_library_vc(const char *catalogue_json_path);

// 本款装机阶段（11-07 Duo「游戏没能启动」：库里对资源包不在机上的款仍给 Play；v0.2.3 装机蒙版：传着的款要显示进度）：
//   s2a_shell_game_install_state：1 就绪 / 2 传完了只等解开 / 3 传输中（推送没完：有 资源包/.transfer 按它画进度，没有按文件改动判传断了）/ 0 没有（资源包不在或是空的，库里不显示）。
//     实现在宿主 ios/app.m（按 Documents/games/<游戏号> 跑 pack_apply.c s2a_game_install_state，同起局导入闸门判据）；本包弱定义缺省 1（Swift 单测不链宿主）
//   s2a_shell_install_game：库在后台解开阶段 2 的那款，解完宿主调 s2a_shell_refresh；同时只解一款，正在解（或游戏号不对）返回 0。弱缺省 0
//   s2a_shell_install_progress：正在解的是这款 → 写已解开包数 / 总包数、返回 1；否则 0。弱缺省 0
//   s2a_shell_pick_game_data：库里点「需要游戏数据」那款 → 宿主给导入说明（含「重新检查」）；弱定义缺省只记日志
int s2a_shell_game_install_state(const char *game_id);
// 这款程序是按别的宿主约定号出的（runtime s2a_launch_ctx_game_needs_update / 点开被拒 S2A_SELECT_NEEDS_UPDATE）→ 1：库卡片标「需要在电脑上更新」。
//   实现在宿主 ios/app.m（每款读一次清单后缓存，点开被拒的也记上；库每秒重判只查缓存）；弱缺省 0
int s2a_shell_game_needs_host_update(const char *game_id);
// 这款的签名状态（0.6.0：签名证书是游戏状态的一部分，库列出时就判，不等点开始；判据 ios/sign_state.m s2a_sign_state_at）：
//   0 可玩 / 1 要手机签、手机上没有签名证书 / 2 手机上只有别的团队（Apple ID）的证书 / 3 装 App 用的证书已换或吊销 / 4 电脑签的签名本机不认、手机上没证书重签 /
//   5 手机上有能用的证书、重签了仍被拒（只能电脑上对这款重装，库卡片「需要在电脑上更新」）。1–4 库卡片「需要签名证书」、主按钮 s2a_shell_cert_get。
//   实现在宿主 ios/app.m（点开被拒的记下；证书导入后清掉、库重判）；弱缺省 0
int s2a_shell_game_sign_state(const char *game_id);
int s2a_shell_install_game(const char *game_id);
int s2a_shell_install_progress(const char *game_id, int *done, int *total);
// 库起解包被拒（s2a_shell_install_game 返回 0）时为什么：1 另一款正在解（同时只解一款）/ 2 正在整理游戏目录（首次清点容器、资源包挪位，ios/app.m img_scan_bg）/ 0 没有在等的事。
//   库据此在卡片上说「等另一款装完」「正在整理游戏目录」，不再只写「安装中」（iOS 装机剃刀 #46 / #47）。主线程；弱缺省 0
int s2a_shell_install_wait(void);
// 库界面第一次出现（启动打点「游戏库界面可操作」）；弱定义缺省什么都不做
void s2a_shell_library_appeared(void);
// 单一 IMG 的分段安装进度（runtime/src/pack_apply.c s2a_pack_apply_phase）：正在解这一款时 1，*phase = 1 解开推送包 / 2 从 game.img 解小文件 /
//   3 核对机上文件，*fraction = 这一段的完成比例（0–1，不知道总量时 < 0）；不在解这款返回 0。主线程
int s2a_shell_install_phase(const char *game_id, int *phase, double *fraction);
// 这一款最后一次解开失败的原因（按失败码查的「标题。下一步」一句人话，app.m install_error_text；原文与码只进日志）；没失败过 / 之后成功了返回 NULL。返回的指针到下次调用前有效。主线程
const char *s2a_shell_install_failure(const char *game_id);
// 主屏快捷操作「设置」冷启动时宿主记下的请求：1 = 游戏库出现时要打开游戏库设置（取走即清）；运行中宿主直接发通知 S2AShellOpenSettings
int s2a_shell_take_open_settings(void);
// 这次安装确定丢了「提高内存上限」权限（ios/iml_probe.m，读不到不算）：返回 {"title","body"}（已按 App 语言）的 JSON，调用方 free；没丢 / 读不到返回 NULL。主线程
char *s2a_shell_iml_notice(void);
/* 游戏库真画出了这条提示：记下，进游戏后起局提示不再重复弹（ios/iml_probe.m） */
void s2a_shell_iml_notice_seen(void);
void s2a_shell_pick_game_data(const char *game_id);
// 库卡片「导入 .s2arm…」（还缺 .s2arm 的款、0.5 老款）：开文件选择器选这款的 .s2arm，同「在文件里用 S2Arm 打开」导入、导好库重读清单。
//   宿主 ios/app.m（iPhone；电视没有文件选择器）；弱缺省只记日志
void s2a_shell_pick_s2arm(const char *game_id);
// 长按卡片「导出这一款…」（0.6.3）：后台生成这款的 <名>.s2arm + <名>.img（ios/game_export.m），交「文件」App 存走，换签名重装后放「放这里导入」导回。
//   宿主 ios/app.m（iPhone；电视没有文件导出）；弱缺省什么都不做。主线程
void s2a_shell_export_game(const char *game_id);
// 宿主让库界面重读游戏清单并重判各款资源包（说明里「重新检查」、后台解包完成、导入文件夹导入 .s2arm 后调）。库界面建好时登记；没登记时 s2a_shell_refresh 什么都不做
typedef void (*s2a_shell_refresh_fn)(void *ctx);
void s2a_shell_set_refresh_handler(s2a_shell_refresh_fn fn, void *ctx);
void s2a_shell_refresh(void);

// 虚拟手柄布局（11-07 维护者：游戏库按住游戏 / 点设置 → 虚拟手柄布局 → 二级页拖动；按游戏存，与游戏内拖动编辑同一份数据）。
//   实现在宿主 ios/vpad_shell.m；本包 s2a_shell.c 里是弱定义缺省（读返回 NULL、写返回 0），Swift 单测不链宿主也能编。
//   坐标：safe_w × safe_h 是编辑页里按键可放的区域（点），原点左上；按键字段同布局 JSON（x / y 为该区域宽高比例、width / height /
//   cornerRadius 为区域短边比例，见 ios/layouts/layout.schema.json）。
// 要编辑的布局：{"selected":"default|mine|touch|other","hasMine":bool,"holdLock":bool,"buttons":[{id,x,y,width,height,cornerRadius}…]}，
//   有本款「我的布局」就是它，否则按这块区域现算的默认布局；malloc 出的 UTF-8，调用方 free。游戏号不合规返回 NULL
// split = 0 普通 / 1 分屏；布局、外观与固定摇杆设置分别保存；键/触模式、锁定和 App 级手感共用。
char *s2a_shell_vpad_layout_json(const char *game_id, double safe_w, double safe_h, int split);
// 存本款「我的布局」并选中：centers_json = {"A":[x,y],…}（区域坐标的点，只含挪过的键也行），返回 1 成功 / 0 失败
int s2a_shell_vpad_save(const char *game_id, const char *centers_json, double safe_w, double safe_h, int split);
// 选方案：layout_id = "default" / "mine"，返回 1 成功 / 0 失败（「恢复默认」= 选 default，「我的布局」文件保留）
int s2a_shell_vpad_select(const char *game_id, const char *layout_id, int split);
// iOS 主线程 UIView 预览：返回真实区域和已避让的按键框（点）；malloc / free，同生产布局。
// {split:bool,area:[x,y,w,h],game:[x,y,w,h],division:[x,y,w,h]|null,buttons:[{id,x,y,width,height,cornerRadius}],stickRadius:number}
char *s2a_shell_vpad_preview(const char *game_id, void *view, int split);
// ZL / ZR 按住锁定开关（按游戏，与游戏内设置同一份数据），返回 1 成功 / 0 失败
int s2a_shell_vpad_set_hold_lock(const char *game_id, int enabled);

// 单款画面补丁与金手指（11-13 维护者：游戏库按住游戏的设置里也有帧率 / 满屏 / 金手指，记住选择）。实现在宿主 ios/game_options.m，
//   与游戏内设置页、社区补丁页、金手指面板同一份存储。本包 s2a_shell.c 是弱定义缺省（读 NULL、写 0）。
// {"fps":{"on","enabled","note"},"fullscreen":{"on","enabled","note"},"patches":[{"id","title","note","on"}],"cheats":[{"key","name","note","on"}]}，
//   note 已按当前语言；malloc 出的 UTF-8，调用方 free。游戏号不合规返回 NULL
char *s2a_shell_game_options_json(const char *game_id);
// kind = "fps" / "fullscreen" / "patch" / "cheat"，key = 补丁编号 / 「文件名/条目名」（前两种不看），返回 1 存成 / 0 没存成
int s2a_shell_game_option_set(const char *game_id, const char *kind, const char *key, int on);

// iCloud 存档同步（新功能线 11-09；方案见 launchers/shared/SaveSync）：
//   s2a_shell_save_context：本款存档作业的公共字段 {"game":<存档身份>,"dataRoot":…,"workRoot":…}，malloc 出的 UTF-8、调用方 free；
//     没选游戏 / 没有存档身份 / 没链服务层回 NULL（不同步）。实现在宿主 ios/save_transfer.m；本包弱定义缺省 NULL
//   s2a_shell_save_request：转给服务层 S2A_SaveTransfer（请求 / 回应 JSON 同 ios/save_transfer.m），回 malloc 出的 UTF-8、调用方 free；没链服务层回 NULL
//   s2a_shell_cloud_sync_vc：实现在 S2ArmShellHost（Swift）。玩家开了云存档就返回 +1 的同步页（同步完 / 玩家放弃后主线程调 done(ctx)），没开回 NULL
char *s2a_shell_save_context(void);
char *s2a_shell_save_request(const char *json);
void *s2a_shell_cloud_sync_vc(const char *game_id, void (*done)(void *ctx), void *ctx);
//   s2a_shell_cloud_upload_background：实现在 S2ArmShellHost（Swift）。游戏进行中切后台时主线程调：开了云存档、本机比云端新才上传（要后台收尾时间、传完交还）；
//     云端有更新 / 冲突不动，留给下次起局前的同步
void s2a_shell_cloud_upload_background(const char *game_id);

// 故障报修（游戏库设置页最下面）：实现在宿主 ios/diag.m（可不填的一句说明 → 打包上传、给短码）；本包弱定义缺省什么也不做
void s2a_shell_report_problem(void);
// 签名证书（游戏库设置「签名证书」，0.6.0）：实现在宿主 ios/cert_import.m。status = 现在手机上用来签游戏的证书（团队 · 来源，按界面语言），没有回空串；
//   p12 = 文件选择器选 .p12、问密码、存钥匙串；sidestore = 打开 SideStore 取它当前的签名证书（回调 s2arm://sidestore-cert）。本包弱定义：status 空串、另两个什么也不做
const char *s2a_shell_cert_status(void);
void s2a_shell_cert_p12(void);
void s2a_shell_cert_sidestore(void);
// 库卡片「需要签名证书」的主按钮：这台手机装了 SideStore 走 SideStore 取证书，否则开文件选择器选 .p12（宿主 ios/cert_import.m；弱缺省什么也不做）
void s2a_shell_cert_get(void);
/// Instant snapshot (0.6.0): 1 = the game has a complete snapshot to go back to (host ios/app.m; the shell's weak stub says 0).
int s2a_shell_snapshot_available(const char *game_id);
/// Starts the game back at its saved moment (asks first when the game saved after that moment). The shell's weak stub does nothing.
void s2a_shell_restore_snapshot(const char *game_id);
/// The folder of the game's complete snapshot into `out` (0), or -1: no snapshot, snapshots off, or `out` too small. The shell's weak stub says -1.
int s2a_shell_snapshot_dir(const char *game_id, char *out, unsigned long size);
/// Deletes the game's snapshot with its picture and manifest, freeing the space: 0 done, -1 not (or nothing to delete). Weak stub -1.
int s2a_shell_delete_snapshot(const char *game_id);

#ifdef __cplusplus
}
#endif

#endif
