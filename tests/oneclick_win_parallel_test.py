#!/usr/bin/env python3
"""pack/orch/oneclick_win.py 并行度按内存封顶（#711：Windows 16 GB 抽取按逻辑核数开满进程池、MemoryError）单测：python3 tests/oneclick_win_parallel_test.py
期望按 tools/cores.sh 同一口径手算（不跑被测实现）：
  抽取 / 改写 = min(核数, 内存 GB × 3 // 4 × 2 // 3)，至少 1
  直连库编译 = min(核数, 1 + (内存 GB × 1024 × 3 // 4 − 1740 − 1065) // 420)，至少 1
  16 GB / 32 核：12 × 2 // 3 = 8；1 + (12288 − 2805) // 420 = 1 + 22 = 23 → (8, 23)
  16 GB / 12 核：(8, 12)      8 GB / 8 核：6 × 2 // 3 = 4；1 + 3339 // 420 = 8 → (4, 8)（同 cores.sh 头注「8 GB / 8 核开满 8 路」）
  4 GB / 8 核：(2, 1)         2 GB / 8 核：1 × 2 // 3 = 0 → 1；直连为负 → 1 → (1, 1)
  内存读不到 / 16 核：(16, 16)（不拦，照旧）     环境 S2A_CPU_BAKE=3、S2A_DIRECT_J=5：用给的
  direct() 交给直连库脚本的 J / S2A_CPU_BAKE 就是上面两个数（S2A_MEM_TOTAL_GB=16、--jobs 32 → J=23、S2A_CPU_BAKE=8）
  工作根联接退回拷贝（v0.3.1 exFAT）：建不了联接 → 整份拷、内容一样；目标已在 → 报错"""
import os, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
from pack.orch import oneclick_win as ow   # noqa: E402

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

for k in ('S2A_CPU_BAKE', 'S2A_DIRECT_J', 'S2A_MEM_TOTAL_GB', 'S2A_DIRECT_CACHE', 'S2A_DIRECT_CACHE_ROOT', 'S2A_PSO_SOURCES', 'S2A_PSO_KNOW'):
    os.environ.pop(k, None)
for (gb, jobs), want in {(16, 32): (8, 23), (16, 12): (8, 12), (8, 8): (4, 8), (4, 8): (2, 1), (2, 8): (1, 1), (None, 16): (16, 16)}.items():
    chk(f'{gb} GB / {jobs} 核', want, ow.parallel(jobs, gb))
os.environ['S2A_CPU_BAKE'] = '3'; os.environ['S2A_DIRECT_J'] = '5'
chk('环境给了就用给的', (3, 5), ow.parallel(32, 16))
os.environ.pop('S2A_CPU_BAKE'); os.environ.pop('S2A_DIRECT_J')
os.environ['S2A_MEM_TOTAL_GB'] = '16'
chk('S2A_MEM_TOTAL_GB 手动指定', 16, ow.mem_gb())

seen = {}
real_sh = ow.Run.sh
def fake_sh(self, args, log, env=None, ok=(0,), cwd=None):
    if log != 'direct_lib.log': return real_sh(self, args, log, env, ok, cwd)
    seen['J'], seen['BAKE'] = env['J'], env['S2A_CPU_BAKE']
    return 0
ow.Run.sh = fake_sh
with tempfile.TemporaryDirectory() as t:
    t = Path(t); cur = t / 'cur'; cur.mkdir()
    ow.direct(ow.Run(t / 'o'), cur, 'ios', 32, '0100abcd00001000')
chk('direct() 交给直连库脚本的 J / S2A_CPU_BAKE', ('23', '8'), (seen.get('J'), seen.get('BAKE')))
# v0.3.1：工作根联到现行各项建不了联接（exFAT / FAT32 上 CreateJunction 报 WinError 1）→ 整份拷过来，内容一样；目标已在照旧报错（不悄悄覆盖）
real_symlink = os.symlink
def no_links(*a, **k): raise OSError(1, 'Incorrect function')
with tempfile.TemporaryDirectory() as t:
    t = Path(t); (t / 'src' / 'sub').mkdir(parents=True); (t / 'src' / 'sub' / 'f').write_bytes(b'x')
    os.symlink = no_links
    try:
        ow.junction(t / 'dst', t / 'src')
        chk('建不了联接：整份拷过来', (False, b'x'), ((t / 'dst').is_symlink(), (t / 'dst' / 'sub' / 'f').read_bytes()))
        try: ow.junction(t / 'dst', t / 'src'); again = '没报错'
        except OSError: again = '报错'
        chk('目标已在：照旧报错、不覆盖', '报错', again)
    finally:
        os.symlink = real_symlink
sys.exit(1 if bad else 0)
