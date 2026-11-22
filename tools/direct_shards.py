#!/usr/bin/env python3
"""直连库分片清点 / 核对（11-01 究极4：出包时分片在，局快照里没有，丢在出包之后某一步；原先 entry_check 只查 lib.idx 在不在）。
用法：
  direct_shards.py check <产物根 | b-<链> 目录>              核 lib.idx 列出的每个分片 lib.NNN.pak 都在且大小相符；缺 / 不符 → 退出 1 并点名哪一片、哪个路径
  direct_shards.py inventory <产物根 | b-<链> 目录> --label X [--log 文件]   打一行「分片清点」（并追加到 --log），不判对错，退出 0
容器格式见 graphics/nvn/lib_pack.inc：头 48 字节（"S2ALIB\\0\\0"、u32 ver=1、u32 n、u32 nshard）+ nshard × 16 字节分片表（u64 size、u64 0）+ n × 24 字节记录。
没有任何 lib.idx 的目录（Vulkan vk/ / OpenGL gl/ 或根里没直连库）check 退出 0、inventory 记「无 lib.idx」。"""
import os, struct, sys, time


def idx_dirs(p):
    """→ 要核的 b-<链> 目录列表：给的就是含 lib.idx 的目录用它；给的是产物根取 shaders/direct/b-*/"""
    if os.path.isfile(os.path.join(p, 'lib.idx')): return [p]
    d = os.path.join(p, 'shaders', 'direct')
    try: return sorted(os.path.join(d, n) for n in os.listdir(d) if n.startswith('b-') and os.path.isfile(os.path.join(d, n, 'lib.idx')))
    except OSError: return []


def scan(b):
    """→ (记录数, 分片数, [(文件名, 路径, 应有字节, 实有字节或 None)], 头错误或 '')"""
    try: h = open(os.path.join(b, 'lib.idx'), 'rb').read()
    except OSError as e: return 0, 0, [], f'读不了 lib.idx（{e}）'
    if len(h) < 48 or h[:8] != b'S2ALIB\0\0': return 0, 0, [], 'lib.idx 头不对（魔数不是 S2ALIB 或不足 48 字节）'
    ver, n, ns = struct.unpack_from('<III', h, 8)
    if ver != 1: return n, ns, [], f'lib.idx 版本 {ver} 不是 1'
    if ns > 65536 or len(h) != 48 + 16 * ns + 24 * n: return n, ns, [], f'lib.idx 长度 {len(h)} 与记录数 {n} / 分片数 {ns} 不符'
    bad = []
    for i in range(ns):
        want = struct.unpack_from('<Q', h, 48 + 16 * i)[0]; f = f'lib.{i:03d}.pak'; path = os.path.join(b, f)
        try: have = os.stat(path).st_size
        except OSError: have = None
        if have != want: bad.append((f, path, want, have))
    return n, ns, bad, ''


def line(b, label):
    n, ns, bad, err = scan(b)
    if err: return f'分片清点[{label}] {b}：{err}'
    miss = [x for x in bad if x[3] is None]; size = [x for x in bad if x[3] is not None]
    s = f'分片清点[{label}] {b}：idx 记录 {n} 条、分片 {ns} 片，在且大小相符 {ns - len(bad)}/{ns}'
    if miss: s += '；缺：' + '、'.join(f'{f}（{p}，应 {w} 字节）' for f, p, w, _ in miss)
    if size: s += '；大小不符：' + '、'.join(f'{f}（{p}，实 {h} 应 {w}）' for f, p, w, h in size)
    return s


def main(a):
    if len(a) < 2 or a[0] not in ('check', 'inventory'): print(__doc__); return 2
    cmd, p = a[0], a[1]; label = a[a.index('--label') + 1] if '--label' in a else '-'; log = a[a.index('--log') + 1] if '--log' in a else ''
    ds = idx_dirs(p)
    if cmd == 'inventory':
        out = [line(d, label) for d in ds] or [f'分片清点[{label}] {p}：无 lib.idx']
        for o in out:
            print(o)
            if log:
                try: open(log, 'a', encoding='utf-8').write(f'{time.strftime("%m-%d %T")} {o}\n')
                except OSError: pass
        return 0
    rc = 0
    for d in ds:
        n, ns, bad, err = scan(d)
        if err or bad: print('🔴 ' + line(d, label)); rc = 1
    return rc


if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
