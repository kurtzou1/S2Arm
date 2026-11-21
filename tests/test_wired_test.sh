#!/bin/bash
# 门禁覆盖：*.sh *.py Makefile *.mk
# 单测接线扫描（tools/test_wired_lint.py，全仓一遍约 25 秒）：bash tests/test_wired_test.sh
# 期望：① 本仓库全部接线或在白名单 → 退出 0；② 本仓库换成空白名单（同一次扫描出的第二份结论）→ 退出 1 且点名仍需私有数据 / 参数的三支手动单测；
#   ③ 临时仓库：门禁调到的、经已接线脚本再调的、Python import 的、Makefile 配方里调的都算接上；只在注释里提到的、谁都没调的报出；
#   白名单没写原因、白名单写了不存在 / 其实已接上的单测只提示，没写原因的报一条；不合格的白名单行不豁免（没写原因的那支照报没接线）
#   ⑤ 文字提及、非执行选项、heredoc、同名不同目录都不算接线；真调用正控仍判接上；解析失败点名文件和原因。
#   ⑧ C# 单测工程纳入：$( ) 里的调用、cd 进工程目录再 dotnet 都算接上，库工程不算，没人调的报出。
#   ③b 子目录 *_test.sh 纳入（顶层 tests/*_test.sh 是自动入口）。⑦ *_test.py 纳入；钩子经中间脚本再调、${S2A_PY:-python3} 解释器、make 配方仓库根路径都算接上，没人调的 *_test.py 报出。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 路由入口读取 git ls-files；每次同步合成仓索引，不提交、不运行其中的载荷。
fixture_lint() {
    local lint=$1 root=$2
    [ -d "$root/.git" ] || git -C "$root" init -q || return
    git -C "$root" add -A || return
    python3 "$lint" "$root"
}
o=$(cd "$H" && S2A_WIRED_EMPTY_OUT=$T/empty.out python3 tools/test_wired_lint.py 2>&1); r=$?   # 同一次扫描顺带出空白名单那份结论（②用，不整仓重扫）
ck "① 本仓库：全部接线或在白名单（$(echo "$o" | tail -1 | cut -c1-120)）" '[ $r = 0 ]'
[ $r = 0 ] || echo "$o" | head -10
o=$(sed '$d' "$T/empty.out"); r=$(tail -1 "$T/empty.out" | sed 's/^退出码 //')
ck "② 空白名单：退出 1（rc=${r}）" '[ $r = 1 ]'
# 拼扩展名：现有扫描器会把断言里的完整文件名误当调用（#484 另行修复）。
for stem in t_pkz_real t_smbw_bnsh t_fout_rule; do
    t=$stem.py
    ck "② 空白名单：点名手动单测 $t" 'grep -Fq "graphics/tools/shbake/tests/$t 没有门禁脚本调它" <<< "$o"'
done
ck "② 已登记的 t_rt_recover.py 不报" '! grep -Fq "graphics/tools/direct/tests/t_rt_recover.py" <<< "$o"'
R=$T/repo; mkdir -p $R/tools $R/graphics/x/tests $R/graphics/m/tests $R/tests; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $R/tools/
for t in t_direct.py t_chain.sh t_viash.py t_imported.py t_mk.sh t_comment.py t_orphan.py t_okwired.py t_ok.py; do echo 'print(1)' > $R/graphics/x/tests/$t; done
printf 'python3 graphics/x/tests/t_direct.py\nbash graphics/x/tests/t_chain.sh\npython3 graphics/x/tests/t_okwired.py\n# python3 graphics/x/tests/t_comment.py\nmake -s -C graphics/m check\n' > $R/graphics/gate.sh
printf 'python3 "$(dirname "$0")/t_viash.py"\n' > $R/graphics/x/tests/t_chain.sh
printf 'import t_imported\n' >> $R/graphics/x/tests/t_direct.py
printf 'check:\n\tbash ../x/tests/t_mk.sh\n' > $R/graphics/m/Makefile
# 白名单 = 单测文件头「门禁手动：<原因>」（10-30 列车线：原 tests/test_wired_ok.tsv 中央表拆回各文件）
printf '# 门禁手动：要私有数据\nprint(1)\n' > $R/graphics/x/tests/t_ok.py; printf '# 门禁手动：已接上还留着\nprint(1)\n' > $R/graphics/x/tests/t_okwired.py
printf '# 门禁手动：\nprint(1)\n' > $R/graphics/x/tests/t_noreason.py
o=$(fixture_lint $R/tools/test_wired_lint.py $R 2>&1); r=$?
ck "③ 临时仓库退出 1（rc=${r}）" '[ $r = 1 ]'
for t in t_direct.py t_chain.sh t_viash.py t_imported.py t_mk.sh; do ck "③ $t 算接上（不报）" '! grep -q "$t" <<< "$o"'; done
ck "③ 只在注释里提到的 t_comment.py 报没接线" 'grep -q "t_comment.py 没有门禁脚本调它" <<< "$o"'
ck "③ 谁都没调的 t_orphan.py 报没接线" 'grep -q "t_orphan.py 没有门禁脚本调它" <<< "$o"'
# ③b 子目录里的 *_test.sh 也要有人调（11-01 审计 P1-64：tests/visual/widen_lib_key_test.sh 没人调、旧正则只认 t_* 与 *_test.py，看不见）；顶层 tests/*_test.sh 是自动入口不报
mkdir -p $R/tests/visual; printf 'echo ok\n' > $R/tests/visual/key_orphan_test.sh; printf 'echo ok\n' > $R/tests/top_auto_test.sh
o3=$(fixture_lint $R/tools/test_wired_lint.py $R 2>&1)
ck "③b 子目录没人调的 key_orphan_test.sh 报没接线" 'grep -q "tests/visual/key_orphan_test.sh 没有门禁脚本调它" <<< "$o3"'
ck "③b 顶层自动入口 tests/top_auto_test.sh 不报" '! grep -q "top_auto_test.sh" <<< "$o3"'
rm -f $R/tests/visual/key_orphan_test.sh $R/tests/top_auto_test.sh
# ③c 间接调用（文件头「门禁间接：<调用方> <说明>」，11-20 android/gate.sh 接回）：调用方按通配逐个跑、静态引用追不到。
#   调用方已接线 → 算接上，并接着追它调的脚本；调用方没接线 → 照报；没写说明 / 调用方不存在 → 声明不对报红
mkdir -p $R/graphics/x/tests/standalone
printf 'for f in graphics/x/tests/standalone/*.sh; do bash "$f"; done\n' > $R/graphics/x/tests/run_all.sh
printf 'bash graphics/x/tests/run_all.sh\n' >> $R/graphics/gate.sh
printf '# 门禁间接：graphics/x/tests/run_all.sh 默认档按通配逐个跑\npython3 graphics/x/tests/t_behind.py\n' > $R/graphics/x/tests/standalone/glob_a_test.sh
echo 'print(1)' > $R/graphics/x/tests/t_behind.py
printf 'echo nobody\n' > $R/graphics/x/tests/unwired_runner.sh
printf '# 门禁间接：graphics/x/tests/unwired_runner.sh 按通配跑\necho b\n' > $R/graphics/x/tests/standalone/glob_b_test.sh
printf '# 门禁间接：graphics/x/tests/run_all.sh\necho c\n' > $R/graphics/x/tests/standalone/glob_c_test.sh
printf '# 门禁间接：graphics/x/tests/no_such.sh 按通配跑\necho d\n' > $R/graphics/x/tests/standalone/glob_d_test.sh
o4=$(fixture_lint $R/tools/test_wired_lint.py $R 2>&1)
ck "③c 调用方已接线：glob_a_test.sh 算接上" '! grep -q "glob_a_test.sh 没有门禁脚本调它" <<< "$o4"'
ck "③c 间接单测再调的 t_behind.py 也算接上" '! grep -q "t_behind.py 没有门禁脚本调它" <<< "$o4"'
ck "③c 调用方没接线：glob_b_test.sh 照报" 'grep -q "glob_b_test.sh 没有门禁脚本调它" <<< "$o4"'
ck "③c 没写说明：glob_c_test.sh 声明报红" 'grep -q "门禁间接」 graphics/x/tests/standalone/glob_c_test.sh 没写说明" <<< "$o4"'
ck "③c 调用方不存在：glob_d_test.sh 声明报红" 'grep -q "glob_d_test.sh 的调用方 graphics/x/tests/no_such.sh 不是仓库里的文件" <<< "$o4"'
rm -rf $R/graphics/x/tests/standalone $R/graphics/x/tests/run_all.sh $R/graphics/x/tests/t_behind.py $R/graphics/x/tests/unwired_runner.sh
sed -i.bak '/run_all.sh/d' $R/graphics/gate.sh && rm -f $R/graphics/gate.sh.bak

# ⑤ 独立反例：字面期望不从扫描器结果生成，不执行任何合成测试文件。
Q=$T/mentions; mkdir -p "$Q/graphics/a/tests"
printf 'raise RuntimeError("must not execute")\n' > "$Q/graphics/a/tests/t_alpha.py"
printf 'python3 graphics/a/tests/t_alpha.py\n' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 真调用正控：退出 0、扫 1 支且调到 1" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf 's2a_gate_step python3 graphics/a/tests/t_alpha.py\n' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 门禁摘要包装的真调用仍接线" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf 's2a_gate_step echo python3 graphics/a/tests/t_alpha.py\n' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 包装的文字提及不是调用" '[ $r2 = 1 ] && grep -Fq "graphics/a/tests/t_alpha.py 没有门禁脚本调它" <<< "$o2"'
while IFS= read -r command; do
    printf '%b\n' "$command" > "$Q/graphics/gate.sh"
    o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
    ck "⑤ 文字或非执行选项不是调用：$command" '[ $r2 = 1 ] && grep -Fq "graphics/a/tests/t_alpha.py 没有门禁脚本调它" <<< "$o2"'
done <<'CASES'
true # python3 graphics/a/tests/t_alpha.py
echo "python3 graphics/a/tests/t_alpha.py"
echo python3 graphics/a/tests/t_alpha.py
printf "%s" "; python3 graphics/a/tests/t_alpha.py"
P=graphics/a/tests; python3 '$P/t_alpha.py'
'$PYV' graphics/a/tests/t_alpha.py
P=graphics/a/tests; P=$UNKNOWN; python3 "$P/t_alpha.py"
P=graphics/a/tests; unset P; python3 "$P/t_alpha.py"
echo prefix"; python3 graphics/a/tests/t_alpha.py ignored"
echo prefix'; python3 graphics/a/tests/t_alpha.py ignored'
printf "%s\n" prefix"; python3 graphics/a/tests/t_alpha.py ignored"
echo "instructions:\npython3 graphics/a/tests/t_alpha.py\n"
python3 --help graphics/a/tests/t_alpha.py
python3 --version graphics/a/tests/t_alpha.py
PYV=echo\n"$PYV" graphics/a/tests/t_alpha.py
PYV=echo\nunset PYV\n"$PYV" graphics/a/tests/t_alpha.py
echo ' H=$(cd "$(dirname "$0")/.." && pwd)'\npython3 "$H/graphics/a/tests/t_alpha.py"
cat <<<"python3 graphics/a/tests/t_alpha.py"
cat <<'EOF'\npython3 graphics/a/tests/t_alpha.py\nEOF
cat <<EOF\npython3 graphics/a/tests/t_alpha.py\nEOF
cat <<-'EOF'\n\tpython3 graphics/a/tests/t_alpha.py\n\tEOF
cat<<'EOF'\npython3 graphics/a/tests/t_alpha.py\nEOF
cat <<'FIRST' <<SECOND\npython3 graphics/a/tests/t_alpha.py\nFIRST\npython3 graphics/a/tests/t_alpha.py\nSECOND
CASES
printf '%s\n' '# ignore \' 'python3 graphics/a/tests/t_alpha.py' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 注释尾反斜杠不吞下一行真调用" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf 'py"thon3" graphics/a/tests/"t_alpha.py"\n' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 真调用的相邻引号仍可接线" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%b\n' 'cat <<EOF\npython3 graphics/a/tests/t_alpha.py\nEOF\npython3 graphics/a/tests/t_alpha.py' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ heredoc 结束后的真调用仍可接线" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%b\n' 'cat <<<"printed only"\npython3 graphics/a/tests/t_alpha.py' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ here-string 不吞下一行真调用" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%s\n' 'P=graphics/a/tests; unset P; P=graphics/a/tests; python3 "$P/t_alpha.py"' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ unset 后重新赋值恢复目录登记" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%s\n' 'P=graphics/a/tests; unset Q; python3 "$P/t_alpha.py"' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ unset 无关变量不清空已知目录" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%s\n' 'PYV=echo; unset PYV; PYV=python3; "$PYV" graphics/a/tests/t_alpha.py' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ unset 后显式赋值恢复解释器登记" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
printf '%s\n' 'P=graphics/a/tests; unset -f P; python3 "$P/t_alpha.py"' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ unset -f 只删函数不清空目录变量" '[ $r2 = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o2"'
mkdir -p "$Q/graphics/b/tests"; printf 'pass\n' > "$Q/graphics/b/tests/t_alpha.py"
printf 'python3 graphics/a/tests/t_alpha.py\n' > "$Q/graphics/gate.sh"
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 仅调用 a 路径：b 同名脚本未接线，2 支只调到 1" '[ $r2 = 1 ] && grep -Fq "graphics/b/tests/t_alpha.py 没有门禁脚本调它" <<< "$o2" && grep -Fq "扫 2 支单测：门禁调到 1、白名单 0、没接线 1" <<< "$o2"'
printf 'import t_leaf\n' > "$Q/graphics/a/tests/t_alpha.py"
for d in a b; do printf 'pass\n' > "$Q/graphics/$d/tests/t_leaf.py"; done
o2=$(fixture_lint "$H/tools/test_wired_lint.py" "$Q" 2>&1); r2=$?
ck "⑤ 同目录 import：b 同名模块未接线，4 支只调到 2" '[ $r2 = 1 ] && grep -Fq "graphics/b/tests/t_leaf.py 没有门禁脚本调它" <<< "$o2" && grep -Fq "扫 4 支单测：门禁调到 2、白名单 0、没接线 2" <<< "$o2"'
ck "③ 白名单里的 t_ok.py 不报" '! grep -q "t_ok.py" <<< "$o"'
ck "③ 白名单过期（t_okwired.py 已接上）只提示、不算红（10-29 白名单 union 后并行删行会合回来）" 'grep -q "提示：.*t_okwired.py 已经有门禁脚本调它了" <<< "$o" && ! grep -q "✗.*t_okwired.py" <<< "$o"'
ck "③ 白名单没写原因的 t_noreason.py 报出" 'grep -q "t_noreason.py 没写原因" <<< "$o"'
ck "③ 末行计数：扫 10 支、门禁调到 6、白名单 1、没接线 3" 'tail -1 <<< "$o" | grep -q "扫 10 支单测：门禁调到 6、白名单 1、没接线 3"'
R=$T/toggle; mkdir -p "$R/graphics/x/tests"
echo 'print(1)' > "$R/graphics/x/tests/t_toggle.py"
printf 'python3 graphics/x/tests/t_toggle.py\n' > "$R/graphics/gate.sh"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$R" 2>&1); r=$?
ck "④ 真实登记：退出 0、扫 1 支且调到 1" '[ $r = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o"'
printf 'true\n' > "$R/graphics/gate.sh"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$R" 2>&1); r=$?
ck "④ 删除登记：退出 1、点名 t_toggle.py" '[ $r = 1 ] && grep -Fq "graphics/x/tests/t_toggle.py 没有门禁脚本调它" <<< "$o"'
printf 'python3 graphics/x/tests/t_toggle.py\n' > "$R/graphics/gate.sh"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$R" 2>&1); r=$?
ck "④ 恢复登记：退出 0、扫 1 支且调到 1" '[ $r = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o"'
# 入口含嵌套参数/命令替换仍完整解析；真语法错误不能静默丢弃整文件。
B=$T/braces; mkdir -p "$B/tools" "$B/tests"
printf 'pass\n' > "$B/tests/t_x.py"
cat > "$B/tools/gate.sh" <<'GATE'
la=${A:-$(echo 1 | awk '{print $1}')}
python3 tests/t_x.py
GATE
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$B" 2>&1); r=$?
ck "⑤ 参数展开里的 awk 花括号不截断入口" '[ $r = 0 ] && grep -Fq "扫 1 支单测：门禁调到 1、白名单 0、没接线 0" <<< "$o"'
cat > "$B/tools/gate.sh" <<'GATE'
la=${A:-${B:-"quoted } brace"}}
python3 tests/t_x.py
GATE
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$B" 2>&1); r=$?
ck "⑤ 嵌套参数展开与引号花括号配对" '[ $r = 0 ] && grep -Fq "门禁调到 1" <<< "$o"'
printf 'echo "unclosed\npython3 tests/t_x.py\n' > "$B/tools/gate.sh"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$B" 2>&1); r=$?
ck "⑤ 真未闭引号报告文件及解析失败原因" '[ $r = 1 ] && grep -Fq "tools/gate.sh：解析失败（引号未闭合）" <<< "$o"'
printf 'la=${A:-missing\npython3 tests/t_x.py\n' > "$B/tools/gate.sh"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$B" 2>&1); r=$?
ck "⑤ 真未闭参数展开报告文件及原因" '[ $r = 1 ] && grep -Fq "tools/gate.sh：解析失败（参数展开未闭合）" <<< "$o"'
printf 'python3 tests/t_x.py\n' > "$B/tools/gate.sh"
printf 'def broken(\n' > "$B/tests/t_x.py"
o=$(fixture_lint "$H/tools/test_wired_lint.py" "$B" 2>&1); r=$?
ck "⑤ 已接线 Python 语法错误不可静默" '[ $r = 1 ] && grep -Fq "tests/t_x.py：解析失败（" <<< "$o" && grep -Fq "第 1 行" <<< "$o"'
# ⑥ T91：浅层钩子不论是否声明路由都可达；声明只决定按改动选择，不决定是否为入口。
R6=$T/r6; mkdir -p $R6/tools $R6/tests/visual; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $R6/tools/; echo 'print(1)' > $R6/tests/visual/t_vis.py
printf 'python3 tests/visual/t_vis.py\n' > $R6/tests/visual/gate.sh
o=$(fixture_lint $R6/tools/test_wired_lint.py $R6 2>&1); r=$?
ck "⑥ 钩子没声明路由：tests/visual/gate.sh 仍是入口（rc=${r}）" '[ $r = 0 ] && grep -Fq "扫 2 支单测：门禁调到 2" <<< "$o"'   # 11-01 分母按 tests 目录：钩子自己也在分母里，入口即接上
printf '# 门禁路由：tests/visual/\npython3 tests/visual/t_vis.py\n' > $R6/tests/visual/gate.sh
o=$(fixture_lint $R6/tools/test_wired_lint.py $R6 2>&1); r=$?
ck "⑥ 钩子文件头声明了路由：t_vis.py 算接上（rc=${r}）" '[ $r = 0 ] && grep -Fq "扫 2 支单测：门禁调到 2" <<< "$o"'
# ⑦ 10-28 质量线：tests/*_test.py 也要接线；钩子经中间脚本（不是单测）再调单测算接上；「${S2A_PY:-python3}」解释器算调用；make 配方里的仓库根相对路径算调用
R7=$T/r7; mkdir -p $R7/tools $R7/tests $R7/plat/tests $R7/runtime/tests/mk; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $R7/tools/
for t in tests/t_a.py tests/t_b.py tests/lone_test.py plat/tests/t_c.py tests/t_d.py; do echo 'print(1)' > $R7/$t; done
printf '# 门禁路由：plat/\nbash plat/run_all.sh\n' > $R7/plat/gate.sh
printf 'd=$(cd "$(dirname "$0")" && pwd)\n"$PY" "$d/tests/t_c.py"\n' > $R7/plat/run_all.sh
printf 'H=$(cd "$(dirname "$0")/.." && pwd)\nexec "${S2A_PY:-python3}" "$H/tests/t_a.py"\n' > $R7/tests/a_test.sh
printf 'H=$(cd "$(dirname "$0")/.." && pwd)\n"${S2A_CONTRACT_PY:-python3}" -I -S tests/t_b.py\n' > $R7/tests/b_test.sh
printf 'check:\n\tpython3 tests/t_d.py\n' > $R7/runtime/tests/mk/d.mk; printf 'make -s -f runtime/tests/mk/d.mk check\n' > $R7/runtime/gate.sh
o=$(fixture_lint $R7/tools/test_wired_lint.py $R7 2>&1); r=$?
ck "⑦ 没人调的 tests/lone_test.py 报没接线（rc=${r}）" '[ $r = 1 ] && grep -Fq "tests/lone_test.py 没有门禁脚本调它" <<< "$o"'
for t in tests/t_a.py tests/t_b.py plat/tests/t_c.py tests/t_d.py; do ck "⑦ $t 算接上（\${S2A_PY:-python3} / 中间脚本 / make 仓库根路径）" '! grep -Fq "$t 没有" <<< "$o"'; done
# ⑧ 10-29 基础设施线：C# 单测工程也要接线；命令替换 $( … ) 里的调用算接上；cd 进工程目录再 dotnet 算接上；库工程（OutputType Library）不算单测
R8=$T/r8; mkdir -p $R8/tools $R8/svc/A.Tests $R8/svc/lone-tests $R8/svc/lib-tests $R8/tests; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $R8/tools/
echo '<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>' > $R8/svc/A.Tests/A.Tests.csproj
echo '<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>' > $R8/svc/lone-tests/Lone.csproj
echo '<Project><PropertyGroup><OutputType>Library</OutputType></PropertyGroup></Project>' > $R8/svc/lib-tests/Fixture.csproj
printf '# 门禁路由：svc/\nout=$(bash svc/test.sh 2>&1)\n' > $R8/svc/gate.sh
printf 'HERE=$(cd "$(dirname "$0")" && pwd)\ncd "$HERE/A.Tests" && dotnet build -c Release\npython3 "$HERE/tests/t_sub.py"\n' > $R8/svc/test.sh; mkdir -p $R8/svc/tests; echo 'print(1)' > $R8/svc/tests/t_sub.py
o=$(fixture_lint $R8/tools/test_wired_lint.py $R8 2>&1); r=$?
ck "⑧ C# 工程：没人调的 svc/lone-tests/Lone.csproj 报出（rc=${r}）" '[ $r = 1 ] && grep -Fq "svc/lone-tests/Lone.csproj 没有门禁脚本调它" <<< "$o"'
ck "⑧ C# 工程：\$(bash svc/test.sh) 里 cd 进 A.Tests 再 dotnet → 算接上" '! grep -Fq "A.Tests.csproj 没有" <<< "$o"'
ck "⑧ \$( ) 里调的脚本照样跟进：svc/tests/t_sub.py 算接上" '! grep -Fq "t_sub.py 没有" <<< "$o"'
ck "⑧ 库工程 Fixture.csproj 不算单测、不报" '! grep -Fq "Fixture.csproj" <<< "$o"'
# ⑨ T140 / #936：按模块调用也算接线（python3 -m unittest tests.x / python3 -m tests.x / python3 -m unittest tests/x.py）
R9=$T/r9; mkdir -p $R9/tools $R9/tests $R9/graphics; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $R9/tools/
echo 'print(1)' > $R9/tests/mod_a_test.py
echo 'print(1)' > $R9/tests/mod_b_test.py
echo 'print(1)' > $R9/tests/mod_c_test.py
echo 'print(1)' > $R9/tests/orphan_mod_test.py
printf 'python3 -m unittest tests.mod_a_test\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ -m unittest tests.mod_a_test 算接上（rc=${r}）" '[ $r = 1 ] && ! grep -Fq "tests/mod_a_test.py 没有" <<< "$o" && grep -Fq "tests/orphan_mod_test.py 没有门禁脚本调它" <<< "$o"'
printf 'python3 -m tests.mod_b_test\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ -m tests.mod_b_test 算接上" '! grep -Fq "tests/mod_b_test.py 没有" <<< "$o"'
printf 'python3 -m unittest tests/mod_c_test.py\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ -m unittest tests/mod_c_test.py 算接上" '! grep -Fq "tests/mod_c_test.py 没有" <<< "$o"'
printf 'python3 -B -m unittest tests.mod_a_test\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ -B 后再 -m unittest 仍算接上" '! grep -Fq "tests/mod_a_test.py 没有" <<< "$o"'
# 负对照
printf '# python3 -m unittest tests.mod_a_test\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ 注释里的 -m unittest 不算接线" 'grep -Fq "tests/mod_a_test.py 没有门禁脚本调它" <<< "$o"'
printf 'echo python3 -m unittest tests.mod_a_test\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ echo 的 -m unittest 不算接线" 'grep -Fq "tests/mod_a_test.py 没有门禁脚本调它" <<< "$o"'
printf 'cat <<EOF\npython3 -m unittest tests.mod_a_test\nEOF\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ heredoc 里的 -m unittest 不算接线" 'grep -Fq "tests/mod_a_test.py 没有门禁脚本调它" <<< "$o"'
printf 'python3 -m unittest discover\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ -m unittest discover 不把整目录算接上" 'grep -Fq "tests/mod_a_test.py 没有门禁脚本调它" <<< "$o" && grep -Fq "tests/orphan_mod_test.py 没有门禁脚本调它" <<< "$o"'
printf 'python3 -m unittest tests.does_not_exist_xyz\n' > $R9/graphics/gate.sh
o=$(fixture_lint $R9/tools/test_wired_lint.py $R9 2>&1); r=$?
ck "⑨ 模块指向不存在文件不算接线（仍报 orphan）" 'grep -Fq "tests/orphan_mod_test.py 没有门禁脚本调它" <<< "$o" && ! grep -Fq "does_not_exist" <<< "$o"'

# ⑩ T91：预期由钩子深度和是否真调用手算，额外核对未修改的生产路由。
for spec in 'declared tests/visual/gate.sh yes yes 0' \
            'undeclared tests/visual/gate.sh no yes 0' \
            'deep-declared custom/a/b/c/gate.sh yes yes 1' \
            'deep-undeclared custom/a/b/c/gate.sh no yes 1' \
            'not-called tests/visual/gate.sh yes no 1' \
            'depth-four custom/a/b/gate.sh yes yes 0'; do
    read -r name hook declared called expected <<< "$spec"
    X=$T/hooks-$name; mkdir -p "$X/$(dirname "$hook")" "$X/tests"
    printf 'raise RuntimeError("fixture payload must not execute")\n' > "$X/tests/t_probe.py"
    : > "$X/$hook"
    [ "$declared" = no ] || printf '# 门禁路由：custom/\n' >> "$X/$hook"
    [ "$called" = no ] || printf 'python3 tests/t_probe.py\n' >> "$X/$hook"
    o=$(fixture_lint "$H/tools/test_wired_lint.py" "$X" 2>&1); r=$?
    routed=$(cd "$X" && python3 "$H/tools/gate_route.py" hooks); route_rc=$?
    ck "⑩ ${name}：生产路由成功" '[ $route_rc = 0 ]'
    if [[ $name = deep-* ]]; then
        ck "⑩ ${name}：生产路由不发现深度5" '[ -z "$routed" ]'
    else
        ck "⑩ ${name}：生产路由发现浅层钩子" '[ "$routed" = "$hook" ]'
    fi
    ck "⑩ ${name}：lint退出 $expected" '[ $r = $expected ]'
    if [ "$expected" = 0 ]; then
        n=1; [[ $hook = tests/* ]] && n=2   # 11-01 分母按 tests 目录：tests/ 下的钩子自己也算一支、入口即接上
        ck "⑩ ${name}：唯一单测真接线" 'grep -Fq "扫 ${n} 支单测：门禁调到 ${n}、白名单 0、没接线 0" <<< "$o"'
    else
        ck "⑩ ${name}：唯一单测仍报未接线" 'grep -Fq "tests/t_probe.py 没有门禁脚本调它" <<< "$o"'
    fi
done

# ⑫ 11-01 审计 P1-39 / P1-64：Makefile 里写了 ≠ 钩子会跑——只跟进门禁 make 到的目标（include 进来的 *.mk、前置目标、配方里再调的 $(MAKE)、目标里带变量当通配），
#   -n 干跑不算；本文件里 shift 后执行 "$@" 的转调函数照常认、只 echo "$@" 的不算；Python 里按脚本目录解析出的 .csproj 字符串算接上。期望按构造手写
M=$T/r12; mkdir -p $M/tools $M/graphics/tests $M/graphics/m $M/plat/tests $M/plat/Py.Tests $M/plat/Lone.Tests; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $M/tools/
for t in t_gated t_notgated t_pre t_inner t_pat t_dry; do echo 'print(1)' > $M/graphics/tests/$t.py; done
for t in t_wrap t_say; do echo 'print(1)' > $M/plat/tests/$t.py; done
printf -- '-include $(sort $(wildcard */build.mk))\n' > $M/Makefile
printf 'gated:\n\tpython3 graphics/tests/t_gated.py\nnotgated:\n\tpython3 graphics/tests/t_notgated.py\nagg: sub-a\nsub-a:\n\tpython3 graphics/tests/t_pre.py\nsub-b:\n\t$(MAKE) -C graphics/m inner\nnative-test-x:\n\tpython3 graphics/tests/t_pat.py\ndry:\n\tpython3 graphics/tests/t_dry.py\nTEST_TARGETS += notgated\n' > $M/graphics/build.mk
printf 'inner:\n\tpython3 ../tests/t_inner.py\n' > $M/graphics/m/Makefile
printf 'make -s gated\ntimeout -k 15 "$GT" make -s agg sub-b\nfor k in x; do make -s "native-test-$k"; done\nmake -n dry\n' > $M/graphics/gate.sh
echo '<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>' > $M/plat/Py.Tests/Py.Tests.csproj; cp $M/plat/Py.Tests/Py.Tests.csproj $M/plat/Lone.Tests/Lone.Tests.csproj
printf 'from pathlib import Path\nhere = Path(__file__).resolve().parent\ncmd = ["dotnet", "build", str(here / "Py.Tests/Py.Tests.csproj")]\n' > $M/plat/run_py.py
printf 'from pathlib import Path\nprint("Lone.Tests.csproj")\n' > $M/plat/mention.py
printf '# 门禁路由：plat/\nrun() { echo "== $1"; shift; "$@"; }\nsay() { echo "$@"; }\nrun wrap python3 plat/tests/t_wrap.py\nsay python3 plat/tests/t_say.py\npython3 plat/run_py.py\npython3 plat/mention.py\n' > $M/plat/gate.sh
o=$(fixture_lint $M/tools/test_wired_lint.py $M 2>&1); r=$?
ck "⑫ 临时仓库退出 1（rc=${r}）" '[ $r = 1 ]'
for t in graphics/tests/t_gated.py graphics/tests/t_pre.py graphics/tests/t_inner.py graphics/tests/t_pat.py plat/tests/t_wrap.py plat/Py.Tests/Py.Tests.csproj; do
  ck "⑫ $t 算接上（门禁 make 到的目标 / 前置 / \$(MAKE) / 通配目标 / 转调函数 / Python 解析出的 .csproj）" '! grep -Fq "$t 没有" <<< "$o"'; done
for t in graphics/tests/t_notgated.py graphics/tests/t_dry.py plat/tests/t_say.py plat/Lone.Tests/Lone.Tests.csproj; do
  ck "⑫ $t 报没接线（只挂顶层聚合目标 / make -n / echo \"\$@\" / 字符串里不是按脚本目录的工程路径）" 'grep -Fq "$t 没有门禁脚本调它" <<< "$o"'; done

# ⑬ 11-01 维护者：分母不按命名——tests 目录（含 *-tests）下的测试入口（.sh、带 shebang / __main__ 的 .py）都要接线（#1243 stop_after_acquire.py 不叫 *_test 没人查）；
#   纯被导入的模块不算入口；unittest discover 按 -s 起始目录 + -p 模式精确展开（模式是变量不认；后面的重定向不算位置参数）；Python 跑器 subprocess.run([sys.executable, Path(__file__).with_name(x)]) 算接上。期望按构造手写
N=$T/r13; mkdir -p $N/tools $N/w/tests $N/vk/foo-tests $N/pk/tests $N/pk2/tests $N/pk3/tests; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $N/tools/
M13='if __name__ == "__main__":\n    print(1)\n'
printf "$M13" > $N/w/tests/stop_after_acquire.py; printf 'def helper():\n    return 1\n' > $N/w/tests/helper_mod.py; printf 'echo hi\n' > $N/w/tests/orphan.sh
printf "import subprocess, sys\nfrom pathlib import Path\nsubprocess.run([sys.executable, str(Path(__file__).with_name('child.py'))])\n$M13" > $N/vk/foo-tests/run.py; printf "$M13" > $N/vk/foo-tests/child.py
printf "$M13" > $N/pk/tests/test_a.py; printf "$M13" > $N/pk/tests/test_b.py; printf "$M13" > $N/pk/tests/other_c.py; printf "$M13" > $N/pk2/tests/test_d.py; printf "$M13" > $N/pk3/tests/test_e.py
mkdir -p $N/graphics; printf "python3 vk/foo-tests/run.py\npython3 -m unittest discover -s pk/tests -p 'test_*.py'\npython3 -m unittest discover -s pk2/tests -p \"\$P\"\npython3 -B -m unittest discover -s pk3/tests -v > build/pk3.log 2>&1 & p3=\$!\n" > $N/graphics/gate.sh
o=$(fixture_lint $N/tools/test_wired_lint.py $N 2>&1); r=$?
ck "⑬ 临时仓库退出 1（rc=${r}）" '[ $r = 1 ]'
for t in w/tests/stop_after_acquire.py w/tests/orphan.sh pk/tests/other_c.py pk2/tests/test_d.py; do
  ck "⑬ $t 报没接线（不按命名的入口 / .sh / discover 模式外 / 模式是变量）" 'grep -Fq "$t 没有门禁脚本调它" <<< "$o"'; done
for t in vk/foo-tests/run.py vk/foo-tests/child.py pk/tests/test_a.py pk/tests/test_b.py pk3/tests/test_e.py; do
  ck "⑬ $t 算接上（*-tests 入口 / Python 跑器 / discover 展开；pk3：discover 后接「> 日志 2>&1 &」，重定向不当模式）" '! grep -Fq "$t 没有" <<< "$o"'; done
ck "⑬ 纯被导入的模块不进分母" '! grep -Fq "w/tests/helper_mod.py" <<< "$o"'
mkdir -p $N/img/tests; printf 'FROM x\nCOPY entry.sh /opt/\nENTRYPOINT ["bash", "/opt/entry.sh"]\n' > $N/img/tests/Dockerfile; printf 'echo in-image\n' > $N/img/tests/entry.sh; printf 'echo loose\n' > $N/img/tests/loose.sh
o=$(fixture_lint $N/tools/test_wired_lint.py $N 2>&1)
ck "⑬ 同目录 Dockerfile COPY 进镜像的脚本是镜像内容、不进分母；没被 COPY 的 .sh 照报" '! grep -Fq "img/tests/entry.sh" <<< "$o" && grep -Fq "img/tests/loose.sh 没有门禁脚本调它" <<< "$o"'

# ⑭ 11-01 分母扩大后补的通用认法（期望按构造手写）：tests 目录下的钩子自己就是入口；source / . 读进来的脚本；
#   环境变量里放「解释器 脚本」命令串交给被测工具执行（S2A_DEVICECTL="python3 …/fake_devicectl.py"）；Python 跑器列表项 str(名字) 跟进赋值。
#   反例：变量只放裸脚本路径、命令串开头不是解释器、注释里的 source、Python 只打印不执行，都不算接上
P=$T/r14; mkdir -p $P/tools $P/tests/visual $P/w/tests; cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$H/tools/gate_route.py" $P/tools/
for t in lib.sh keep.sh commented.sh; do printf 'x() { :; }\n' > $P/w/tests/$t; done
for t in fake.py bare.py echoed.py gen.py printed.py; do printf "$M13" > $P/w/tests/$t; done
printf 'echo hook\n' > $P/tests/visual/gate.sh
printf 'here=$(cd "$(dirname "$0")" && pwd)\nsource "$here/lib.sh"\n[ 1 = 1 ] || { . "$(dirname "$0")/keep.sh"; }\n# source w/tests/commented.sh\nH=$(cd "$(dirname "$0")/../.." && pwd)\nexport X="python3 $H/w/tests/fake.py" Y="$H/w/tests/bare.py"\nZ="echo python3 w/tests/echoed.py" python3 w/tests/run_gen.py\n' > $P/w/tests/run.sh
printf "import subprocess, sys\nfrom pathlib import Path\nROOT = Path(__file__).resolve().parents[2]\ngen = ROOT / 'w' / 'tests' / 'gen.py'\nsubprocess.run([sys.executable, str(gen)])\nprinted = ROOT / 'w' / 'tests' / 'printed.py'\nprint(str(printed))\n$M13" > $P/w/tests/run_gen.py
mkdir -p $P/graphics; printf 'bash w/tests/run.sh\n' > $P/graphics/gate.sh
o=$(fixture_lint $P/tools/test_wired_lint.py $P 2>&1); r=$?
ck "⑭ 临时仓库退出 1（rc=${r}）" '[ $r = 1 ]'
for t in tests/visual/gate.sh w/tests/lib.sh w/tests/keep.sh w/tests/fake.py w/tests/gen.py w/tests/run_gen.py; do
  ck "⑭ $t 算接上（tests 下的钩子 / source / . / 环境变量命令串 / str(名字)）" '! grep -Fq "$t 没有" <<< "$o"'; done
for t in w/tests/commented.sh w/tests/bare.py w/tests/echoed.py w/tests/printed.py; do
  ck "⑭ $t 报没接线（注释 / 裸路径 / 命令串开头不是解释器 / 只打印）" 'grep -Fq "$t 没有门禁脚本调它" <<< "$o"'; done

# ⑪ 缺少真实路由入口时必须报红，不能静默退回旧名单。
F=$T/route-failure; mkdir -p "$F/tools" "$F/tests"
cp "$H/tools/test_wired_lint.py" "$H/tools/gate_decl.py" "$F/tools/"
printf 'raise RuntimeError("must not execute")\n' > "$F/tests/t_unwired.py"
o=$(fixture_lint "$F/tools/test_wired_lint.py" "$F" 2>&1); r=$?
ck "⑪ 路由入口缺失明确报红" '[ $r = 1 ] && grep -Fq "门禁钩子发现失败" <<< "$o"'

[ $bad = 0 ] && echo "test_wired 单测全过" || { echo "$o" | head -20; echo "test_wired 单测有不通"; }
exit $bad
