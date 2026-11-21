# C 改写器（J08 / #184）

按 `main@4e1660c4114e0e9de42177735f9b98def332373f` 的 `patch_nso.py` 移植，提供静态 C 库和命令行。10-31 起只有这一份改写器（维护者 拍板删 Python 改写器 `patch_nso.py`：双实现互相对拍是路径依赖）：`pack/stage_rewrite.sh`、Mac 局、安卓出包都用它；正确性靠门禁里的金样字节 + 进局验证，有意改变改写产物时在提交里写明并更新金样。

在 #230 / #238 的基址求值之上，已同步 Python `e71052ee7` 的 SDK 地址区削减 / `aregion` 返回门，以及 `7630cf892` 的拷贝环求值（#101、#290 前置）。验证基线为 `main@eef695373`。open / adr 两种跳转表继续先线性回看，失败后检查到达定义：具体定义可为同块 `adrp + add` 或 `mov xB,xS` 拷贝。共用已访问定义集合，环不提供新值，全部到达常量必须恰好一个；未知或异值仍报缺口。新拷贝链上限与 Python 一致为 16 层，定义顺序和完整原因链保持一致。宽屏 `asp` 继续接受 Wd / Xd，两条指令须同宽、同目标寄存器。

SDK 节点区按两次常量装载、加法、字段存储和节点大小识别，将约 1 GB 改为 62 MB；邻近对齐常量组将大区域对齐从 1 GB 改为 32 MB。通过 MOD0 动态符号表限定 `VammManager::AllocateAddressRegion` 范围，只给尚未改写的普通 `ret` 接返回门。两项均按程序结构识别，无逐款地址表；不命中特征或没有对应导出时不修改。CLI 的 `S2A_SDK_ADDR_CUT=0` 同时关闭削减与返回门，缺省开启，与 Python 一致。

## 构建

需要 CMake 3.18+、Clang/GCC（C11，使用 128 位整数保存 GP / SIMD / 标志位的独立寄存器集合）；Windows 使用支持该类型的 Clang/MinGW 工具链。已验证 Mac 构建、Alpine arm64 的 GCC 原生构建，以及 Mac 上的 Windows x86_64 交叉构建与 Wine 兼容层运行。真实 Windows 宿主构建 / 运行仍未验证，不能用交叉编译或 Wine 代替；实际读数和限制见 [PR #192](https://github.com/jhaizhou-ops/S2Arm/pull/192)。

显式联网准备依赖（Python 3.12+ 只用于下载解压，不参与 C 库或 C CLI 运行）：

```sh
python3 runtime/rewriter/prepare_deps.py build/rewriter-deps
cmake -S runtime/rewriter -B build/rewriter-c \
  -DS2A_REWRITER_DEPS="$PWD/build/rewriter-deps" -DCMAKE_BUILD_TYPE=Release
cmake --build build/rewriter-c --parallel 4
```

### 出包入口（#416 第 1 件）

准备好上述固定依赖后，`pack/stage_rewrite.sh` 缺省通过 `pack/rewriter.py` 离线编译本树宿主 C 命令行并复用。缓存位于 `build/rewriter-cli/`，按实际源码内容、宿主和编译选项区分；并发构建用独立临时目录，完整可执行文件原子发布。缺依赖或编译失败就报红，不自动下载、不自动改走 Python。

完整固定依赖按顺序查找：`S2A_REWRITER_DEPS` → 本树 `build/rewriter-deps` → 运行区 `<S2A_RUN_ROOT>/s2arm/deps/rewriter-deps`，取第一个同时有钉版 Capstone / LZ4 源码的目录；都没有才报红，报错列出实际查过的路径。从源码构建时一键准备 `python3 launchers/macos/prepare_build.py` 会下载到本树 `build/rewriter-deps`。运行区那份适合同一台机器上多棵工作树共用，仍需各机安装 CMake 3.18+ 和宿主 C 编译器。

```sh
# 显式准备一次固定依赖（此命令联网；出包与测试不调用）
python3 runtime/rewriter/prepare_deps.py build/rewriter-deps
# 也可显式准备到运行区共享位置（目录尚不存在时执行）
python3 runtime/rewriter/prepare_deps.py "$S2A_RUN_ROOT/s2arm/deps/rewriter-deps"
# 后续出包缺省走 C；也可复用别处已准备的源码依赖
S2A_REWRITER_DEPS=<固定依赖目录> bash pack/stage_rewrite.sh <款>
# 调用者明确选择自己已验证的宿主命令行（不在此模式自动重编）
S2A_REWRITER_C=<C可执行文件> bash pack/stage_rewrite.sh <款>
```

`S2A_REWRITER` 只认 `c`（设成别的直接报红：Python 改写器已删）；`S2A_REWRITER_CACHE` 可指定可写缓存目录。改写器编译输入指纹（`pack/rewriter.py source`）与显式 C 二进制 SHA-256 进入阶段键，只算键和同键跳过均不构建 C；本目录的说明文档不进键。宽屏扫描、GPU 驱动识别等出包步骤仍用 Python。改写器继承目标、自旋和 SDK 削减开关，失败不提交新版产物根。

C 已包含 #290 的 FRONT 容量重选（见下节）。维护方须在最新 PR 头对九款主程序（含王国之泪、暗黑3）经实际出包阶段复核全部产物 SHA-256 与改写耗时。用户机器的启动器分发由维护方另跟：App 内置编译好的 `s2a-rewrite` 并通过 `S2A_REWRITER_C` 接入，不要求用户机器准备源码依赖；该分发接入不在 #416 本次改动范围内。

维护方可用下列入口逐款跑完整改写阶段（不是只跑 CLI）：工具先克隆固定输入到私有根、清掉改写戳，用 C 改写器跑完整阶段，记每模块五种必需产物和可选宽屏表的 SHA-256、阶段墙钟、日志与失败现场；`--baseline` 给一份先前的 `report.json`，逐款比全部产物哈希（有意改变产物时在提交里写明并换基线）。C 首次构建时间单列，不混入阶段读数；源根不修改。输出包含游戏派生内容，全部留在本机、不上传。

```sh
"$S2A_PY" tests/pack_rewrite_compare.py --output <新的私有目录> --baseline <先前的 report.json> \
  botw=<塞尔达现行根> d3=<暗黑3现行根> <其余款名=现行根> ...
```

构建与测试不自动下载。离线机器可提前复制已准备的依赖目录；固定版本、压缩包哈希和许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。生成目录放 `build/` 或调用方指定的外置磁盘，不进仓库。

```sh
# S2A_TARGET 支持 apple / ios / macos / android，默认 apple
build/rewriter-c/s2a-rewrite <NSO> <输出目录> <模块名> [宽屏候选表]
S2A_TARGET=android S2A_REWRITE_SPIN=1 build/rewriter-c/s2a-rewrite <NSO> <输出目录> <模块名>
```

输出同名的 `patched.bin`、`fixups.tsv`、`gates.tsv`、`sites.tsv`、`gaps.tsv` 和有宽屏点时的 `widen.tsv`。缺口返回 3、删旧映像、列全缺口；输入 / I/O / 编码致命错误返回 1。库入口见 [rewriter.h](rewriter.h)：请求和日志流借用到调用结束；不同线程用独立上下文及输出目录；库不读环境变量、不启动子进程、不依赖 Python。CLI 读取环境变量后传给库。

原 `s2a_rewrite_request` 布局和 `s2a_rewrite_files` 符号不变，旧入口采用 SDK 削减开启的默认值。需要显式关闭时，使用 `s2a_rewrite_files_with_options(request, options, log)` 并传 `s2a_rewrite_options { .sdk_addr_cut = 0 }`；`options == NULL` 采用默认值。选项借用到调用结束、存入各请求独立上下文，库仍不读取进程环境。新增入口及 CLI 与库的契约请原生层和调用方共同审查。

FAR 补丁区容量不足、重选也放不下（需要超过 32 MiB）时保留 `gaps.tsv`，输出 `PFRW ... fatal=1` 和补丁长度 / FRONT / 可用容量 / 所需 FRONT，删除同名旧 `patched.bin` 后返回 1，不会先创建空映像。容量不足但放得下时，先自动重选布局，见下节。

### 自旋取锁补 acquire（11-04，1-2-Switch 作业环崩溃）

游戏自旋锁取锁只用 `ldxr`/`stxr`、出环后不加屏障就读锁内数据时，ARMv8 允许这些读提前到取锁之前；Apple M 系列乱序激进，同一作业被两条线程各弹出一次（1-2-Switch：不改 6 局全崩，把取锁 `ldxr` 改 `ldaxr` 后 3 局 0 崩）。改写器在分析前按指令形态扫代码段（不看地址）：`ldxr` → 8 条内同基址 `stxr`/`stlxr` → 3 条内 `cbnz` 状态寄存器回跳；存的不是零寄存器、值在环外备好；环内按读到的值回头等；出环后（跟无条件 `b` 至多 3 跳、12 条内）先碰普通读而不是 `dmb`/`dsb`/`isb`/`ldar`/`ldapr`。命中只置 bit 15（`ldxr` → `ldaxr`，等长原地）。日志打「自旋取锁补 acquire」行，统计键 `acq_upgrade`。缺省开；`S2A_REWRITE_ACQ=0`（库：`s2a_rewrite_options.acq_off = 1`）关。单测 `bash tests/rewrite_acq_test.sh`。

### 独占存补 release（11-05，极品飞车热力追踪重制版出图停住）

游戏先用普通 `str` 写好节点内容，再用 `ldxp`/`stxp`（或 `ldxr`/`stxr`）把节点挂上无锁链头，中间不加屏障也不用 `stlxp`。ARMv8 允许别的核先看到链头、后看到节点内容；本机 M5 Max 实测约 0.2% 的发布被读到旧内容（`stlxp` 0 次）。极品飞车作业系统的续作链因此跑了上一轮的回调，主线程等的信号量没人释放。改写器在分析前按指令形态扫代码段（不看地址）：独占存（`stxr`/`stxrb`/`stxrh`/`stxp`，o0 = 0；不含 CASP）且前 16 条内有独占取 → 只置 bit 15（`stxr*` → `stlxr*`、`stxp` → `stlxp`，等长原地）。前面没有独占取的字不动。日志打「独占存补 release」行，统计键 `rel_upgrade`。缺省开；`S2A_REWRITE_REL=0`（库：`s2a_rewrite_options.rel_off = 1`）关，关时产物与改前逐字节相同。单测 `bash tests/rewrite_rel_test.sh`。

### 补丁包 [code] 段（正确性类补丁，补丁包_v1设计.md 12.11；一次成功线 11-02）

`S2A_CODE_PATCH=<补丁目录>/<程序号>/patch.tsv`、`S2A_CODE_BUILD=<main 构建号 32 位小写>`（库接口为请求的 `code_patch` / `code_build`；`pack/stage_rewrite.sh` 在 `S2A_PATCH_DIR` 下有本款补丁时自动给）。只读 `[code]` 段，行：`<模块> <偏移> orig=<原字节> new=<新字节，同长> [sig=<前>|<后>]`（字节按内存顺序的十六进制，sig 可 `??` 通配，点本身不写进 sig，整指令对齐）。文件头 `build` 与 `S2A_CODE_BUILD` 相同按偏移打，先核原字节；不同则在本模块代码段按「前 sig + 原字节 + 后 sig」扫，唯一命中才打。分析前直接改字（不走社区补丁的双路 + 槽）；跳过的行记黄进改写日志，全部结果写 `<输出目录>/<模块>.code_patch.tsv`。单测 `bash tests/code_patch_test.sh`。

### FAR 容量重选（#290；C 版 10-25 同步）

第一轮沿用原来的保守 FRONT，已成功的输入不改布局。补丁容量不足时（11-17 起首轮有 GAP 也一样，#1476），按 `align64KiB(补丁字节数 + 16KiB)` 扩展 FRONT，从原 NSO 完整重做分析和编码。每轮保留全部 B、ADRP、compact 表头编码范围检查及已成功的自旋回边；容量候选严格增大，上限 127 MiB（10-30 起不再写死 32 MiB：够不够得着由每条 B 的编码检查判，越射程即整轮改用下面的双补丁岛）。

重试前删除旧 `patched.bin`，中间轮不发布产物或 PFRW。首轮的 GAP 带到重试轮照常降级（返回 3、照出产物）；重试后 GAP 比触发重试那轮多时（新增的是编码缺口），保留完整明细，输出唯一 `fatal=1`，明确报告「重选后 B / ADRP 超出跳转范围」、text 末尾和新 FRONT，删除旧映像后返回 1。超过布局限额或丢失自旋回边也明确失败；最终容量失败复用 #268 的摘要与清理。Python 通过私有 `runpy` 入口建立全新上下文，从外部以其他 `run_name` 执行也进入同一驱动，成功以 `SystemExit(0)` 结束。

C 已同步 SDK 地址削减 / aregion、mov 成环不动点和自动重选：C 内部按轮重建整个改写上下文（`attempt`），跨轮只带 FRONT 与成功的 (自旋头, 回边)，合成 FAR 模块回归 `python3 tests/rewrite_front_synth_test.py`（缺省用 `pack/rewriter.py c-path` 的 C 命令行）：125 MiB text，首轮 0x200000 不够，自动重选到 0x270000，五种产物与金样同。真实依据与限制见 FRONT 容量重选。

定向回归以实现前独立冻结的完整产物哈希为期望：

```sh
"$S2A_PY" tests/rewrite_front_real_test.py \
  --manifest <私有用例.json> --output <尚不存在的私有输出目录>
```

JSON 顶层为 `schemaVersion: 1`、非空 `cases` 数组。每例填写唯一 `name`（小写字母 / 数字 / 下划线 / 连字符）、真实 `input` 与 `sha256`、`target`、`spin`、`need`、`patchOff`、`retries`、`spins`、完整输出文件名到 SHA-256 的 `artifacts`；有宽屏表时填 `widen` / `widenSha256`，可用 `runName` 检查外部 runpy 入口。工具复用 `rewrite_benchmark.py` 的哈希与完整产物检查，保留日志并核对唯一 PFRW、布局、自旋区及重试次数；私有路径和二进制不提交。

Android arm64（NDK 路径由调用方传入）：

```sh
cmake -S runtime/rewriter -B build/rewriter-android \
  -DS2A_REWRITER_DEPS="$PWD/build/rewriter-deps" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DCMAKE_BUILD_TYPE=Release
cmake --build build/rewriter-android --parallel 4
```

### 双补丁岛（原生层 10-30）

补丁区与代码之间都是 B（±128 MiB）。原布局只有一个岛：近布局在映像（含 bss、键页）之后，FAR 在基址前 FRONT 处。前岛（基址前）与后岛（映像之后：近布局即原补丁区位置，FAR 为键页后 `align64KiB(IMAGE_SIZE)`）在任何布局下都是候选：

- **何时启用**：原布局本轮出现 B 越射程（任何改写单元，含可选的自旋区和社区补丁 p 行），或 FAR 前岛需求超 127 MiB，就整轮按双岛重做；`128 MiB − text − 1 MiB < 1 MiB`（text 超约 127 MiB）的 FAR 模块直接双岛。没越射程的模块产物逐字节不变。
- **选岛**：每个改写单元（窗口、相对 / 尾调用跳转表、改写点、aregion、宽屏点、帧率 bl_rec / veneer、社区补丁 p 行、自旋区）按自己的地址选：低于 `SPLIT = 后岛偏移 / 2` 先试前岛，否则先试后岛；当前岛 B 越射程就撤掉本单元、换另一个岛再生成一次。切岛 = 当前岛与另一个岛整体交换，块内 `here()` / 回填都跟着当前岛。
- **前岛容量**：双岛首轮 FRONT = 1 MiB，放不下按 `align64KiB(前岛字节数 + 16KiB)` 整轮重做（双岛下前岛超容量那轮的缺口不作数，上限 127 MiB）。
- **两岛都够不着**：必改点里能在信号里按原语义模拟的（`mrs tpidr_el0` / `mrs tpidrro_el0` / `msr tpidr_el0` / `mrs ctr_el0`，x18 目的除外）原地改成 `brk #(0x8000 + 序号)`（≤ 0x2000 个，0xA000 留给远跳，避开 macOS 截走的 0xB000–0xBFFF），装载器在 SIGTRAP 里模拟后 pc += 4（`runtime/src/traps.c`，每点计命中、收局打一行）；可选的自旋区不改写，但不许无声：日志打一行【红】汇总（几处、地址列表），表头 `SPIN_UNREACHED` 记数；其余单元（svc、x18 类、窗口、跳转表等）照旧记缺口（退出码 3），消息带 `B range frm … to … off …`。
- **远跳**（出包线 10-31，Minecraft [128, 144) MiB 那段 6325 个 x18 改写点）：x18 窗口 / 改写点两岛都越射程（且不是上一条能在信号里模拟的种类）时，远跳模式重做一次：单元照常生成进岛，越射程的 B（原代码进岛那一跳 = 入口，岛里跳回原代码 = 出口）写成 `brk #0xA000`，fixups 表头 `# FAR_JUMPS n` 后跟 n 行 `# FAR <从> <到> <E|X>`（相对基址，有符号）；装载器排序后在 SIGTRAP 里按 pc 二分、把 pc 设到 <到>（信号返回不受 ±128 MiB 射程限制，块语义就是普通 x18 块），入口计命中，收局打一行（`runtime/src/traps.c`）。每执行一次单元多两次陷入；只给 x18 两类（块里没有 BL）
- **表头**（只在双岛写，在 `IMAGE_SIZE / FILE_IMAGE_LEN` 之后、`KEY_*_IDX` 之前）：`# PATCH2_OFF`（另一个岛相对基址的偏移，有符号十六进制；近布局为 `−(FRONT + LOAD_BIAS)`，FAR 为后岛偏移）、`# PATCH2_LEN`（字节）、`# TRAP_SITES`（十进制）、`# SPIN_UNREACHED`（十进制），随后 `TRAP_SITES` 行 `# TRAP\t<偏移>\t<种类>\t<寄存器>\t<原字>`，序号即出现顺序。`PATCH_OFF` 仍是原布局那个岛。单岛也可能有兜底点：36 位老 SDK 写死的可随机区 / 栈区（`sdk_as36_ranges`，#1503，种类 `as_aslr_lo` / `as_aslr_hi` / `as_stack_lo` / `as_stack_hi`）认出时，单岛在同一位置只写 `# TRAP_SITES` 与随后的 `# TRAP` 行；没有兜底点时单岛表头不变。
- **patched.bin**：原布局的文件（近布局 = 映像 + 键页 + 补丁区；FAR = 映像前段 `FILE_IMAGE_LEN` + 前岛）之后，再接另一个岛的 `PATCH2_LEN` 字节。装载器（Mac / iOS / 安卓三条映射路径）按表头把它放到 `基址 + PATCH2_OFF` 并封只读可执行，岛与映像之间的空隙不可访问；iOS 内嵌节多一段 `__sw<名>x2`（`ios/embed.py`，16K 圆整）。门表返回点按「在任一岛内」核。
- **合成回归**：`bash tests/rewrite_islands_test.sh`（近布局越线 → 前岛接住低地址单元；text > 128 MiB → 双岛 + brk + 自旋报红；产物与金样逐字节比，期望按布局公式手算）。

### Android 真机内改写与宿主 C 对拍（#416 第 2 件）

先等待两份 `cmake --build` 都成功退出，再执行设备测试。两端必须使用同一份本树源码与上述固定依赖；交叉编译目录不能代替真机执行。构建、输入和产物可以放在外置磁盘，测试目录必须位于仓库外且尚不存在。

```sh
# 先按上面的命令分别完成宿主 / Android arm64、API 28 的 Release 构建。
# 显式选择一台已授权 USB 调试的 arm64 真机（系统 API >= 28）。
adb devices -l
python3 tests/rewrite_android_compare.py \
  --host <宿主构建目录>/s2a-rewrite \
  --android <Android构建目录>/s2a-rewrite \
  --serial <本机adb设备标识> \
  --output <仓库外尚不存在的私有目录> \
  <自备的NSO主程序main>
```

工具固定 `S2A_TARGET=android S2A_REWRITE_SPIN=0 S2A_SDK_ADDR_CUT=1`，清除宿主继承的其他 `S2A_*`，设备进程使用独立环境。先为输入和两份 CLI 建私有快照，验证 Android ELF64/AArch64 头以及传到设备的输入 / CLI 的 SHA-256，再在设备独有的 `/data/local/tmp/s2arm-rewriter-*` 目录直接运行 C CLI。整个过程不安装 APK、不运行游戏、不下载依赖，不需要手机上有 Python。

两端退出码必须为 0，且各自只有一条 `PFRW`、`gaps=0 fatal=0`；拉回完整输出后检查五份必需文件、可选文件集、所有文件 SHA-256 和实际字节。空文件也必须存在。exFAT 上只跳过有对应数据文件、AppleDouble 头与条目边界合法的 `._` 元数据，其他文件仍计入比较。失败返回非零，保存已取得的退出码和失败阶段，不能把两端都缺文件当作通过。

`report.json` 记录源码 / 输入 / CLI 哈希、设备型号 / Android 版本、环境、退出码、PFRW、完整产物哈希与本次耗时；不含设备序列号和个人路径。原始日志、快照、`commands.json`（含私有路径 / 设备标识）和 `device-directory.txt` 只留本地，设备目录也保留。发布前只审阅并摘取报告中的读数，不提交这些私有文件。超时同样失败并保留设备目录，不能据此认定远端进程已退出。

离线验证比较判据（不连接设备、不替代真机验收）：

```sh
S2A_PY=<Python3解释器> bash tests/rewrite_android_compare_test.sh
```

vivo X Fold / Android 13 的真实五份产物对拍与完整复现命令见 [Android 设备验证](ANDROID_VALIDATION.md)。本项证明设备内 C 改写，不证明生成的映像可以在 Android 上起局，也不改苹果出包路径。

## 无游戏输入的检查

测试 Python 按 `tools/rewriter-requirements.txt` 准备。CLT 的 `xcrun clang` / `otool` 可汇编合成 NSO，不需要游戏文件。各单测缺省用 `pack/rewriter.py c-path` 的 C 命令行，取不到就报红；REW 可另指一个 C 可执行文件。

```sh
export S2A_PY=<安装固定依赖的Python>
for t in target corpus compact excl_head_jt_adr jt_bound jt_open jt_cfg_base spin; do
  bash "tests/rewrite_${t}_test.sh" || exit 1
done
"$S2A_PY" tests/rewrite_c_test.py
```

原有 fixture 与判据保持不变。逐字节金样（`tests/fixtures/rewrite_golden/`，比对助手 `tests/rewrite_golden.py`；10-31 由 Python 改写器与 C 改写器同产物时生成）覆盖原 20 例语料加 49 例栈 / 系统 / 自旋 / 宽屏、寄存器词边界与到达定义用例，各跑 Apple/Android × spin 开/关 × NSO 压缩/未压缩，比较全部输出文件及退出码。有意改变改写产物时 `S2A_GOLDEN_WRITE=1` 重写金样，并在提交里写明原因。词边界用例覆盖 `x18/w18` 与含 `0x18` 的立即数共存、无 x18 的 `0x18b2`，以及独占窗口里带 / 不带 x18 的条件分支指向 `0x18a0`；另手算退出码与 x18 需求数，防止两边同时报缺口却被当成通过。自旋回边分组用例覆盖候选头顺序与回边出现顺序不同、同头多条回边的情况，并手算核对自旋头和两条回边，防止只保留第一条回边。到达定义用例在 open / adr 两种形态下分别检查同值、异值、非 add、缺 adrp、部分定义和全未定义，成功时另核对手算分派目标；宽屏用例接受两种 Xd 常量，拒绝双向混宽和寄存器不一致。新增拷贝用例分别验证多源同值 / 异值、未知源、四条 / 五条与十六条 / 十七条拷贝边界、32 位拷贝拒绝、拷贝后源被改写与循环拷贝；另用 65 个到达值检查超过 600 字节的完整诊断，不截断原因。可在命令末尾传用例名前缀只跑一部分。它打印的合成语料耗时包含进程启动，不代表九款主程序性能。

C ABI 并发、重复调用与畸形输入检查：

```sh
cmake -S runtime/rewriter -B build/rewriter-c -DS2A_REWRITER_API_TEST=ON
cmake --build build/rewriter-c --parallel 4
"$S2A_PY" tests/rewrite_c_api_test.py
```

可另建 ASan/UBSan 构建目录，传 `-DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'` 与 `-DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined'`，并设置 `UBSAN_OPTIONS=halt_on_error=1 ASAN_OPTIONS=halt_on_error=1`。Mac 的 LeakSanitizer 不可用，不声称完成泄漏检查。

SDK 特征 / 动态符号范围金样及 C API 开关隔离检查：

```sh
REW=<C可执行文件> "$S2A_PY" tests/rewrite_sdk_c_test.py
```

16 个自有合成输入共 80 组合，包含 MOVZ / ORR、STR / STP、最大距离边界、错误特征、距离限制、缺少对齐常量、导出缺失 / 未定义 / 零值 / 零长度 / 超长 / 越界，以及 Apple/Android、压缩、自旋和 SDK 开关。独立核对改后常量、门的来源及恢复寄存器后返回的指令编码；完整输出再和金样比较。原入口与显式关闭选项双线程各调用 8 次，与各自配置的金样比较，验证库不读进程环境。

本轮真实输入仅为异界锁链 v1.0.1 的 main / sdk：默认 SDK 开启，Apple/Android × spin 0/1 共 8 组全部产物相同。SDK 只命中 1 个 `aregion` 门，未命中节点区及对齐削减特征；这两项的本轮验证来自上述自有合成输入，不能把该 SDK 对拍写成真实削减命中。没有完整出包、游戏局或真机读数。

## 维护方代跑

1. 九款金样：`S2A_PY=<固定依赖Python> bash tests/rewrite_apple_golden_test.sh`；由 `pack/rewriter.py c-path` 取得出包 C 命令行对照原表，失败就报红，不更新金样掩盖差异。输入缺省 `~/.s2arm/data/<款>/exefs/main`，独立数据根可用 `S2A_REWRITE_GOLDEN_DIR` 指定；`REW` 只能追加候选实现，不能替代必跑的 C。
2. 九款及审核要求的王国之泪、暗黑3：使用同一批私有主程序，Apple/Android × spin 开/关各跑一次：

   ```sh
   "$S2A_PY" tests/rewrite_benchmark.py --rew "$REW" --target apple --spin 0 <主程序1> <主程序2> ...
   ```

   脚本只跑 C，记全部输出文件名与 SHA-256（包括存在时的 `widen.tsv`）和耗时；真实输入的正确性由 `tests/rewrite_front_real_test.py` 对冻结哈希核。模块名缺省 `main`；对 SDK 或 subsdk 用 `--module sdk` / `--module subsdk0`；`--widen <widen_sites.tsv>` 交入已有宽屏候选表。失败（含超时）时返回非零，保留私有目录；`--output <尚不存在的目录>` 可保留成功结果；单个进程缺省超时 600 秒（`--timeout`）。原始产物和日志可能含游戏内容，只在本地检查。

3. 在维护方工具链跑 `bash tools/contrib_check.sh`、全门禁和苹果出包回归。合成金样不能代替真实主程序及设备验证。
4. 原生执行语义改动由原生层线审查。

### 代码段内嵌数据（#108）

有的游戏把大量数据放进代码段，线性扫描会把数据当指令，变成海量缺口并误改数据。第一轮扫描后，只有 hvc / smc / dcps 这类用户态不可能执行的指令达到 64 条才启用第二轮：真实代码 = `.eh_frame` 函数范围 + 动态符号的函数 + 从它们出发的直接分支闭包，范围外当数据，不改写也不算缺口。这些指令不足九成在范围外时，说明范围不可信，不启用，缺口照报。没有这类指令的模块不进第二轮，产物逐字节不变。日志行「内嵌数据判定」写明是否启用、各来源字节数、排除字节数和缺口变化。

## 分配器初始化闸（sdk_sainit，11-20）

游戏把「地址传空、尺寸几十 GiB」交给 `nn::mem::StandardAllocator` 初始化（`Initialize(void*, ulong[, bool])`、构造函数 C1 / C2 同参），SDK 在别名区划一整块地址、用到才提交。宿主窗口放不下这块时，块的顶端伸出窗口走远端代执行，游戏卡在开头。

- **改写器**：在这 6 个导出的入口各挂一个门（门类复用 `aregion`、参数 1，门表格式不变、不升 HOST_ABI）。补丁岛：`str x0,[sp,#-16]!` → `mov x0,#0` → 进门 → `ldr x0,[sp],#16` → 原入口第一条 → `b 入口+4`。进门前清零 x0，是让旧宿主的 aregion 处理看到 w0 = 0 什么都不做（旧 App 配新产物不出错）。原第一条只收与位置无关、只碰栈或寄存器的几类（提示类、立即数 / 寄存器运算、以 sp 为基址的存取），不收就黄字跳过、计 `sdk_sainit_skip`，不算缺口（构造函数先写对象字段、再尾调用已挂门的 Initialize）。统计 `sdk_sainit`。契约：`tests/rewrite_sainit_test.py`。
- **宿主**：`runtime/src/svc_mem.c s2a_sainit_gate` 只在 x1（地址）为空时看 x2（尺寸），按 `runtime/src/layout.c s2a_sainit_size` 定压后的尺寸：别名区整段在窗口里，或这块连前后保护页的末端在窗口里 → 原样（与今天逐字节相同）；否则压到「窗口末 − 块起点 − 余量」按 GiB 向下取整，余量 = 应用池 + 8 KiB（其余地址区提交总量受应用池封顶；留不够的部分照旧落远端，只慢不错），压出来不到 1 GiB 就不压。日志「分配器预留从 X MB 压到 Y MB」。
- **地址表**：`tools/addr_need.py static_claim` 另记静态大区是不是经分配器初始化申请的，是就在 `addr_need.tsv` 多一行「大区来源 分配器初始化」（只有这类款的表变，其余逐字节同前；旧宿主忽略这行）。宿主据此在闸门压得了时不弹「地址空间不够」页。
- **老游戏**：`pack/jobs/rewrite_refresh.py` 只把「地址表认出开局大区、sdk 挂上了闸门」的款算受影响，玩家对这一款操作时换 sdk 产物并重出地址表；其余款不换。
