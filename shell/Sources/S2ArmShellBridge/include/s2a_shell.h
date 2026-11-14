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
int s2a_shell_install_game(const char *game_id);
int s2a_shell_install_progress(const char *game_id, int *done, int *total);
// 库起解包被拒（s2a_shell_install_game 返回 0）时为什么：1 另一款正在解（同时只解一款）/ 2 正在整理游戏目录（#569 迁移）/ 0 没有在等的事。
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
void s2a_shell_pick_game_data(const char *game_id);
// 宿主让库界面重判各款资源包（说明里「重新检查」后调）。库界面建好时登记；没登记时 s2a_shell_refresh 什么都不做
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

#ifdef __cplusplus
}
#endif

#endif
