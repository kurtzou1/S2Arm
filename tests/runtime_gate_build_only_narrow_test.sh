#!/bin/bash
# 门禁覆盖：runtime/gate.sh tools/include_closure.py
# 原生层钩子「只编」按改动收窄（11-24：main 全量只编 461 组 907 秒 / 热缓存 178 秒，合入前要 ≤ 2 分钟）。临时仓库，期望手写：
#   组：a（t_a.c 直接 include a.h）、c（t_c.c 经 c.h 间接 include a.h）、b（t_b.c 只 include b.h）、rec（规则里自己调 $(MAKE)，同 graphics_session）。
#   ① GATE_BUILD_ONLY=1 GATE_CHANGED=runtime/src/a.h → 只编 a、c；b、rec 不编（build/tests 下没有它们的产物）；
#   ② GATE_BUILD_ONLY=1 GATE_CHANGED=runtime/src/z.h（没有源用到）→ 一组都不编；
#   ③ 反证：不带 GATE_BUILD_ONLY、同 ① 的改动 → 头文件改动照旧全跑，四组都编。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/rgbon.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() {   # mk <目录>：搭一份临时仓库
  mkdir -p "$1/runtime/tests" "$1/runtime/src" "$1/tools"; cd "$1" || exit 1
  cp "$H/runtime/gate.sh" runtime/; cp "$H/tools/build_only_shell.sh" "$H/tools/include_closure.py" tools/
  printf '#define A 1\n' > runtime/src/a.h; printf '#define B 1\n' > runtime/src/b.h; printf '#define Z 1\n' > runtime/src/z.h
  printf '#include "a.h"\n' > runtime/src/c.h
  for k in a b c rec; do h=$k; [ $k = rec ] && h=b; printf '#include <stdio.h>\n#include "../src/%s.h"\nint main(void){puts("✓ t_%s");return 0;}\n' $h $k > runtime/tests/t_$k.c; done
  { echo 'host: ; @true'
    for k in a b c; do printf 'native-test-%s:\n\t@mkdir -p build/tests\n\tcc -o build/tests/t_%s runtime/tests/t_%s.c\n\tbuild/tests/t_%s\n' $k $k $k $k; done
    printf 'native-test-rec:\n\t@mkdir -p build/tests\n\t$(MAKE) -s host\n\tcc -o build/tests/t_rec runtime/tests/t_rec.c\n\tbuild/tests/t_rec\n'; } > Makefile
  git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t
}
built() { local o=; for k in a b c rec; do [ -x build/tests/t_$k ] && o="$o $k"; done; echo "${o# }"; }
mk "$T/1"; GATE_BUILD_ONLY=1 GATE_CHANGED=runtime/src/a.h S2A_RUN_ROOT=$T/rr1 bash runtime/gate.sh > "$T/1.out" 2>&1
ck "① 只编、改 a.h：只编 a c（真 $(built)）" '[ "$(built)" = "a c" ]'
mk "$T/2"; GATE_BUILD_ONLY=1 GATE_CHANGED=runtime/src/z.h S2A_RUN_ROOT=$T/rr2 bash runtime/gate.sh > "$T/2.out" 2>&1
ck "② 只编、改的头文件没有源用到：一组都不编（真「$(built)」）" '[ -z "$(built)" ]'
mk "$T/3"; GATE_CHANGED=runtime/src/a.h S2A_RUN_ROOT=$T/rr3 bash runtime/gate.sh > "$T/3.out" 2>&1
ck "③ 反证（不带只编）：头文件改动全跑，四组都编（真 $(built)）" '[ "$(built)" = "a b c rec" ]'
[ $bad = 0 ] || { for i in 1 2 3; do echo "== $i"; tail -5 "$T/$i.out"; done; }
exit $bad
