#!/usr/bin/env python3
"""普查直连库缓存（每台机器常驻，按款分目录 <根>/<程序号>/）的总量上限：用前调一次，超了按最久没用的款淘汰（11-01 维护者批）。
用法：dcache_gc.py <根> <上限 GB> <本次要用的款>   → 先给本次的款记「用过」（<款>/.used 改时刻），再淘汰
  - 在用的不淘汰：直连出库 direct_lib.py 在 <款>/ 下建 work.stage.<进程号> / mac.stage.<进程号>，进程号还活着 = 有出包在用（与 direct_lib.py 清残留同一判据）；
    旧 Python 仓 dmsh_store 对 <款>/store/.inuse 持共享锁，拿不到独占锁也算在用。本次要用的款也不淘汰
    （11-02 无主之地3：C# 出库不持 .inuse 锁、Build.cs 还把它当旧文件删掉，别的批次的淘汰在出库中途删了这款缓存，build.log 被删、出库卡死 600 秒被杀）
  - 删除走 S2A_SAFE_RM（我方机器给 safe_rm.sh），没给就直接删；每次淘汰写一行到 <根>/gc.log 并打到标准输出
  - 体积按实际占块（st_blocks）算，APFS 克隆按各自块计
原先（10-29）缓存放各局工作目录、局完即删，是因为常驻缓存没人回收（本机 15 款积到 45 GB、Spare-host 单款 211 GB）；带上限后常驻，普查重跑同款命中缓存"""
import fcntl, os, shutil, subprocess, sys, time

def size(d):
    n = 0
    for r, _, fs in os.walk(d):
        for f in fs:
            try: n += os.lstat(os.path.join(r, f)).st_blocks * 512
            except OSError: pass
    return n

def alive(pid):
    try: os.kill(pid, 0)
    except ProcessLookupError: return False
    except PermissionError: return True
    return True

def in_use(d):
    for n in os.listdir(d):
        stem, _, pid = n.rpartition('.')
        if stem in ('work.stage', 'mac.stage') and pid.isdecimal() and alive(int(pid)): return True
    p = os.path.join(d, 'store', '.inuse')
    if not os.path.exists(p): return False
    with open(p, 'a') as f:
        try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: return True
        fcntl.flock(f, fcntl.LOCK_UN); return False

def used_at(d):
    try: return os.stat(os.path.join(d, '.used')).st_mtime
    except OSError: return os.stat(d).st_mtime

def main(root, cap_gb, keep):
    os.makedirs(os.path.join(root, keep), exist_ok=True)
    with open(os.path.join(root, keep, '.used'), 'a'): pass
    os.utime(os.path.join(root, keep, '.used'))
    ents = [(n, os.path.join(root, n)) for n in os.listdir(root) if os.path.isdir(os.path.join(root, n))]
    sz = {n: size(d) for n, d in ents}; total = sum(sz.values()); cap = cap_gb * (1 << 30)
    rm = os.environ.get('S2A_SAFE_RM')
    for n, d in sorted(ents, key=lambda e: used_at(e[1])):
        if total <= cap: break
        if n == keep or in_use(d): continue
        t = used_at(d)
        if rm: r = subprocess.run(['bash', rm, d], capture_output=True, text=True); ok = r.returncode == 0
        else: shutil.rmtree(d, ignore_errors=True); ok = not os.path.exists(d)
        line = f'{time.strftime("%m-%d %H:%M:%S")} 淘汰 {n} {sz[n] / (1 << 30):.1f} GB（最近用 {time.strftime("%m-%d %H:%M", time.localtime(t))}）' + ('' if ok else ' 【红】没删掉')
        print(line, flush=True)
        with open(os.path.join(root, 'gc.log'), 'a') as f: f.write(line + '\n')
        if ok: total -= sz[n]
    print(f'普查直连缓存 {total / (1 << 30):.1f} GB / 上限 {cap_gb} GB（{root}）', flush=True)

if __name__ == '__main__':
    if len(sys.argv) != 4: sys.exit(__doc__)
    main(sys.argv[1], float(sys.argv[2]), sys.argv[3])
