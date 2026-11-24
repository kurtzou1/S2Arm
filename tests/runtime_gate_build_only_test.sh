#!/bin/bash
# 门禁覆盖：runtime/gate.sh tools/build_only_shell.sh
# 原生层钩子「只编」模式（GATE_BUILD_ONLY=1，11-24 门禁把它作为合入前必跑步）。临时仓库，约 5 秒。期望手写：
#   ① 漏桩的组（t_bad.c 调没声明、没定义的函数，同 D-92BW dsh_stats / front_layer_race）只编就红：「bad 构建失败（只编）」、退出非 0；
#   ② 编得过但运行判据不符的组（t_run 跑起来打「✗ t_run」）只编判绿、且单测程序没被运行（没留下运行标记文件）；
#   ③ 正常组绿；④ 规则里非编译步骤失败（没有编译 / 链接报错）的组记「只编判不了」、不红；⑤ 带环境变量赋值 / timeout 前缀的运行行也跳过；
#   组都照真仓库的写法：规则里先编（$(CC) … -o build/tests/t_x）、再运行（timeout 30 build/tests/t_x），没有先决目标（11-24 首版按先决目标编，真仓库 dsh_stats / front_layer_race 全成「只编不了」）；
#   反证：不带 GATE_BUILD_ONLY 照常跑 → t_run 被运行（有标记）、判据不符红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/rgbo.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/r/runtime/tests $T/r/tools; cd $T/r || exit 1; cp "$H/runtime/gate.sh" runtime/; cp "$H/tools/build_only_shell.sh" tools/
printf '#include <stdio.h>\nint main(void){puts("✓ t_ok");return 0;}\n' > runtime/tests/t_ok.c
printf '#include <stdio.h>\nint main(void){return mtl_libact_stats_missing();}\n' > runtime/tests/t_bad.c
printf '#include <stdio.h>\nint main(void){FILE*f=fopen("%s/ran_run","w");if(f)fclose(f);puts("✗ t_run 不符");return 1;}\n' "$T" > runtime/tests/t_run.c
printf '#include <stdio.h>\nint main(void){FILE*f=fopen("%s/ran_env","w");if(f)fclose(f);puts("✓ t_env");return 0;}\n' "$T" > runtime/tests/t_env.c
printf '#include <stdio.h>\nint main(void){puts("✓ t_gen");return 0;}\n' > runtime/tests/t_gen.c
cat > Makefile <<'M'
host: ; @true
native-test-ok:
	@mkdir -p build/tests
	cc -o build/tests/t_ok runtime/tests/t_ok.c
	timeout 30 build/tests/t_ok
native-test-bad:
	@mkdir -p build/tests
	cc -Werror=implicit-function-declaration -o build/tests/t_bad runtime/tests/t_bad.c
	build/tests/t_bad
native-test-run:
	@mkdir -p build/tests
	cc -o build/tests/t_run runtime/tests/t_run.c
	build/tests/t_run
native-test-env:
	@mkdir -p build/tests
	cc -o build/tests/t_env runtime/tests/t_env.c
	T_LIB=build/x ./build/tests/t_env
native-test-gen:
	python3 -c 'import sys; sys.exit(3)'
	cc -o build/tests/t_gen runtime/tests/t_gen.c
.PHONY: host native-test-ok native-test-bad native-test-run native-test-env native-test-gen
M
git init -q; git config user.email t@t; git config user.name t; git add -A; git commit -qm 1
o=$(GATE_BUILD_ONLY=1 S2A_NATIVE_GATE_TIMES= bash runtime/gate.sh 2>&1); rc=$?
ck "① 漏桩只编就红（退出 ${rc}）" '[ $rc != 0 ] && grep -q "bad 构建失败（只编）" <<< "$o"'
ck "② 运行期不符的组只编判绿、程序没被运行" '[ ! -e $T/ran_run ] && ! grep -q "run 构建失败\|run 判据不符" <<< "$o"'
ck "④ 规则里非编译步骤失败的组记只编判不了、不红" 'grep -q "只编判不了 1 组" <<< "$o" && ! grep -q "gen 构建失败" <<< "$o"'
ck "⑤ 带环境变量前缀的运行行也跳过" '[ ! -e $T/ran_env ]'
ck "末行带（只编）" 'tail -1 <<< "$o" | grep -q "（只编）"'
rm -f runtime/tests/t_bad.c; python3 - <<'P'
import re; t=open('Makefile').read(); t=re.sub(r'native-test-bad:\n(\t[^\n]*\n)+', '', t); open('Makefile','w').write(t.replace(' native-test-bad',''))
P
 git add -A; git commit -qm 2
o=$(GATE_BUILD_ONLY=1 S2A_NATIVE_GATE_TIMES= bash runtime/gate.sh 2>&1); rc=$?
ck "③ 补好桩后只编全绿（退出 ${rc}）" '[ $rc = 0 ] && tail -1 <<< "$o" | grep -q "绿 3 组；只编判不了 1 组"'
o=$(S2A_NATIVE_GATE_TIMES= bash runtime/gate.sh 2>&1); rc=$?
ck "反证：照常跑 → t_run 被运行、判据不符红" '[ -e $T/ran_run ] && [ $rc != 0 ] && grep -q "run 判据不符" <<< "$o"'
cd "$H"; [ $bad = 0 ] && echo "runtime_gate_build_only 单测全过" || { echo "runtime_gate_build_only 单测有不通"; echo "$o" | tail -8; exit 1; }
