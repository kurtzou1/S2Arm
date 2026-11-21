#!/usr/bin/env python3
# 门禁覆盖：graphics/tools/direct/cs_pipelines.py graphics/tools/direct/base_pipelines.py
# 管线出包的子进程不走 fork（cs_pipelines.run_tt / run_tool / clone）：18 路线程池里 fork 要复制整个大进程且持全局锁，同一时刻只能起一个，
#   原先一款大作每对起 3 个子进程平均各 300 ms、metal-tt 只占线程时间 36%。期望按构造写死：
#   ① run_tool 起绝对路径工具走 os.posix_spawn（计 1 次），收到输出与退出码；② run_tt 走 os.posix_spawnp 1 次、新会话（子进程组号 = 自己的进程号 ≠ 本进程组号）、
#      输出写进 log、退出码照传；③ 超时：假工具自己睡 30 秒并留一个睡 30 秒的孙进程，上限改 1 秒 → 退 124、3 秒内返回、输出带「ran past」、孙进程不在了；
#   ④ clone 不起子进程（subprocess.run 计 0 次）、内容一致
import os, subprocess, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cs_pipelines as cs

n = fail = 0
def ck(name, ok):
    global n, fail
    n += 1; fail += not ok; print(('✓ ' if ok else '✗ ') + name)

calls = {'spawn': 0, 'spawnp': 0, 'run': 0}
osp, ospp, orun = os.posix_spawn, os.posix_spawnp, subprocess.run
def sp(*a, **k): calls['spawn'] += 1; return osp(*a, **k)
def spp(*a, **k): calls['spawnp'] += 1; return ospp(*a, **k)
os.posix_spawn, os.posix_spawnp = sp, spp

with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    r = cs.run_tool(['/bin/sh', '-c', 'echo hi; exit 3'])
    ck(f'① run_tool 走 posix_spawn {calls["spawn"]} 次（期望 1）、退出 {r.returncode}（期望 3）、输出 {r.stdout!r}', calls['spawn'] == 1 and r.returncode == 3 and r.stdout == b'hi\n')
    tool = d / 'tt'; tool.write_text('#!/bin/sh\necho "pg $(ps -o pgid= -p $$ | tr -d " ") pid $$"\nexit 5\n'); tool.chmod(0o755)
    rc, text = cs.run_tt([str(tool), 'x', 'script', '-o', 'out'], dict(os.environ), d / 'tt.log')
    pg, pid = text.split()[1], text.split()[3]
    ck(f'② run_tt 走 posix_spawnp {calls["spawnp"]} 次（期望 1）、退出 {rc}（期望 5）、子进程组 {pg} = 自身 {pid}、≠ 本进程组 {os.getpgid(0)}、log 同输出',
       calls['spawnp'] == 1 and rc == 5 and pg == pid and int(pg) != os.getpgid(0) and (d / 'tt.log').read_text() == text)
    slow = d / 'slow'; mark = d / 'gc.pid'
    slow.write_text(f'#!/bin/sh\nsleep 30 & echo $! > {mark}\nsleep 30\n'); slow.chmod(0o755)
    cs.TT_TIMEOUT = 1; t = time.monotonic()
    rc, text = cs.run_tt([str(slow), str(d / 'slow.mtl4-json'), '-o', 'out'], dict(os.environ), d / 'slow.log')
    dt = time.monotonic() - t; time.sleep(0.3)
    gc = int(mark.read_text())
    try: os.kill(gc, 0); alive = True
    except ProcessLookupError: alive = False
    ck(f'③ 超时：退出 {rc}（期望 124）、用时 {dt:.1f} 秒（期望 < 3）、输出带 ran past、孙进程 {"还在" if alive else "已杀"}', rc == 124 and dt < 3 and 'ran past' in text and not alive)
    def cnt(*a, **k): calls['run'] += 1; return orun(*a, **k)
    subprocess.run = cnt
    src = d / 's.bin'; src.write_bytes(os.urandom(4096)); dst = d / 'c' / 'x.e'; dst.parent.mkdir()
    cs.clone(src, dst)
    subprocess.run = orun
    ck(f'④ clone 起子进程 {calls["run"]} 次（期望 0）、内容{"一致" if dst.read_bytes() == src.read_bytes() else "不一致"}', calls['run'] == 0 and dst.read_bytes() == src.read_bytes())
print(f't_pipelines_spawn：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
