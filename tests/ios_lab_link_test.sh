#!/bin/bash
# 门禁只看：ios/* runtime/src/* runtime/include/* ios/lab/* tools/ios_lab_link.py tools/weak_link_decl.py
# iOS 输入工作台编链（只编链不跑，约 20 秒）：bash tests/ios_lab_link_test.sh
# 11-01 维护者：c3c296ac1（10-28）让 settings.m 调 s2a_caps_apply、工作台工程没带 caps.c，main 上链不过三天没人发现——它不在门禁里。
# 期望：当前工程链得过、放行的弱符号在每个目标文件里都是弱引用；反证 = 去掉 runtime/src/caps.c 的工程（10-28 起的状态）链接失败、点名 _s2a_caps_apply
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/toolchain.sh"
o=$(python3 "$H/tools/ios_lab_link.py" --out "$T/now" 2>&1); r=$?
ck "当前工程链得过（rc=${r}：$(echo "$o" | head -1 | cut -c1-160)）" '[ $r = 0 ]'
grep -v '^ *- runtime/src/caps.c$' "$H/ios/lab/project.yml" > "$T/project.yml"
o=$(python3 "$H/tools/ios_lab_link.py" --spec "$T/project.yml" --out "$T/old" 2>&1); r=$?
ck "反证：工程去掉 caps.c → 链接失败点名 _s2a_caps_apply（rc=${r}）" '[ $r = 1 ] && [[ "$o" == *"未定义 _s2a_caps_apply"* ]]'
# #1953：放行的弱符号在某个源文件里是普通声明（强引用）→ 链得过但工作台一启动 dyld 就退出；期望编链检查点名那个源文件
printf '#import <Foundation/Foundation.h>\nvoid s2a_dprompt_notice(NSString *t, NSString *b, double d, double s);\nvoid s2a_lab_strong_probe(void) { s2a_dprompt_notice(@"", @"", 0, 0); }\n' > "$T/strong_probe.m"
sed "s|^\( *\)- ios/diag.m\$|&\n\1- $T/strong_probe.m|" "$H/ios/lab/project.yml" > "$T/project2.yml"
o=$(python3 "$H/tools/ios_lab_link.py" --spec "$T/project2.yml" --out "$T/strong" 2>&1); r=$?
ck "反证：加一个强引用 s2a_dprompt_notice 的源文件 → 点名它（rc=${r}）" '[ $r = 1 ] && [[ "$o" == *"strong_probe.m：s2a_dprompt_notice"* ]]'
[ $bad = 0 ] && echo "iOS 输入工作台编链单测全过" || { echo "iOS 输入工作台编链单测有不通"; exit 1; }
