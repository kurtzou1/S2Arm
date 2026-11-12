#!/usr/bin/env python3
# romfs 里的 NRO → 改写器能吃的 NSO（未压缩），并出 nro_modules.tsv（10-29 普查 c1029c：大航海4 HD / 魔界战记6 / 忍者龟 用 nn::ro 装 NRO，
#   我方 ldr:ro 映射未支持，LoadNro 失败 → 游戏 Break）。NRO 与 exefs 模块一样在出包时改写、编进 App；运行时 ro LoadNro 按整个 NRO 文件的
#   SHA-256（与 NRR 登记的哈希同一口径）在 nro_modules.tsv 里找到模块名，装载器（runtime/src/loader.c s2a_nro_map）映射预先改写好的映像。
# 用法：nro_to_nso.py <romfs 目录> <输出目录>
#   输出目录/<模块名>      NSO（模块名 nro0、nro1 …；iOS 节名 __sw<名>x0 ≤ 16 字符）
#   输出目录/nro_modules.tsv  模块名<TAB>SHA-256<TAB>NRO 大小<TAB>bss 大小<TAB>来源（同内容多份以 | 分隔）
# 收哪些 NRO（零配置、各款通用）：
#   ① romfs 任意深度的 *.nro（不分大小写，含点目录），按 romfs 相对路径排序、同内容去重——没有 .nrr 的游戏只有这一步，行为与原先逐字节相同。
#   ② 有 romfs/.nrr/*.nrr（游戏登记给 ro 服务的 NRO 哈希表，ro 只装登记过的 NRO）且 ① 后还有登记哈希没找到：扫 romfs 其余文件（.nrr 目录与 *.nro 除外，
#      按相对路径排序、流式分块读，不整块进内存），认两种藏法——原样 NRO（+0x10 'NRO0'）与 zstd 帧（帧头 28 B5 2F FD，先只解前 0x20 字节认 NRO0，
#      再按头里大小整帧解）；整份 NRO 的 SHA-256 **必须在 NRR 登记里**才收，没登记的一律不收（所以不会把归档里别的东西误当模块）。全部登记哈希都找到就停扫。
#      11-03 大乱斗 SPECIAL：764 个 NRO 全以 zstd 帧藏在 romfs/data.arc（17.6 GB 游戏自有归档），romfs 没有一个 .nro → 原先一个没收、LoadNro 报不在表。
#      ② 收的模块排在 ① 之后，按 NRR 文件名、表内登记顺序编号（与归档内摆放无关）；来源写 <romfs 相对路径>@<偏移>（原样）/ <…>@<偏移>:zstd（zstd 帧起点）。
# 退出码：0（没有 NRO 也是 0，不出表）。读不懂的 NRR / 读坏的 NRO 跳过这一份、打【黄】记一笔，其余照转（#713：一份 NRR 认不出原先整款出不了包）；
#   只有环境问题（找不到 libzstd）退出 1。
# NRO 格式（switchbrew NRO）：+0x4 MOD0 偏移；+0x10 'NRO0'；+0x18 文件大小；+0x20 三段（文件偏移、大小）text / ro / data；+0x38 bss 大小；
#   +0x40 构建号（0x20）；+0x68 / 0x70 / 0x78 api 信息 / 动态串表 / 动态符号表（相对 ro 段，与 NSO 同口径）。映像未压缩，文件偏移即模块内偏移。
# NRR 格式（switchbrew NRR0）：+0x0 'NRR0'；+0x10 证书（0x220）；+0x230 签名（0x100）；+0x330 程序号（u64）；+0x338 大小（u32）；+0x33C NrrKind（u8）；
#   +0x340 哈希表偏移（u32，实际总是 0x350）；+0x344 哈希个数（u32）；表内每项 32 字节 = 一个 NRO 整文件的 SHA-256。
#   Switch 2 的 NRR（#713，一款 Switch 2 赛车游戏 .nrr/EffectScript.nrr，0x1000 字节）在 +0x340 读出的是乱数：签名等前面的字段变长、后面整体后移，
#   switchbrew 没有这一版的定义。不猜签名长：「大小」字段等于文件长、紧跟着程序种类、再后面是哈希表偏移与个数，按这个锚点在头里找（nrr_table）；
#   找错了也不会收错模块——只有整份 SHA-256 对得上登记的 NRO 才收。
import hashlib, os, struct, sys
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py，walk 同 os.walk）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'graphics', 'nvn', 'tools')); import romfs_list

PAGE = 0x1000
CHUNK = 64 << 20          # 扫描分块（内存只占一块 + 重叠）
ZHEAD = 0x20000 + 0x400   # 解 zstd 帧前 0x20 字节最多要整个第一块（块 ≤ 128 KB）+ 帧头；也是分块重叠长度
ZMAGIC, NMAGIC = b'\x28\xb5\x2f\xfd', b'NRO0'
NMAX = 1 << 30            # 单个 NRO 大小上限（实测大乱斗最大约 20 MB；超过这个的头当垃圾，不去读）


def seg_ok(b, s, n):
    """b[s:] 处的 NRO 头：text / ro / data 三段从 0 起首尾相接、合计 = n（与 parse 同一判据，只看头、不读正文）"""
    if s + 0x38 > len(b): return False
    (to, ts), (ro, rs), (do, ds) = (struct.unpack_from('<II', b, s + 0x20 + i * 8) for i in range(3))
    return to == 0 and ro == ts and do == ro + rs and do + ds == n


def parse(d, what):
    if len(d) < 0x80 or d[0x10:0x14] != NMAGIC: raise ValueError(f'{what}：不是 NRO（缺 NRO0 标记）')
    size = struct.unpack_from('<I', d, 0x18)[0]
    segs = [struct.unpack_from('<II', d, 0x20 + i * 8) for i in range(3)]
    bss = struct.unpack_from('<I', d, 0x38)[0]
    if size != len(d): raise ValueError(f'{what}：头里的大小 {size:#x} ≠ 文件 {len(d):#x}')
    (to, ts), (ro, rs), (do, ds) = segs
    if to != 0 or ro != ts or do != ro + rs or do + ds != size: raise ValueError(f'{what}：三段不连续（{segs}）')
    if any(x & (PAGE - 1) for x in (ts, rs, ds, bss)): raise ValueError(f'{what}：段 / bss 没按 4 KB 对齐')
    m0 = struct.unpack_from('<I', d, 4)[0]
    if d[m0:m0 + 4] != b'MOD0': raise ValueError(f'{what}：MOD0 偏移 {m0:#x} 处没有 MOD0')
    return segs, bss


def to_nso(d, segs, bss):
    h = bytearray(0x100)
    h[0:4] = b'NSO0'   # 版本 0、flags 0（三段都不压缩、不校验哈希）
    fo = len(h)
    for i, (mo, sz) in enumerate(segs):
        struct.pack_into('<III', h, 0x10 + i * 0x10, fo, mo, sz)
        struct.pack_into('<I', h, 0x60 + i * 4, sz)
        fo += sz
    struct.pack_into('<I', h, 0x3c, bss)
    h[0x40:0x60] = d[0x40:0x60]   # 构建号
    h[0x88:0xa0] = d[0x68:0x80]   # api 信息 / 动态串表 / 动态符号表（相对 ro）
    return bytes(h) + d


def nrr_table(d):
    """NRR 哈希表的 (偏移, 个数)：先按 switchbrew NRR0（+0x338 大小 = 文件长，+0x340 偏移 / 个数）；对不上再在头里找「u32 = 文件长」的锚点，
    其后第 8 / 12 字节是偏移 / 个数，要求表在锚点之后、整张落在文件里、16 字节对齐、个数 ≥ 1（Switch 2 的 NRR 字段后移，#713）。认不出 → None"""
    def ok(p):
        if p + 0x10 > len(d) or struct.unpack_from('<I', d, p)[0] != len(d): return None
        off, cnt = struct.unpack_from('<II', d, p + 8)
        return (off, cnt) if cnt and off % 0x10 == 0 and off >= p + 0x10 and off + cnt * 32 <= len(d) else None
    return ok(0x338) or next((t for p in range(0x300, min(len(d), 0x1000) - 0x10, 4) for t in [ok(p)] if t), None)


def nrr_hashes(romfs):
    """romfs/.nrr/*.nrr 登记的 NRO 哈希（十六进制），按 NRR 文件名、表内顺序，去重；没有 .nrr 目录 → []。认不出的 NRR 跳过、打【黄】"""
    nd = os.path.join(romfs, '.nrr')
    if not os.path.isdir(nd): return []
    out, seen = [], set()
    for f in sorted(romfs_list.listdir(nd)):
        if not f.lower().endswith('.nrr') or not os.path.isfile(os.path.join(nd, f)): continue
        d = open(os.path.join(nd, f), 'rb').read()
        t = nrr_table(d) if len(d) >= 0x350 and d[:4] == b'NRR0' else None
        if not t:
            print(f'【黄】.nrr/{f}：认不出哈希表（{len(d):#x} 字节，开头 {d[:4]!r}），这一份不用；它登记的、又不是 *.nro 文件的模块这次收不到', file=sys.stderr); continue
        off, cnt = t
        for i in range(cnt):
            k = d[off + i * 32:off + i * 32 + 32].hex()
            if k not in seen: seen.add(k); out.append(k)
    return out


def scan(path, rel, want, hit, zstd, out):
    """流式扫一个文件，SHA-256 在 want 里的原样 / zstd 内嵌 NRO 当场写成 <输出目录>/.<哈希>（不攒在内存：大乱斗 764 个约 1.45 GB），
    hit[哈希] = 来源，并从 want 去掉"""
    with open(path, 'rb') as f:
        size = os.fstat(f.fileno()).st_size; base = 0

        def pread(n, off):   # 按偏移读（不用 os.pread：Windows 的 Python 没有它，11-06 Windows 出包机马力欧高尔夫改写阶段 AttributeError、整单红）
            f.seek(off); return f.read(n)

        def take(d, src):
            if len(d) < 0x80 or d[0x10:0x14] != NMAGIC: return
            k = hashlib.sha256(d).hexdigest()
            if k in want:
                want.discard(k); hit[k] = src
                with open(os.path.join(out, '.' + k), 'wb') as w: w.write(d)

        while base < size and want:
            buf = pread(CHUNK + ZHEAD, base)
            lim = min(CHUNK, len(buf))   # 本块只认起点在 [base, base+CHUNK) 的候选；重叠部分归下一块
            p = buf.find(NMAGIC, 0x10)
            while 0 <= p and p - 0x10 < lim and want:   # 原样 NRO：起点 = 魔数 - 0x10，头里大小 +0x18
                s = p - 0x10; n = struct.unpack_from('<I', buf, s + 0x18)[0] if s + 0x1c <= len(buf) else 0
                # 头里大小当真之前先核：≤ NMAX、三段首尾相接且合计 = 大小（归档里随机出现的 NRO0 四字节后面是任意数，
                #   11-03 大乱斗 data.arc 有头里大小 > 2 GB 的，直接 pread 那么长 macOS 回 EINVAL、整个改写阶段红）
                if 0x80 <= n <= min(NMAX, size - (base + s)) and seg_ok(buf, s, n): take(pread(n, base + s), f'{rel}@{base + s:#x}')
                p = buf.find(NMAGIC, p + 1)
            q = buf.find(ZMAGIC)
            while 0 <= q < lim and want:   # zstd 帧：先解前 0x20 字节认 NRO0，是才按头里大小整帧解
                try: h = zstd.decompress(buf[q:q + ZHEAD], max_length=0x20)
                except zstd.ZstdError: h = b''
                if len(h) == 0x20 and h[0x10:0x14] == NMAGIC:
                    n = struct.unpack_from('<I', h, 0x18)[0]
                    if not 0x80 <= n <= NMAX: q = buf.find(ZMAGIC, q + 1); continue
                    src = pread(n + (n >> 7) + ZHEAD, base + q)   # 压缩后不会超过原长 + 1/128 + 块头余量（zstd 最坏情况按原样块存）
                    try: d = zstd.decompress(src, max_length=n)
                    except zstd.ZstdError: d = b''
                    if len(d) == n: take(d, f'{rel}@{base + q:#x}:zstd')
                q = buf.find(ZMAGIC, q + 1)
            base += CHUNK


def main(argv):
    if len(argv) != 2: print('用法：nro_to_nso.py <romfs 目录> <输出目录>', file=sys.stderr); return 2
    romfs, out = argv
    found, rest = [], []
    for dp, dn, fn in romfs_list.walk(romfs):
        dn.sort()
        for f in fn:
            rel = os.path.relpath(os.path.join(dp, f), romfs)
            (found if f.lower().endswith('.nro') else rest).append(rel)
    found.sort(); rest.sort()
    try: reg = nrr_hashes(romfs)
    except OSError as e: print(f'【黄】.nrr 读不了（{e}），不按登记找藏起来的 NRO', file=sys.stderr); reg = []
    mods = {}   # SHA-256 → [模块名, 大小, bss, 来源…]
    for rel in found:
        d = open(os.path.join(romfs, rel), 'rb').read()
        try: segs, bss = parse(d, rel)
        except (ValueError, struct.error) as e: print(f'【黄】{e}：这一份不转，游戏装它时会失败；其余照转', file=sys.stderr); continue
        k = hashlib.sha256(d).hexdigest()
        if k in mods: mods[k][3].append(rel); continue
        name = f'nro{len(mods)}'
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, name), 'wb').write(to_nso(d, segs, bss))
        mods[k] = [name, len(d), bss, [rel]]
    want = {k for k in reg if k not in mods}; nreg = len(want); hit = {}
    if want:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../graphics/tools/shbake')); import zstd_lib   # 仓库唯一的 zstd 解码入口
        try: zstd_lib._lib()   # 找不到 libzstd 是环境问题：报红，不当「没找到」静默放过
        except zstd_lib.ZstdError as e: print(f'【红】{e}', file=sys.stderr); return 1
        os.makedirs(out, exist_ok=True)
        for rel in rest:
            if not want: break
            if rel.split(os.sep)[0] != '.nrr': scan(os.path.join(romfs, rel), rel, want, hit, zstd_lib, out)
        for k in reg:   # 按 NRR 登记顺序编号（与归档内摆放无关）
            if k not in hit: continue
            tmp = os.path.join(out, '.' + k); d = open(tmp, 'rb').read(); os.remove(tmp)
            try: segs, bss = parse(d, hit[k])
            except (ValueError, struct.error) as e: print(f'【黄】{e}：这一份不转，游戏装它时会失败；其余照转', file=sys.stderr); continue
            name = f'nro{len(mods)}'
            open(os.path.join(out, name), 'wb').write(to_nso(d, segs, bss))
            mods[k] = [name, len(d), bss, [hit[k]]]
        print(f'NRR 登记 {len(reg)} 个哈希：*.nro 命中 {len(reg) - nreg}，其余文件里找到 {len(hit)}（{sum(mods[k][1] for k in hit) / 1e6:.1f} MB），没找到 {len(want)}')
    if not mods: print('romfs 里没有 *.nro，不出表' if not reg else '没有 *.nro、也没找到 NRR 登记的 NRO，不出表'); return 0
    with open(os.path.join(out, 'nro_modules.tsv'), 'w') as f:
        f.write('# 模块名\tSHA-256\tNRO 大小\tbss 大小\tromfs 相对路径\n')
        for k, (name, size, bss, rels) in sorted(mods.items(), key=lambda kv: int(kv[1][0][3:])):
            f.write(f'{name}\t{k}\t{size:#x}\t{bss:#x}\t{"|".join(rels)}\n')
    print(f'NRO：{len(found)} 个文件，{len(mods)} 个不同内容 → {out}/nro_modules.tsv')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
