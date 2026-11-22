// 系统键盘桥接（游戏软键盘 → 苹果宿主自己的输入框）：服务层 services/S2A.Services/TextInput.cs 经 Native.cs Imports 直连下面两个导出
//   （公用核心 runtime/src/text_input.c 分发），平台实现启动时用 s2a_text_input_provide 登记：iOS ios/textinput.m、Mac 玩家前端
//   macos/textinput_mac.m（两端同一份约定）；没登记的平台（安卓、Mac 开发宿主）回 0。
//   json：{"header","subtitle","guide","initial","submit","mode":"numeric|ascii|full","min","max"}（UTF-8、以 0 结尾，调用期间有效）。
//   localPlayers 可选：有值时按顺序显示可选用户，空数组直接创建。确认返回从 0 起的列表位置，或「new:」加新用户名。
//   返回 1 = 已在主线程排上弹框，之后 cb 恰好调一次；0 = 不交互（无人值守局 s2a_unattended，验收开关 S2A_TEXT_INPUT_UI=1 除外，见 s2a_text_input_rules.h），调用方自己应答。
//   cb 在主线程调：status 1 = 确定（text = 玩家输入，UTF-8，回调期间有效），0 = 取消（text = NULL）。
//   cancel：收起这个 id 的框且不再回调（调用方自己按取消处理）；已答过 / 不认识的 id 忽略。任何线程可调。
#pragma once
#include <stdint.h>
typedef void (*s2a_text_input_cb)(int64_t id, int status, const char *text);
int s2a_host_text_input(int64_t id, const char *json, s2a_text_input_cb cb);
void s2a_host_text_input_cancel(int64_t id);
typedef int (*s2a_text_input_begin_fn)(int64_t id, const char *json, s2a_text_input_cb cb);
typedef void (*s2a_text_input_cancel_fn)(int64_t id);
void s2a_text_input_provide(s2a_text_input_begin_fn begin, s2a_text_input_cancel_fn cancel);
