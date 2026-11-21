#!/bin/bash
# tools/gate_ios.sh 单测（10-24：门禁开头解析的改写产物根在门禁中途被 root_commit 删掉，make ios 编到一半目录没了误红）：
#   假 make 编译途中删掉共享根的那一版 → 新代码读的是门禁自己的克隆，照常出可执行文件、绿；
#   假 make 失败、配方报「No such file」类不含 error 的行 → 门禁结论里带配方最后 30 行
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 小仓库（gate_ios.sh 在仓库根跑、把整棵树 rsync 进镜像）
mkdir -p $T/repo/tools $T/repo/ios $T/repo/pack/orch && cp $H/tools/gate_ios.sh $T/repo/tools/ && cp $H/pack/roots.sh $T/repo/pack/ && cp $H/pack/orch/current.py $T/repo/pack/orch/ && cp $H/ios/embed.py $H/ios/macho_dylib.py $T/repo/ios/ && git -C $T/repo init -q && git -C $T/repo add -A && git -C $T/repo -c user.email=t@t -c user.name=t commit -qm t
# 改写产物（格式有效的假模块：门禁要用它真写一次游戏镜像包）：TEXT_END 0x5000、键页 0x8000、PATCH_OFF 0xC000、patched.bin 0xD000 字节
mods() { mkdir -p "$1"; head -c 53248 /dev/zero > "$1/main.patched.bin"; printf '# TEXT_END 0x5000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n' > "$1/main.fixups.tsv"; echo g > "$1/main.gates.tsv"; echo n > "$1/main.npdm"; }
# 共享根：acnh@现行 → acnh@pkg-old（带改写产物）
mods $T/roots/acnh@pkg-old; printf '%s\n' acnh@pkg-old > $T/roots/acnh@现行
# 假 make（11-04 全外置后 make ios 只出壳、不收改写产物）：编译途中删掉共享根那一版（模拟登记新包时 root_commit 清旧版），门禁随后用自己的克隆写游戏镜像包；
#   TRACE 记 make 收到的全部参数（核没有 IOS_MODS）；FAIL=1 时模拟配方失败
mkdir -p $T/bin; cat > $T/bin/make <<'MK'
#!/bin/bash
for a in "$@"; do case $a in BUILD=*) B=${a#*=};; esac; done
[ -z "${TRACE:-}" ] || printf '%s\n' "$*" >> "$TRACE"
rm -rf "$DEL_ROOT"; sleep 0.2
if [ "${FAIL:-0}" = 1 ]; then for i in $(seq 1 40); do echo "配方行 $i"; done; echo "cp: build/x.o: No such file or directory"; echo "🔴 make ios 失败"; exit 2; fi
mkdir -p "$B/ios/S2Arm.app" && printf '#!/bin/sh\n' > "$B/ios/S2Arm.app/S2Arm" && chmod +x "$B/ios/S2Arm.app/S2Arm"
MK
chmod +x $T/bin/make
run() { (cd $T/repo && env -u GATE_IOS_MODS PATH=$T/bin:$PATH DEL_ROOT=$T/roots/acnh@pkg-old S2A_ROOTS_SHARED=$T/roots GATE_IOS_DIR=$T/gi "$@" bash tools/gate_ios.sh); }
o1=$(run env 2>&1); r1=$?
ck "门禁中途删掉共享根那一版：照常编完、绿（rc=${r1}）、结论写改写产物 acnh@pkg-old（克隆）" '[ $r1 = 0 ] && grep -q "通过" <<< "$o1" && grep -q "acnh@pkg-old（克隆）" <<< "$o1"'
ck "门禁结束后自己的克隆目录已清（gi/*/mods.* 没有残留）" '[ -z "$(ls -d $T/gi/*/mods.* 2> /dev/null)" ]'
mods $T/roots/acnh@pkg-old
o2=$(run env FAIL=1 2>&1); r2=$?
ck "配方失败（报错行不含 error）：门禁红（rc=${r2}），结论附配方最后 30 行（含 No such file 与 🔴 行、不含配方行 1–12）" '[ $r2 != 0 ] && grep -q "make ios 最后 30 行" <<< "$o2" && grep -q "No such file" <<< "$o2" && grep -q "🔴 make ios 失败" <<< "$o2" && grep -q "配方行 40" <<< "$o2" && ! grep -q "配方行 12$" <<< "$o2"'

# 开发者只有非旧白名单款的现行，也能选；不依赖商业游戏输入。
mods "$T/roots/silksong@pkg-local"; printf '%s\n' silksong@pkg-local > "$T/roots/silksong@现行"
o=$(run env 2>&1); rc=$?
ck "共享根只有其他款的完整现行也能检查（rc=${rc}）" '[ "$rc" = 0 ] && grep -q "silksong@pkg-local（克隆）" <<< "$o"'
mods "$T/roots/acnh@pkg-old"
o=$(run env 2>&1); rc=$?
ck "多款可用时保留既有动森优先顺序（rc=${rc}）" '[ "$rc" = 0 ] && grep -q "acnh@pkg-old（克隆）" <<< "$o"'

mods "$T/developer mods"; before=$(shasum "$T/developer mods/"*)
o=$(run env GATE_IOS_MODS="$T/developer mods" TRACE="$T/trace" 2>&1); rc=$?
after=$(shasum "$T/developer mods/"*)
ck "显式目录可含空格、优先于共享根，输入逐字节未改（rc=${rc}）" '[ "$rc" = 0 ] && grep -q "developer mods（克隆）" <<< "$o" && [ "$before" = "$after" ] && [ -s "$T/trace" ]'
ck "make 只出壳：拿不到任何改写产物路径（没有 IOS_MODS、没有开发者原目录）" '! grep -q "IOS_MODS\|developer mods" "$T/trace"'

rm -f "$T/trace"
o=$(run env GATE_IOS_MODS="$T/not-there" TRACE="$T/trace" 2>&1); rc=$?
ck "显式目录不存在 → 报红、不换其他款、不调用 make" '[ "$rc" != 0 ] && grep -q "GATE_IOS_MODS 不是可用目录" <<< "$o" && [ ! -e "$T/trace" ]'
o=$(run env GATE_IOS_MODS= TRACE="$T/trace" 2>&1); rc=$?
ck "显式空目录参数 → 报红，不自动选择共享产物" '[ "$rc" != 0 ] && grep -q "GATE_IOS_MODS 不是可用目录" <<< "$o" && [ ! -e "$T/trace" ]'
mods "$T/broken"; rm "$T/broken/main.gates.tsv"
o=$(run env GATE_IOS_MODS="$T/broken" TRACE="$T/trace" 2>&1); rc=$?
ck "缺主模块随行表 → 编译前报红并指出缺项" '[ "$rc" != 0 ] && grep -q "模块缺少可读随行表" <<< "$o" && [ ! -e "$T/trace" ]'
mods "$T/broken"; echo module > "$T/broken/subsdk0.patched.bin"
o=$(run env GATE_IOS_MODS="$T/broken" TRACE="$T/trace" 2>&1); rc=$?
ck "新增模块缺随行表 → 同样报红，不只核 main" '[ "$rc" != 0 ] && grep -q "subsdk0.fixups.tsv" <<< "$o" && [ ! -e "$T/trace" ]'
mods "$T/empty-npdm"; : > "$T/empty-npdm/main.npdm"
o=$(run env GATE_IOS_MODS="$T/empty-npdm" TRACE="$T/trace" 2>&1); rc=$?
ck "空 npdm → 编译前报红" '[ "$rc" != 0 ] && grep -q "非空 main.npdm" <<< "$o" && [ ! -e "$T/trace" ]'
o=$(run env S2A_ROOTS_SHARED="$T/no-roots" TRACE="$T/trace" 2>&1); rc=$?
ck "无自动候选 → 报红，给显式目录用法，不调用 make" '[ "$rc" != 0 ] && grep -q "GATE_IOS_MODS=<现有改写产物目录>" <<< "$o" && [ ! -e "$T/trace" ]'
# 出壳输入闭包（11-11：新增出壳输入漏登 shell.tsv 第三次，razor1 让 make ios 读体验规格，门禁不查、到发版出壳才红）：
#   小仓库加上 pack/shell/closure.py 与输入表（只登记 ios/a.txt），假 make 按 READ 读镜像里的一个文件。
#   READ=ios/a.txt（登记了）→ 绿、日志有「壳输入闭包」行；READ=ios/b.txt（没登记）→ 红、点名 ios/b.txt、说明编译链接本身通过
mkdir -p $T/repo/pack/shell $T/repo/pack/stage_inputs; cp $H/pack/shell/closure.py $T/repo/pack/shell/; cp $H/tools/gate_ios.sh $T/repo/tools/
printf '入\tios/a.txt\n入\tios/embed.py\n入\tios/macho_dylib.py\n入\ttools\n' > $T/repo/pack/stage_inputs/shell.tsv; echo a > $T/repo/ios/a.txt; echo b > $T/repo/ios/b.txt
git -C $T/repo add -A && git -C $T/repo -c user.email=t@t -c user.name=t commit -qm closure
cat > $T/bin/make <<'MK'
#!/bin/bash
for a in "$@"; do case $a in BUILD=*) B=${a#*=};; esac; done; S=; prev=; for a in "$@"; do [ "$prev" = -C ] && S=$a; prev=$a; done
[ -n "${READ:-}" ] && cat "$S/$READ" > /dev/null
mkdir -p "$B/ios/S2Arm.app" && printf '#!/bin/sh\n' > "$B/ios/S2Arm.app/S2Arm" && chmod +x "$B/ios/S2Arm.app/S2Arm"
MK
chmod +x $T/bin/make; mods $T/roots/acnh@pkg-old
o=$(run env READ=ios/a.txt 2>&1); rc=$?
ck "闭包：读登记过的 ios/a.txt → 绿（rc=${rc}）、日志有壳输入闭包结论" '[ "$rc" = 0 ] && grep -q "壳输入闭包：出壳读到" <<< "$o"'
o=$(run env READ=ios/b.txt 2>&1); rc=$?
ck "闭包：读没登记的 ios/b.txt → 红（rc=${rc}）、点名 ios/b.txt、说明编译链接本身通过" '[ "$rc" != 0 ] && grep -q "没登记的 1 个文件.*ios/b.txt" <<< "$o" && grep -q "出壳闭包漏登记（编译链接本身通过）" <<< "$o"'
rm -rf $T; [ $bad = 0 ] && echo "gate_ios 单测全过" || { echo "gate_ios 单测有不通"; exit 1; }
