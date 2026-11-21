# #172 直连静态勘察与临时档

本工具只从已有合法解包输入生成临时数据，不安装、联网、构建、起局或修改运行时。
规则用 ../games/profile_guess.py（直连普查同一份；相对上游固定提交只改了 NSO 的 LZ4 解压，见 SOURCE.profile.json）；profile_write.py 的
EMPTY_TABLES / write_profile 原样摘出，许可见 ../LICENSE，来源/哈希见
SOURCE.profile.json。S2Arm 的包装层在两个调用点均传空宿主 hook 集，避免沿用
上游的 SDK 拦截策略。生成结果中的模块和内存建议仅供上游工具使用，
不会配置或替换 S2Arm 的 NPDM 加载器、服务层和内存管理。

## 调用

使用已有 Python + lz4。输入为 <产物根>/exefs/{main,main.npdm,...} 和
romfs/；也可给 --manifest <romfs_manifest.tsv>（无表头，每行：
/路径<TAB>字节数<TAB>前至多32字节十六进制）。只支持主程序明确导入
nvnBootstrapLoader、可校验的 NSO0/MOD0/DT_HASH 布局；其他布局明确拒绝，
不能将无静态信号当 NVN 支持。

    python3 graphics/nvn/tools/direct_profile.py generate <产物根> \
      --out <产物配置根> --version v65536 --display 1.1.0 --name <款名>
    bash pack/stage_direct_profile.sh <产物根> <产物配置根> --version v65536

版本取真实 content version；不指定时阶段只从当前 nx_unpack 的 unpack.tsv 的 update 数字读取。
空 update 不透露本体 CNMT 版本，此时必须显式给 --version。
CLI 不会把缺失版本编成 v0。显示版本缺失写 unknown，不声称知道它。

输出 <产物配置根>/<程序号>/：

- game.tsv：每个上游推导键附理由；仅本工具新生成的临时档，tex_flush_upload /
  tex_dirty_upload 缺省 on（现有 TSV 枚举，生成宏 DM_GAME_TEX_*_UPLOAD=1）。
  这是[直连线要求的默认策略](https://github.com/jhaizhou-ops/S2Arm/pull/220#issuecomment-6385496772)，
  **默认值，非静态推断**，不计入猜档准确率；其他无静态信号的开关仍留既有缺省。
- survey.json / survey.md：输入和规则指纹、模块导入/导出摘要、候选键和未知项。
  defaults 单列上述两键，origin=default-not-inferred；guesses 只保留上游静态候选。
  unknown 仍列出它们缺乏静态信号。defaults 记录生成时策略，后续人工调整以 game.tsv 为准。
- 上游空表模板：等待实际抽取，空表不表示 shader/PSO 覆盖通过。

完整目录生成后原子发布。原有 game.tsv 不覆盖；带匹配来源指纹的人工调整保留，
输入/版本变化、手工无来源档或不完整目录拒绝，提示选择新的输出位置。
策略版本和默认值也进入来源指纹 / 阶段缓存键；策略变化时自动阶段生成新键目录，
旧自动档不复用也不覆盖。显式指定旧目录或通过 DM_GAMES_DIR 提供旧自动档时拒绝，
保留旧档并提示新输出位置。登记档 / 外置手调档不套默认策略；来源仍匹配的生成档
人工改成 off 也逐字节保留，不擅自重新开启。
不得输出到源码或原始 exefs/romfs/aoc。阶段 stdout 是 JSON，禁止当 shell source 执行。
DM_GAMES_DIR 可取返回路径的父目录，既有 game.py 按其既定顺序查找。
默认优先仓库配置；本工具不写 DM_GAMES_FIRST，不抢占人工登记档。

## 逐键对比与验收

    python3 graphics/nvn/tools/direct_profile.py generate <动森产物根> \
      --out <动森对比配置根> --version <真实v版本>
    python3 graphics/nvn/tools/direct_profile.py compare \
      <动森对比配置根>/01006F8002326000 graphics/nvn/games/01006F8002326000

马车8同样操作，登记档目录 graphics/nvn/games/0100152000022000。

    S2A_PYTHON=<已有Python> bash tests/direct_profile_test.sh -v

对比包含两边每个显式键和重复行，数值按值比较；状态 match / different /
missing / generated_only。不把缺省值、无静态信号、合成题号的输出算猜对率。
真实两款静态输入尚未具备时，只交工具，不生成准确率表。

## 产物与登记档的硬约束

临时档只作为出包产物，放在产物根/资源包里，按输入指纹缓存，
**不提交进仓库 graphics/nvn/games/**。仓库 game.tsv 只保留上游带来的47款；
某款要转成登记档，走单独的 PR 并给出理由。本工具禁止把 --out 指到源码。
宿主不再内置每款表（10-25 删掉 gen_profiles.py / game_profiles.inc）：起局读随包的 shaders/direct/game.tsv，临时档与登记档同一条路；不把自动猜档变成逐款人工配置。

## 自动阶段与归属

[直连线方向及接缝确认](https://github.com/jhaizhou-ops/S2Arm/pull/220#pullrequestreview-5638196739)：

- 本卡实现 direct_lib.sh 的 game.py/DM_GAMES_DIR 选择；生成档随库进入
  shaders/direct/game.tsv。所选档所有文件内容摘要进入直连库阶段键。
- 运行时由直连线实现：程序号不在内置表时读取
  S2A_GAME_DATA/shaders/direct/game.tsv。host_adapt.m 的写集由直连线协调，
  当前 #214/wwmogu 正在改该文件，本卡不碰。
- 转正式前仍须真实动森、马车8的逐键差异表。真实起局由直连线验证，
  本卡没有运行成功/性能/画面验收结论。一级环境不完整时继续 Draft。

开发期 oneclick / refresh / ipa 的 S2A_DUAL 缺省为 1，所有款都走直连配置推导与出库，
不以有无手写档决定是否直连；推导或出库失败报红，不自动退成通用包。显式兼容模式
S2A_DUAL=0 不调用该直连阶段，具体准入限制以当前出包入口为准。

## 构建期接口与拒绝语义

    bash pack/stage_direct_profile.sh <款>
    bash pack/stage_direct_profile.sh <款> --require-consumer
    python3 pack/direct_profile_stage.py <产物根> --key
    python3 pack/direct_profile_stage.py <产物根> --selected

- 输入沿用 roots.sh 的现行产物根、exefs/romfs、内容版本元数据。
  oneclick 从实际 inspect 选择的 CNMT（最新 update 或 base）写
  direct-profile-input.json；双轨 seed 原样带入该构建期元数据与 unpack.tsv。
  只用 update 可兼容原有解包；没有版本时拒绝，不虚构 v0。
- roots.sh 的 clone/commit/replay/CAS 发布到新版本根：
  direct-profile/<阶段键>/<程序号>/game.tsv + survey/表模板；
  direct_profile.json 只记相对配置路径、阶段选择及 provisional/runtime_verified=false；
  .stage_direct_profile 是“静态候选已准备”键，不代替 .stage_direct。
- --key/--selected 不写产物根（只可能写下面的 RomFS 清单，在产物根之外）。配置键覆盖模块、RomFS名称/大小/头部、规则/读取器/schema、
  元数据和阶段代码。--selected 重新校验候选来源及相对路径，返回已选择档与其完整文件摘要。
  该 JSON 仅在构建期使用；运行时仍按直连线确认的既有 game.tsv 读取，没有新运行时协议。
- 登记档、外置人工档、生成档分别标识。经 DM_GAMES_DIR 找到的生成档仍必须
  校验当前输入/版本/元数据与来源指纹，保持 provisional；缺来源自动档拒绝。
  生成档进入产物时只复制已校验候选并保留人工调整。标准模块名 sdk/subsdk 坏魔数也拒绝，
  不把损坏文件当成“没有模块”。
- 双轨 refresh 在昂贵着色器阶段前准备配置；stage_direct 独立调用有同一前置检查。
  direct_lib 读取同一份选择的配置，副本写在私有缓存，出库把 game.tsv 随各表带上。
  坏输入、缺档、编译失败均非零；不切失败事务，不记直连成功键。
- --require-consumer 只要求建库输入可选取；不验证运行时或游戏。候选准备返回0、
  合成流程通过、库文件存在，均不等于真实GPU/起局/覆盖通过。

## RomFS 清单（11-03 晚扩成全出包通用：graphics/nvn/tools/romfs_list.py；格式 v1 → v2）

一键出包里原先 6–8 个步骤各自从头遍历 RomFS、逐个打开读头（火纹 27.4 万文件：本阶段单次 337 秒、GLSLC 判要不要 82 秒、
能力清单 326 秒）。现在仓库里遍历 RomFS 目录只有 `graphics/nvn/tools/romfs_list.py` 一处（`tools/romfs_walk_lint.py` 守，
`tests/romfs_walk_lint_test.sh` 跑），文件头（前 32 字节）同一份 RomFS 只读一次，按内容身份落盘清单，各阶段 / 各进程共用。

- 入口：`walk(目录)`（同 os.walk）、`scan(目录)`（盘点：scandir + lstat，不打开文件）、`heads(目录[, 清单目录])`（盘点 + 文件头，
  有对得上身份的清单就不读盘）、`listdir`；shell：`romfs_list.py has-ext / files0 / sizes`（见模块头注释）。
  每次调用都现盘点（身份要靠盘点核对；每个用到的进程仍各做一次只取文件信息的盘点，火纹约 2–5 秒），读头只在第一次。
- 清单目录：`direct_profile_stage.py ... --walk <目录>`；不给 = 环境变量 `S2A_ROMFS_WALK`（`off` = 不落盘），再不给 =
  `<产物根的上一级>/.romfs-walk/`（roots.sh 版本根 → `<S2A_ROOTS>/.romfs-walk/`）。只给名为 `romfs` 的目录落盘
  （追加内容 aoc/<序号> 的缺省位置会落进产物根里，不落盘）。direct_profile 的库函数（prepare / generate 命令）不给清单目录就照常现读。
- 文件名：`<标签>-<身份>.json`。标签 = 产物根目录名 `@` 之前（`t0100…@rx-1a2b3c4d` → `t0100…`）；身份 = 32 位小写十六进制。
- 身份（RomFS 内容身份）：全部条目按相对路径（/ 分隔，UTF-8 字节序）排序，每条「相对路径 \0 类型位 \0 大小:修改时间纳秒（普通文件才带）」
  逐行喂 sha256（前缀 `s2arm-romfs-walk-v2`），取前 32 位。不含 inode / ctime / 目录时间：clonefile 克隆的版本根身份不变；
  阶段改了 RomFS 文件 → 大小或修改时间变 → 身份变 → 重读。假设同 make / rsync 快速比对：内容变了修改时间必变。盘点有错 → 没有身份，不读不写清单。
- 格式：UTF-8 JSON（ensure_ascii）`{"format": "s2arm-romfs-walk-v2", "identity": <身份>, "head": 32, "entries": [[相对路径, 类型位, 大小, 修改时间纳秒, 前32字节十六进制|null, [errno, strerror, filename]|null], …]}`；
  类型位 1 软链 / 2 目录（不跟随）/ 4 普通文件（跟随软链）/ 8 目录（跟随，os.walk 的分法）。v1 清单不再认（重读一次另写 v2）。
- 读：格式、身份、条目集合与类型位全对上才用，否则当没有；写：临时文件 + os.replace 原子替换，同标签只留最近 2 份；写不了不报错（只是不提速）。
- 不进任何键：读清单与现读逐字节相同（tests/romfs_list_test.py、tests/direct_profile_test.py 钉住）；清单在仓库外、产物根外，出包读入记录（tools/stage_deps.py）不收。
- 跨平台：只用 os.scandir / os.replace / os.path.join，相对路径一律 /；Windows 照用。

