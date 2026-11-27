// 生成文件，别手改：tools/game_defaults.py emit 按 launchers/shared/game_defaults.v1.tsv + game_settings.v1.json 的 env 映射生成（11-27 逐款缺省）。
// 宿主 runtime/src/gdefaults.c s2a_game_defaults_apply 读；Mac 启动设置页读同一份表（tools/game_defaults.py lookup）。新鲜度由单测核（game_defaults.py check）
#pragma once
#include "gdefaults.h"   // s2a_game_default_row
static const s2a_game_default_row s2a_game_default_rows[] = {
    {0, 0, 0, 0, 0, 0, 0, 0}   // 表尾（空表也有这一行，C 不收零长数组）
};
