#!/usr/bin/env python3
# S2Arm 抽取（nxsh_extract.py）着色器字节的存放：每个进程一份追加写的大文件 <抽取目录>/src/p<进程号>.pk，不再每支落 <键>.ctl / <键>.code 两个小文件。
#   11-02 出包线：Overcooked! All You Can Eat 唯一键 384497 支 → 约 77 万个小文件，同一份输入 J=8 不落盘 52 秒、逐支落盘 556 秒（普查 2 路 1508 秒），九成时间在建文件 / 改名的元数据操作上。
#   记录 = u16 键长 | 键（ASCII）| u32 控制段长 | u32 机器码长 | 控制段 | 机器码（小端）。同一键可能被多个进程各写一次（内容相同：键是两段的 sha256 前缀），读时取第一条。
#   读取方（merge_extract.py、exe_shtab_programs / red_static_programs / ue_programs、ShaderBake.cs SrcPack）扫一遍各 .pk 建「键 → 位置」表再按键取；不另写索引文件，抽取中途也能读。
#   分组 / 配对语义（shader_groups、变体号）在 rows.tsv / index.tsv 里，与字节存放无关，不变。
import glob
import os
import struct

HEAD = struct.Struct('<H')
LENS = struct.Struct('<II')


class Writer:
    """本进程的追加写端：put(key, code, ctl) 同一进程内同键只写一次；每次 put 后不必 flush，flush() 在一批写完后调用（工作进程不保证正常退出，所以按批 flush）"""
    def __init__(self, outdir):
        self.dir = os.path.join(outdir, 'src'); self.f = None; self.seen = set()

    def put(self, key, code, ctl):
        if key in self.seen: return
        if self.f is None:
            os.makedirs(self.dir, exist_ok=True); self.f = open(os.path.join(self.dir, f'p{os.getpid()}.pk'), 'ab')
        kb = key.encode('ascii')
        self.f.write(HEAD.pack(len(kb))); self.f.write(kb); self.f.write(LENS.pack(len(ctl), len(code))); self.f.write(ctl); self.f.write(code); self.seen.add(key)

    def flush(self):
        if self.f is not None: self.f.flush()


_W = {}
def writer(outdir):
    """同一进程、同一输出目录共用一个写端（进程池工作进程跨任务复用）"""
    k = (os.getpid(), os.path.abspath(outdir))
    if k not in _W: _W[k] = Writer(outdir)
    return _W[k]


class Src:
    """读端：扫 <抽取目录>/src/*.pk 建表；get(key) → (code, ctl)，没有 → KeyError；keys() 全部键"""
    def __init__(self, xdir):
        self.loc = {}; self.files = []
        for i, p in enumerate(sorted(glob.glob(os.path.join(glob.escape(xdir), 'src', '*.pk')))):   # 目录名按字面量（#1009：游戏库在「[2]NS…」下，[2] 被当成字符类 → 一份 .pk 都找不到）
            self.files.append(open(p, 'rb')); f = self.files[-1]; size = os.fstat(f.fileno()).st_size; off = 0
            while off + HEAD.size <= size:
                f.seek(off); (kl,) = HEAD.unpack(f.read(HEAD.size)); h = f.read(kl + LENS.size)
                if len(h) < kl + LENS.size: break   # 写到一半的尾巴（进程被杀）：不认
                cl, dl = LENS.unpack(h[kl:]); body = off + HEAD.size + kl + LENS.size; end = body + cl + dl
                if end > size: break
                self.loc.setdefault(h[:kl].decode('ascii'), (i, body, cl, dl)); off = end

    def __contains__(self, key): return key in self.loc
    def __len__(self): return len(self.loc)
    def keys(self): return self.loc.keys()

    def get(self, key):
        i, o, cl, dl = self.loc[key]; f = self.files[i]; f.seek(o); ctl = f.read(cl); code = f.read(dl)
        return code, ctl

    def get_code(self, key): return self.get(key)[0]

    def close(self):
        for f in self.files: f.close()
