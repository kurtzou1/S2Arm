#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.sh tools/redact.py tests/direct_lib_fail_why_test.sh
# 出库失败红行带原因（direct_lib.sh fail_why，约 1 秒）：bash tests/direct_lib_fail_why_test.sh
#   诊断#3d03f4：玩家诊断只收到「出库失败 rc=134（[PRIVATE_PATH]」，异常原文只在 build.log 末尾。函数从 direct_lib.sh 原样抽出来跑。期望手写：
#   ① .NET 未处理异常（后面还有调用栈、Python 包装层的 CalledProcessError）→ 取「Unhandled exception…」那行
#   ② 没有异常字样 → 取最后一行非缩进、非「[直连库]」进度的输出
#   ③ 超长原因截到 160 字
#   ④ 拼成的红行（原因在路径前）过脱敏后原因还在、路径被抹（负对照：旧写法原因不在行里）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source <(sed -n '/^fail_why() {/,/^}/p' "$H/graphics/tools/direct/direct_lib.sh")
type fail_why > /dev/null 2>&1 || { echo "不通 direct_lib.sh 里找不到 fail_why"; exit 1; }
printf '[直连库] 第 4/5 步 出库：812 支\nUnhandled exception. System.NullReferenceException: Object reference not set to an instance of an object.\n   at S2A.Dsh.Batch.Build.Run()\nsubprocess.CalledProcessError: returned non-zero exit status 134.\n' > $T/a.log
o1=$(fail_why $T/a.log)
ck "① 取 .NET 异常行（${o1}）" '[ "$o1" = "Unhandled exception. System.NullReferenceException: Object reference not set to an instance of an object." ]'
printf '[直连库] 第 4/5 步 出库\nmetal: error: unsupported air version\n    note: from here\n[直连库] 收尾\n' > $T/b.log
o2=$(fail_why $T/b.log)
ck "② 取最后一行有效输出（${o2}）" '[ "$o2" = "metal: error: unsupported air version" ]'
python3 -c 'print("x" * 500)' > $T/c.log
o3=$(fail_why $T/c.log)
ck "③ 截到 160 字（${#o3}）" '[ ${#o3} = 160 ]'
red() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import redact; print(redact.redact_text(sys.argv[2], key_values=()))' "$H/tools" "$1"; }
new=$(red "[直连库] 🔴 出库失败 rc=134：${o1}（/Users/player/Library/Application Support/S2Arm/cache/work.stage.1/build.log）")
old=$(red "[直连库] 🔴 出库失败 rc=134（/Users/player/Library/Application Support/S2Arm/cache/work.stage.1/build.log）")
ck "④ 脱敏后原因还在、路径抹掉（${new}）" '[[ $new == *NullReferenceException* ]] && [[ $new == *PRIVATE_PATH* ]] && [[ $new != *Application\ Support* ]] && [[ $old != *Exception* ]]'
[ $bad = 0 ] && echo "direct_lib fail_why 单测全过" || { echo "direct_lib fail_why 单测有不通"; exit 1; }
