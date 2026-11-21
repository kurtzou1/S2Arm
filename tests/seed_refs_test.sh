#!/bin/bash
# seed_refs 单测（tools/seed_refs.py + gc.sh 联动，约 2 秒）：bash tests/seed_refs_test.sh
# 期望（按规则手写）：
#   ① 打印引用：两个根各有 seed.txt，共 3 个 src；去重后输出 2 行（root2/seed1 和 root1/seed1 同 src）
#   ② --check 命中 src 本身 → 退出 1；命中 src 的祖先目录 → 退出 1；不相干路径 → 退出 0
#   ③ --missing：只列 src 不存在的那条
#   ④ gc.sh：被 seed.txt 的 src= 引用的目录不删；同类未引用目录照删
#   ⑤ src 是符号链接（10-29 运维线：ops_pkg/xc3_extract_221 → SSD，按 src 原文核在用漏了链接后面的真实目录）：打印里有真实目录，--check 真实目录 → 退出 1
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0   # pwd -P：/var 是指向 /private/var 的链接，不解开时每个 src 都多出一行真实路径
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }

# ── 搭建两个虚拟根目录 ──────────────────────────────────────────────
R1=$T/roots/g1; R2=$T/roots/g2
mkdir -p "$R1/v1" "$R1/v2" "$R2/v1"
SRC_EXIST=$T/orig/romfs; mkdir -p "${SRC_EXIST}"
SRC_MISSING=$T/orig/gone   # 故意不建，模拟已删除

# root1: src 存在
printf 'src=%s\ntag=t1\n' "$SRC_EXIST" > "$R1/v1/seed.txt"
# root2: 和 root1 相同 src（去重用）
printf 'src=%s\ntag=t2\n' "$SRC_EXIST" > "$R2/v1/seed.txt"
# root1 另一版本: src 不存在（--missing 用）
printf 'src=%s\ntag=t3\n' "$SRC_MISSING" > "$R1/v2/seed.txt"

export S2A_ROOTS="$T/roots/g1:$T/roots/g2"

# ① 打印引用：去重，期望 2 行（SRC_EXIST 与 SRC_MISSING）
out=$(python3 "$H/tools/seed_refs.py" 2>&1)
ck "①打印引用：去重后 2 行（${out//$'\n'/ }）" \
  '[ "$(echo "$out" | grep -c .)" = 2 ] && grep -qF "$SRC_EXIST" <<< "$out" && grep -qF "$SRC_MISSING" <<< "$out"'

# ② --check：命中 src 本身
python3 "$H/tools/seed_refs.py" --check "$SRC_EXIST" > /dev/null 2>&1; r=$?
ck "② --check 命中 src 本身 → 退出 1" '[ $r = 1 ]'

# --check 命中 src 的祖先目录（T/orig 是 SRC_EXIST 的父目录）
python3 "$H/tools/seed_refs.py" --check "$T/orig" > /dev/null 2>&1; r=$?
ck "② --check 命中 src 祖先 → 退出 1" '[ $r = 1 ]'

# --check 命中 src 下的子目录
python3 "$H/tools/seed_refs.py" --check "$SRC_EXIST/sub" > /dev/null 2>&1; r=$?
ck "② --check 命中 src 子孙 → 退出 1" '[ $r = 1 ]'

# --check 不相干路径
python3 "$H/tools/seed_refs.py" --check "$T/other" > /dev/null 2>&1; r=$?
ck "② --check 不相干路径 → 退出 0" '[ $r = 0 ]'

# ③ --missing：只列 SRC_MISSING 那条
out=$(python3 "$H/tools/seed_refs.py" --missing 2>&1)
ck "③ --missing 报出不存在的 src（${out//$'\n'/ }）" \
  'grep -qF "$SRC_MISSING" <<< "$out" && ! grep -qF "$SRC_EXIST" <<< "$out"'

# ④ gc.sh 联动：被 seed 引用的目录不删；未引用的同类目录照删
# 搭建最小化的 gc 运行环境（照 gc_test.sh 造法）
export S2A_WT_ROOT=$T/wt S2A_REPO=$T/repo S2A_BOARD=$T/board.tsv
export S2A_GC_FREE_GB=999 S2A_GC_WT_DIRS=$T/wt_none S2A_GC_CDDELTA=$T/cd_none
export GAL_PSO_CACHE=$T/pc_none GAL_AIR_CACHE=$T/air_none GAL_DL_CACHE=$T/dl_none
export S2A_PACK_SLOT_DIR=$T/locks_none

rm -rf "$T/run4"; mkdir -p "$T/run4/roots" "$T/run4/sched" "$T/run4/wip/ops"
# wip 下两个目录：xc3_extract 被 seed 引用，xc3_extract_old 未引用
PROT_DIR=$T/run4/wip/ops/xc3_extract; FREE_DIR=$T/run4/wip/ops/xc3_extract_old
mkdir -p "${PROT_DIR}/romfs" "${FREE_DIR}/romfs"
# 产物根 seed.txt 的 src 直接指向 wip 下的 PROT_DIR（gc.sh 内部按 $S/roots 扫，能扫到）
R4=$T/run4/roots/xc3@v1; mkdir -p "${R4}"
printf 'src=%s\ntag=gctest\n' "${PROT_DIR}" > "${R4}/seed.txt"
# 造现行软链与旧版本，gc 产物根规则需要
mkdir -p "$T/run4/roots/xc3@v0"; printf '%s\n' xc3@v1 > "$T/run4/roots/xc3@现行"
# 把两个 wip 条目拨到 7 小时前，触发 gc 的 wip 6 小时闲删
python3 -c "
import os, sys, time
t = time.time() - 7 * 3600
for base in sys.argv[1:]:
    for path, dirs, files in os.walk(base):
        os.utime(path, (t, t))
        for f in files:
            os.utime(os.path.join(path, f), (t, t))
" "${PROT_DIR}" "${FREE_DIR}"

# ⑤ src 是符号链接：真实目录也算被引用
mkdir -p "$T/ssd/real_extract" "$T/roots/g3/v1"; ln -s "$T/ssd/real_extract" "$T/orig/link_extract"
printf 'src=%s\ntag=t5\n' "$T/orig/link_extract" > "$T/roots/g3/v1/seed.txt"
out5=$(S2A_ROOTS="$T/roots/g3" python3 "$H/tools/seed_refs.py" 2>&1); S2A_ROOTS="$T/roots/g3" python3 "$H/tools/seed_refs.py" --check "$T/ssd/real_extract" > /dev/null 2>&1; r=$?
ck "⑤ src 是链接：打印有链接与真实目录两行（${out5//$'\n'/ }）、--check 真实目录退出 1（rc=${r}）" '[ "$(grep -c . <<< "$out5")" = 2 ] && grep -qxF "$T/ssd/real_extract" <<< "$out5" && [ $r = 1 ]'
# ⑥ 不进产物根里面找（11-02：旧版 os.walk 把每个根的 romfs 目录项全列一遍，一轮 gc 扫十几分钟）：根自己有 seed.txt 就记下、不往里走；
#   期望手写：根 roots6/g6-v1 有 seed.txt（src=A），它的 romfs/deep 里放一个假的 seed.txt（src=B）→ 只认 A；根 roots6/g6-v2.tmp 没有 seed.txt、里面第 2 层有 seed.txt（src=C）→ 认 C
mkdir -p "$T/roots6/g6-v1/romfs/deep" "$T/roots6/g6-v2.tmp/inner"
printf 'src=/srcA\n' > "$T/roots6/g6-v1/seed.txt"; printf 'src=/srcB\n' > "$T/roots6/g6-v1/romfs/deep/seed.txt"; printf 'src=/srcC\n' > "$T/roots6/g6-v2.tmp/inner/seed.txt"
out6=$(S2A_ROOTS="$T/roots6" python3 "$H/tools/seed_refs.py" 2>&1 | tr '\n' ' ')
ck "⑥ 只认根自己的 seed.txt（A）与没有 seed.txt 的目录里找到的（C），不进根里面（B 不认）（实得：${out6}）" '[ "$out6" = "/srcA /srcC " ]'
[ $bad = 0 ] && echo "✓ seed_refs 单测全过" || { echo "seed_refs 单测有不通"; exit 1; }
