// 启动上下文（LaunchContext，11-07 启动器线：iOS「一个 App 装多款游戏」的宿主侧第一刀）：一进程一款，起局前冻结「这一局是哪款、各个根在哪」。
//   来源二选一：
//   ① 上下文文件：环境变量 S2A_LAUNCH_CTX=<文件>（iOS 从桌面点开带不了环境，可写进 Documents/env.txt，构造期 99 就生效）。
//      文件每行「键<TAB>值」，# 起注释；值是绝对路径，或 @bundle/<相对>（可执行文件所在目录 = App 包）、@home/<相对>（$HOME），S2A_LAUNCH_CTX 本身同样可用这两个前缀。
//      键：version（必填，只认 1）、game_id（必填，[A-Za-z0-9._-]）、build_id、images（必填，镜像包）、module_dir（必填，随行表 + main.npdm 所在）、
//      caps_dir（缺省 = module_dir）、game_data（必填，资源包根）、docs（必填，本款文档根）、ryu_data（缺省 = <docs>/S2A/ryujinx）。
//      不认的键 = 报错（版本化，不静默吞）。host.log 本刀仍是进程级（os.c 构造期 100 就打开 $HOME/Documents/host.log），文件里不收 log_dir。
//      冻结时把 S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA / S2A_LAUNCH_GAME_ID 写进进程环境（覆盖），C# 服务层（Exports.cs / NxColdStart.cs）与
//      原生各读者照旧按这三个变量取根——冻结在 iOS 构造期（vawin.c 101）/ main 开头，早于 S2A_Init。
//   ② 没有 S2A_LAUNCH_CTX：兼容解析器按现行单款规则填同一个结构，且不写任何环境变量（现行单款包行为完全不变）：
//      模块目录 / 能力清单目录 = 可执行文件目录，镜像包 = <可执行文件目录>/Frameworks/S2AImages.dylib，
//      资源包根 = S2A_GAME_DATA（非空）否则 $HOME/Documents/资源包，文档根 = S2A_DOCS（非空）否则 $HOME/Documents，
//      Ryujinx 数据根 = S2A_RYU_DATA（非空）否则 $HOME/Documents/S2A/ryujinx，日志目录 = $HOME/Documents。
//   ③ 多款容器（11-07 P2 单款启动门，共用布局约定 v1）：App 包根（可执行文件目录）有 s2a_catalogue.json 且有 Games/ 目录、且没设 S2A_LAUNCH_CTX
//      （显式上下文文件优先，自动化局照用 ①）。构造期不冻结：玩家还没选游戏，s2a_launch_ctx_get() 在选之前回 NULL（error 说「还没选游戏」），
//      所以任何在 Play 之前读游戏相关值的读者都拿不到、不会读到别款或全局缺省；s2a_launch_ctx_select(gid) 按布局构造、校验、冻结、写环境：
//      模块目录 = 能力清单目录 = <App>/Games/<gid>，镜像包 = <App>/Frameworks/S2AImages-<gid>.dylib，文档根 = $HOME/Documents/games/<gid>，
//      资源包根 = <文档根>/资源包，Ryujinx 数据根 = <文档根>/S2A/ryujinx，host.log 目录仍是进程级 $HOME/Documents。
//      地址窗口在构造期由宿主对 Games/ 下每一款按单款同一套算法算需求、取最大占（vawin.c s2a_window_container_need；各款地址空间类型不一致 = 报红不占），
//      包里没有窗口表；envfile.c 构造期只读进程级 Documents/env.txt，
//      本款 <文档根>/env.txt 在 host_run 开头补读（s2a_launch_ctx_game_env_dir）。
//   Mac 宿主的模块目录仍取命令行 argv[1]（module_dir / images 只给 iOS 装载用）；文档 / 资源 / 数据根两端同一口径。
#ifndef S2A_LAUNCH_CTX_H
#define S2A_LAUNCH_CTX_H
#include <stddef.h>

enum { S2A_LCTX_COMPAT = 0, S2A_LCTX_FILE = 1, S2A_LCTX_CONTAINER = 2 };
#define S2A_LCTX_PATH 1024
typedef struct s2a_launch_ctx {
    int source;                       // S2A_LCTX_COMPAT / S2A_LCTX_FILE
    char ctx_path[S2A_LCTX_PATH];     // 上下文文件（兼容 = 空）
    char game_id[128], build_id[128]; // 兼容 = 空（单款包不需要）
    char bundle_dir[S2A_LCTX_PATH];   // 可执行文件目录（iOS = App 包）
    char images[S2A_LCTX_PATH];       // 外置镜像包（loader.c ext_pack）
    char module_dir[S2A_LCTX_PATH];   // 随行表 / main.npdm / programs（host_main.c、vawin.c）
    char caps_dir[S2A_LCTX_PATH];     // 能力清单 s2a_caps.tsv 所在（ios/settings.m）
    char game_data[S2A_LCTX_PATH];    // 资源包根（S2A_GAME_DATA）
    char ryu_data[S2A_LCTX_PATH];     // Ryujinx 数据根（S2A_RYU_DATA，存档在这下面）
    char docs[S2A_LCTX_PATH];         // 文档根（S2A_DOCS：wire / 补丁 / 档位梯子 / threads.txt / env.txt …）
    char log_dir[S2A_LCTX_PATH];      // host.log 所在（本刀进程级 = $HOME/Documents）
} s2a_launch_ctx;

// 纯解析（不碰进程环境之外的状态、不写环境）：exe_dir / home 由调用方给，ctx_path 为 NULL 或空 = 兼容解析。成功回 0；失败回 -1，why 写原因
int s2a_launch_ctx_resolve(s2a_launch_ctx *c, const char *exe_dir, const char *home, const char *ctx_path, char *why, size_t why_n);
// 多款容器（③）的纯解析：bundle_dir = App 包根，home = $HOME；校验 gid 字符（[A-Za-z0-9._-]、不以 . 开头）、gid 在 <包根>/s2a_catalogue.json 的 title_id 里、
//   Games/<gid>/ 是目录、Frameworks/S2AImages-<gid>.dylib 是文件。成功回 0（source = S2A_LCTX_CONTAINER）；失败回 -1，why 写原因，结构清空
int s2a_launch_ctx_resolve_game(s2a_launch_ctx *c, const char *bundle_dir, const char *home, const char *gid, char *why, size_t why_n);
// 包根是不是多款容器布局（有 s2a_catalogue.json 且有 Games/ 目录）
int s2a_launch_ctx_is_container_dir(const char *bundle_dir);
// 本进程是不是多款容器模式（③：容器布局且没设 S2A_LAUNCH_CTX）；只看包根与环境，不冻结、不读任何一款的文件，构造期可调
int s2a_launch_ctx_container(void);
// App 包根（可执行文件目录），不冻结；取不到为空串
const char *s2a_launch_ctx_bundle_dir(void);
// 多款容器选游戏（主线程，界面 Play 后、起宿主前）：按 ③ 构造本款上下文、校验、建本款文档根、冻结、写 S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA / S2A_LAUNCH_GAME_ID。
//   成功回 NULL，之后 s2a_launch_ctx_get() 回本款；失败回原因（不冻结，可换一款再选）。不是容器模式 / 本进程已选过 = 拒绝（一进程一款：请关掉 App 重新打开）
const char *s2a_launch_ctx_select(const char *gid);
// 上一次 s2a_launch_ctx_select 被拒的类别（给玩家看的话按它选，原文只进日志）：
//   APP_INCOMPLETE = 这款在 App 里不完整（不在清单、随行目录 / 镜像包不在）→ 在电脑上重新装到 iPhone；STORAGE = 建不了本款文档目录（多半存储满）；OTHER = 其余
enum { S2A_SELECT_OTHER = 0, S2A_SELECT_APP_INCOMPLETE = 1, S2A_SELECT_STORAGE = 2 };
int s2a_launch_ctx_select_kind(void);
// 进程内冻结一次（线程安全）：可执行文件目录取 _NSGetExecutablePath，home 取 $HOME（没有 = "."），文件取 S2A_LAUNCH_CTX。
//   文件来源时把四个根写进进程环境。失败回 NULL，原因见 s2a_launch_ctx_error()（宿主 main 开头据此停）。
//   多款容器模式：s2a_launch_ctx_select 成功之前一律回 NULL（error =「还没选游戏」），之后回本款
const s2a_launch_ctx *s2a_launch_ctx_get(void);
const char *s2a_launch_ctx_error(void);
// 一进程一款（照 NX2Apple dm_shell_start_game 的 started++）：第一次回 NULL，之后回拒绝原因。进程内同款重启（session.c s2a_host_rebuild）不经过这里
const char *s2a_launch_ctx_begin(void);
// 每款 env.txt 的目录：文件 / 容器来源且本款文档根 ≠ proc_docs（envfile.c 构造期读的进程文档根）时回本款 docs，host_run 开头据此补读 <docs>/env.txt
//   （s2a_envfile_apply，只补缺）；兼容来源 / 同一目录回 NULL（构造期已读过，不重复）
const char *s2a_launch_ctx_game_env_dir(const char *proc_docs);
// 构造期读 env.txt 用的进程级文档目录（envfile.c 定义；放这里不放 native.h：native.h 在出包 extract 阶段键里，改它 = 冷改动）
const char *s2a_envfile_process_docs(void);

#endif
