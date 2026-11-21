# Windows 前三段 Python 编排（#1100 W1）

本入口新增于 `pack/orch/`，不接启动器、不改既有 bash、改写器、服务和图形工具。
生产入口不调用 bash；复用核心程序与 `pack/jobs/filelock.py`。

```powershell
git -c core.autocrlf=false clone <仓库地址> <独立检出目录>
cd <独立检出目录>
python -m pack.orch.refresh <款> --roots <私有产物根> --from-extract <已解包目录> --stages ""
python -m pack.orch.refresh <款> --roots <私有产物根> --stages rewrite,romfsidx,direct_profile
python -X utf8 tests/orch_roots_test.py -v
python -X utf8 tests/orch_stages_test.py -v
```

检出必须 `core.autocrlf=false`。文本用 UTF-8/LF；路径列表按宿主 `os.pathsep`，持久相对路径用 `/`。
保留 `S2A_ROOTS`、`S2A_PYTHON`/`S2A_PY`、`S2A_PREBUILT_TOOLS`、`DOTNET` 和阶段原有环境变量。
参数 `--stages` 是按 `rewrite → romfsidx → direct_profile` 排列的子集；空串只播种。
播种只取原始 exefs/romfs/systemdata/upd、元数据和显式启用的 AOC，不调解包器。

## 根事务与退路

版本目录 `<款>@<标签>`、工作目录 `.tmp`、现行指针文件 `<款>@现行`（普通文件，内容 = 现行版本目录名；`pack/orch/current.py`，不建链接）、`.root_*` 与 bash 根事务同布局。
阶段写入独立副本，提交持内核文件锁并核开工时的现行；未声明重放路径的并发冲突中止。
声明重放的阶段只替换自己的产物，保留新现行其它阶段产物，支持删除与 `!路径` 排除。
共享根只接受 main 上的干净源码，拒绝旧来源覆盖更新来源的同阶段；私有根供分支验证。
读取现行写进程起始时间钉，修剪留现行、上一版和仍在读取的版本。
Windows 核进程退出状态，避免已退出但句柄尚存的进程被当成活钉。

RomFS 收进 `.romfs_store/<款>/<身份>`；仅允许版本顶层的
`romfs → ../.romfs_store/<款>/<身份>`。其余重解析点/软链拒绝；绝不沿链接清除外部文件。
存储用 POSIX 去写位或 Windows 只读 DACL 封存；Windows 不用目录 readonly 属性冒充写保护。
源目录和产物根须由调用者独占管理；不宣称抵御同一用户的恶意并发改链进程。
RomFS 盘点仍经仓库唯一的 `graphics/nvn/tools/romfs_list.py`。

Windows ReFS 同卷文件走 `CopyFile2`，其它卷显式打印【黄】实拷；不调用 `shutil.copyfile`。
Mac 使用 clonefile；Linux 尝试 FICLONE，不支持时显式实拷。
软链失败时 Windows 显式报 junction 退路，用重解析点 API 创建；切现行用一次 rename，绝不先删旧现行。
不创建 Dev Drive、不改开发者模式、不下载工具。
API 依据：[CopyFile2 参数](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-copyfile2_extended_parameters)、
[按句柄重命名](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)。
调用该 API 不代表本机已测得 ReFS 实际块共享或速度收益。

## 核心调用与键合同

rewrite 直调 `pack/rewriter.py`/C 改写器及既有扫描、NRO、补丁、帧率工具；
romfsidx 直调 .NET 索引 DLL（可用既有预编 DLL）；direct_profile 直调 `pack/direct_profile_stage.py`。
构建失败不运行旧 DLL；.NET 构建加 `--no-restore`，缺依赖明确报环境未就绪，不触发联网还原。
每段成功提交独立版本，stdout 报阶段秒数/现行版本/键；版本内 `.orch_last.json` 保存对应记录。
`timing_scope=key+core+deps_before_commit`：包含判键、核心执行和依赖收集，到提交前截止，
不把事务提交/修剪耗时算进去；完整 CLI 墙钟由外层另测，避免写入已提交的不可变版本。
退出：0 成功、1 内部失败、3 内容缺口、75 必需工具或固定构建依赖未就绪。内容缺口不会写成功阶段戳。
这三个阶段不需要手机、签名材料、Metal、sidecar 或 anisette；不会为了环境缺口自动安装组件。

维护方 6635387480 明确：跨宿主对照都用源码自动构建的改写器，取消 `S2A_REWRITER_C`、不用 App bundled runtime，
现有 `rewriter.key()` 为 `c`。显式/预编工具仍保留 `c:<实际 exe SHA>`，不伪造相同身份。
须同时记录实际 Windows 编译器与 CMake 版本。

`.stage_*` 保留 bash 基础键字节。依赖清单保留 bash 入口、`stage_keyfiles.sh`、`stage_deps.py`、hook 和实际读入，
再加实际使用的 `pack/orch/` 源码记录。格式与排序均用既有 stage_deps 工具。
验收先剔除 `R:pack/orch/` 行与 Mac bash 清单逐字节比，再在同提交 Mac 上对全表 rehash，不能删实际输入强行对齐。
不存在完整新清单或任一依赖变动时禁止缓存命中。
维护方补充 6635717510：仓库内 `R:` 行按上述规则比；社区补丁的仓库外行只在比较时将两端根前缀换成 `<EXT>`，
后半路径与哈希仍须一致，原清单不改写。数据快照未给齐时按维护方规定的缺项口径单列，不能冒充已对拍。
根克隆缓存交接和分片盘点继续调用既有 Python helper，并保留 baseline 中的 clonedir 算法身份行。

## 当前验证边界

本地验证只用原创文件和已有测试生成的 NSO/NPDM。事务、字节键、依赖失效和工具错误回滚的分母见 PR 原始日志。
初轮链接/ACL实现错误日志保留，不拿 setup error 当有效先红后绿。
活钉回收用真实子进程触发过 1 个断言失败，修复后重测；另持有退出进程句柄测起始时间不能替代存活状态。
生成配置的 LF 断言先发现 `bf_want.tsv` 的 CRLF（1 断言失败），新编排只规范化新生成的 UTF-8 文本；
不修改原始输入、二进制或已存在的外部手工配置。撤修负控另报。
依赖清单也单独按原始字节测 LF，先发现子进程 stdout 的 CRLF（1 断言失败），协议返回值规范化后通过，原始日志仍保留。
维护方 8 行 RomFS 索引仓库依赖表已有原创根上的逐行集合判据；该项替代 .NET 核心边界，只验清单，不冒充索引字节。
现有 .NET 10.0.403 / runtime 10.0.14 已可复用。以清空包源的本地配置仅用已有 NuGet 缓存还原，
还原 6.338300 秒、构建 49.540832 秒均退出 0。真实 W1 索引阶段已在单个原创文件上生成 `S2ARFS01`，
独立核对文件数、路径、长度、镜像边界和不含原始 payload，重复调用缓存命中；不是游戏/Mac 字节对拍。
真实游戏三段产物、阶段键/依赖清单、维护方 Mac 同提交复验与三段耗时待维护方执行。
不把旧 Windows 临时驱动的 33/12/28 秒、30/30 对照，或 W5 签名实验当成本实现验收。
ReFS 实际克隆、完整自动源码改写构建和真实 .NET 索引运行若未实跑须单列缺跑，不用 mock 代替。
本机已有 MSVC 19.44 与 CMake 3.31.6。获用户许可下载并核验 Capstone 5.0.7/lz4 4.4.5 源码后，
自动源码构建于 `rewriter.c:26` 报 C4235（`__int128` 不受此编译器支持），16.678282 秒退出 1。
未改该共享源码，未把构建错误改写成成功；需对齐维护方 Windows 驱动使用的编译器再验证完整改写。

## 首轮真实游戏评审后的修订

维护方在 `9c210f247` 的 Windows/ReFS 首跑发现：播种成功，改写收尾 `stage_deps.py collect`
打开记录目录里的 `addr` 子目录而失败，索引/配置未跑到。记录目录协议只接受记录文件。
现将依赖 inbox 放在独立 `records/`，地址工具、索引列表、构建日志放在它的同级；
整份临时工作区建在产物根同卷，关闭时一起回收。没有改共享 collector 去跳过错误条目。
原创 NSO 经真实地址采集后检查 inbox、真实 collect 并写阶段戳：修前 1 断言失败，修后通过；撤修另报。

补丁输入按未改 `stage_rewrite.sh` 对照：`[code]` 原文/头部 build、按构建号的 FPS 表、
宽屏 EN/VR、社区补丁选择。新增四组有/无输入的基础键对照，私有源镜像存原创表，未改检出中的共用表。
已修正显式社区补丁列表漏合并 verified 默认条目的差异；`all`/`none` 仍保持原语义。
参数/复制检查的 C 边界使用明确替身，只证明输入传入，不能代替真实改写产物与 bash 的字节对拍。
完整 C 产物与命中补丁款的 Mac 对照仍待编译环境/维护方数据齐备。

维护方报告其编译环境为 clang 23.1.1（x86_64-pc-windows-msvc）、MSVC 14.44/SDK 10.0.22621、
CMake 4.4.3、Ninja 1.13.0，以 `CC` 指绝对编译器、`CMAKE_GENERATOR=Ninja` 自动源码构建，非本机读数。
本机新增编译器仍按用户下载许可处理，不安装或换用旧二进制。
维护方 `6637106132` 已将三项 pre 红归 Windows 自检环境卡，明确不挡本片评审；Mac 代跑尚待回执。
原本机红行与不完整 contrib 继续保留。`fix/win-newline-profile` 合入并验证源头写 LF 后，
再移除配置推导的临时 LF 转换，避免掩盖上游换行回归；本修订不越界修改这两个共用工具。

维护方 `6639248356` 在头 `aae99a168` 的 Windows/ReFS 复验报告：播种及三段退出0，
改写31.6秒（含首编）、索引31.2秒（含构建）、配置20.9秒；改写重跑3.0秒命中。
与 Mac 基准比较三阶段键一致，三段产物41/41字节相同（播种记录 `seed.txt` 单列）；
索引/配置依赖8/16行及社区5行相同。改写清单差异为维护方 Mac 记录器的23行假条目，
由维护方另修；不在本实现的实际清单里过滤条目。这些是维护方报告，不改写原本机缺跑。

同次 Mac 代跑的三项宿主检查均退出0，但新测试各有一处假设需修：
实拷用例现在显式让 clonefile/FICLONE 报跨卷退路，再核真实复制字节与黄提示；
不再假定 macOS 同卷克隆必失败。索引测试在缺还原资产时先核环境码75和事务回滚，
才明示 skip；有还原资产或非75错误仍报红，不自动还原。另用真实 SDK、
私有空 MSBuild 资产目录及 `--no-restore` 核 `NETSDK1004`→75、不执行旧DLL，
已还原路径继续独立核索引结构与缓存。两生产模块字节未改，尚待维护方 Mac 复跑新测试。


## W2 轻阶段

W2 写集由 issue1100/6641726711 明确为 stages.py、refresh.py、
新增 orch_stages_light_test.py 与本节；共用核心与 gfx 不改。
新增 sysdata、uilayout、aoc、caps、nacp、shaders 六段，直接调用原核心，
不经 bash。当前只有原创夹具的 Windows 验证，没有 W2 实款、Mac 对拍或
all-light 完整九段验收；本机原生 zstd/Clang 和布局共用适配仍是具名缺口。

- all-light 的串行依赖顺序为 rewrite、sysdata、uilayout、aoc、caps、
  romfsidx、nacp、direct_profile、shaders；布局改 RomFS 后才出索引，
  caps 读取改写产物，原 W1 三段相对顺序不变。
- CLI 只在调用需要 shaders 且外部没有指定时临时设置
  S2A_SHADER_LAZY=1，返回后恢复；明确指定非 LAZY 时拒绝。
  lazy 路径清除旧通用着色器，保留 direct/，按真实读入清单记键并跳过。
- caps 直接调用 caps_policy.py，一次 decide --both 输出两份清单；
  保留发布/测试口径、S2A_DUAL、完整原因和 UTF-8/LF 字节，
  实现文件的强信号哈希与本款验证账行按 bash 基础键规则处理。
- issue1100/6644224489 明确保留原语义：NACP 已有 ctl/control.nacp 就
  跳过，没有阶段键和 deps；缺时从本款原件补齐，工具成功却缺产物仍报红。
  sysdata/uilayout 保留原戳和原失效条件，不新增 deps。
- sysdata 使用 S2A_FONTS 或 S2A_APP_FONTS_DIRS（os.pathsep 分隔），
  保留真实时区、统一目录名大写，调用原 sysdata_need/synth 核心。
  缺时区只接受已存在且符合钉版内容摘要的产物；不下载 IANA、不编 zic。
  开源字体生成器在子进程禁用 urlopen；缺固定依赖或离线原料报75，不自动下载。
- uilayout 缺省宽2346，工具身份、覆盖摘要和阶段键沿用原字节公式。
  只从 seed.txt 指向的原版生成，只替换已有文件；撤掉的覆盖恢复原件，
  同事务清掉旧索引与索引戳。RomFS 先取自有副本，不写共享只读原件。
  生成前核原生 zstd1.5.7、CC/Clang 和 Windows 共用适配，并实调 C 编码器
  拒绝字面量退路；已有覆盖缓存可直接核内容应用，不需要重新编译。
- AOC 保留候选绝对路径、大小、纳秒 mtime/ctime、inode 的宿主身份键；
  Windows ctime 是创建身份，不要求跨宿主同键。只对拍产品和原规则 deps。
  成功同级缓存原子发布，失败逐份探测/兜底，部分缺失具名记入 aoc.log；
  全部失败保留旧追加内容、不写新戳，下一次仍可尝试。不设 S2A_HDD_READ。
  nx_unpack 只接受显式工具、当前源码内容缓存，或已有资产的 --no-restore
  构建；缺环境报75，不取旧工具顶构建失败，不自动下载 NuGet 包。
- 本机 Python3.13.5 扩展21方法21过、0失败/错误/跳过，22.109秒。
  使用真实系统数据合成器和 caps 核心；布局覆盖缓存、NACP/AOC 解包边界
  使用原创数据和明确替身，不证明真实 NSZ/XCZ 解包或布局压缩字节一致。
  新四项撤修各1方法1断言失败、0错误/跳过：留旧索引、已有NACP仍重做、
  AOC 漏ctime/inode、忽略字体变更。此前7方法/5撤修保留原源码绑定，
  不算当前全套重跑。原 main 缺 all-light 只算缺功能基线，不算机制负控。
- 既有三阶段兼容性在正常权限、现有固定 Python 依赖下20方法：
  18过、1失败、1缺还原资产 skip，34.360秒。失败项选择了系统 .NET9；
  只将项目已有 .NET10 放在测试进程 PATH 首位后，该项定向1/1通过，
  1.119秒。原受限 Git Bash/SDK 路径错误日志保留，不改既有测试或断言。
- 经用户明确许可，原生 zstd 1.5.7 与 LLVM 21.1.8 已官方下载、核验并
  放入项目隔离目录本地测试，系统 PATH 不变；这不授权其它依赖下载。
  Yaz0 的 CC/Windows .exe 共用适配仍按维护方明确合入回执核 main；
  不用 Cygwin zstd 或字面量压缩退路冒充同字节验收。

PR1509 的布局复验修订（6652716900）：工具身份按顺序纳入 ui_lyt.py、
yaz0enc.c、romfs_list.py、nxfmt.py 与 yaz0dec.c 的源码字节；解码模块或
现编 C 解码源码改变时，覆盖目录和阶段键一起失效，不复用原坏缓存。
生成日志含 Traceback、Python Error/Exception 类，或非零退出但没有明确
内容诊断时，报环境75，不发布覆盖缓存、不推进现行版本，下一次重试。
只有逐项明确“内容缺口”且有报错汇总的失败才允许采用成功覆盖；现有
生成器逐项捕获后打印异常类的失败不属于该类。不改共用生成器或解包器。
本机 Windows/Python3.13.5：三个新增方法在修前共8处断言失败，修后通过；
分别撤回依赖闭包和崩溃拒绝发布后，各1方法4处断言失败，恢复后各1/1。
经现有壳入口24方法24过、0失败/错误/跳过，22.230秒（外层22.655秒）。
新增生成边界使用会实际导入原创模块的私有 Python 小生成器与原创布局，
不证明真实编解码、实款六段或 Mac 对拍；维护方实款发现与本机复现分开。

轻阶段测试由 `bash tests/orch_stages_light_test.sh` 接入现有门禁；
可用 `S2A_PY` 指定现有 Python，包装入口以 `PYTHONUTF8=1` 传递 UTF-8
模式并原样返回测试退出码。入口声明覆盖两个编排模块与 Python 测试，
不用手动白名单；共用路由器、扫描器及测试断言不改。
现行接线扫描器不解析 Python `-X utf8` 的带值参数，因此包装入口使用
环境变量传递该模式。新增壳文件须进入 Git 索引，路由才会把它作为入口。
在本片原头与 main `ca2faedb2` 的私有合并树上，WSL 原生临时目录扫描
577 支测试：修前490接线、86手动、1漏；修后491接线、86手动、0漏。
仅撤掉实际调用后恢复1漏，恢复调用后0漏；三条改动路径的路由均选中壳入口。
Windows Python3.13.5 经该壳实际运行21方法，21过、0失败/错误/跳过，
测试报告19.651秒（外层启动与回收合计20.311秒）。Python断言及编排生产源码
未变；这组接线验证不代替真实游戏六段或 Mac 跨平台产物验收。
