#!/bin/bash
# dsh_batch 临时目录接线检查（约 1 秒）：direct_lib.py 起 dsh_batch build 时 TMPDIR 落哪儿。直接调 direct_lib.batch_tmp，按几种调用方 TMPDIR 跑：
#   ① 调用方已把 TMPDIR 指到工作盘（oneclick_win.py：Windows 出包 <工作目录>/tmp）→ 沿用，落 <它>/dsh_batch.<进程号>，退出时删（11-07 Windows 出包机两次 rc=127 盘满：
#      原先写死 $W/tmp 把几十 GB 临时文件拉回常驻直连缓存所在的 T 盘）；② Mac 系统缺省 /var/folders/… → $W/tmp（不让内置盘被写爆，原口径）；
#   ③ 没设 → $W/tmp；④ Windows 用户 Temp（<用户目录>\AppData\Local\Temp，反斜杠与正斜杠两种写法）→ $W/tmp；⑤ 只有一处起 dsh_batch build，子进程环境带 TMPDIR=BT
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PYTHON:-${S2A_PY:-python3}}" - "$H" <<'PY'
import os, re, sys
H = sys.argv[1]; F = os.path.join(H, 'graphics', 'tools', 'direct', 'direct_lib.py')
sys.path.insert(0, os.path.dirname(F))
import direct_lib
bad = 0
def ck(msg, ok):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += not ok
pick = lambda td: direct_lib.batch_tmp(td, '/W', 42)
ck(f'① TMPDIR=/T/work/wtmp → 沿用其下子目录、退出时清（{pick("/T/work/wtmp")}）', pick('/T/work/wtmp') == ('/T/work/wtmp/dsh_batch.42', '/T/work/wtmp/dsh_batch.42'))
ck(f'② TMPDIR=/var/folders/ab/T/ → $W/tmp（{pick("/var/folders/ab/T/")}）', pick('/var/folders/ab/T/') == ('/W/tmp', ''))
ck(f'③ 没设 → $W/tmp（{pick("")}）', pick('') == ('/W/tmp', ''))
WT = ('D:\\P\\x\\AppData\\Local\\Temp', 'D:/P/x/AppData/Local/Temp')
ck(f'④ Windows 用户 Temp → $W/tmp（{[pick(t) for t in WT]}）', all(pick(t) == ('/W/tmp', '') for t in WT))
src = open(F, encoding='utf-8').read()
calls = [l for l in src.splitlines() if "'/dsh_batch.py', 'build'" in l]
ck(f'⑤ 只有一处起 dsh_batch build，带 TMPDIR=BT（{len(calls)} 处）', len(calls) == 1 and 'TMPDIR=BT' in calls[0])
print('dshb_tmp_wire 单测全过' if not bad else 'dshb_tmp_wire 单测有不通'); sys.exit(1 if bad else 0)
PY
