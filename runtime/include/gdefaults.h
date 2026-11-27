// 逐款测过的缺省（11-27）：表 launchers/shared/game_defaults.v1.tsv → tools/game_defaults.py emit → runtime/include/s2a_game_defaults.h（编进宿主，单测核一致）。
// 优先级（全仓一条）：启动环境 > 玩家选过的（Mac pack/jobs/community.py launch_env / iOS ios/settings.m 只写选过的）> 逐款缺省（本模块，未设才写）> 定义表 default（宿主各处未设时的缺省）。
// 匹配：精确构建号优先于 *，同一层里精确平台优先于 *。值要的杠杆这款没有（画质 MetalFX / FSR 要走直连；帧率档非自动要能力清单有帧率来源）→ 不写、打黄，按全局缺省。
// 独立成文件、不放进 caps.c：caps.c 是宽屏 / 60 帧两项能力的实现哈希成员（tools/caps_policy.py IMPL），改它会让全部款这两项的验证结论失效
#ifndef S2A_GDEFAULTS_H
#define S2A_GDEFAULTS_H
#include <stddef.h>

typedef struct { const char *pid, *bid, *plat, *key, *value, *env, *env_value, *why; } s2a_game_default_row;   // 生成头的数组一行，表尾全 0

// 起局：模块目录（main.npdm、nro_tables.tsv / main.fixups.tsv 所在）取程序号 + 构建号，能力清单目录（s2a_caps.tsv 所在）判杠杆在不在。
//   能力清单之后调；未设对应环境变量才写
void s2a_game_defaults_apply(const char *module_dir, const char *caps_dir);
void s2a_game_defaults_apply_rows(const s2a_game_default_row *rows, const char *module_dir, const char *caps_dir);   // 单测给自己的行
// 进程内重启前（iOS s2a_ios_reload_graphics_settings）：撤掉本模块写进环境、值没被别处改过的变量
void s2a_game_defaults_reset(void);
// 设置页显示用：本款这一项（定义表 id，如 "docked"）的逐款缺省值，没有 → NULL
const char *s2a_game_default_value(const char *module_dir, const char *key);
const s2a_game_default_row *s2a_game_default_find(const s2a_game_default_row *rows, const char *pid, const char *bid, const char *plat, const char *key);
// 模块目录里的程序号（16 位大写十六进制）与 main 构建号（小写）；读不到程序号回 0
int s2a_game_defaults_peek(const char *dir, char *pid, size_t pn, char *bid, size_t bn);

#endif
