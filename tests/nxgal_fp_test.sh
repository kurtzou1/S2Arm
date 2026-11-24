#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/batch/Build.cs graphics/tools/direct/dsh/batch/Program.cs
# libnxgal 进翻译键的功能身份单测（dsh_batch --lib-fp，graphics/tools/direct/dsh/batch/Store.cs ToolLib.Fp；约 1 分钟，含编 dsh_batch）：bash tests/nxgal_fp_test.sh
# 11-02 出包线：翻译键原先取 libnxgal.dylib 整文件哈希，而 clang 一步编译加链接时调试映射记随机临时目标文件名，UUID / 签名跟着变——
#   同一份源码每编一次字节都不同，每换一棵工作树全部着色器翻译缓存作废（马力欧派对 82790 支 hit 0）。期望按规则手写：
#   ① 同一份源码一步编两次（-g、临时 .o 名随机）→ 两份文件字节不同，--lib-fp 相同
#   ② 改一行代码（返回值 1 → 2）再编 → --lib-fp 不同
#   ③ 不是 Mach-O（文本文件）→ 退回整文件 sha256
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
[ "$(uname -s)" = Darwin ] || { echo "非 macOS：本单测要 clang 出 Mach-O，跳过"; exit 75; }
DSHB=$(python3 -c "import sys; sys.path.insert(0, '$H/translator'); import dsh_batch; import shlex; print(' '.join(map(shlex.quote, dsh_batch.get()[0])))" 2> "$T/build.err") || { echo "🔴 编不出 dsh_batch：$(tail -3 "$T/build.err")"; exit 1; }
fp() { $DSHB --lib-fp "$1"; }
printf 'int nxgal_probe(int x) { return x + 1; }\nstatic const char tag[] = "probe";\nconst char *nxgal_tag(void) { return tag; }\n' > "$T/a.c"
mk() { ( cd "$T" && clang -g -O2 -dynamiclib -arch arm64 a.c -o "$1" ); }
mk l1.dylib && mk l2.dylib || { echo "🔴 clang 编不出测试动态库"; exit 1; }
f1=$(fp "$T/l1.dylib"); f2=$(fp "$T/l2.dylib")
ck "① 同源两次一步编：文件不同（$(cmp -s "$T/l1.dylib" "$T/l2.dylib" && echo 相同 || echo 不同)）、功能身份相同（${f1:0:12} / ${f2:0:12}）" '! cmp -s "$T/l1.dylib" "$T/l2.dylib" && [ -n "$f1" ] && [ "$f1" = "$f2" ]'
perl -pi -e 's/x \+ 1/x + 2/' "$T/a.c"; mk l3.dylib; f3=$(fp "$T/l3.dylib")
ck "② 改一行代码 → 功能身份变（${f1:0:12} → ${f3:0:12}）" '[ -n "$f3" ] && [ "$f3" != "$f1" ]'
echo hello > "$T/t.txt"; f4=$(fp "$T/t.txt"); s4=$(shasum -a 256 "$T/t.txt" | cut -c1-64)
ck "③ 非 Mach-O → 整文件 sha256" '[ "$f4" = "$s4" ]'
[ $bad = 0 ] && echo "nxgal_fp 单测全过" || { echo "nxgal_fp 单测有不通"; exit 1; }
