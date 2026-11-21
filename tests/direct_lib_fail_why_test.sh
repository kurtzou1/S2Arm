#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.py tools/redact.py tests/direct_lib_fail_why_test.sh
# 出库失败红行带原因（direct_lib.py fail_why，约 1 秒）：bash tests/direct_lib_fail_why_test.sh
#   诊断#3d03f4：玩家诊断只收到「出库失败 rc=134（[PRIVATE_PATH]」，异常原文只在 build.log 末尾。直接调 direct_lib.fail_why。期望手写：
#   ① .NET 未处理异常（后面还有调用栈、Python 包装层的 CalledProcessError）→ 取「Unhandled exception…」那行
#   ② 没有异常字样 → 取最后一行非缩进、非「[直连库]」进度的输出
#   ③ 超长原因截到 160 字
#   ④ 拼成的红行（原因在路径前）过脱敏后原因还在、路径被抹（负对照：旧写法原因不在行里）
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PYTHON:-${S2A_PY:-python3}}" - "$H" <<'PY'
import os, sys, tempfile
H = sys.argv[1]
sys.path.insert(0, os.path.join(H, 'graphics', 'tools', 'direct')); sys.path.insert(0, os.path.join(H, 'tools'))
import direct_lib, redact
bad = 0
def ck(msg, ok):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += not ok
def fw(text):
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, 'a.log'); open(p, 'w', encoding='utf-8').write(text); return direct_lib.fail_why(p)
o1 = fw('[直连库] 第 4/5 步 出库：812 支\nUnhandled exception. System.NullReferenceException: Object reference not set to an instance of an object.\n   at S2A.Dsh.Batch.Build.Run()\nsubprocess.CalledProcessError: returned non-zero exit status 134.\n')
ck(f'① 取 .NET 异常行（{o1}）', o1 == 'Unhandled exception. System.NullReferenceException: Object reference not set to an instance of an object.')
o2 = fw('[直连库] 第 4/5 步 出库\nmetal: error: unsupported air version\n    note: from here\n[直连库] 收尾\n')
ck(f'② 取最后一行有效输出（{o2}）', o2 == 'metal: error: unsupported air version')
o3 = fw('x' * 500 + '\n')
ck(f'③ 截到 160 字（{len(o3)}）', len(o3) == 160)
new = redact.redact_text(f'[直连库] 🔴 出库失败 rc=134：{o1}（/Users/player/Library/Application Support/S2Arm/cache/work.stage.1/build.log）', key_values=())
old = redact.redact_text('[直连库] 🔴 出库失败 rc=134（/Users/player/Library/Application Support/S2Arm/cache/work.stage.1/build.log）', key_values=())
ck(f'④ 脱敏后原因还在、路径抹掉（{new}）', 'NullReferenceException' in new and 'PRIVATE_PATH' in new and 'Application Support' not in new and 'Exception' not in old)
print('direct_lib fail_why 单测全过' if not bad else 'direct_lib fail_why 单测有不通'); sys.exit(1 if bad else 0)
PY
