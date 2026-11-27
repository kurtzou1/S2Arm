#!/bin/bash
# 门禁覆盖：runtime/gate.sh tools/include_closure.py
# 原生层钩子按改动跳组不分目录（11-26：原先只认 runtime/ graphics/ 下的 C 源——只改 android/native 下的测试 C 文件时 480 组全编；
#   runtime 源和 android/native 源同批改时后者被忽略，编到它的组被跳 = 假绿；目录外的头文件 / 生成器脚本改了也被忽略）。临时仓库，期望手写：
#   组：a（t_a.c + android/native/x.c）、b（t_b.c）、h（t_h.c include android/native/inc/h.h）。
#   ① 只编、只改没有组编到的 android/native/tests/y.c → 一组都不编（旧：清单空，三组全编）
#   ② 只编、改 t_b.c + android/native/x.c → 编 a b（旧：x.c 被忽略，只编 b，a 被跳）
#   ③ 只编、只改被 h 组包含的 android/native/inc/h.h → 只编 h（旧：目录外头文件被忽略，清单空，三组全编）
#   ④ 完整门禁（当天已全跑过）、同 ② → 跑 a b（旧：只跑 b）
#   ⑤ 只编、改 t_b.c + 生成器脚本 tools/gen_flags.py → 三组全编（非源文件可能改编译结果；旧：脚本被忽略，只编 b）
#   ⑥ 完整门禁（当天已全跑过）、只改 android/native/inc/h.h → 只跑 h（11-27 起完整门禁头文件也按 include 闭包收窄；旧：三组全跑）
#   ⑦ 完整门禁（当天已全跑过）、改 t_b.c + 没有源 include 的 android/native/inc/lone.h → 三组全跑（没人 include 的头可能是脚本 / 数据在读）
#   ⑧ 只编、改 t_b.c + h.h、闭包脚本出错 → 三组全编（旧：脚本失败时 h.h 被静默丢掉、只编 b = 假绿）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/rgdap.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() {   # mk <目录>：搭一份临时仓库
  mkdir -p "$1/runtime/tests" "$1/android/native/inc" "$1/android/native/tests" "$1/tools"; cd "$1" || exit 1
  cp "$H/runtime/gate.sh" runtime/; cp "$H/tools/build_only_shell.sh" "$H/tools/include_closure.py" tools/
  printf 'int x(void){return 1;}\n' > android/native/x.c; printf 'int y(void){return 2;}\n' > android/native/tests/y.c
  printf '#define HV 3\n' > android/native/inc/h.h; printf '#define LONE 1\n' > android/native/inc/lone.h; printf 'print("flags")\n' > tools/gen_flags.py
  printf '#include <stdio.h>\nint x(void);\nint main(void){puts("✓ t_a");return x()-1;}\n' > runtime/tests/t_a.c
  printf '#include <stdio.h>\nint main(void){puts("✓ t_b");return 0;}\n' > runtime/tests/t_b.c
  printf '#include <stdio.h>\n#include "../../android/native/inc/h.h"\nint main(void){puts("✓ t_h");return HV-3;}\n' > runtime/tests/t_h.c
  { echo 'host: ; @true'
    printf 'native-test-a:\n\t@mkdir -p build/tests\n\tcc -o build/tests/t_a runtime/tests/t_a.c android/native/x.c\n\tbuild/tests/t_a\n'
    for k in b h; do printf 'native-test-%s:\n\t@mkdir -p build/tests\n\tcc -o build/tests/t_%s runtime/tests/t_%s.c\n\tbuild/tests/t_%s\n' $k $k $k $k; done; } > Makefile
  git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t
}
built() { local o=; for k in a b h; do [ -x build/tests/t_$k ] && o="$o $k"; done; echo "${o# }"; }
fullday() { mkdir -p "$1/s2arm/gate_depskip" && : > "$1/s2arm/gate_depskip/full.$(date +%Y%m%d)"; }   # 当天这台已全跑过（否则完整门禁首跑全量）
mk "$T/1"; GATE_BUILD_ONLY=1 GATE_CHANGED=android/native/tests/y.c S2A_RUN_ROOT=$T/rr1 bash runtime/gate.sh > "$T/1.out" 2>&1
ck "① 只编、只改没有组编到的安卓 C 源：一组都不编（真「$(built)」）" '[ -z "$(built)" ]'
mk "$T/2"; GATE_BUILD_ONLY=1 GATE_CHANGED="runtime/tests/t_b.c android/native/x.c" S2A_RUN_ROOT=$T/rr2 bash runtime/gate.sh > "$T/2.out" 2>&1
ck "② 只编、runtime 源 + 编到的安卓源：编 a b（真 $(built)）" '[ "$(built)" = "a b" ]'
mk "$T/3"; GATE_BUILD_ONLY=1 GATE_CHANGED=android/native/inc/h.h S2A_RUN_ROOT=$T/rr3 bash runtime/gate.sh > "$T/3.out" 2>&1
ck "③ 只编、只改被 h 组包含的目录外头文件：只编 h（真「$(built)」）" '[ "$(built)" = "h" ]'
mk "$T/4"; fullday "$T/rr4"; GATE_CHANGED="runtime/tests/t_b.c android/native/x.c" S2A_RUN_ROOT=$T/rr4 bash runtime/gate.sh > "$T/4.out" 2>&1
ck "④ 完整门禁、同 ②：跑 a b（真 $(built)）" '[ "$(built)" = "a b" ]'
mk "$T/5"; GATE_BUILD_ONLY=1 GATE_CHANGED="runtime/tests/t_b.c tools/gen_flags.py" S2A_RUN_ROOT=$T/rr5 bash runtime/gate.sh > "$T/5.out" 2>&1
ck "⑤ 只编、源 + 生成器脚本：三组全编（真 $(built)）" '[ "$(built)" = "a b h" ]'
mk "$T/6"; fullday "$T/rr6"; GATE_CHANGED=android/native/inc/h.h S2A_RUN_ROOT=$T/rr6 bash runtime/gate.sh > "$T/6.out" 2>&1
ck "⑥ 完整门禁、只改被 h 组包含的目录外头文件：只跑 h（真「$(built)」）" '[ "$(built)" = "h" ]'
mk "$T/7"; fullday "$T/rr7"; GATE_CHANGED="runtime/tests/t_b.c android/native/inc/lone.h" S2A_RUN_ROOT=$T/rr7 bash runtime/gate.sh > "$T/7.out" 2>&1
ck "⑦ 完整门禁、源 + 没人 include 的头：三组全跑（真 $(built)）" '[ "$(built)" = "a b h" ]'
mk "$T/8"; printf 'import sys\nsys.exit(3)\n' > tools/include_closure.py
GATE_BUILD_ONLY=1 GATE_CHANGED="runtime/tests/t_b.c android/native/inc/h.h" S2A_RUN_ROOT=$T/rr8 bash runtime/gate.sh > "$T/8.out" 2>&1
ck "⑧ 只编、源 + 头、闭包脚本出错：三组全编（真 $(built)）" '[ "$(built)" = "a b h" ]'
[ $bad = 0 ] || { for i in 1 2 3 4 5 6 7 8; do echo "== $i"; tail -5 "$T/$i.out"; done; }
exit $bad
