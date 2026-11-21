#!/bin/bash
# 门禁层：合入后（路由命中时合入前也跑）
# 门禁路由：ios/ runtime/ graphics/ services/ compat/ tests/autoplay/ tests/build.mk Makefile */build.mk platform/apple/cs/ shell/ launchers/shared/ pack/shell/ pack/stage_inputs/shell.tsv pack/jobs/errors.py
# 门禁 full 档：iOS 全量编译检查 + 出壳输入闭包（10-20 维护者：任何一线弄坏 iOS 构建都在合入前拦下；11-11：出壳读到的文件漏登 shell.tsv 也在这里拦）——make ios S2A_CS=1 编译 + 链接出壳的主程序，再用一款现成改写产物写游戏镜像包（11-04 全外置），不签名、不出包。
# GATE_IOS_MODS=<现有改写产物目录> 显式指定；未指定时从共享根任一款的现行选取（只读，保留01006F8002326000 / 马车 / 暗黑2的既有优先顺序）。
# 显式目录无效就报红，不改用其他款；产物必须包含 main.npdm、模块映像及对应随行表，不下载游戏。
# 源码先同步到本树的私有镜像 ~/.s2arm/run/s2arm/gate_ios/<树号>/src 再编（10-20 回归提速）：C# 的 obj / build/cs 锁都在镜像里，不和同仓库其他钩子的 dotnet 抢，
#   门禁可以把本步和钩子并行；镜像跨门禁保留，nxaot 缓存与 obj 增量命中。多份门禁同时跑时按镜像锁排队（持锁进程死了接管）。
# 在仓库根跑：bash tools/gate_ios.sh；退出 0 绿，最后一行「期望 → 真结果」
set -u
R=$(git rev-parse --show-toplevel) || exit 2; cd "$R"
# 镜像与构建目录按工作树分开（10-21 测试出包线：全机一份时几条线的门禁排同一把锁 10–17 分钟，且不同树轮流往同一个增量构建目录里编、互相污染，
#   本树单独编通过的提交在共享目录里 make ios 失败）。一棵树一份约 350 MB、冷编约 1.5 分钟；24 小时没用的由维护方内部清扫器清
TK=$(printf %s "$R" | shasum | cut -c1-12)
#   放在独立的 gate_ios/<树号>/ 下：不能放进旧的全机镜像 gate_ios_src/ 里——还没 rebase 的树跑旧版本脚本时对它 rsync --delete，会把子目录整个删掉（10-21 实测）
GI=${GATE_IOS_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_ios}/$TK
RT=${S2A_ROOTS_SHARED:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots}; B=${GATE_IOS_BUILD:-$GI/build}
valid_mods() {
  local bin stem found=0; MODS_ERROR=
  [ -s "$1/main.npdm" ] && [ -r "$1/main.npdm" ] || { MODS_ERROR='缺少可读非空 main.npdm'; return 1; }
  [ -s "$1/main.patched.bin" ] || { MODS_ERROR='缺少非空 main.patched.bin'; return 1; }
  for bin in "$1"/*.patched.bin; do
    [ -e "$bin" ] || continue; found=1; stem=${bin%.patched.bin}
    [ -s "$bin" ] && [ -r "$bin" ] || { MODS_ERROR="模块映像不可读或为空：$(basename "$bin")"; return 1; }
    [ -f "$stem.fixups.tsv" ] && [ -r "$stem.fixups.tsv" ] && [ -f "$stem.gates.tsv" ] && [ -r "$stem.gates.tsv" ] || { MODS_ERROR="模块缺少可读随行表：$(basename "$stem").fixups.tsv / .gates.tsv"; return 1; }
  done
  [ "$found" = 1 ]
}
M=
if [ "${GATE_IOS_MODS+x}" = x ]; then
  [ -n "$GATE_IOS_MODS" ] || { echo '期望 iOS 编译链接通过 → 真结果 GATE_IOS_MODS 不是可用目录：（空）'; exit 1; }
  c=$(cd -P "$GATE_IOS_MODS" 2>/dev/null && pwd) || { echo "期望 iOS 编译链接通过 → 真结果 GATE_IOS_MODS 不是可用目录：$GATE_IOS_MODS"; exit 1; }
  valid_mods "$c" || { echo "期望 iOS 编译链接通过 → 真结果 GATE_IOS_MODS 产物不完整：${MODS_ERROR}（${c}）"; exit 1; }
  M=$c
else
  source "$R/pack/roots.sh"   # root_cur_in：共享根里各款的现行（<款>@现行 是指针文件）
  for candidate in "$RT/acnh@现行" "$RT/mk8d@现行" "$RT/d2r@现行" "$RT/"*@现行; do
    candidate=${candidate##*/}; c=$(root_cur_in "$RT" "${candidate%@现行}" 2>/dev/null) || continue
    valid_mods "$c" && { M=$c; break; }
  done
fi
[ -n "$M" ] || { echo "期望 iOS 编译链接通过 → 真结果 没有完整可用的改写产物（共享根 ${RT}）；可设 GATE_IOS_MODS=<现有改写产物目录>，需 main.npdm、*.patched.bin 和对应 .fixups.tsv / .gates.tsv"; exit 1; }
# 改写产物先 APFS 克隆进本门禁自己的目录，整轮只读克隆（10-24 帧率能耗线查实：门禁开头解析出 01006F8002326000@pkg-dd5259ef2，07:13 登记新包时 root_commit 只留现行 + 上一版、把它删了，
#   make ios 编到一半目录没了、门禁误红）。make ios 只读产物根顶层文件（*.patched.bin / .fixups.tsv / .gates.tsv / .widen.tsv / main.npdm / widen_*.tsv），只克隆顶层普通文件，秒级、不占新空间
MC=$GI/mods.$$; mkdir -p "$MC" || exit 1
for f in "$M"/*; do [ -f "$f" ] && { cp -c "$f" "$MC/" 2> /dev/null || cp "$f" "$MC/"; } || true; done
valid_mods "$MC" || { rm -rf "$MC"; echo "期望 iOS 编译链接通过 → 真结果 改写产物克隆不完整：${MODS_ERROR}（$M 克隆到 ${MC}，起步时共享根可能已被换掉）"; exit 1; }
MN=$(basename "$M"); M=$MC; trap 'rm -rf "$MC"' EXIT
S=${GATE_IOS_SRC:-$GI/src}; mkdir -p "$B" "$S"; touch "$GI"; echo "$R" > "$GI/tree"; q0=$SECONDS
until mkdir "$S.lock" 2> /dev/null; do p=$(cat "$S.lock/pid" 2> /dev/null); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$S.lock"; sleep 1; done
echo $$ > "$S.lock/pid"; trap 'rm -rf "$S.lock" "$MC"' EXIT; t0=$SECONDS
# 排队不算挂死（10-21 测试出包线：四五条线同时跑门禁时排镜像锁 10 分钟以上，门禁 600 秒上限把排队也算进去、整步判超时红）：
#   拿到锁后干活限 GATE_IOS_WORK_S（缺省 900）秒，排队另报；门禁给本步的总上限放宽（tools/gate.sh 的 GATE_IOS_S，缺省 3600）
# 只同步受版本控制的源码面：仓库根 build/、.git、各处 dotnet 的 obj/ bin/ 留在镜像里（增量）；--delete 让镜像 = 本次提交
#   __pycache__/ 不同步（.gitignore 里的生成物）：同树别的门禁步同时跑 Python 单测在写 .pyc 临时文件，rsync 扫到又消失报 code 24（10-24 test/sysdata full 门禁 7 秒红「源码同步到镜像失败」）
# 不保留源文件时间（不带 -t）、按内容比（-c）：内容没变的不重写（增量照样命中），变了的落当前时间。原先 -a 保留源时间：
#   镜像被别的分支编过（obj 时间更新），本分支改过但时间更早的文件被 MSBuild 当成没变、跳过重编，用了别的分支的旧 dll
#   （10-20 服务接入 DLC：S2AHooks 19:18 改、镜像里 Ryujinx.HLE.dll 19:24 别的分支编，报「S2AHooks 没有 OpenAocDataStorage」）
rsync -rlpDc --delete --exclude /build/ --exclude .git --exclude obj/ --exclude bin/ --exclude __pycache__/ "$R/" "$S/" || { echo "期望 iOS 编译链接通过 → 真结果 源码同步到镜像失败"; exit 1; }
# 编译缓存（tools/cc_cache.sh，门禁已开）的路径改写以镜像为根：本步在镜像里编，镜像按树号各一份，以镜像为根才能跨树命中
[ -n "${S2A_CCACHE_BIN:-}" ] && export CCACHE_BASEDIR=$S
# 出壳输入闭包（11-11 维护者：新增出壳输入漏登 pack/stage_inputs/shell.tsv 第三次——razor1 让 make ios 读体验规格生成文案，4 个文件没登记，
#   门禁不查、到发版出壳 pack/shell_build.sh 核闭包才红删壳）：用出壳同一套核对（pack/shell/closure.py）。镜像由本步独占（镜像锁），
#   rsync 之后、make ios 之前把镜像里的仓库文件访问时间设旧（清单取自本树 git），make 完看被读过的文件是否都在表里，漏登就红、点名文件。
#   有缓存的热编也抓得到：新依赖只能经由改已登记的文件引入，那部分必然重编、新文件必然被读到（closure.py 文件头）。
#   核对放在写游戏镜像包之前：ios/embed.py 是按款出包的一半，不算出壳
#   工具链先选好再设旧（同 pack/shell_build.sh：source tools/toolchain.sh 在 closure.py mark 之前）：不然 make 第一行按 Makefile 的
#   $(or $(S2A_DEVELOPER_DIR),…,$(shell . tools/toolchain.sh …)) 现选 Xcode，tools/toolchain.sh、pack/jobs/toolchain.py 一串 8 个文件被算成「出壳读到」误红；
#   值与 Makefile 那条表达式同一个，make 照用
[ -z "${S2A_DEVELOPER_DIR:-}" ] && [ -f "$S/tools/toolchain.sh" ] && { DD=$(cd "$S" && S2A_TC_QUIET=1 bash -c '. tools/toolchain.sh > /dev/null && printf %s "$DEVELOPER_DIR"' 2> /dev/null); [ -n "$DD" ] && export S2A_DEVELOPER_DIR=$DD; }
CL=; [ -f "$S/pack/shell/closure.py" ] && [ -f "$S/pack/stage_inputs/shell.tsv" ] && grep -q -- '--list-from' "$S/pack/shell/closure.py" && \
  python3 "$S/pack/shell/closure.py" mark "$S" --list-from "$R" > /dev/null 2>&1 && CL=1
rm -f "$B/cs/nxaot_ios.err"; timeout "${GATE_IOS_WORK_S:-900}" make -s -C "$S" ios S2A_CS=1 IOS_BUNDLE=io.s2arm.gatecheck BUILD="$B" > "$B/gate.log" 2>&1; rc=$?
X=$B/ios/S2Arm.app/S2Arm
if [ $rc = 0 ] && [ -x "$X" ]; then ok=1; else ok=0; fi
CLR=; if [ $ok = 1 ] && [ -n "$CL" ]; then CLR=$(python3 "$S/pack/shell/closure.py" check "$S" 2>&1); [ $? = 0 ] && echo "$CLR" || { ok=0; rc=3; }; fi
# 全外置（11-04）：make ios 只出与游戏无关的壳；按款这一半再用同一款现成改写产物写一次游戏镜像包（ios/embed.py，出包组装 pack/ship_ext.py 调的同一份）
if [ $ok = 1 ]; then MS=$(cd "$M" && ls *.fixups.tsv | sed 's/\.fixups\.tsv$//')
  # shellcheck disable=SC2086
  python3 "$S/ios/embed.py" "$M" "$B/S2AImages.dylib" $MS >> "$B/gate.log" 2>&1 && [ -s "$B/S2AImages.dylib" ] || { ok=0; rc=2; echo "写游戏镜像包失败（ios/embed.py）"; }; rm -f "$B/S2AImages.dylib"; fi
# 失败时附配方最后 30 行原样（10-24：目录没了时配方报的是「No such file」「🔴 make ios …」，不含 error 字样，原先只 grep error 只剩一行 make Error 1）
[ $ok = 1 ] || [ $rc = 3 ] || { grep -E 'error|Error' "$B/gate.log" | head -8; echo "—— make ios 最后 30 行 ——"; tail -30 "$B/gate.log"; echo "—— 完 ——"; }
WS=${GATE_IOS_WORK_S:-900}; ov=; [ $rc = 124 ] && ov="，干活超 ${WS} 秒"
# NativeAOT 缓存命中与否（10-30 列车线，调研报告⑥：注释写「热编约 5 秒」、实测每批一两分钟，要当场看得见）：nxaot.sh 只在没命中时打「nxaot：编」
NX=; [ -s "$B/cs/nxaot_ios.err" ] && { if grep -q 'nxaot：编' "$B/cs/nxaot_ios.err"; then NX="，NativeAOT 现编 $(sed -n 's/.*用时 \([0-9]*\) 秒.*/\1/p' "$B/cs/nxaot_ios.err" | tail -1) 秒"; else NX="，NativeAOT 命中"; fi; }
[ $rc = 3 ] && { echo "$CLR"; echo "期望 iOS 壳编译 + 链接出可执行文件、出壳读到的仓库文件都在 pack/stage_inputs/shell.tsv → 真结果 出壳闭包漏登记（编译链接本身通过）"; exit 1; }
echo "期望 iOS 壳编译 + 链接出可执行文件、游戏镜像包写得出 → 真结果 $([ $ok = 1 ] && echo 通过 || echo "失败 rc=$rc") （干活 $((SECONDS - t0)) 秒、排队 $((t0 - q0)) 秒${ov}${NX}，改写产物 ${MN}（克隆）)"
[ $ok = 1 ]
