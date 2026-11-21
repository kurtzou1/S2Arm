#!/bin/bash
# 宽屏自动出表结论三态单测（10-29：基础设施失败被记成判据「不过」、按工具版本冻结不再重跑），不起局、约 5 秒：bash tests/widen_auto_infra_test.sh
# 门禁覆盖：graphics/widen/scan/loop_state.sh graphics/widen/scan/closed_loop.sh graphics/widen/scan/auto_table.sh graphics/widen/scan/auto_pkg.sh graphics/widen/scan/auto_kick.sh tools/widen_accept.py
# 三态：过 = 判出可用表；不过 = 局起来了、到了判断点（到 MARK，或开着点集崩了），判出画面问题；未判 = 基础设施失败，或没到判断点又不是画面原因。
# 期望（手算，不跑被测实现）：
#   A 局目录判定（graphics/widen/scan/loop_state.sh，造出来的局目录）：等负载 / 排队超时「；局没起」、构建失败、链号不一致（【红】）、存档准备失败、局超时、
#     没有 host.log、verdict 空、起了没崩没到 MARK → 未判，说明里带对应信号；链号【黄】放行后到 MARK 判出露空、崩溃、只有⑩不过但对照局正常、
#     主局①–⑤有不过（对照局没起也算）、没有界面路线 → 不过；全过 → 过；只有⑩不过且对照局没起 / 界面项不过且界面局构建失败 → 未判
#   B closed_loop.sh --rejudge-write 真走一遍（不起局）：局超时没到 MARK → 退 75；构建号对不上 → 退 75；负对照：到了 MARK、没录像 → 退 1；
#     直连局（host.log 图形模式：直连）④ 按核心改投影占比、⑤ 按截图 16:9 断崖判，各带负对照
#   C auto_table.sh（闭环换成桩，桩按 closed_loop 的退出码约定：0 过 / 1 不过 / 75 未判）：
#     C1 闭环未判 → status 第 1 行未判、退 75、点集缓存不记；C2 再触发 → 照常重排（桩又被调）、出表过
#     C3 负对照：闭环真不过 → status 不过；再触发 → 「已有结论」、桩 0 次
#     C4 旧的冻结缓存（点集缓存旧格式 3 列、rc=1，来自局没起的那局）不再复用：整组那局真重跑
#     C5 探测局未判（没到 MARK、没崩）→ 未判，不再冻结成「探测局没到 MARK」不过；再触发真重跑探测局
#     C6 已有「过」后再跑一次未判：status 第 1 行未判、第 2 行留着上次的过
#     C7 探测局开全部候选崩：崩前执行到的点剔出候选重探（最多 3 轮），出表过、后续组合不含嫌疑点；C8 负对照：每轮都崩 → 候选剔空 / 3 轮后不过
#   D auto_pkg.sh list：最近一条结论（过 / 不过）是过才选自动表——mhrise 式（结论不过、旧通过表还在）不选；未判压在不过上不选；
#     未判压在过上照选（C6 那格）；没有 status 不选；过照选
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=1; fi; }
LS=$H/graphics/widen/scan/loop_state.sh
# ── A 局目录判定 ──
V() { local d=$1; shift; mkdir -p "$d"; : > "$d/verdict.tsv"; for r in "$@"; do printf '%s\t%s\tx\n' "${r%%=*}" "${r#*=}" >> "$d/verdict.tsv"; done; }
ALLB=("①崩溃 / MARK=不过" "②点都执行到=不过" "③出图满宽=不过" "④3D 镜头比=不过" "⑤露空 ≤0.5%=不过")
GOOD=("①崩溃 / MARK=过" "②点都执行到=过" "③出图满宽=过" "③b上屏满屏=过" "④3D 镜头比=过")
MARK='S2A 标记 MARK：帧 100'
st() { bash "$LS" "$T/a/$1" 2> /dev/null; }
a() { local s w=$2 k=${3:-} r; s=$(st "$1"); r=$?; ck "A $1：期望 ${w}${k:+（说明含「${k}」）} → 实「${s:-（空）}」（rc=${r}）" '[ "$(cut -f1 <<< "$s")" = "$w" ] && [[ "$s" == *"$k"* ]]'; }   # ck 里 eval 的 $2 是 ck 自己的参数，期望值走局部变量
V "$T/a/wait_load" "${ALLB[@]}"; printf '独占局 宽屏闭环 zz：等实测 CPU 空闲到 40%%（现 12%%）\n🔴 独占局 宽屏闭环 zz：等了 3601 秒，实测 CPU 空闲没到 40%%（现 12%%）；局没起\n' > "$T/a/wait_load/run.out"
a wait_load 未判 局没起
V "$T/a/wait_load_old" "${ALLB[@]}"; printf '🔴 独占局 宽屏闭环 smg2：等了 3601 秒，出包没停或负载没降（1 分钟负载 62 / 18 核）；局没起\n' > "$T/a/wait_load_old/run.out"
a wait_load_old 未判 局没起
V "$T/a/slot_queue" "${ALLB[@]}"; printf '🔴 Mac 局槽：宽屏闭环 zz 排队超时（排了 1801 秒，排队上限 1800 秒；局没起）\n' > "$T/a/slot_queue/run.out"
a slot_queue 未判 局没起
V "$T/a/build" "${ALLB[@]}"; printf 'services/build.mk:11: *** services/nxaot.sh 失败.  Stop.\n🔴 构建失败\n' > "$T/a/build/run.out"
a build 未判 构建失败
V "$T/a/chain" "${ALLB[@]}"; printf '【红】Mac 起局链号不一致：产物 373c9df83002，宿主 6b8af7fe3786；请重出产物，专测回退时设 S2A_ALLOW_CHAIN_MISMATCH=1\n' > "$T/a/chain/run.out"
a chain 未判 链号
V "$T/a/save" "${ALLB[@]}"; : > "$T/a/save/run.out"; printf '【红】存档：拷 /x 失败\n' > "$T/a/save/save.txt"
a save 未判 存档
V "$T/a/timeout" "${ALLB[@]}"; printf 'make: ...\n🔴 宽屏闭环 zz：局超时（拿到槽后 295 秒没出结果）\n' > "$T/a/timeout/run.out"; printf '[s2a] boot\n' > "$T/a/timeout/host.log"
a timeout 未判 局超时
V "$T/a/timeout_mark" "①崩溃 / MARK=不过" "②点都执行到=过" "③出图满宽=不过"; printf '🔴 宽屏闭环 zz：局超时（拿到槽后 295 秒没出结果）\n' > "$T/a/timeout_mark/run.out"; printf '%s\n' "$MARK" > "$T/a/timeout_mark/host.log"
a timeout_mark 未判 局超时
V "$T/a/nohost" "${ALLB[@]}"; : > "$T/a/nohost/run.out"
a nohost 未判 host.log
V "$T/a/empty"
a empty 未判 判据
V "$T/a/nomark" "${ALLB[@]}"; printf 'zz 收局 rc=0，未实现系统调用： 无\n' > "$T/a/nomark/run.out"; printf '[s2a] boot\n[s2a] 收局\n' > "$T/a/nomark/host.log"
a nomark 未判 MARK
V "$T/a/real_bad" "${GOOD[@]}" "⑤露空 ≤0.5%=不过"; printf 'zz 收局 rc=0，未实现系统调用： 无\n' > "$T/a/real_bad/run.out"; printf '%s\n' "$MARK" > "$T/a/real_bad/host.log"
a real_bad 不过 ⑤
V "$T/a/chain_yellow" "${GOOD[@]}" "⑤露空 ≤0.5%=不过"; printf '【黄】Mac 起局链号不一致：产物 a，宿主 b；S2A_ALLOW_CHAIN_MISMATCH=1 显式放行\n' > "$T/a/chain_yellow/run.out"; printf '%s\n' "$MARK" > "$T/a/chain_yellow/host.log"
a chain_yellow 不过
V "$T/a/crash" "${ALLB[@]}"; printf '🔴 zz：崩溃（见 host.log）\n' > "$T/a/crash/run.out"; printf '[s2a] CRASH at main+0x10\n' > "$T/a/crash/host.log"
a crash 不过
V "$T/a/base_down" "${GOOD[@]}" "⑤露空 ≤0.5%=过" "⑩界面裁剪不多切=不过"; printf '%s\n' "$MARK" > "$T/a/base_down/host.log"; : > "$T/a/base_down/run.out"
mkdir -p "$T/a/base_down/base"; printf '🔴 独占局 宽屏闭环对照 zz：等了 3600 秒，实测 CPU 空闲没到 40%%（现 3%%）；局没起\n' > "$T/a/base_down/base/run.out"
a base_down 未判 对照局
V "$T/a/base_down_main_bad" "${GOOD[@]}" "⑤露空 ≤0.5%=不过" "⑩界面裁剪不多切=不过"; printf '%s\n' "$MARK" > "$T/a/base_down_main_bad/host.log"; : > "$T/a/base_down_main_bad/run.out"
mkdir -p "$T/a/base_down_main_bad/base"; printf '🔴 构建失败\n' > "$T/a/base_down_main_bad/base/run.out"
a base_down_main_bad 不过 ⑤
V "$T/a/base_ok" "${GOOD[@]}" "⑤露空 ≤0.5%=过" "⑩界面裁剪不多切=不过"; printf '%s\n' "$MARK" > "$T/a/base_ok/host.log"; : > "$T/a/base_ok/run.out"
mkdir -p "$T/a/base_ok/base"; printf 'zz 收局 rc=0\n' > "$T/a/base_ok/base/run.out"; printf '%s\n' "$MARK" > "$T/a/base_ok/base/host.log"
a base_ok 不过 ⑩
V "$T/a/ui_noroute" "${GOOD[@]}" "⑤露空 ≤0.5%=过" "⑥界面路线=不过"; printf '%s\n' "$MARK" > "$T/a/ui_noroute/host.log"; : > "$T/a/ui_noroute/run.out"; mkdir -p "$T/a/ui_noroute/ui"
a ui_noroute 不过 ⑥
V "$T/a/ui_build" "${GOOD[@]}" "⑤露空 ≤0.5%=过" "⑥界面路线 0 崩=不过" "⑨界面点都执行到=不过"; printf '%s\n' "$MARK" > "$T/a/ui_build/host.log"; : > "$T/a/ui_build/run.out"
mkdir -p "$T/a/ui_build/ui"; printf '🔴 构建失败\n' > "$T/a/ui_build/ui/run.out"
a ui_build 未判 界面局
V "$T/a/pass" "${GOOD[@]}" "⑤露空 ≤0.5%=过"; printf '%s\n' "$MARK" > "$T/a/pass/host.log"
a pass 过
# ── B closed_loop.sh --rejudge-write 真走（不起局：离线重判只读局目录）──
r=$T/roots/zz@v1; mkdir -p "$r/exefs"; printf '%s\n' zz@v1 > "$T/roots/zz@现行"
{ head -c 64 /dev/zero; printf 'BIDBIDBIDBIDBID1'; } > "$r/exefs/main"; B=$(xxd -s 0x40 -l 16 -p "$r/exefs/main")
printf '模块\t偏移\t种类\t证据\nmain\t0x10\tf2w\tx\nmain\t0x20\tmovz\tx\nmain\t0x30\taspdiv\tx\n' > "$r/widen_sites.tsv"
bd() { mkdir -p "$1"; cp "$r/widen_sites.tsv" "$1/"; echo "${3:-$B}" > "$1/bid"; echo "$2" > "$1/rc"; }
CL() { env S2A_ROOTS=$T/roots S2A_LOOP_MODE=handheld S2A_LOOP_UICLIP=0 S2A_WIDEN_DIR=$T/tables bash "$H/graphics/widen/scan/closed_loop.sh" zz "$1" main:0x10 mark+150:4 --rejudge-write > "$1.out" 2>&1; echo $?; }
bd "$T/b/timeout" 124; printf '[s2a] boot\n' > "$T/b/timeout/host.log"; printf '🔴 宽屏闭环 zz：局超时（拿到槽后 295 秒没出结果）\n' > "$T/b/timeout/run.out"
c=$(CL "$T/b/timeout"); ck "B 局超时没到 MARK：closed_loop 退 75（实 ${c}，$(grep -m1 -e 未判 -e 不过 "$T/b/timeout.out" | cut -c1-80)）" '[ "$c" = 75 ]'
bd "$T/b/bid" 0 00000000000000000000000000000009; printf '%s\n' "$MARK" > "$T/b/bid/host.log"; : > "$T/b/bid/run.out"
c=$(CL "$T/b/bid"); ck "B 构建号对不上：退 75（实 ${c}）" '[ "$c" = 75 ]'
bd "$T/b/real" 0; printf '%s\n[宽] 点 main+0x10 首次命中\n' "$MARK" > "$T/b/real/host.log"; printf 'zz 收局 rc=0\n' > "$T/b/real/run.out"
c=$(CL "$T/b/real"); ck "B 负对照：到了 MARK、没录像（④⑤不过）→ 退 1（实 ${c}）" '[ "$c" = 1 ]'
# B 直连判法（11-01：闭环原先写死通用局）：host.log「图形模式：直连」→ ④ 看核心改投影占比、⑤ 看截图 16:9 断崖（期望手算）：
#   本局 rewritten 300 / into core 1000 = 0.3，对照局 960 / 1000 = 0.96 → 0.3 ≤ 0.48 ④ 过；本局也 0.96 → 0.96 > 0.48 ④ 不过
#   截图 2346×1080 满幅噪声 → 断崖 ≈ 0 ⑤ 过；16:9 边界（213 / 2133 列）以外两侧纯黑 → 断崖 ≈ 1 ⑤ 不过
bdd() {   # bdd <局目录> <本局改写数> <两侧黑 0|1>
  bd "$1" 0; mkdir -p "$1/base"; echo 0 > "$1/base/rc"
  printf '[s2a] 图形模式：直连（依据 测试）\n%s\n[宽] 点 main+0x10 首次命中\n[dm] S2Arm widen: submits 300, draws 1200 (into core 1000, rewritten %s with 5 new copies)\n' "$MARK" "$2" > "$1/host.log"
  printf '[dm] S2Arm widen: submits 300, draws 1200 (into core 1000, rewritten 960 with 5 new copies)\n' > "$1/base/host.log"; : > "$1/run.out"
  python3 -c "
import sys, numpy as np; from PIL import Image
a = np.random.default_rng(1).integers(40, 220, (1080, 2346, 3), dtype=np.uint8)
if sys.argv[2] == '1': a[:, :213] = 0; a[:, 2133:] = 0
for f in ('ap_mark', 'ap_end'): Image.fromarray(a).save(sys.argv[1] + '/' + f + '.png')" "$1" "$3"; }
vd() { awk -F'\t' -v k="$2" 'index($1, k) == 1 { print $2 }' "$1/verdict.tsv"; }
bdd "$T/b/dgood" 300 0; CL "$T/b/dgood" > /dev/null
ck "B 直连：改写占比 0.3 ≤ 0.96×0.5 → ④ 过（实 $(vd "$T/b/dgood" ④)）；满幅截图 → ⑤ 过（实 $(vd "$T/b/dgood" ⑤)）" '[ "$(vd "$T/b/dgood" ④)" = 过 ] && [ "$(vd "$T/b/dgood" ⑤)" = 过 ]'
bdd "$T/b/dsame" 960 0; CL "$T/b/dsame" > /dev/null
ck "B 直连负对照：本局改写占比 0.96 = 对照局 → ④ 不过（实 $(vd "$T/b/dsame" ④)）" '[ "$(vd "$T/b/dsame" ④)" = 不过 ]'
bdd "$T/b/dcliff" 300 1; CL "$T/b/dcliff" > /dev/null
ck "B 直连负对照：16:9 以外两侧纯黑 → ⑤ 不过（实 $(vd "$T/b/dcliff" ⑤)）" '[ "$(vd "$T/b/dcliff" ⑤)" = 不过 ]'
# B ③c 空洞按对照局边际判（11-01 胡闹宇航员：舱外本来就暗，开点左带 +0.28、对照局 +0.96 却判不过）。期望手算：
#   本局左带（0–213 列）0–150 列纯灰 → 空洞约 +0.7，对照局左带全黑（量不出，按 1.0）：本局比对照局好 → ③c 过
#   本局同上约 +0.7，对照局满幅噪声 → 约 0：本局比对照局坏 → ③c 不过
bimg() {   # bimg <png> <左带：0 噪声 / gray 第 0–150 列纯灰（不碰 16:9 边界、不造接缝）/ black 整列黑>
  python3 -c "
import sys, numpy as np; from PIL import Image
a = np.random.default_rng(2).integers(40, 220, (1080, 2346, 3), dtype=np.uint8); m = sys.argv[2]
if m == 'gray': a[:, :150] = 128
if m == 'black': a[:, :213] = 0
Image.fromarray(a).save(sys.argv[1])" "$1" "$2"; }
bdd "$T/b/hgood" 300 0; for f in ap_mark ap_end; do bimg "$T/b/hgood/$f.png" gray; bimg "$T/b/hgood/base/$f.png" black; done; CL "$T/b/hgood" > /dev/null
ck "B ③c 边际：本局左带空洞约 0.7 < 对照局纯黑（1.0） → 过（实 $(vd "$T/b/hgood" ③c)）" '[ "$(vd "$T/b/hgood" ③c)" = 过 ]'
bdd "$T/b/hbad" 300 0; for f in ap_mark ap_end; do bimg "$T/b/hbad/$f.png" gray; bimg "$T/b/hbad/base/$f.png" 0; done; CL "$T/b/hbad" > /dev/null
ck "B ③c 边际负对照：本局左带空洞约 0.7 > 对照局约 0 → 不过（实 $(vd "$T/b/hbad" ③c)）" '[ "$(vd "$T/b/hbad" ③c)" = 不过 ]'
# B ③c 截图不是加宽图（11-09 哈迪斯 II：Mac 窗口 16:9、2.17:1 画面上下加黑边塞进截图，band_checks 不量，原先记「过」）。期望：两张都是 1280×720 → ③c 未验
bdd "$T/b/h169" 300 0; for f in ap_mark ap_end; do python3 -c "
import sys, numpy as np; from PIL import Image
Image.fromarray(np.random.default_rng(3).integers(40, 220, (720, 1280, 3), dtype=np.uint8)).save(sys.argv[1])" "$T/b/h169/$f.png"; done; CL "$T/b/h169" > /dev/null
ck "B ③c 截图都是 16:9（不是加宽图）→ 未验，不记过（实 $(vd "$T/b/h169" ③c)）" '[ "$(vd "$T/b/h169" ③c)" = 未验 ]'
# ── C auto_table.sh（闭环桩）──
cat > "$T/stub.sh" <<'EOF'
#!/bin/bash
G=$1; D=$2; S=$3; FR=$4; W=${5:-}
echo "$S|$FR|${S2A_SCREEN_W:-}|$W" >> "$STUB_LOG"
if [ "$W" = --rejudge-write ]; then E=$S2A_WIDEN_DIR/${G}_$(cat "$D/bid"); mkdir -p "$E"; echo "$S" > "$E/widen_enable.$S2A_LOOP_MODE.tsv"; exit 0; fi
mkdir -p "$D"; echo "$STUB_BID" > "$D/bid"; printf '①\t不过\tx\n' > "$D/verdict.tsv"
if [ "${S2A_SCREEN_W:-}" = 1922 ]; then
  # STUB_PROBE=crash：点集含 main:0x30 时只命中它就崩；STUB_PROBE=crashall：每轮命中点集第一个点就崩
  case "${STUB_PROBE:-},$S," in crash,*,main:0x30,*|crashall,*) f=${S%%,*}; [ "${STUB_PROBE}" = crash ] && f=main:0x30
    printf '[宽] 点 %s 首次命中\n[s2a] 【红】CRASH 信号 11 地址 0x0\n' "${f/:/+}" > "$D/host.log"; exit 1;; esac
  [ "${STUB_PROBE:-}" = crash ] && { printf 'S2A 标记 MARK：帧 100\n[宽] 点 main+0x10 首次命中\n[宽] 点 main+0x20 首次命中\n' > "$D/host.log"; exit 1; }
  [ "${STUB_PROBE:-}" = 75 ] && { printf '[s2a] boot\n' > "$D/host.log"; echo "🟡 $G 闭环未判（不是画面结论，下次触发重排）：主局起了、没崩、没到 MARK"; exit 75; }
  printf 'S2A 标记 MARK：帧 100\n[宽] 点 main+0x10 首次命中\n[宽] 点 main+0x20 首次命中\n[宽] 点 main+0x30 首次命中\n' > "$D/host.log"; exit 1; fi
[ "${STUB_T:-}" = 75 ] && { printf '🔴 独占局 宽屏闭环 %s：等了 3601 秒，实测 CPU 空闲没到 40%%；局没起\n' "$G" > "$D/run.out"; echo "🟡 $G 闭环未判（不是画面结论，下次触发重排）：局没起"; exit 75; }
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
case ",$S," in *,main:0x10,*) case ",$S," in *,main:0x20,*) exit 0;; esac;; esac; exit 1
EOF
AT() { env STUB_BID=$B S2A_ROOTS=$T/roots S2A_WIDEN_AUTO=$T/auto S2A_WIDEN_DIR=$T/tables STUB_LOG=$T/log S2A_AUTO_LOOP=$T/stub.sh "$@" bash "$H/graphics/widen/scan/auto_table.sh" zz; }
E=$T/auto/zz_$B; nt() { grep -v -c -e '|1922|' -e rejudge "$T/log"; }
: > "$T/log"; o=$(AT STUB_T=75); rc=$?
ck "C1 闭环未判：status 第 1 行未判、退 75、点集缓存不记（rc ${rc}，status「$(head -1 "$E/handheld.status" 2> /dev/null | cut -f1,3 | cut -c1-60)」，缓存 $(wc -l < "$E/handheld.sets.tsv" 2> /dev/null | tr -d ' ') 行）" \
  '[ $rc = 75 ] && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 未判 ] && [ ! -s "$E/handheld.sets.tsv" ]'
: > "$T/log"; o=$(AT)
ck "C2 再触发：照常重排（桩 t 局 $(nt) 次）、出表过" '[ "$(nt)" -ge 1 ] && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 过 ] && [ -s "$E/widen_enable.handheld.tsv" ]'
rm -rf "$T/auto"; : > "$T/log"; o=$(AT STUB_FAIL=1)
ck "C3 负对照：闭环真不过 → status 不过（$(head -1 "$E/handheld.status" | cut -f1)）" '[ "$(head -1 "$E/handheld.status" | cut -f1)" = 不过 ]'
: > "$T/log"; o=$(AT)
ck "C3 负对照：再触发不重排（「已有结论」、桩 $(wc -l < "$T/log" | tr -d ' ') 次）" '[ ! -s "$T/log" ] && grep -q 已有结论 <<< "$o"'
rm -rf "$T/auto"; mkdir -p "$E"; printf 'main:0x10,main:0x20,main:0x30\tmark+150:4\t1\n' > "$E/handheld.sets.tsv"; : > "$T/log"; o=$(AT)
ck "C4 旧格式点集缓存（局没起记成 rc=1）不复用：整组那局真起了、出表过" 'grep -q "^main:0x10,main:0x20,main:0x30|mark+150:4||$" "$T/log" && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 过 ]'
rm -rf "$T/auto"; : > "$T/log"; o=$(AT STUB_PROBE=75); rc=$?
ck "C5 探测局没到 MARK（没崩）：未判、退 75（rc ${rc}，$(head -1 "$E/handheld.status" | cut -f1,3 | cut -c1-60)）" '[ $rc = 75 ] && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 未判 ]'
: > "$T/log"; o=$(AT)
ck "C5 再触发：探测局真重跑、出表过" 'grep -q "|1922|" "$T/log" && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 过 ]'
sed -i '' "1s/	[^	]*	/	oldver	/" "$E/handheld.status"; rm -f "$E/handheld.sets.tsv"; : > "$T/log"; o=$(AT STUB_T=75)
ck "C6 过（旧工具版本）后再跑未判：第 1 行未判、第 2 行留上次的过（$(cut -f1 "$E/handheld.status" | tr '\n' ' ')）" '[ "$(cut -f1 "$E/handheld.status" | tr "\n" " ")" = "未判 过 " ]'
# ── D auto_pkg.sh list ──
L() { env S2A_WIDEN_AUTO=$T/auto S2A_WIDEN_DIR=$T/tables bash "$H/graphics/widen/scan/auto_pkg.sh" list "$1" "$2" | sed "s|$T/||" | tr '\n' ' '; }
ck "D 未判压在过上：照选（$(L zz "$B")）" '[ "$(L zz "$B")" = "auto/zz_$B/widen_enable.handheld.tsv " ]'
dl() { mkdir -p "$T/auto/${1}_$B"; echo t > "$T/auto/${1}_$B/widen_enable.docked.tsv"; [ -n "$2" ] && printf "$2" > "$T/auto/${1}_$B/docked.status"; }
dl mh '不过\tv1\t最后一组 t7 重判不过\n'; ck "D mhrise 式：结论不过、旧通过表还在 → 不选（「$(L mh "$B")」）" '[ -z "$(L mh "$B")" ]'
dl un '未判\tv2\t局没起\n不过\tv1\tx\n'; ck "D 未判压在不过上 → 不选（「$(L un "$B")」）" '[ -z "$(L un "$B")" ]'
dl ns ''; ck "D 没有 status → 不选（「$(L ns "$B")」）" '[ -z "$(L ns "$B")" ]'
dl ok '过\tv1\t启用 x\n'; ck "D 过 → 选（「$(L ok "$B")」）" '[ "$(L ok "$B")" = "auto/ok_$B/widen_enable.docked.tsv " ]'
rm -rf "$T/auto"; : > "$T/log"; o=$(AT STUB_PROBE=crash)
ck "C7 探测局开全部候选崩（崩前只命中 main:0x30）→ 剔除重探、出表过、后续组合不含它（status $(head -1 "$E/handheld.status" | cut -f1)，探测 $(grep -c '|1922|' "$T/log") 次）" \
  '[ "$(head -1 "$E/handheld.status" | cut -f1)" = 过 ] && [ "$(grep -c "|1922|" "$T/log")" = 2 ] && ! grep -v "|1922|" "$T/log" | grep -q "main:0x30" && [ -d "$E/handheld/probe_crash1" ] && grep -q "剔除崩前执行到的嫌疑点 main:0x30" "$E/handheld.log"'
rm -rf "$T/auto"; : > "$T/log"; o=$(AT STUB_PROBE=crashall)
ck "C8 负对照：每轮都崩 → 候选 3 个每轮剔 1 个、剔空后判不过（status $(head -1 "$E/handheld.status" | cut -f1,3 | cut -c1-50)，探测 $(grep -c '|1922|' "$T/log") 次）" \
  '[ "$(head -1 "$E/handheld.status" | cut -f1)" = 不过 ] && [ "$(grep -c "|1922|" "$T/log")" = 3 ]'
echo "宽屏自动出表三态单测：$([ $fail = 0 ] && echo 全过 || echo 有失败)"; exit $fail
