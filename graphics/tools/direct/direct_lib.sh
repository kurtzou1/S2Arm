#!/bin/bash
# 直连着色器库出包（双轨 §12.3，着色器线 10-24）：游戏原始输入 → 两边抽取合并 → 直连离线链出直连库，布局照直连离线链原样。
# 用法：bash graphics/tools/direct/direct_lib.sh <产物根（含 romfs/ exefs/main）> <输出目录>
#   输出目录 = <资源包>/shaders/direct：b-<链版本>/lib.idx + lib.NNN.pak（iOS 库容器，lib_pack.py；内含各键 _b.metallib / _b.json / _bf / _bv / _bg*）、shader_map.tsv（并集）、shader_facts.tsv、shader_pairs.tsv、bf_want.tsv、
#   pso_manifest.tsv（经 pack/stage_direct.sh 时只有配置档维护过的，零配置的由 pack/stage_direct_seed.sh 另写）、c1_full.tsv、cb_extent.tsv、keys.tsv（实际出成的键，一行一个，并集里出库失败的不列）；另出 ps_inputs.tsv（片元键 → 读的 user(locn)，兜底现编补顶点输出用）与 key_map.tsv（S2Arm 键 → 直连键，pack/stage_direct.sh 出 seen 用的客体代码表时换键）与 direct_lib.json（读数）。
# 步骤：① 直连抽取 shader_split：在配置档 graphics/nvn/games/<程序号> 的副本里重出包目录与着色器表（原配置档不动）② S2Arm nxsh_extract
#   ③ merge_extract：S2Arm 独有键补进直连包目录与表 ④ dmsh_build（经 dmsh_par 按键分片成 J 个进程、再经 own_compilers：本机编译器，链版本不变）出 Mac + iOS 库；Mac 那份只留缓存，给 c1_full / cb_extent 用
#   ⑤ 收表、出 keys.tsv。
# 缓存：S2A_DIRECT_CACHE（缺省 <运行根>/s2arm/cache/direct/<程序号>）只放两样：内容寻址仓 store/（translator/dmsh_store.py：256 个分片文件，
#   着色器翻译结果、批库、变体、Metal 编译结果都在里面，整份出库结束只留本次用到的条目）与上次出库的日志 logs/。10-31 出包线深修：原先按键落小文件
#   （mac/b-<链>、ios/b-<链> 两代 + cas/shader、index、variant…），马车8 一款 66 万个，出库时盘每秒上万次读写、CPU 闲着。
# 逐键产物只在本次出库的临时目录里（Mac 库 / work 写 <名>.stage.<进程号>，输出目录写 <输出>.stage.<进程号>）：出完核验齐全、打成容器，
#   只把容器原子换进输出目录（renamex_np RENAME_SWAP）；中途停下输出目录逐字节不动，临时目录下次起跑时按进程号已不在清掉
# S2A_DIRECT_TARGETS=ios：只出 iOS 库（转成 DMSH_NO_MAC_LIB=1）：Mac 的 metal -c / metallib 一律不跑，Mac 那份只有 _b.metal / _b.json（ps_inputs / c1_full / cb_extent 照读）；
#   不设 = 两份照出。运行时不读 Mac 那份（10-25 直连线核实：Mac 局 / Mac 版 App 读的都是随包的 shaders/direct，gate-host 暗黑2 Mac 直连局映射的就是输出目录的库），
#   Mac 那份只是出库中间产物；pack/stage_direct.sh 出 iOS 包缺省设 ios，出 Mac 版 App（S2A_PACK_PLAT=macos，含普查 / 快测的 Mac 局）缺省设 mac（10-31：只出 Mac 库、发布它，
#   原先两份都出、iOS 那份没有读者，Metal 编译白做一倍：怪猎崛起 4921 秒里 2490 秒是 iOS）
# S2A_DIRECT_TARGETS=android（#783，出安卓包：pack/stage_direct.sh 在 S2A_PACK_PLAT=android 时缺省设它，发布目标 S2A_DIRECT_PUBLISH=android）：只出离线 Vulkan 库
#   <输出目录>/b-<链>-vk/lib.idx + lib.NNN.pak（与苹果的 b-<链>/ 同层、同一种 LibPack 容器；键与 Metal 相同，每键 _b.json 种类 1 + _b.spv 种类 52，头部记 Vulkan 侧指纹；
#   graphics/tools/direct/vklib 的 dsh_vklib 出），不编 Metal、不出 Metal 专用的变体请求表 / 管线种子表。
#   抽取只用产物根里抽取阶段的 extract/（pack/refresh.sh 安卓分支在直连库之前跑 pack/stage_extract.sh：兄弟平台根克隆来的键相同就跳过，没有才抽），这里不另抽，没有就按内容缺口退 3；Vulkan / OpenGL 款安卓运行时自己编，退 0 不出库
# 配置由 game.py dir 选择，支持既有 DM_GAMES_DIR/DM_GAMES_FIRST；缺档明确失败。
set -u
PD=-P; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PD=-L;; esac   # Windows 工作区走短根联接，-P 会展开回长路径
ROOT=$(cd "${1:?产物根}" && pwd $PD) || exit 1; OUT=${2:?输出目录}
R=$(cd "$(dirname "$0")/../../.." && pwd); NX=$R/graphics/nvn
# Windows（Git Bash / MSYS）：pwd 给的是 /r/... 写法，只有命令行参数会被自动转成 R:/...，经环境变量或文件交给 Windows 原生 Python 的不会转
#   （11-04 Windows 出包机旷野之息：shader_split 读 /r/.../exefs/main 报找不到路径）。产物根、输出目录、仓库路径统一换成 R:/... 混合写法（bash 自己也认）
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ROOT=$(cygpath -m "$ROOT"); OUT=$(cygpath -m "$OUT"); R=$(cygpath -m "$R"); NX=$R/graphics/nvn;; esac
PY=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PY=${PY:-$(command -v python3)}
say() { echo "[直连库] $*"; }
# 降级汇总（v0.3.1 拿不准不停）：离线翻译剔掉的支数写进产物根 degrade.direct.tsv（格式同 degrade.rewrite.tsv：阶段 / 类别 / 处数 / 玩家提示 / 说明；
#   出包作业收尾读它上屏、诊断包收它）。本阶段开头删掉上一版的，有降级再写
DEG=$ROOT/degrade.direct.tsv; rm -f "$DEG"
deg() { [ -s "$DEG" ] || printf '# 阶段\t类别\t处数\t玩家提示\t说明\n' > "$DEG"; printf 'direct\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$DEG"; }
# Windows 出包机（#1100 W6）：没有 Homebrew 的 spirv-cross，PATH 上没有就用仓库同一份源码（= 链锁版本）现编命令行、放进 PATH（translator/spvc_inproc.py cli）
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)
  export PYTHONUTF8=1   # Windows 的 Python 缺省按系统代码页（GBK）写标准输出，中文 / 🟢 写不出就抛错；日志一律 UTF-8，同 Mac
  command -v spirv-cross > /dev/null || { SC=$("$PY" "$NX/../../translator/spvc_inproc.py" cli) && SC=$(cygpath -u "$SC") || { say "🔴 Windows 上编不出 spirv-cross 命令行（translator/spvc_inproc.py cli）"; exit 1; }; PATH="${SC%/*}:$PATH"; export PATH; };;
esac
# 失败分类（10-25 维护者，同抽取阶段的原则）：退出 3 = 内容缺口（某支着色器翻不了、本款用了直连还没实现的结构），本款这次出不了直连库，打「🟡 直连缺口：<类别> <计数>」，
#   refresh 走通用、285 款普查按它归类派单；能部分出库的照常出（退 0，末行黄、列没出成的类别与计数）。其余非 0 = 基础设施出错（缺文件、工具 / 编译器起不来、
#   脚本异常、超时、写盘失败）与判不清的，报红退 1；本机这台出包机做不了的退 75（环境缺件）。gap <日志> <步骤> 只认确定的内容缺口形状，认出就打黄退 3，认不出就返回（调用方照旧报红）：
#   · 有 Python 异常栈 → 判不清（脚本异常）
#   · NVN 出库（dmsh_build.py）一支着色器结构不支持就整份停住（在链版本清单里、改了九款整份重出，所以在这里认）：「[RED] <16 位键>: vertex shader of shader type 0 without a VertexB part」
#     「[RED] <16 位键>: compute code area」「[RED] vertex shader without a main0 main function」
#   · Vulkan 离线翻译（vk_shaders.py / graphics/tools/spirv_msl.py 的 red）一支翻不了就整份停住，消息带那支的路径：「[RED] /<路径>: <原因>」（没有部分出库的设计，整款走通用）
gap() {
  local l k why
  grep -aq '^Traceback ' "$1" && return 0
  l=$(grep -aE '^\[RED\] ([0-9a-f]{16}: (vertex shader of shader type 0 without a VertexB part|compute code area)|vertex shader without a main0 main function)' "$1" | tail -1)
  [ -n "$l" ] || { l=$(grep -a '^\[RED\] ' "$1" | tail -1); [[ "$l" =~ ^\[RED\]\ /[^:]+:\ .+ ]] || l=; }
  [ -n "$l" ] || return 0
  l=${l#\[RED\] }; why=${l#*: }; [ "$why" = "$l" ] && k=- || k=${l%%: *}; why=${why%% (*}
  say "🟡 直连缺口：$2 翻不了 1 支（${k##*/}：${why:0:120}），现有出库不支持部分出库，本款这次走通用"
  exit 3
}
# 并行路数与进度（10-25 维护者「多核要适配机器的核心数」「能看到进度么」；接口是交付线的出包提速框架）：各子步骤统一用 J 路——
#   J / S2A_CPU_BAKE = 本阶段分到的路数（tools/cores.sh 定、pack/stage_direct.sh 按账再定），都没给才用 S2A_JOBS / 本机核数；导出给下面每个工具
#   （shader_split / nxsh_extract / dmsh_build / c1_guard / cb_extent 都按 J 开路数）。
#   进度：出包进度协议（tools/progress.sh prog_tick、Python 侧 tools/progress.py Ticker，写 S2A_PROGRESS）：阶段「直连库」= 第几步 / 5 步，各步内「直连库·<步骤>」= 完成 / 总数；
#   日志里每步另打一行「[直连库] 第 k/5 步 …」给人看
export J=${J:-${S2A_CPU_BAKE:-${S2A_JOBS:-$(getconf _NPROCESSORS_ONLN)}}}
source "$R/tools/progress.sh"
PS=0; prog() { PS=$((PS + 1)); say "第 ${PS}/5 步 $*"; prog_tick 直连库 $((PS - 1)) 5; }
[ -d "$ROOT/romfs" ] && [ -f "$ROOT/exefs/main" ] || { say "🔴 $ROOT 缺 romfs/ 或 exefs/main"; exit 1; }
source "$R/pack/srcs.sh"; TID=$(prog_id "$ROOT"); [ -n "$TID" ] || { say "🔴 取不到程序号"; exit 1; }
# Vulkan 款（main 直接导入 vk*：哈迪斯、超级马力欧银河 1 / 2）：直连走直连层的 Vulkan 层（graphics/nvn/gfx/vk/hle_vk.m），着色器是 RomFS 里的 SPIR-V，
#   出包时用 vk_shaders.py（spirv-cross）离线翻成一个库：<输出目录>/vk/vk_shaders.metallib + vk_shaders.tsv（运行时 <DM_MSL_DIR>/vk/，DM_MSL_DIR = shaders/direct）。
#   不要配置档（排在配置档检查之前），按魔数扫 RomFS + 追加内容；Mac 那份留缓存。keys.tsv 列 SPIR-V 键（hle_vk 按 SPIR-V 哈希查）；运行时生成 SPIR-V 的款（银河）出包不起局，只出表头、全部设备首遇现编
API=$("$PY" "$NX/tools/gfx_api.py" "$ROOT/exefs" "$ROOT/romfs") || { say "🔴 判图形接口失败（graphics/nvn/tools/gfx_api.py）：${API#*	}"; exit 1; }   # 出包分流的唯一判法
if [ "${S2A_DIRECT_TARGETS:-}" = android ] && { [ "${API%%	*}" = vulkan ] || [ "${API%%	*}" = gl ]; }; then say "🟡 ${TID} 是 ${API%%	*} 款：着色器是游戏自带的 SPIR-V / GLSL，安卓运行时自己编，不出直连库"; exit 0; fi
if [ "${API%%	*}" = vulkan ]; then
  command -v spirv-cross > /dev/null || { say "🔴 Vulkan 款要 spirv-cross（brew install spirv-cross）"; exit 1; }
  C=${S2A_DIRECT_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/direct/$TID}; mkdir -p "$C" "$OUT"; s=$SECONDS
  # 出库期间在缓存目录放占用标记 vk.stage.<本进程号>（清理器 stage_live 认：进程活着就不删这款缓存）；主流程的 work.stage.$$ 到不了这条分支（11-07）
  : > "$C/vk.stage.$$"; trap 'rm -f "$C/vk.stage.$$"' EXIT
  DIRS=("$ROOT/romfs"); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] && DIRS+=("${a%/}"); done
  # RomFS / 追加内容里一个 SPIR-V 都没有 = 游戏运行时才生成（银河 1 / 2）
  # 文件头取 RomFS 清单（graphics/nvn/tools/romfs_list.py：仓库里唯一的 RomFS 遍历，同一份 RomFS 各阶段只读一次头）；打不开的文件同原先跳过
  if ! "$PY" - "$R" "${DIRS[@]}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics', 'nvn', 'tools'))
import romfs_list
for d in sys.argv[2:]:
    for e in romfs_list.heads(d).files():
        if e.error is None and e.head[:4] == b'\x03\x02\x23\x07': sys.exit(0)
sys.exit(1)
PY
  then NOSPV=1; else NOSPV=0; fi
  # 跑局学到的 SPIR-V（设备首遇现编时存下、收局拉回 pso_seed/<程序号>/vk_spv/，经跑局知识快照 vk_spv/）：照 RomFS 一起翻进离线库，下一包不再首遇现编（11-05）
  KN=${S2A_RUN_KNOWLEDGE:-}
  if [ -z "$KN" ]; then KN=$C/knowledge
    "$PY" "$R/graphics/tools/direct/run_knowledge.py" "$KN" "$TID" > "$C/run_knowledge.log" 2>&1 || { say "🔴 跑局知识快照出不来（$C/run_knowledge.log）"; tail -3 "$C/run_knowledge.log"; exit 1; }
  fi
  NRT=$(ls "$KN/vk_spv" 2> /dev/null | grep -c '\.spv$'); [ "${NRT:-0}" = 0 ] || DIRS+=("$KN/vk_spv")
  if [ "$NOSPV" = 1 ] && [ "${NRT:-0}" = 0 ]; then
    # 出包不起局（11-05 维护者：出包从不允许起一局游戏；原先在 Mac 上直连起宿主 60 秒抓 SPIR-V、Windows 上退 75 交回 Mac）：只出表头、没有库，keys.tsv 为空，
    #   全部交设备首遇现编（hle_vk.m → vk_rt.inc 后台编、编好持久化，下次开机直接读），同 OpenGL 款离线 0 支的做法；Mac、Windows 同一条路
    "$PY" "$NX/../../translator/vk_shaders.py" --header-only "$C/vkmac" --ios "$OUT" > "$C/vk_shaders.log" 2>&1 || { say "🔴 Vulkan 表头没写出（$C/vk_shaders.log）"; tail -3 "$C/vk_shaders.log"; exit 1; }
    [ -s "$OUT/vk/vk_shaders.tsv" ] || { say "🔴 没出 $OUT/vk/vk_shaders.tsv"; exit 1; }
    : > "$OUT/keys.tsv"
    say "🟡 Vulkan 款 ${TID}：RomFS / 追加内容里没有 SPIR-V（游戏运行时生成），跑局知识里也没有，出包不起局，只出表头、全部设备首遇现编（vk/vk_shaders.tsv），$((SECONDS - s)) 秒"
    exit 0
  fi
  [ "${NRT:-0}" = 0 ] || say "Vulkan 款 ${TID}：跑局知识里有设备现编存下的 SPIR-V ${NRT} 支，照 RomFS 一起翻进离线库"
  "$PY" "$R/tools/nostall.py" --watch "$C/vkmac" --watch "$OUT" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/vk_shaders.py" "${DIRS[@]}" "$C/vkmac" --ios "$OUT" > "$C/vk_shaders.log" 2>&1; vrc=$?
  [ "$vrc" = 0 ] || { [ "$vrc" = 1 ] && gap "$C/vk_shaders.log" "Vulkan 着色器"; say "🔴 Vulkan 着色器离线翻译失败 rc=${vrc}（$C/vk_shaders.log）"; tail -3 "$C/vk_shaders.log"; exit 1; }
  # 单支翻不了 / Metal 编不过的已剔掉（vk_shaders.py，v0.3.1），汇总行「Vulkan 汇总：成功 N、失败 M」：M > 0 记降级；N = 0 只出表头、全部设备首遇现编
  VOK=$(sed -n 's/^Vulkan 汇总：成功 \([0-9]*\)、失败 \([0-9]*\).*/\1 \2/p' "$C/vk_shaders.log" | tail -1)
  [ "${VOK##* }" -gt 0 ] 2> /dev/null && deg vk_failed "${VOK##* }" "这款有 ${VOK##* } 个着色器没能提前编好，用到时会现场编译、可能卡一下，遇到请反馈" "Vulkan 离线翻译剔掉的支（$C/vk_shaders.log）"
  if [ "${VOK%% *}" = 0 ]; then
    [ -s "$OUT/vk/vk_shaders.tsv" ] || { say "🔴 没出 $OUT/vk/vk_shaders.tsv"; exit 1; }
    : > "$OUT/keys.tsv"; say "🟡 Vulkan 款 ${TID}：离线一支没编成（失败 ${VOK##* }），只出表头、全部设备首遇现编，$((SECONDS - s)) 秒"; exit 0
  fi
  # 两个目标各剔各的（审计 P1-176）：别的目标编成、这个目标（$OUT = iPhone）一支不剩时只有表头没有库，照出、keys.tsv 空
  [ -s "$OUT/vk/vk_shaders.tsv" ] || { say "🔴 没出 $OUT/vk/vk_shaders.tsv"; exit 1; }
  grep -v '^#' "$OUT/vk/vk_shaders.tsv" | cut -f1 | sort -u > "$OUT/keys.tsv"
  [ ! -s "$OUT/keys.tsv" ] || [ -s "$OUT/vk/vk_shaders.metallib" ] || { say "🔴 表里有 $(wc -l < "$OUT/keys.tsv" | tr -d ' ') 支却没出 $OUT/vk/vk_shaders.metallib"; exit 1; }
  say "Vulkan 款 ${TID}：SPIR-V $(wc -l < "$OUT/keys.tsv" | tr -d ' ') 支 → vk/vk_shaders.metallib $(du -h "$OUT/vk/vk_shaders.metallib" | cut -f1)，$((SECONDS - s)) 秒（$(tail -1 "$C/vk_shaders.log" | cut -c1-120)）"
  exit 0
fi
# OpenGL 款（main 导入 eglCreateWindowSurface、取 glShaderSource、带 GLSL：数码宝贝物语）：直连走 GL 层（graphics/nvn/gfx/gl），着色器是游戏运行时编的 GLSL 源码，
#   出包时用 gl_shaders.py（glslang → SPIR-V → spirv-cross）把 RomFS（含 MVGL 归档）、追加内容与 main 里能找到的源码离线翻成一个库：<输出目录>/gl/gl_shaders.metallib + .tsv
#   （运行时 <DM_MSL_DIR>/gl/）。不要配置档；keys.tsv 列 GLSL 键（GL 层按源码哈希查）；运行时才拼出来的源码：宿主首遇现场翻译（gl_prog.m），DM_GL_CAPTURE 抓的目录可并进下次出包
if [ "${API%%	*}" = gl ]; then
  # 与 gl_shaders.py 的 os.environ.get 一致：只有未设置 GLSLANG 才回退 PATH，空值不能回退。
  type -P -- "${GLSLANG-glslangValidator}" > /dev/null || { say "🔴 OpenGL 款要 glslangValidator（brew install glslang spirv-cross）"; exit 1; }
  command -v spirv-cross > /dev/null || { say "🔴 OpenGL 款要 spirv-cross（brew install glslang spirv-cross）"; exit 1; }
  C=${S2A_DIRECT_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/direct/$TID}; mkdir -p "$C" "$OUT"; s=$SECONDS
  : > "$C/gl.stage.$$"; trap 'rm -f "$C/gl.stage.$$"' EXIT   # 同 Vulkan 分支：出库期间的占用标记
  INS=("$ROOT/romfs" "$ROOT/exefs/main"); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] && INS+=("${a%/}"); done
  "$PY" "$R/tools/nostall.py" --watch "$C/glmac" --watch "$OUT" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/gl_shaders.py" "${INS[@]}" "$C/glmac" --ios "$OUT" > "$C/gl_shaders.log" 2>&1; grc=$?
  # gl_shaders.py 翻成的照写库、有翻不了的退 1，汇总行「GLSL 汇总：成功 N、失败 M」：N > 0 = 部分出库（照常出、末行黄）；成功 0 或别的退出码 = 判不清，报红
  GOK=$(sed -n 's/^GLSL 汇总：成功 \([0-9]*\)、失败 \([0-9]*\).*/\1 \2/p' "$C/gl_shaders.log" | tail -1); GMISS=0
  if [ "$grc" = 0 ] || { [ "$grc" = 1 ] && [ "${GOK%% *}" -gt 0 ] 2> /dev/null; }; then GMISS=${GOK##* }; [ "$GMISS" -ge 0 ] 2> /dev/null || GMISS=0
  elif [ "$grc" != 0 ]; then say "🔴 GLSL 着色器离线翻译失败 rc=${grc}（$C/gl_shaders.log）"; tail -3 "$C/gl_shaders.log"; exit 1; fi
  # 离线一支没有（成功 0、失败 0：GameMaker 等引擎运行时才拼 GLSL，RomFS / main 里没有成形源码，或只有没有 main 的拼接片段、gl_shaders.py 记跳过，#518）：照出，只有表头、没有库，keys.tsv 为空；
  #   宿主库里没有的源码首遇时现场翻译（gl_prog.m 运行时兜底，按源码哈希缓存），这里记一行黄
  [ "$GMISS" -gt 0 ] && deg gl_failed "$GMISS" "这款有 ${GMISS} 个着色器没能提前编好，用到时会现场编译、可能卡一下，遇到请反馈" "GLSL 离线翻译译不过的支（$C/gl_shaders.log）"
  if [ "$grc" = 0 ] && [ "${GOK%% *}" = 0 ]; then   # 成功 0：离线一支没有（失败 0）或一支都没译成（失败 > 0，v0.3.1 起照出空表）
    [ -s "$OUT/gl/gl_shaders.tsv" ] || { say "🔴 没出 $OUT/gl/gl_shaders.tsv"; exit 1; }
    : > "$OUT/keys.tsv"
    if [ "${GMISS:-0}" -gt 0 ]; then say "🟡 OpenGL 款 ${TID}：离线一支没编成（编译失败 ${GMISS} 支），只出表头、全部运行时首遇现编（gl/gl_shaders.tsv），$((SECONDS - s)) 秒"
    else say "🟡 OpenGL 款 ${TID}：离线 0 支 GLSL（运行时拼源码的引擎；没有 main 的片段记跳过），只出表头、全部运行时首遇现编（gl/gl_shaders.tsv），$((SECONDS - s)) 秒（$(tail -1 "$C/gl_shaders.log" | cut -c1-120)）"; fi
    exit 0
  fi
  [ -s "$OUT/gl/gl_shaders.tsv" ] || { say "🔴 没出 $OUT/gl/gl_shaders.tsv"; exit 1; }
  grep -v '^#' "$OUT/gl/gl_shaders.tsv" | cut -f1 | sort -u > "$OUT/keys.tsv"
  [ ! -s "$OUT/keys.tsv" ] || [ -s "$OUT/gl/gl_shaders.metallib" ] || { say "🔴 表里有 $(wc -l < "$OUT/keys.tsv" | tr -d ' ') 支却没出 $OUT/gl/gl_shaders.metallib"; exit 1; }   # 同 Vulkan：这个目标一支不剩时只有表头
  say "$([ "$GMISS" = 0 ] || echo "🟡 直连缺口（部分出库）：GLSL 翻不了 ${GMISS} 支（运行时走现编 / 兜底）；")OpenGL 款 ${TID}：GLSL $(wc -l < "$OUT/keys.tsv" | tr -d ' ') 支 → gl/gl_shaders.metallib $(du -h "$OUT/gl/gl_shaders.metallib" | cut -f1)，$((SECONDS - s)) 秒（$(tail -1 "$C/gl_shaders.log" | cut -c1-120)）"
  exit 0
fi
PROF=$("$PY" "$NX/games/game.py" dir "$TID") || { say "🔴 ${TID} 没有可用配置档（先运行 pack/stage_direct_profile.sh）"; exit 1; }
[ -f "$PROF/game.tsv" ] || { say "🔴 ${TID} 配置档缺 game.tsv"; exit 1; }
VK=0; case "${S2A_DIRECT_TARGETS:-}" in '') NOMAC=0 NOIOS=0 CK=;; ios) NOMAC=1 NOIOS=0 CK=--no-mac-lib;; mac) NOMAC=0 NOIOS=1 CK=;; android) NOMAC=1 NOIOS=1 CK= VK=1;; *) say "🔴 S2A_DIRECT_TARGETS=${S2A_DIRECT_TARGETS} 不认识（不设 = Mac + iOS 两份，ios = 只出 iOS，mac = 只出 Mac，android = 只出安卓 Vulkan 库）"; exit 1;; esac
# 发布哪一份进输出目录（#897）：S2A_DIRECT_PUBLISH=ios（缺省）/ mac（Mac 版 App；pack/stage_direct.sh 按 S2A_PACK_PLAT 定）。mac 要 Mac 那份真编了库
PUB=${S2A_DIRECT_PUBLISH:-ios}
case "$PUB" in ios) [ "$NOIOS" = 0 ] || { say "🔴 发布 iOS 库却没出 iOS 那份（S2A_DIRECT_TARGETS=${S2A_DIRECT_TARGETS}）"; exit 1; };; mac) [ "$NOMAC" = 0 ] || { say "🔴 发布 Mac 库却没出 Mac 那份（S2A_DIRECT_TARGETS=${S2A_DIRECT_TARGETS}）"; exit 1; };;
  android) [ "$VK" = 1 ] || { say "🔴 发布安卓库却没出安卓那份（S2A_DIRECT_TARGETS=${S2A_DIRECT_TARGETS:-}）"; exit 1; };; *) say "🔴 S2A_DIRECT_PUBLISH=${PUB} 不认识（ios / mac / android）"; exit 1;; esac
[ "$VK" = 0 ] || [ "$PUB" = android ] || { say "🔴 只出安卓 Vulkan 库（S2A_DIRECT_TARGETS=android）却要发布 ${PUB}"; exit 1; }
C=${S2A_DIRECT_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/direct/$TID}; OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd -P) || exit 1
V=$(cd "$NX/../../translator" && "$PY" -c 'import dmsh_chain; print(dmsh_chain.version())') || { say "🔴 取不到链版本"; exit 1; }
# 缓存只剩内容寻址仓 $C/store（dmsh_store.py 分片文件，10-31 出包线深修：按键小文件马车8 一款 66 万个）与上次的日志 $C/logs/；
#   旧布局（$C/mac/b-<链>/、$C/mac/cas/{shader,index,variant,unity,metallib}/、$C/ios/b-<链>/、$C/work/）第一次碰到整个删掉（旧链号整代不留）
#   改名挪开是瞬间的，真删放后台：旧布局一款几十万个小文件，同步 rm -rf 把出库卡住半小时（10-31 马车8 03:51 → 04:24 全在删）。
#   上次被停在半路留下的 .old-* 同样后台删
for d in "$C/mac" "$C/ios" "$C/work"; do [ -e "$d" ] && { mv "$d" "$C/.old-$$-${d##*/}" && say "旧布局缓存 ${d##*/}/ 已挪开、后台删（改存内容寻址仓 $C/store）"; }; done
for d in "$C"/.old-*; do [ -e "$d" ] && { nohup rm -rf "$d" > /dev/null 2>&1 & }; done
mkdir -p "$C/store" "$C/logs"
for d in "$C"/work.stage.* "$C"/mac.stage.* "$OUT".stage.*; do [ -d "$d" ] && ! kill -0 "${d##*.}" 2>/dev/null && rm -rf "$d"; done   # 上次被停留下的临时目录
W=$C/work.stage.$$ MS=$C/mac.stage.$$ OS=$OUT.stage.$$; DONE=0
# 成功：临时目录换进来的是旧版本，删；失败：只删库，work 留着看日志（下次起跑时清）
trap 'rm -rf "$MS" "$OS"; [ -n "${BTX:-}" ] && rm -rf "$BTX"; [ "$DONE" = 1 ] && rm -rf "$W"' EXIT
# 输出目录里原有的东西（旧链版本的容器、表）克隆进临时输出目录；逐键产物不跨次保留，每次由 dmsh_build 从内容寻址仓恢复（命中的键只是写回几个文件）
"$PY" "$R/tools/clonedir.py" "$OUT" "$OS" || { say "🔴 建临时输出目录失败"; exit 1; }
mkdir -p "$W/profile/$TID" "$W/pkg" "$MS"
cp "$PROF/"* "$W/profile/$TID/" || { say "🔴 配置档复制失败"; exit 1; }
# L3 判定结果表（fps_l3_results.tsv，名单线产出）拷进配置档，随包带给宿主运行时（host_adapt.m fps_l3_override）
[ -f "$NX/games/fps_l3_results.tsv" ] && cp "$NX/games/fps_l3_results.tsv" "$W/profile/$TID/" || true
# 零源跳过事实（graphics/nvn/games/zero_skip.tsv，按程序号逐款登记）写成副本 game.tsv 的 zero_skip 键，随包带给宿主（nvn_mtl.m zskip_facts_load）；
#   配置档自己写了 zero_skip 的，宿主取文件里第一行，即配置档那行
ZS=$(awk -F'\t' -v t="$TID" 'toupper($1) == toupper(t) { printf "%s%s:%s:%s:%s", n++ ? " " : "", $2, $3, $4, $5 }' "$NX/games/zero_skip.tsv") || { say "🔴 读零源跳过事实表失败"; exit 1; }
[ -z "$ZS" ] || printf '\n# 零源跳过事实（出库时取自 graphics/nvn/games/zero_skip.tsv）\nzero_skip\t%s\n' "$ZS" >> "$W/profile/$TID/game.tsv"
# 只有 game.tsv 的配置档（10-24 塞尔达 / 马车8 / 丝之歌：dmsh_build.py 读冲突表时 FileNotFoundError）：照上游 dm/games/README.md 新游戏第 3 步，
#   缺的三张表补成只有表头的空表（表头照上游马力欧 010015100B514000 那份）；维护过的配置档原样不动
P=$W/profile/$TID
[ -f "$P/shader_map.tsv.conflicts.tsv" ] || printf '# kind: evidence  control-section key conflict rulings: this game'"'"'s keys already include the code area (dm/gfx/tools/shader_split.py), so one key never has two different codes; empty\ndm_ctl_sha16\tchosen_pc\tclass\tcandidates\trecords\n' > "$P/shader_map.tsv.conflicts.tsv"
[ -f "$P/bf_want.tsv" ] || printf '# generated\n' > "$P/bf_want.tsv"
# 管线种子表：维护过的配置档原样带；没有的零配置生成（⑤ 后 pso_seed.py；经 pack/stage_direct.sh 时归轻阶段 pack/stage_direct_seed.sh，审计 #1534 P1-54 B3：真跑留下的 pso_user.tsv，11-02 起不再补库里的计算着色器：没有来源 = 空表，首帧不等、用到再编）。
#   原先补空表，随包 0 行 = 不预建，首遇管线全在提交线程当场建（10-25 马车8 冷局 698 个、30–350 ms 慢帧）
#   「维护过」= 表里有数据行：零配置款的临时配置档（profile_write.py）自带一份只有表头的空表，按「有文件」判会把它当维护过的原样带，
#   10-26 怪猎 / 八方2 / 暗黑2 / 暗黑3 / 巫师3 / 异度3 六款随包种子表全是 0 行（pso_seed/ 里来源 3–14 份一直没进包），新装首局怪猎 111 次、八方2 75 次没顶上的首遇
PSO_GEN=0; grep -q -v -E '^(#|[[:space:]]*$)' "$P/pso_manifest.tsv" 2> /dev/null || PSO_GEN=1
export DM_GAMES_DIR=$W/profile DM_GAMES_FIRST=1 DM_GAME=$TID DM_ROOT=$C IOSOUT=$OS DMSH_NO_MAC_LIB=$NOMAC DMSH_NO_IOS_LIB=$NOIOS
# ⑥ 换进位（苹果 / 安卓共用）：临时输出目录与正式输出目录原子互换（macOS renamex_np RENAME_SWAP，Linux renameat2 RENAME_EXCHANGE；正式的还没有就直接改名），
#   换下来的旧版本由 EXIT 陷阱删（原 lib_swap.py swap）；日志留进 $C/logs/
swap_out() {
  "$PY" -c 'import os, sys, ctypes, ctypes.util
a, b = sys.argv[1:3]
if not os.path.lexists(b): os.rename(a, b); sys.exit(0)
if sys.platform == "win32": os.rename(b, a + ".old"); os.rename(a, b); os.rename(a + ".old", a); sys.exit(0)   # Windows 没有目录原子互换：三步改名，换下的旧版本仍落在临时名、由 EXIT 陷阱删
c = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
sw = getattr(c, "renamex_np", None)
if (sw(os.fsencode(a), os.fsencode(b), ctypes.c_uint(2)) if sw else c.renameat2(-100, os.fsencode(a), -100, os.fsencode(b), ctypes.c_uint(2))):
    e = ctypes.get_errno()
    if e not in (45, 95, 102): sys.exit(f"{a} ⇄ {b}: {os.strerror(e)}")
    # exFAT 等外接盘不支持原子互换（ENOTSUP / EOPNOTSUPP）：同 Windows 三步改名
    os.rename(b, a + ".old"); os.rename(a, b); os.rename(a + ".old", a)' "$OS" "$OUT" || { say "🔴 换进位失败"; exit 1; }
  rm -rf "$C/logs.new" && mkdir -p "$C/logs.new" && find "$W" -maxdepth 1 -name '*.log' -exec cp {} "$C/logs.new/" \; && rm -rf "$C/logs" && mv "$C/logs.new" "$C/logs"
}
# ①② 抽取（10-25 维护者「抽着色器只做一次」）：共享抽取阶段（pack/stage_extract.sh）已经出好的 <产物根>/extract/（有 ok）就整份 APFS 克隆进工作目录，不重抽；
#   没有（单独调用 / 单测）就当场跑同一份 graphics/tools/direct/extract.sh。抽取的产物（直连包目录与三张表、S2Arm 抽取）与原先 ①② 的一样。
# 追加内容（DLC）：nx_unpack 解在 <产物根>/aoc/<序号>/（数据分区即 RomFS）。两边抽取都把它们并进来：直连抽取按「RomFS 与 main 逗号列表一一配对、取并集」，
#   每份追加内容配同一个 main（键按内容算，重复的合并）；S2Arm 抽取本来就收多个资源目录。没解追加内容的产物根照旧只扫 romfs/
AOCS=(); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] && AOCS+=("${a%/}"); done
T0=$SECONDS; s=$SECONDS
# ① 抽取的表写临时目录，不盖配置档：配置档的答案表 / 配对表是维护过的（同上游 build_ipa_from_nsp.py split_shaders：已有配置档时以它为准、抽取只核对）。
#   取用：着色器表用抽取的（序号对得上本次出的包目录）；答案表 = 配置档 + 抽取里配置档没有的键；配对表 = 两边并集。
#   配置档里有、本次抽不到的行（如动森配置档带「快乐家乐园」追加内容的 12 个，本产物根没解追加内容）只报 🟡 计数：游戏没挂那份数据就用不到这些着色器。
if [ -f "$ROOT/extract/ok" ]; then X=$ROOT/extract; prog "抽取着色器：用抽取阶段的（$(tr '\t\n' '= ' < "$X/ok")）"
elif [ "$VK" = 1 ]; then say "🟡 直连缺口：产物根里没有抽取阶段的 extract/（安卓刷新在直连库之前跑抽取阶段），这里不另抽着色器"; exit 3   # 文案里不写脚本路径：阶段输入闭包扫描（tools/stage_inputs.py）按字面路径认依赖
else X=$W/x; prog "抽取着色器（${J} 路）"; bash "$R/graphics/tools/direct/extract.sh" "$ROOT" "$X" 2>&1 | tee "$W/extract.log" | sed 's/^/  /'; xrc=${PIPESTATUS[0]}
  # 退 3 = 只有直连用的那两份抽不出（extract.sh 头注：运行时现编的 GLSL 没抓到输出、认不出着色器容器……）：同 Mac 链抽取阶段（pack/stage_extract.sh 写 direct_gap.txt、
  #   pack/stage_direct.sh 出空库），出运行时现编空直连库、照常换进输出目录、退 0（11-06 Windows 出包机疯狂兔子 / 马力欧高尔夫：Windows 出包机链直接调本脚本、不走那两段，整单红）
  if [ "$xrc" = 3 ]; then
    # 一个 Python 进程做完清目录、出空库、换进位、拷日志（不再 rm / 子壳 / 多次 python：抽取刚因内存吃紧失败，再起一串子进程会一起倒——
    #   v0.3.0 Windows 8 GB 机 cygwin fork rm 报 Win32 299，兜底失败整单红）
    "$PY" "$R/graphics/tools/direct/runtime_only_lib.py" "$OS" "$V" "$TID" auto "$W/direct_gap.txt" "$PROF/game.tsv" --gap-from "$W/extract.log" --swap-to "$OUT" --logs-from "$W" --logs-to "$C" \
      || { say "🔴 出运行时现编空直连库失败"; exit 1; }
    gap=; read -r gap < "$W/direct_gap.txt"   # 内建 read：这一段不再起子进程
    DONE=1; say "🟡 ${TID} 离线 0 支、运行时首遇现编（${gap:0:200}）"; exit 0
  fi
  [ "$xrc" = 0 ] || { say "🔴 抽取失败（${X}）"; exit 1; }; fi
# 翻译编译开工前复核盘（pack/jobs/space_rule.py，#265：预检放过、编到一半写满，十几分钟白编；Mac / Windows 两条链都过这里）：与出包预检同一规则，
#   按产物根里的游戏内容大小（原件那一档）记、扣掉已有的同款缓存。玩家点过「仍然继续」（S2A_SPACE_OVERRIDE=1）只打黄。原话「磁盘空间不足」pack/jobs/errors.py 归 disk_full
"$PY" "$R/pack/jobs/space_rule.py" direct-check "$ROOT" "$C" "$OUT"; src=$?   # 退 1 = 空间不够；别的非 0 = 复核本身没跑成（缺脚本 / Python 出错），不冒充空间问题
[ "$src" = 1 ] && { say "🔴 直连库开工前空间不足，没开始编"; exit 1; }   # 估不够：玩家点过「仍然继续」会带 S2A_SPACE_OVERRIDE 过这一关（space_rule.py）
# 复核本身没跑成（缺脚本 / Python 出错）：拿不准就不停（v0.3.1 ⑫），打黄照编；真写满时写盘报 ENOSPC，那才是物理停（disk_full）
[ "$src" = 0 ] || [ "$src" = 1 ] || say "🟡 直连库开工前的空间复核没跑成（pack/jobs/space_rule.py 退 ${src}），照常开编；真写满时会按盘满停"
CPC=-c; [ "$(uname -s)" = Darwin ] || CPC=   # macOS cp -c = APFS 克隆；Linux（安卓出包机）的 GNU cp 没有 -c，普通拷贝
rm -rf "$W/pkg" && cp $CPC -R "$X/pkg" "$X/split" "$X/s2x" "$W/" && cp $CPC "$X/split.log" "$X/s2x.log" "$W/" || { say "🔴 抽取结果克隆进工作目录失败（${X} → ${W}）"; exit 1; }
PROF_ONLY=$("$PY" - "$W/split" "$W/profile/$TID" <<'PYEOF'
import sys, os
sp, pf = sys.argv[1:3]
def data(p): return [l for l in open(p, encoding='utf-8') if l.strip() and not l.startswith('#') and not l.startswith('package\t')] if os.path.exists(p) else []
def head(p): return [l for l in open(p, encoding='utf-8') if l.startswith('#') or l.startswith('package\t')] if os.path.exists(p) else []
key = lambda l: l.split('\t', 1)[0]
# 着色器表：抽取的为准；数出配置档有、抽取没有的键
pk = {l.split('\t')[3] for l in data(os.path.join(pf, 'shader_map.tsv')) if len(l.split('\t')) > 4}
sk = {l.split('\t')[3] for l in data(os.path.join(sp, 'shader_map.tsv')) if len(l.split('\t')) > 4}
open(os.path.join(pf, 'shader_map.tsv'), 'w', encoding='utf-8', newline='\n').writelines(head(os.path.join(pf, 'shader_map.tsv')) + data(os.path.join(sp, 'shader_map.tsv')))
# 答案表：配置档的行原样，再补抽取里配置档没有的键
f0 = data(os.path.join(pf, 'shader_facts.tsv')); have = {key(l) for l in f0}
f1 = [l for l in data(os.path.join(sp, 'shader_facts.tsv')) if key(l) not in have]
open(os.path.join(pf, 'shader_facts.tsv'), 'w', encoding='utf-8', newline='\n').writelines(head(os.path.join(pf, 'shader_facts.tsv')) + f0 + f1)
# 配对表：并集（去重保序）
p0 = data(os.path.join(pf, 'shader_pairs.tsv')); seen = set(p0)
open(os.path.join(pf, 'shader_pairs.tsv'), 'w', encoding='utf-8', newline='\n').writelines(head(os.path.join(pf, 'shader_pairs.tsv')) + p0 + [l for l in data(os.path.join(sp, 'shader_pairs.tsv')) if not (l in seen or seen.add(l))])
print(len(pk - sk))
PYEOF
) || { say "🔴 合表失败"; exit 1; }
[ "$PROF_ONLY" = 0 ] || say "🟡 配置档里有、本次抽不到的着色器 ${PROF_ONLY} 个（多为没解的追加内容，游戏没挂那份数据就用不到）"
tx=$(awk -F'\t' '$1 == "s2a_extract" {print $2}' "$X/ok"); ts=$(awk -F'\t' '$1 == "split" {print $2}' "$X/ok"); [ "$X" = "$ROOT/extract" ] && ts=0 tx=0   # 用现成抽取 = 本次没花时间
s=$SECONDS
prog "合并两边抽取"
# ③ 并集表放回配置档副本（dmsh_build 按配置档读表、按包目录读记录）
"$PY" "$R/graphics/tools/direct/merge_extract.py" "$W/s2x" "$W/pkg" "$W/profile/$TID/shader_map.tsv" "$W/merged" > "$W/merge.log" 2>&1 \
  || { say "🔴 合并抽取失败（$W/merge.log）"; tail -3 "$W/merge.log"; exit 1; }
cp "$W/merged/shader_map.tsv" "$W/profile/$TID/shader_map.tsv"
cp "$W/merged/shader_facts.tsv" "$W/profile/$TID/shader_facts.tsv"   # 答案表：计算着色器补齐线程组 / 共享内存（merge_extract.py）
# 真机转储的着色器（产物根 rt_shaders/：游戏文件里抽不到、真机首遇只能现编的，DM_NVN_SHDUMP 存的 <键>.ctl / .code）：按 shader_split 同一记录格式并进合并后的包与表、
#   补进并集键清单，出库把它们编进库（11-05 时之笛 Switch 2 版开局 11 支计算着色器，真机现编每支约 20 秒、开局停帧 30 秒以上）。放在这里而不进抽取阶段：
#   抽取键不变（不为几支转储重抽 4 万支），直连阶段键另算 rt_shaders 内容（pack/stage_direct.sh）
if ls "$ROOT"/rt_shaders/*.code > /dev/null 2>&1; then
  n0=$(grep -c . "$W/profile/$TID/shader_map.tsv")
  "$PY" "$NX/../../translator/rt_dump_merge.py" "$ROOT/rt_shaders" "$W/merged/pkg" "$W/profile/$TID/shader_map.tsv" "$W/profile/$TID/shader_facts.tsv" > "$W/rt_dump.log" 2>&1 \
    || { say "🔴 真机转储着色器并不进库（$(tail -1 "$W/rt_dump.log")；$W/rt_dump.log）"; exit 1; }
  tail -n +$((n0 + 1)) "$W/profile/$TID/shader_map.tsv" | cut -f4 >> "$W/merged/union_keys.tsv"
  say "$(tail -1 "$W/rt_dump.log")"
fi
# 跑局知识（审计 #1534 P1-54 B1）：只读快照 KN，不读活文件。pack/stage_direct.sh 算键前出好一份、经 S2A_RUN_KNOWLEDGE 交来（键与出库用的是同一份）；
#   单独调用（单测 / 手工）时这里按同一工具现出。来源 = pso_seed/<程序号>/（或 S2A_PSO_SOURCES），出包不读 ~/Documents/wire（Mac 局收局拷进 pso_seed/，runtime/run_mac.sh），
#   同一提交、同一份 pso_seed/ 在 Mac 与Windows 出包机出的库相同。四张表的含义见 graphics/tools/direct/run_knowledge.py 头注
KN=${S2A_RUN_KNOWLEDGE:-}
if [ -z "$KN" ]; then KN=$W/knowledge
  "$PY" "$R/graphics/tools/direct/run_knowledge.py" "$KN" "$TID" > "$W/run_knowledge.log" 2>&1 || { say "🔴 跑局知识快照出不来（$W/run_knowledge.log）"; tail -3 "$W/run_knowledge.log"; exit 1; }
  say "$(tail -1 "$W/run_knowledge.log")"
fi
for f in pairs fout_want se_want; do [ -f "$KN/$f.tsv" ] || { say "🔴 跑局知识快照缺 $f.tsv（${KN}）"; exit 1; }; done
# 跑局里见到、出包没配上的「顶点 + 片元」对（宿主 pso_user.tsv 的 P 行，快照 pairs.tsv）并进配对表，④ 的 vs_pad 给顶点着色器补上片元要读的输出（run_pairs.py）
"$PY" "$R/graphics/tools/direct/run_pairs.py" "$W/profile/$TID/shader_pairs.tsv" "$W/merged/union_keys.tsv" "$KN/pairs.tsv" > "$W/run_pairs.log" 2>&1 \
  || { say "🔴 跑局配对并不进配对表（$W/run_pairs.log）"; tail -2 "$W/run_pairs.log"; exit 1; }
say "$(tail -1 "$W/run_pairs.log")"
# 片元输出类型变体请求表（现编回收 R2）：快照里的 fout_want.tsv（fout_want.py 从 R 行 + 设备拉回的 rt_fout.tsv 算出各片元键要的整数输出位置）原样作配置档副本的表，
#   ④ 的 dmsh_build.py ft_finish 按它把 main0_t<u>_<s> 编进库（<键>_ft）。进链的输入表（dmsh_chain.py INPUT_TABLES）
#   这两张变体请求表只给 Metal 库用（_ft / _se），安卓（VK=1）不出
if [ "$VK" = 0 ]; then
cp "$KN/fout_want.tsv" "$P/fout_want.tsv" || { say "🔴 输出类型变体请求表拷不进配置档副本（$KN/fout_want.tsv）"; exit 1; }
say "输出类型变体请求：$(grep -vc '^#' "$P/fout_want.tsv") 条（跑局知识快照）"
# 采样模拟变体请求表（缺口族 31，11-01 维护者）：快照里真绑过要模拟的采样器的键按本次并集滤 → se_want.tsv，④ 的 dmsh_build.py se_finish 把它们的 <键>_se 预编进库；
#   没有这样的键时表是空的、出库不多编一支。按配置档副本写，进链的输入表（dmsh_chain.py INPUT_TABLES）
"$PY" "$R/graphics/tools/direct/se_want.py" "$P/se_want.tsv" "$W/merged/union_keys.tsv" --keys "$KN/se_want.tsv" > "$W/se_want.log" 2>&1 \
  || { say "🔴 采样模拟变体请求表出不来（$W/se_want.log）"; tail -3 "$W/se_want.log"; exit 1; }
say "$(tail -1 "$W/se_want.log")"
fi
tm=$((SECONDS - s)); s=$SECONDS
# ④⑤ 安卓（VK=1，#783）：graphics/tools/direct/vklib/dsh_vklib.py 按需编 dsh_vklib 再调：逐键出 Vulkan 产物进工作目录 $W/vk/keys（键按 shader_map.tsv 排序，
#   gs / hs / ds 记 skipped、翻不了的记 failed，逐键状态 vk_build.tsv；有 failed 就报红停止，不发布部分库，再把成功批次打成 LibPack 容器 <临时输出>/b-<链>-vk/（lib.idx + lib.NNN.pak，头部记完整 Vulkan 侧指纹）；
#   收表、出 keys.tsv（只列出成的键）、vk_build.tsv 副本与 direct_lib.json，换进位。不编 Metal，不出 ps_inputs / c1_full / cb_extent / 管线种子表（都是 Metal 侧的）
if [ "$VK" = 1 ]; then
  prog "翻译成 Vulkan"
  L=$OS/b-$V-vk K=$W/vk/keys; rm -rf "$L" "$K"; mkdir -p "$W/vk"
  "$PY" "$R/tools/nostall.py" --watch "$W/vk" --watch "$OS" "${S2A_NOSTALL_S:-600}" -- "$PY" "$R/graphics/tools/direct/vklib/dsh_vklib.py" build --pkg "$W/merged/pkg" --profile "$P" --out "$K" \
    --lib "$L" --chain "$V" --dsx "${DSX_LIB:-$R/build/dsx/libdsx.dylib}" --work "$W/vk/work" > "$W/build.log" 2>&1; brc=$?
  [ "$brc" = 0 ] && [ -f "$K/vk_build.tsv" ] && [ -s "$L/lib.idx" ] || { say "🔴 安卓 Vulkan 库出库失败 rc=${brc}（$W/build.log）"; tail -5 "$W/build.log"; exit 1; }
  cp "$K/vk_build.tsv" "$OS/vk_build.tsv" || { say "🔴 vk_build.tsv 拷不进输出目录"; exit 1; }
  awk -F'\t' '$3 == "ok" { print $1 }' "$K/vk_build.tsv" | sort > "$OS/keys.tsv"
  GAPS=$(awk -F'\t' '$3 != "ok" { c[$3]++ } END { for (k in c) printf "%s%s %d 支", n++ ? "、" : "", k, c[k] }' "$K/vk_build.tsv")
  { printf '键\t类别\t错误\n'; awk -F'\t' '$3 != "ok" { print $1 "\t" $3 "\t" substr($4, 1, 200) }' "$K/vk_build.tsv"; } > "$W/direct_fail.log"
  tb=$((SECONDS - s))
  prog "收表"
  for f in game.tsv fps_l3_results.tsv shader_map.tsv shader_facts.tsv shader_pairs.tsv bf_want.tsv pso_manifest.tsv c1_full.tsv cb_extent.tsv shader_map.tsv.conflicts.tsv; do
    [ -f "$W/profile/$TID/$f" ] && cp "$W/profile/$TID/$f" "$OS/$f"
  done
  cp "$W/merged/key_map.tsv" "$OS/"
  nu=$(wc -l < "$W/merged/union_keys.tsv" | tr -d ' '); nk=$(wc -l < "$OS/keys.tsv" | tr -d ' ')
  miss=$(comm -23 "$W/merged/union_keys.tsv" "$OS/keys.tsv" | wc -l | tr -d ' ')
  "$PY" - "$OS/direct_lib.json" "$W/merged/merge.json" <<EOF
import json, sys
m = json.load(open(sys.argv[2]))
json.dump({'title': '$TID', 'chain': '$V', 'target': 'android', 'union': $nu, 'built': $nk, 'missing': $miss, 'profile_only': $PROF_ONLY, 'aoc_dirs': ${#AOCS[@]}, 'merge': m,
           'jobs': $J, 'wall_s': {'split': $ts, 's2a_extract': $tx, 'merge': $tm, 'build': $tb, 'total': $((SECONDS - T0))}}, open(sys.argv[1], 'w', newline='\n'), ensure_ascii=False, indent=1)
EOF
  prog "换进位"
  swap_out
  DONE=1
  prog_tick 直连库 5 5
  say "$([ "$miss" = 0 ] && echo 🟢 || echo "🟡 直连缺口（部分出库）：${GAPS:-没出成 $miss 支}（运行时走现编）；") $TID 安卓 Vulkan 库 b-${V}-vk：并集 ${nu}，出库 ${nk}，没出成 ${miss}；用时 抽取 ${ts}+${tx} / 合并 ${tm} / 出库 ${tb} / 合计 $((SECONDS - T0)) 秒（$(tail -1 "$W/build.log" | cut -c1-80)）"
  exit 0
fi
# ④ 翻译 + 编库 + 发布：内容寻址仓 $C/store 里有的翻译产物 / Metal 库按内容取，其余现做；发布那一侧（S2A_DIRECT_PUBLISH）直接写成 $OS/b-<链>/lib.NNN.pak + lib.idx，
#   出 keys.tsv / ps_inputs.tsv / c1_full / cb_extent / _b_build.json；进度按 S2A_PROGRESS 协议写（Build.cs Ticker）
prog "翻译 + 编库（${J} 路）"
#   S2A_DIRECT_KEEP=1：整份出库另把 Mac 那份逐键产物导出到 $C/keep/mac/b-<链>（门禁考卷冻结 t_dsh.sh freeze / 全量对拍 DSH_EXAM 读它）
KM=; [ "${S2A_DIRECT_KEEP:-0}" = 1 ] && { rm -rf "$C/keep" && mkdir -p "$C/keep/mac" && KM=$C/keep/mac/b-$V; }
#   11-01 出包线：出库链整条在 C# 一个进程里（graphics/tools/direct/dsh/batch/Build.cs：翻译、逐键收尾、变体、编批库、两张表、发布打包全在线程池里并发，
#   Metal 由并发闸限路数），替掉 Python 的 dmsh_par.py / dmsh_build.py（GIL 把编批库段卡在一核）。链号、配置档输入摘要先由 dmsh_chain.py 核过工具再给
# stdout 只收链号 / 程序号 / 输入摘要；编译器版本提示走 stderr，合流会把 note: 误读成链号。
BE=$(cd "$NX/../../translator" && "$PY" dmsh_chain.py --build-env "$W/profile_rows.txt" 2> "$W/build_env.log") || { say "🔴 出库前核工具 / 链号失败"; cat "$W/build_env.log" >&2; printf '%s\n' "$BE" | tail -3 >&2; exit 1; }
cat "$W/build_env.log" >&2
read -r BV BG BI < <(printf '%s\n' "$BE"); [ "$BV" = "$V" ] || { say "🔴 链号前后不一（${V} / ${BV}）"; exit 1; }
SPVC=$(cd "$NX/../../translator" && "$PY" -c 'import spvc_inproc; print(spvc_inproc.lib_path())') || { say "🔴 spirv-cross 进程内库编不出"; exit 1; }
BA=(--pkg "$W/merged/pkg" --profile "$P" --game "$BG" --chain "$V" --inputs "$BI" --profile-rows "$W/profile_rows.txt" --out "$MS" --iosout "$OS" --publish "$PUB"
    --cas "$C/store" --dsx "${DSX_LIB:-$R/build/dsx/libdsx.dylib}" --spvc "$SPVC" -j "$J" --lock "$NX/../../translator/dmsh_chain.lock")
[ "$NOMAC" = 1 ] && BA+=(--no-mac); [ "$NOIOS" = 1 ] && BA+=(--no-ios); [ -n "$KM" ] && BA+=(--export-mac "$KM")
#   dsh_batch 的临时工作目录（spill.dat / side_*.dat，大款几十 GB）按 .NET 习惯落 TMPDIR = 内置盘 /var/folders（11-02 本机内置盘 15 分钟掉 61 GB 就是它）；
#   改落本次出库的工作目录 $W/tmp（在缓存目录 $C 下 = 2T 数据区，随 $W 出库收尾一起清）
#   调用方已把 TMP / TEMP / TMPDIR 指到本单工作盘（pack/orch/oneclick_win.py：Windows 出包机 / Windows 出包时指 <工作目录>/tmp，盘位按它登记）就沿用、在下面建本次的子目录：
#   11-07 Windows 出包机两次出库 rc=127 = STATUS_DISK_FULL——常驻直连缓存在 T 盘，这里写死 $W/tmp 把几十 GB 临时文件拉回 T 盘，盘位登记里没有它，同时两单就写满。
#   是系统缺省临时目录（Mac /var/folders、/tmp，Windows 用户 AppData\Local\Temp）才落 $W/tmp（原意：不让内置盘被写爆）
# 出库 rc=127 怎么说（只在 Windows Git Bash 上说）：Windows 进程退出码经 Git Bash 只留低 8 位，127 可能是 0xC000007F（STATUS_DISK_FULL，11-07 Windows 出包机
#   两次），也可能就是出库程序异常退出 127（11-09 维护方测试树诊断替换写错，dsh_batch 抛异常退 127，被一律译成盘满——T 盘还剩 127 GB，照着提示误删 37 GB 缓存）。
#   判据：build.log 里有盘满原文 → 盘满；否则看临时目录 / 缓存所在盘余量，任一 < 2 GB 才说多半是盘满（带余量）；余量都够 → 明说不是盘满、看 build.log 末尾异常；
#   有盘量不出余量（df 认不出路径）→ 两种都说、不下结论。
#   余量 S2A_DISK_FREE_G（GB，单测注入，同 pack/jobs/space_rule.py）给了就用它。「不是盘满」那句不带系统盘满字样，错误分类（pack/jobs/errors.py）不会再归成 disk_full
rc127_note() {   # rc127_note <rc> <build.log> <目录>… → 追加在报红行后的说明（可能为空）
  local rc=$1 log=$2 d g gs= low= unk=; shift 2
  [ "$rc" = 127 ] || return 0
  case $(uname -s 2> /dev/null) in MINGW*|MSYS*|CYGWIN*) ;; *) return 0;; esac
  if grep -aqiE 'not enough space on the disk|磁盘空间不足|No space left on device|ENOSPC|0x80070070|ERROR_DISK_FULL' "$log" 2> /dev/null; then
    echo "；127 = 盘满（build.log 里有盘满原文，STATUS_DISK_FULL），看 $* 所在盘"; return 0; fi
  for d; do
    g=${S2A_DISK_FREE_G:-$(df -Pk "$d" 2> /dev/null | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }')}
    gs="${gs}${d} 剩 ${g:-?} GB、"; [ -n "$g" ] || unk=1; [ -n "$g" ] && awk -v g="$g" 'BEGIN { exit !(g + 0 < 2) }' && low=1
  done
  if [ -n "$unk" ] && [ -z "$low" ]; then echo "；rc=127 可能是盘满（Windows 盘满码的低 8 位），也可能是出库程序异常退出：余量量不全（${gs%、}），先看下面 build.log 末尾"
  elif [ -n "$low" ]; then echo "；127 多半是盘满（STATUS_DISK_FULL 0xC000007F 低 8 位）：${gs%、}"
  else echo "；rc=127 不是盘满（${gs%、}）：出库程序异常退出，看下面 build.log 末尾"; fi
}
BTX=; case "${TMPDIR:-}" in ''|/var/folders/*|/private/var/folders/*|/tmp|/tmp/*|/private/tmp|/private/tmp/*|*/AppData/Local/Temp|*/AppData/Local/Temp/*|*'\AppData\Local\Temp'*) BT=$W/tmp;;
  *) BT=${TMPDIR%/}/dsh_batch.$$; BTX=$BT;; esac
mkdir -p "$BT"
TMPDIR="$BT" "$PY" "$R/tools/nostall.py" --watch "$MS" --watch "$OUT" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/dsh_batch.py" build "${BA[@]}" > "$W/build.log" 2>&1
brc=$?
DF=$(rc127_note "$brc" "$W/build.log" "$BT" "$C")
[ "$brc" = 0 ] || { [ "$brc" = 1 ] && gap "$W/build.log" "NVN 着色器"; say "🔴 出库失败 rc=${brc}（$W/build.log）${DF}"; tail -"$([ -n "$DF" ] && echo 20 || echo 5)" "$W/build.log"; exit 1; }
# 核产物出自本树的翻译器（11-06 时之笛第 49 版：DSH_BATCH_CMD 指到Windows 出包机上按旧树编的 dsh_batch.exe，它键里的翻译器指纹是旧的，41971 支全命中旧缓存，
#   2ce17db8c 的翻译器改动没进包、出库照报绿）：dsh_batch 把自己的翻译器指纹 xfp 与 --lock 文件摘要写进库印章 inputs.tsv（Build.cs WriteStamp），
#   这里拿本树算的 dmsh_chain.xlate_fp()（与 C# 编译期 Xfp 同一份清单、同一算法）与本树锁文件摘要逐项比，不等 / 印章没这两行（旧程序）报红。只核产物，不管出库命令经谁转手
XC=$(cd "$NX/../../translator" && "$PY" dmsh_chain.py --check-stamp "$OS/b-$V" 2>&1) || { say "🔴 直连库不是本树的翻译器出的：${XC}（DSH_BATCH_CMD=${DSH_BATCH_CMD:-未设}）"; exit 1; }
# 没出成的按类别计数（dmsh_build.py 逐支记进 _b_build.json 的 st：translation failed / MSL failed / metal failed / …），末行黄行带上，普查按它归类
GAPS=$("$PY" -c 'import json,sys,collections
c = collections.Counter(r["st"] for r in json.load(open(sys.argv[1])) if r["st"] != "ok")
print("、".join(f"{k} {v} 支" for k, v in c.most_common()))' "$MS/b-$V/_b_build.json" 2> /dev/null)
# 编不过的键清单（11-01 维护者：确定性的编不过是翻译缺陷、玩家首遇卡顿 / 设备上编不过少画东西，目标归零）：随 *.log 收进 $C/logs，
#   快测拷进局日志、普查总表「直连编不过」列与批次清单读它；出库成功就写（没有编不过的也写表头，区别于「没出库 / 没读到」）
"$PY" -c 'import json,sys
rs = [r for r in json.load(open(sys.argv[1])) if r["st"] != "ok"]
print("键", "类别", "错误", sep=chr(9))
for r in rs: print(r["key"], r["st"], " ".join(str(r.get("err") or "").split())[:200], sep=chr(9))' "$MS/b-$V/_b_build.json" > "$W/direct_fail.log" 2> /dev/null || rm -f "$W/direct_fail.log"
tb=$((SECONDS - s))
prog "收表"
# ⑤ 收表、出 keys.tsv（以实际出成的 iOS 库为准）
L=$OS/b-$V; [ -d "$L" ] || { say "🔴 没出 $L"; exit 1; }
for f in game.tsv fps_l3_results.tsv shader_map.tsv shader_facts.tsv shader_pairs.tsv bf_want.tsv pso_manifest.tsv c1_full.tsv cb_extent.tsv shader_map.tsv.conflicts.tsv; do
  [ -f "$W/profile/$TID/$f" ] && cp "$W/profile/$TID/$f" "$OS/$f"
done
cp "$W/merged/key_map.tsv" "$OS/"
# 管线种子表（配置档没有时，direct_lib.json 记 pso_seed=gen；配置档维护过的记 profile、上面收表时原样带了）：
#   经 pack/stage_direct.sh 出库（S2A_PSO_SEED_STAGE=1）不在这里生成，归轻阶段 pack/stage_direct_seed.sh（审计 #1534 P1-54 B3：只写这一张表，新跑局只多几行 R 行时不让本阶段整段重跑），
#   这里只不发布配置档那份只有表头的空表；单独调用（Windows 出包 pack/orch/oneclick_win.py、单测）照旧在这里按快照的 seen.tsv 生成（同一个 pso_seed.py）。
#   R 行长度按当前 pso_skey 的字节数核（pso_layout.json，Mac / Windows 同一份；tests/pso_layout_test.sh 核它与 nvn_pso_skey.h 一致）
if [ "$PSO_GEN" = 1 ] && [ "${S2A_PSO_SEED_STAGE:-0}" = 1 ]; then rm -f "$OS/pso_manifest.tsv"
elif [ "$PSO_GEN" = 1 ]; then
  # 种子表是锦上添花（审计 #1592 P1-100，同 pack/stage_direct_seed.sh）：出不来只打【黄】、放只有表头的空表，库照常换进位（原先 exit 1 在换进位之前，这次库不发布、包不出）
  seedsoft() { say "🟡 ${TID} 管线种子表这次没生成：$1；库照常出，缺的是首局管线预建（首遇现编）；包里那张空表的表头记着同一原因"
    printf '# Prewarm seed list: empty (generation failed at packing time: %s); pipelines compile at their first use\n' "$(tr -d '\t\n' <<< "$1" | cut -c1-200)" > "$OS/pso_manifest.tsv"; }
  if [ ! -f "$KN/seen.tsv" ]; then seedsoft "跑局知识快照缺 seen.tsv（${KN}）"
  elif ! SK=$("$PY" "$R/graphics/tools/direct/pso_layout.py" skey-size 2> "$W/pso_seed.log"); then seedsoft "量不出管线键字节数（$W/pso_seed.log）"
  elif ! "$PY" "$R/graphics/tools/direct/pso_seed.py" "$OS/pso_manifest.tsv" "$OS/keys.tsv" "$W/merged/shader_map.tsv" "$SK" "$KN/seen.tsv" >> "$W/pso_seed.log" 2>&1; then
    seedsoft "pso_seed.py 失败：$(tail -1 "$W/pso_seed.log" | cut -c1-200)"
  else say "$(tail -1 "$W/pso_seed.log" | cut -c1-300)"; fi
fi
nu=$(wc -l < "$W/merged/union_keys.tsv" | tr -d ' '); nk=$(wc -l < "$OS/keys.tsv" | tr -d ' ')
miss=$(comm -23 "$W/merged/union_keys.tsv" "$OS/keys.tsv" | wc -l | tr -d ' ')
"$PY" - "$OS/direct_lib.json" "$W/merged/merge.json" <<EOF
import json, sys
m = json.load(open(sys.argv[2]))
json.dump({'title': '$TID', 'chain': '$V', 'union': $nu, 'built': $nk, 'missing': $miss, 'profile_only': $PROF_ONLY, 'aoc_dirs': ${#AOCS[@]}, 'merge': m,
           'pso_seed': '$([ "$PSO_GEN" = 1 ] && echo gen || echo profile)', 'jobs': $J, 'wall_s': {'split': $ts, 's2a_extract': $tx, 'merge': $tm, 'build': $tb, 'total': $((SECONDS - T0))}}, open(sys.argv[1], 'w', newline='\n'), ensure_ascii=False, indent=1)
EOF
# NVN 款另带 GL（gfx_api.py --gl-also：真建 GL 上下文、有 GL 入口、带 GLSL；11-03 火影忍者 终极风暴羁绊的界面中间件 Scaleform 走 GL）：同 OpenGL 款分支再出一份 GL 着色器库，
#   写进临时输出目录 $OS/gl，随 NVN 库一起原子换进位（运行时 GL 层读 <DM_MSL_DIR>/gl/，与 NVN 库同一个 shaders/direct）。keys.tsv 仍是 NVN 键（出包核「带了直连库」看它）。
#   GL 这份翻不全或出不来只打黄、不挡 NVN 库发布（主画面是 NVN；界面那部分走 GL 层的现编 / 报红）。主类别不变，抽取 / 通用着色器 / 配置推导阶段都不受影响
GLX=$("$PY" "$NX/tools/gfx_api.py" --gl-also "$ROOT/exefs" "$ROOT/romfs") || GLX="0	判不了（gfx_api.py --gl-also 出错）"
GLMSG=
if [ "${GLX%%	*}" = 1 ]; then
  rm -rf "$OS/gl"; s=$SECONDS
  if ! type -P -- "${GLSLANG-glslangValidator}" > /dev/null || ! command -v spirv-cross > /dev/null; then GLMSG="🟡 另带 GL 的着色器库没出：缺 glslangValidator / spirv-cross（brew install glslang spirv-cross）"
  else
    INS=("$ROOT/romfs" "$ROOT/exefs/main"); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] && INS+=("${a%/}"); done
    "$PY" "$R/tools/nostall.py" --watch "$C/glmac" --watch "$OS" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/gl_shaders.py" "${INS[@]}" "$C/glmac" --ios "$OS" > "$W/gl_shaders.log" 2>&1; grc=$?
    GOK=$(sed -n 's/^GLSL 汇总：成功 \([0-9]*\)、失败 \([0-9]*\).*/\1 \2/p' "$W/gl_shaders.log" | tail -1)
    if [ "$grc" = 0 ] && [ "$GOK" = "0 0" ] && [ -s "$OS/gl/gl_shaders.tsv" ]; then GLMSG="🟡 另带 GL 离线 0 支 GLSL：只出表头、界面那部分运行时首遇现编，$((SECONDS - s)) 秒"
    elif { [ "$grc" = 0 ] || { [ "$grc" = 1 ] && [ "${GOK%% *}" -gt 0 ] 2> /dev/null; }; } && [ -s "$OS/gl/gl_shaders.metallib" ] && [ -s "$OS/gl/gl_shaders.tsv" ]; then
      GN=$(grep -vc '^#' "$OS/gl/gl_shaders.tsv"); GMISS=$([ "$grc" = 1 ] && echo "${GOK##* }" || echo 0)
      GLMSG="$([ "$GMISS" = 0 ] && echo "另带 GL" || echo "🟡 另带 GL 部分出库（GLSL 翻不了 ${GMISS} 支）")：GLSL ${GN} 支 → gl/gl_shaders.metallib，$((SECONDS - s)) 秒"
    else rm -rf "$OS/gl"; GLMSG="🟡 另带 GL 的着色器库没出（rc=${grc}，$C/logs/gl_shaders.log）：界面那部分运行时报红"; fi
  fi
fi
prog "换进位"
# ⑥ 核验齐全、发布哪一份（S2A_DIRECT_PUBLISH）、反射 -sdk 与目标相符、打成 lib.NNN.pak + lib.idx 已在整份出库里从内存做完（dmsh_build.py 收尾，10-31 起不落按键文件），这里只看结果
for l in '核验齐全' '发布 ' '打包：'; do grep -a "\[直连库\] .*$l" "$W/build.log" | tail -1 | sed 's/^\[直连库\] //' | while IFS= read -r x; do say "$x"; done; done
[ -s "$OS/b-$V/lib.idx" ] || { say "🔴 整份出库没写出 $OS/b-$V/lib.idx（$W/build.log）"; exit 1; }
#   只把打好的容器换进输出目录；逐键的 Mac / iOS 产物与工作目录是这次出库的临时品，日志留进 $C/logs/，其余退出时删
swap_out   # 换进位（见上面 swap_out）
# S2A_DIRECT_KEEP=1：这次的工作目录与 Mac 那份逐键产物留到 $C/keep/{work,mac}（门禁考卷冻结 graphics/tools/direct/tests/t_dsh.sh freeze / 全量对拍 DSH_EXAM 读它们；平时不留）
if [ "${S2A_DIRECT_KEEP:-0}" = 1 ]; then mv "$W" "$C/keep/work" || say "🟡 S2A_DIRECT_KEEP：没留全（$C/keep）"; fi
DONE=1   # 临时目录（逐键产物、工作目录）退出时删
prog_tick 直连库 5 5
say "$([ "$miss" = 0 ] && echo 🟢 || echo "🟡 直连缺口（部分出库）：${GAPS:-没出成 $miss 支}（运行时走现编 / 兜底）；") $TID 直连库 b-${V}$([ "$NOMAC" = 1 ] && echo '（只出 iOS）')：并集 ${nu}，出库 ${nk}，没出成 ${miss}；${J} 路并行，用时 抽取 ${ts}+${tx} / 合并 ${tm} / 出库 ${tb} / 合计 $((SECONDS - T0)) 秒（$(tail -1 "$C/logs/build.log" | cut -c1-80)）"
[ -z "$GLMSG" ] || say "${GLMSG}（${GLX#*	}）"
