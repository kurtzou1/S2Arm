#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.py pack/jobs/errors.py tests/direct_lib_rc127_test.sh
# 出库 rc=127 的说法（direct_lib.py rc127_note，约 1 秒）：bash tests/direct_lib_rc127_test.sh
#   11-09 维护方测试树诊断替换写错，dsh_batch 抛异常退 127，原先在 Windows 上一律译成「127 = 盘满」（T 盘还剩 127 GB，照提示误删 37 GB 缓存）。
#   直接调 direct_lib.rc127_note（win= 造 Windows / Mac）；余量用 S2A_DISK_FREE_G 注入（⑥ 不注入、量真盘）。期望手写：
#   ① Windows、build.log 有 .NET 盘满原文 → 「127 = 盘满」，错误分类归 disk_full
#   ② Windows、没有盘满原文、两盘都剩 127 GB → 「不是盘满」、带余量、让看 build.log；错误分类不归 disk_full（负对照：旧码这里一律报盘满）
#   ③ Windows、没有盘满原文、剩 1 GB（< 2 GB）→ 「多半是盘满」、带余量，错误分类归 disk_full
#   ④ Mac 上 rc=127 → 不加说明
#   ⑤ Windows、rc=1 → 不加说明
#   ⑥ Windows、不注入余量、临时目录在本机（远大于 2 GB）→ 「不是盘满」
#   ⑦ Windows、不注入余量、有一个目录量不出余量（不存在）→ 不下结论（「可能是盘满…也可能是…异常退出」），错误分类不归 disk_full
#   ⑧ 原生进程拿到完整退出码：Windows 的 0xC000007F（STATUS_DISK_FULL）与 127 同样按上面判（剩 1 GB → 多半是盘满）
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PYTHON:-${S2A_PY:-python3}}" - "$H" <<'PY'
import os, re, sys, tempfile
H = sys.argv[1]
sys.path.insert(0, os.path.join(H, 'graphics', 'tools', 'direct')); sys.path.insert(0, os.path.join(H, 'pack', 'jobs'))
import direct_lib, errors
bad = 0
def ck(msg, ok):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += not ok
def cls(t): return next((c for p, c in errors.LOG_CAUSES if re.search(p, t)), '无')
with tempfile.TemporaryDirectory() as T:
    bt, c = os.path.join(T, 'bt'), os.path.join(T, 'c'); os.makedirs(bt); os.makedirs(c)
    full, exc = os.path.join(T, 'full.log'), os.path.join(T, 'exc.log')
    open(full, 'w').write('Unhandled exception. System.IO.IOException: There is not enough space on the disk. : spill.dat\n')
    open(exc, 'w').write('Unhandled exception. System.MissingMethodException: Method not found: Diag.Replace\n')
    def note(rc, log, dirs, win=True, free=None):
        os.environ.pop('S2A_DISK_FREE_G', None)
        if free is not None: os.environ['S2A_DISK_FREE_G'] = free
        return direct_lib.rc127_note(rc, log, dirs, win=win)
    o1 = note(127, full, [bt, c], free='127')
    ck(f'① 有盘满原文 → 盘满（{o1}）、分类 {cls(o1)}', '127 = 盘满' in o1 and cls(o1) == 'disk_full')
    o2 = note(127, exc, [bt, c], free='127')
    ck(f'② 余量充足、没有盘满原文 → 不是盘满（{o2}）、分类 {cls(o2)}', '不是盘满' in o2 and '剩 127 GB' in o2 and 'build.log' in o2 and cls(o2) != 'disk_full')
    o3 = note(127, exc, [bt, c], free='1')
    ck(f'③ 剩 1 GB → 多半是盘满（{o3}）、分类 {cls(o3)}', '多半是盘满' in o3 and '剩 1 GB' in o3 and cls(o3) == 'disk_full')
    o4 = note(127, exc, [bt, c], win=False, free='1')
    ck(f'④ Mac 上 127 → 不加说明（「{o4}」）', o4 == '')
    o5 = note(1, full, [bt, c], free='1')
    ck(f'⑤ rc=1 → 不加说明（「{o5}」）', o5 == '')
    o6 = note(127, exc, [bt])
    ck(f'⑥ 不注入、量本机真盘 → 不是盘满（{o6}）', '不是盘满' in o6)
    o7 = note(127, exc, [os.path.join(T, 'no', 'such', 'dir')])
    ck(f'⑦ 量不出余量 → 不下结论（{o7}）、分类 {cls(o7)}', '可能是盘满' in o7 and '异常退出' in o7 and cls(o7) != 'disk_full')
    o8 = note(0xC000007F, exc, [bt, c], free='1')
    ck(f'⑧ 完整退出码 0xC000007F、剩 1 GB → 多半是盘满（{o8}）', '多半是盘满' in o8)
print('direct_lib rc127 单测全过' if not bad else 'direct_lib rc127 单测有不通'); sys.exit(1 if bad else 0)
PY
