#!/usr/bin/env python3
# 通用着色器抽取：递归（Yaz0 / SARC / zstd，认不出的打包格式按 zlib 流）扫游戏资源目录与主程序模块，找标准容器 BNSH / 引擎归档 BAHS / 相邻的控制段+机器码，
# 沿 变体 → 二进制程序 → 各阶段代码记录 取出 Maxwell 机器码与控制段，按运行时键落盘。
# 运行时键（与 nvn_mtl.m prog_get 同口径）= sha256(控制段[0 : 控制段+0x20 处的长度] ‖ 机器码[0 : 控制段+0x704 处的长度]) 前 16 位十六进制。
#   （暗黑的控制段能唯一标识着色器；塞尔达 10918 份机器码只有 7163 种控制段，键必须把机器码算进去）
# 用法：nxsh_extract.py <输出目录> <资源目录…> [--nso <主程序 NSO>…]   环境 J=并发
# 输出：<输出目录>/src/<键>.code / .ctl，<输出目录>/index.tsv（键、阶段、来源、容器内变体号）
import bisect, sys, os, re, struct, zlib, hashlib, collections, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')))
import nxfmt
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，heads 给清单里的文件头，同一份 RomFS 只读一次）
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'nvn', 'tools'))); import romfs_list
_NXFMT_SRC = 'graphics/tools/nxfmt.py'  # 字面路径给 pack/stage_inputs.py 收进抽取 / 直连库的源码键
if os.path.basename(nxfmt.__file__) != os.path.basename(_NXFMT_SRC):
    raise ImportError(_NXFMT_SRC)
STAGES = ['vs', 'hs', 'ds', 'gs', 'ps', 'cs']
RAW = '--raw' in sys.argv   # 同文件内两两配对的裸扫描：噪声大（配出来的多数不成对），缺省关；扫不到的着色器靠运行时落盘（--miss）
if RAW: sys.argv.remove('--raw')
def trpfs_report(root, outdir, stat, rf=None):
    """Trinity 容器（arc/*.trpfs + *.trpfd）枚举：按包 / 条目列出并把压缩方式分开记。
    枚举不需要游戏解码器；Oodle 条目（压缩 = 3）要取内容才需要（游戏自带解码器，见 graphics/nvn/.../shader_split.oodle）。
    这里只做「能列出条目」这一步，并把读不到的条目数如实记进统计，不静默当作没抽到。"""
    import trpfs as T
    packs = 0; ents = 0; oodle = 0; stored = 0; shaderish = 0
    rep = os.path.join(outdir, 'trpfs.tsv')
    for rel in sorted(romfs_list.listdir(root)):
        p = os.path.join(root, rel)
        if not p.endswith('.trpfs') or not os.path.exists(p[:-1] + 'd'):
            continue
        # 读不了的容器（打不开 / FlatBuffers 偏移越界抛 struct.error）只记这一个红、接着列下一个，不打断整次抽取（审计 #846 F-trpfs-extract-abort：
        #   原先 open 失败时 finally 里 fsrc 未绑定 → UnboundLocalError，struct.error 也不在捕获列表里，两者都从这里冒出去、后面的 pak / 目录不再扫）
        try:
            with open(p, 'rb') as fsrc:
                for off, name, size, rows in T.walk(p, p[:-1] + 'd'):
                    packs += 1
                    for h, comp, ln, doff in rows:
                        if rf: rf.write(f'{name}\t{off:#x}\t{h:016x}\t{comp}\t{ln}\t{doff if doff is not None else -1}\n')
                        ents += 1
                        if comp == 3: oodle += 1
                        else:
                            stored += 1
                            if doff is not None and ln >= 4:
                                fsrc.seek(doff); head = fsrc.read(4)
                                if head in (b'BNSH', bytes.fromhex('34127698')): shaderish += 1
        except (ValueError, OSError, struct.error) as e:
            print(f'【红】trpfs：{rel} 读不了（{type(e).__name__}：{e}）', file=sys.stderr)
            stat['【红】trpfs 结构读不了'] = stat.get('【红】trpfs 结构读不了', 0) + 1
    if packs:
        stat['trpfs 包'] = stat.get('trpfs 包', 0) + packs
        stat['trpfs 条目'] = stat.get('trpfs 条目', 0) + ents
        stat['trpfs Oodle 条目（需游戏解码器）'] = stat.get('trpfs Oodle 条目（需游戏解码器）', 0) + oodle
        stat['trpfs 存储条目'] = stat.get('trpfs 存储条目', 0) + stored
        if shaderish: stat['trpfs 存储条目里像着色器的'] = stat.get('trpfs 存储条目里像着色器的', 0) + shaderish
        print(f'trpfs：{packs} 个包 / {ents} 个条目，Oodle {oodle}（要游戏解码器）、存储 {stored}（像着色器 {shaderish}）；清单 {rep}')
    return packs, ents, oodle, stored, shaderish


def key_of(ctl, code):
    cn = struct.unpack_from('<I', ctl, 0x20)[0]; dn = struct.unpack_from('<I', ctl, 0x704)[0]
    if ctl[:4] != bytes.fromhex('34127698') or cn != len(ctl) or dn != len(code): return None
    return hashlib.sha256(ctl + code).hexdigest()[:16]
def sph(code):
    """SPH（机器码 +0x30 起 0x50 字节，NVIDIA 公开布局）的通用属性接口位图 (读, 写)，逐分量一位；与 ShaderBake.cs Sph 同口径（程序表读取器按接口配阶段用：red_static_programs 曲面、ue_programs 全局几何）"""
    h = code[0x30:0x80]
    def bits(lo, n): return sum(1 << i for i in range(n) if (h[(lo + i) >> 3] >> ((lo + i) & 7)) & 1)
    if (h[0] & 0x1f) == 1: return bits(192, 128), bits(432, 128)
    im = 0
    for a in range(32):
        for c in range(4):
            b = 192 + a * 8 + c * 2
            if (h[b >> 3] >> (b & 7)) & 3: im |= 1 << (a * 4 + c)
    return im, 0
def bnsh_codes(b):
    if b[0x60:0x64] != b'grsc': return None
    nvar = struct.unpack_from('<I', b, 0x7c)[0]; va = struct.unpack_from('<Q', b, 0x80)[0]; out = []
    for v in range(nvar):
        binp = struct.unpack_from('<Q', b, va + v * 0x40 + 0x10)[0]
        if not binp: continue
        for si, p in enumerate(struct.unpack_from('<6Q', b, binp + 8)):
            if not p: continue
            pc, pd, dsz, csz = struct.unpack_from('<QQII', b, p + 8)
            if csz < 0x708 or pc + csz > len(b) or pd + dsz > len(b): raise ValueError('BNSH 着色器块越界或控制块过短')
            ctl = b[pc:pc + csz]
            cn = struct.unpack_from('<I', ctl, 0x20)[0]; dn = struct.unpack_from('<I', ctl, 0x704)[0]
            if ctl[:4] != bytes.fromhex('34127698') or not (0x708 <= cn <= csz) or dn != dsz: raise ValueError('BNSH 控制段与机器码长度不符')
            # 容器控制块可能比控制段自报长度多 12 字节（惊奇 1.2.1）；容器尾部不进入控制段或键，key_of 仍严格核长度。
            out.append((v, STAGES[si], b[pd:pd + dsz], ctl[:cn], pc))   # （机器码，控制段，控制段在容器内的偏移）
    return out
def scan_raw(path, data, rows, blobs, stat):
    """不在标准容器里的着色器（字体库自带的、SDK 模块内嵌的）：控制段以 34127698 开头并自带长度，机器码以 78563412 开头、长度记在控制段 +0x704。
    容器格式不认识就不猜对应关系：同一个文件里的控制段与机器码两两配对算键（数量小），运行时只会用到真正成对的那些键。"""
    ctls = [m.start() for m in re.finditer(bytes.fromhex('3412769801000000'), data)]
    codes = [m.start() for m in re.finditer(bytes.fromhex('78563412') + bytes(12), data)]
    if not ctls or not codes or len(ctls) * len(codes) > 4096: 
        if ctls and codes: stat['裸着色器文件配对过多，跳过'] += 1
        return
    for c in ctls:
        if c + 0x708 > len(data): continue
        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]
        if not (0x708 <= cn <= 0x10000) or c + cn > len(data) or not (0x80 <= dn <= (4 << 20)): continue
        ctl = data[c:c + cn]
        for d in codes:
            if d + dn > len(data): continue
            code = data[d:d + dn]; ty = struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf
            st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(ty)
            if not st: continue
            key = key_of(ctl, code)
            if not key: continue
            stat['裸配对'] += 1; rows.append((key, st, f'{path}@ctl{c:#x}+code{d:#x}', 0))
            if key not in blobs: blobs[key] = (code, ctl)
def scan_bahs(path, data, rows, blobs, stat):
    """引擎自带的着色器归档（魔数 BAHS，塞尔达 / 任天堂本家引擎的 .sharcb）：不是标准容器 BNSH。布局（10-14 对着塞尔达的文件定的）：
    头 +0x1c = 机器码区起点。记录区里每个着色器一条记录：[记录长 S][阶段 0/1][0][S−0x10] 之后在 x 处依次是
    [机器码在码区内的偏移][0][…][控制段相对 x 的偏移（有符号）]。控制段多数紧跟在自己的记录里（偏移 +0x60），
    也有许多记录用负偏移指回别的记录里的控制段——同一个控制段配多份机器码（头一版只认 +0x60 的，漏掉这类 66 个）。
    运行时才发现的「缺失着色器」里，塞尔达 170 个全部出自这种归档——离线认全它，第一次进游戏就不黑屏。
    阶段字段 0 / 1 / 2 是图形着色器（机器码带 78563412 头，阶段看头里的类型；2 = 几何，10-17 mk8d 1 支）；3 是计算着色器（机器码没有头，直接是指令；10-17 塞尔达 agl_technique_pfx 20 条记录、12 个控制段，
    此前只认 0 / 1，这 12 个控制段落到相邻扫描，被反向配上控制段前面的任意字节，成了翻不过的幽灵着色器）。
    返回本归档认领的控制段偏移集合：相邻扫描跳过它们。"""
    cs = struct.unpack_from('<I', data, 0x1c)[0]; MG = bytes.fromhex('78563412') + bytes(12); CM = bytes.fromhex('3412769801000000'); n = 0; owned = set()
    if not (0x40 <= cs <= len(data)): stat['BAHS 头不认识'] += 1; return owned
    W = struct.unpack_from('<%dI' % (cs // 4), data, 0)
    for q in range(4, len(W) - 4):
        S = W[q - 4]
        if W[q - 1] != S - 0x10 or W[q - 3] > 5 or W[q - 2] != 0 or not (0x40 <= S <= 0x20000): continue
        x = q * 4; off = W[q]; rel = W[q + 3]; rel = rel - (1 << 32) if rel & 0x80000000 else rel; c = x + rel; comp = data[cs + off:cs + off + 16] != MG   # 无头 = 计算着色器（阶段字段 3）；有头按头里的类型（阶段字段 0 / 1 / 2 = 顶点 / 像素 / 几何，mk8d gsys common 有 1 支几何）
        if not (0 <= c and c + 0x708 <= cs) or data[c:c + 8] != CM or (comp and W[q - 3] != 3): continue
        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]; code = data[cs + off:cs + off + dn]
        if not (0x708 <= cn <= 0x10000) or len(code) != dn: stat['BAHS 记录对不上'] += 1; continue
        ctl = data[c:c + cn]; st = 'cs' if comp else {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf); key = key_of(ctl, code)
        if not st or not key: stat['BAHS 记录对不上'] += 1; continue
        rows.append((key, st, f'{path}@bahs{x:#x}', 0)); n += 1; owned.add(c)
        if key not in blobs: blobs[key] = (code, ctl)
    stat['BAHS 归档'] += 1; stat['BAHS 着色器'] += n
    return owned
def scan_offhdr(path, data, rows, blobs, stat):
    """NVN SDK 自带的着色器文件（nn::font / PrimitiveRenderer 的 *_nvn_shader.bin，动森 System/Font 与 System/PrimitiveRenderer 下）：
    文件头 = n 个控制段偏移 + n 个机器码偏移（u32），第一个控制段紧跟文件头。控制段与机器码不相邻，相邻扫描认不出（10-17 动森 3 个文件：
    顶点那对整个漏掉，像素那对被反向配成幽灵）。按头里的偏移逐对核魔数与长度，全对上才认；返回认领的控制段偏移。"""
    owned = set()
    if len(data) < 0x20 or data[:4] == b'BAHS': return owned
    h0 = struct.unpack_from('<I', data, 0)[0]
    if h0 % 8 or not (8 <= h0 <= 0x80) or h0 + 0x708 > len(data) or data[h0:h0 + 8] != bytes.fromhex('3412769801000000'): return owned
    n = h0 // 8; W = struct.unpack_from('<%dI' % (2 * n), data, 0); got = []
    for i in range(n):
        c, d = W[i], W[n + i]
        if c + 0x708 > len(data) or data[c:c + 8] != bytes.fromhex('3412769801000000') or data[d:d + 16] != bytes.fromhex('78563412') + bytes(12): return owned
        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]
        st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', data, d + 0x30)[0] >> 10 & 0xf)
        key = key_of(data[c:c + cn], data[d:d + dn]) if c + cn <= len(data) and d + dn <= len(data) else None
        if not st or not key: return owned
        got.append((key, st, c, data[d:d + dn], data[c:c + cn]))
    for key, st, c, code, ctl in got:
        rows.append((key, st, f'{path}@hdr{c:#x}', 0)); owned.add(c)
        if key not in blobs: blobs[key] = (code, ctl)
    stat['偏移头着色器文件'] += 1; stat['偏移头着色器'] += len(got)
    return owned
def scan_sdf(path, data, rows, blobs, stat):
    """RE 引擎着色器定义文件（魔数 SDF\\0，怪猎崛起 pak 里 620 个：每个母材质 / 系统效果一份）自带程序表（10-21 对着怪猎的文件定的布局）：
    头 = 魔数 + u16 版本 + u16 记录数 n + u64 字符串区终点；+0x10 起 n 条记录，每条 0x108 字节：+0 名字（文件内偏移，如 ShadowStatic / GUIPoly2D），
    +8 输入布局表，+0x10 起 6 个 u64 = vs / hs / ds / gs / ps / cs 各阶段着色器块的文件内偏移（0 = 没有这个阶段），其余是资源绑定表。
    着色器块 = [控制段长 u32][机器码长 u32][控制段][机器码]；多条记录可指同一块（ShadowStatic 与 TSShadowStatic 共用顶点）。
    一条记录 = 引擎能建的一个程序：来源记成 <文件>#sdf|<记录名>、变体号 = 记录号，shbake 的「# 变体组」规则按它配程序（与 BNSH 变体同一条规则）。
    全部记录都配：按材质标志收窄 A（透明测试）/ TS（双面）变体试过、被证伪——10-21 端到端局里标志全 0 的 NPC 皮肤材质照样用了 ADepthWrite / AZPrePass 等 A 变体（运行时淡出类效果），收窄后 4 个程序现翻。
    依据：两局怪猎带存档 Mac 局 Ryujinx 缓存里运行时现翻的 54 个图形程序（10-21，pair）全部是某条记录的阶段组合。
    返回认领的控制段偏移（相邻扫描跳过）；头或任一记录对不上就整个文件不认（返回空集，退回相邻扫描），不猜。"""
    owned = set()
    if len(data) < 0x10: return owned
    _, n = struct.unpack_from('<HH', data, 4)
    if 0x10 + n * 0x108 > len(data): stat['SDF 头不认识'] += 1; return owned
    got = []
    for r in range(n):
        b = 0x10 + r * 0x108; sl = struct.unpack_from('<6Q', data, b + 0x10); st = []; no = struct.unpack_from('<Q', data, b)[0]
        nm = data[no:data.find(b'\0', no, no + 256)].decode('latin-1') if 0 < no < len(data) else ''
        if not re.fullmatch(r'[\x21-\x7e]{1,255}', nm): stat['SDF 记录对不上'] += 1; return set()
        for si, o in enumerate(sl):
            if not o: continue
            if o + 8 > len(data): stat['SDF 记录对不上'] += 1; return set()
            cn, dn = struct.unpack_from('<II', data, o); c = o + 8; ctl = data[c:c + cn]; code = data[c + cn:c + cn + dn]; key = key_of(ctl, code)
            want = STAGES[si]; hdr = code[:16] == bytes.fromhex('78563412') + bytes(12)
            got_st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf) if hdr and len(code) >= 0x34 else ('cs' if not hdr else None)
            if not key or got_st != want: stat['SDF 记录对不上'] += 1; return set()
            st.append((key, want, c, code, ctl))
        got.append((nm, st))
    for r, (nm, st) in enumerate(got):
        for key, want, c, code, ctl in st:
            rows.append((key, want, f'{path}#sdf|{nm}', r)); owned.add(c)
            if key not in blobs: blobs[key] = (code, ctl)
    stat['SDF 文件'] += 1; stat['SDF 记录'] += sum(1 for _, st in got if st)
    return owned
def scan_spch(path, data, rows, blobs, stat):
    """Monolith 着色器容器 SPCH（异度神剑 3 的 .wishp / .wismt / .wipac 等，xbc1 里 zlib / zstd 压缩，解压后文件内可嵌多个；11-07 对着 bf3.ard 定的布局）：
    控制段集中放在控制段区、机器码集中放在代码区，几支控制段共用一份机器码，相邻扫描配不上（11-07 异度 3 读档首遇现编 32 支里 27 支即此）。
    头（u32，相对 SPCH 起点）：+0x08 SLCT 表偏移、+0x0c 条数（每条 8 字节，首字 = SLCT 相对 +0x18 SLCT 区起点的偏移，可为 0）；+0x20 代码区偏移、+0x24 长；+0x28 控制段区偏移、+0x2c 长。
    SLCT（魔数 SLCT）：+0x10 程序数、+0x1c 程序表偏移（相对 SLCT，每条 [机器码偏移, 控制段偏移]，相对本 SLCT 的两块起点）；+0x28 控制段块相对控制段区偏移、+0x2c 长、+0x30 代码块相对代码区偏移、+0x34 长。
    一个程序 = 从它的控制段偏移到下一程序（末个到块尾）的连续若干支控制段（vs、ps…），机器码从它的代码偏移起按各支控制段 +0x704 的长度依次排。
    来源记 <文件>#spch<偏移>.<SLCT 号>、变体号 = 程序号，走 shbake「# 变体组」规则配 vs + ps。任一支魔数 / 长度 / 键对不上整个 SPCH 不认、计红，退回相邻扫描，不猜。
    返回认领的控制段偏移（相邻扫描跳过）。"""
    owned = set()
    for m in re.finditer(b'HCPS', data):
        s = m.start(); got = []
        try:
            _, _, to, tn, _, _, sb, _, xo, xl, co, cl = struct.unpack_from('<12I', data, s)
            if not (0 < tn < 0x10000) or s + co + cl > len(data) or s + xo + xl > len(data): stat['SPCH 头对不上（不认）'] += 1; continue
            for t in range(tn):
                a = s + sb + struct.unpack_from('<I', data, s + to + 8 * t)[0]
                if data[a:a + 4] != b'SLCT': raise ValueError('SLCT 魔数')
                S = struct.unpack_from('<14I', data, a); pn, pt = S[4], S[7]; cr, cs, dr, ds = S[10:14]
                if cr + cs > cl or dr + ds > xl: raise ValueError('SLCT 块越界')
                ent = [struct.unpack_from('<II', data, a + pt + 8 * i) for i in range(pn)]
                for i, (dof, cof) in enumerate(ent):
                    c, ce, d = s + co + cr + cof, s + co + cr + (ent[i + 1][1] if i + 1 < pn else cs), s + xo + dr + dof
                    while c < ce:
                        if data[c:c + 8] != bytes.fromhex('3412769801000000'): raise ValueError('控制段魔数')
                        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]
                        ctl, code = data[c:c + cn], data[d:d + dn]; key = key_of(ctl, code)
                        if not key or d + dn > s + xo + dr + ds: raise ValueError('长度')
                        hdr = code[:4] == bytes.fromhex('78563412')
                        st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf) if hdr else 'cs'
                        if not st: raise ValueError('阶段')
                        got.append((key, st, f'{path}#spch{s:#x}.{t}', i, c, code, ctl)); c += cn; d += dn
        except (ValueError, struct.error):
            stat['【红】SPCH 结构对不上（不认，退回相邻扫描）'] += 1; continue
        for key, st, src, i, c, code, ctl in got:
            rows.append((key, st, src, i)); owned.add(c)
            if key not in blobs: blobs[key] = (code, ctl)
        stat['SPCH'] += 1; stat['SPCH 阶段记录'] += len(got)
    return owned
_NOP, _BRA, _EXIT = 0x50b0000000070f00, (0xe2400fffff87000f, 0xe2400fffff07000f), 0xe30000000007000f
def code_ok(code, ctl):
    """候选机器码像不像这个控制段的指令区：控制段 +0x700 记着指令区终点（其后是常量段 c1）；指令区去掉末尾的 0 之后最后一个字是 NOP 或跳回自身，且区内有 EXIT。
    四款已知真着色器 37661 支全部满足（10-17 核过）；把相邻的字符串表 / 别的着色器尾巴当机器码配出来的幽灵过不了"""
    import struct as _s
    c1o = _s.unpack_from('<I', ctl, 0x700)[0]
    if not (16 <= c1o <= len(code)) or c1o % 8: return False
    W = list(_s.unpack_from('<%dQ' % (c1o // 8), code, 0))
    while W and W[-1] == 0: W.pop()
    return bool(W) and (W[-1] == _NOP or W[-1] in _BRA) and _EXIT in W
def rec_hdr(data, c, cn, dn):
    """控制段前紧贴的 32 字节记录头（11-02 World War Z initial.pak 的 *.sdc 解压后，每支一条）：4 个 u64，相对记录起点 r0 = c − 0x20：
    [控制段偏移 = 0x20][控制块长 ≥ 控制段自报长][机器码长 = 控制段 +0x704][机器码偏移 ≥ 0x20 + 控制块长]。控制块比控制段多 0x18 字节的那些（WWZ 7 支里 5 支），
    机器码不紧跟控制段，正向带头认不出、无头分支把错位 0x18 的字节当机器码、再被线程组 0 丢掉，整支漏抽（运行时首遇的曲面域着色器 de3bc41685e5f143 即此）。
    四个字段全对上、且机器码带头（图形 78563412 / 计算 79563412）或像这个控制段的指令区（code_ok）才认，返回机器码在 data 里的起点，否则 None。
    计算着色器的机器码可以没有头（11-03 WWZ common_nx64_compute 等 .sdc：直接是指令字 f00720e2…）：只认带头时控制块多 0x18 的无头计算着色器整支漏抽
    （运行时首遇 5 支 cs 即此；控制块 = 控制段的那些靠后面的正向无头分支收到，与本函数无关）"""
    if c < 0x20: return None
    o, cb, n, co = struct.unpack_from('<4Q', data, c - 0x20)
    if o != 0x20 or not (cn <= cb <= cn + 0x100) or n != dn or co < 0x20 + cb or co > 0x20 + cb + 0x100: return None
    r = c - 0x20 + co
    if r + dn > len(data): return None
    return r if data[r:r + 4] in (bytes.fromhex('78563412'), bytes.fromhex('79563412')) or code_ok(data[r:r + dn], data[c:c + cn]) else None
def scan_adj(path, data, rows, blobs, stat, tag='adj', owned=frozenset()):
    """控制段与自己的机器码紧挨着：正向（暗黑三：控制段后紧跟 78563412 开头的机器码）或反向（暗黑2 SHAD 包：机器码紧贴在控制段之前）。
    控制段自带长度（+0x20）与机器码长度（+0x704），只认长度恰好接上的一对，不两两乱配。
    owned = 已被容器（BNSH / BAHS）按结构认领的控制段偏移：跳过。反向分支不核机器码头（暗黑2 计算着色器没有头），容器里的控制段前面是别的数据，
    会被硬配成幽灵着色器——10-17 塞尔达 16453 个相邻项里 16440 个是这样来的（控制段与容器里的真着色器逐字节相同、机器码对不上），翻译失败 15902 个、侥幸翻过 538 个进了库。"""
    n = 0; pend = []; used = set(); HDR = bytes.fromhex('78563412') + bytes(12)
    def put(c, ctl, code, how):
        nonlocal n
        st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf, 'cs') if code[:4] == bytes.fromhex('78563412') else 'cs'; key = key_of(ctl, code)
        # 没有代码头（图形 78563412 / 计算 79563412）就只能是计算着色器，而计算着色器的控制段一定记着线程组（+0x748 三维 u32，每维 ≥ 1）：带 0 的是接错位的幽灵
        #   （10-27 密特罗德 生存恐惧 MSHD：控制段后跟编译选项表，正向无头分支把选项表当机器码，515 支全是 (0,0,0)、控制段与正规顶点 / 片元逐字节相同，
        #   翻译时撞片元指令崩 486 支；另一款 010074F013262000 的 65 支机器码全 0 或是另一段控制段。14 款真无头计算着色器线程组全 ≥ 1）
        if code[:4] not in (bytes.fromhex('78563412'), bytes.fromhex('79563412')) and 0 in struct.unpack_from('<3I', ctl, 0x748):
            stat['无头且线程组为 0（不是计算着色器，丢弃）'] += 1; return
        if not key: return
        rows.append((key, st, f'{path}@{tag}{how}{c:#x}', 0)); n += 1
        if key not in blobs: blobs[key] = (code, ctl)
    # 「机器码在前」背靠背排的（11-02 Unravel Two 的 PhyreEngine 集群：机器码 1、控制段 1、机器码 2、控制段 2…）：控制段后面带头的是下一支的机器码，按正向带头会切给上一支，
    #   出幽灵键、丢真着色器；「控制段在前」的（暗黑三 / 怪猎崛起）两支长度相同时前面也恰好是一段像样的机器码。两头都像的分不出，按这段字节里只有一头像的控制段多数定方向：
    #   反向（前面紧贴一段带头、像指令的机器码）多才对两头都像的取前面那段，正向多或一样多照旧取后面
    def rev_ok(c, cn, dn): return 0 < dn <= c and data[c - dn:c - dn + 4] in (HDR[:4], bytes.fromhex('79563412')) and code_ok(data[c - dn:c], data[c:c + cn])
    vote = 0
    for m in re.finditer(bytes.fromhex('3412769801000000'), data):
        c = m.start()
        if c in owned or c + 0x708 > len(data): continue
        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]
        if not (0x708 <= cn <= 0x100000) or c + cn > len(data): continue
        f = data[c + cn:c + cn + 16] == HDR and c + cn + dn <= len(data) and code_ok(data[c + cn:c + cn + dn], data[c:c + cn]); r = rev_ok(c, cn, dn)
        vote += (r and not f) - (f and not r)
    rev_first = vote > 0
    for m in re.finditer(bytes.fromhex('3412769801000000'), data):
        c = m.start()
        if c in owned or c + 0x708 > len(data): continue
        cn, dn = struct.unpack_from('<I', data, c + 0x20)[0], struct.unpack_from('<I', data, c + 0x704)[0]
        # 控制段长上限 1 MB（原 64 KB）：常量区大的控制段超过 64 KB（10-23 八方2 全局着色器缓存片元 69448 字节），原先直接跳过、整支漏抽；
        #   放宽不放松认定：后面仍要正向带头 / 两段长度前缀 / code_ok 之一成立才收
        if not (0x708 <= cn <= 0x100000) or c + cn > len(data): continue
        ctl = data[c:c + cn]
        fwd = data[c + cn:c + cn + 16] == HDR and c + cn + dn <= len(data)
        if fwd and rev_first and rev_ok(c, cn, dn): fwd = False   # 这段字节是「机器码在前」背靠背排的：两头都像时取前面那段（见 rev_first）
        if fwd: code = data[c + cn:c + cn + dn]; used.add(c + cn)   # 正向带头（暗黑三 / 怪猎崛起 SDF 的图形着色器）
        elif (r := rec_hdr(data, c, cn, dn)) is not None: code = data[r:r + dn]; used.add(r)   # 控制段前紧贴 32 字节记录头、头里写着机器码偏移（World War Z .sdc）
        elif 8 + dn <= c and struct.unpack_from('<I', data, c - 4)[0] == cn and struct.unpack_from('<I', data, c - 8 - dn)[0] == dn and code_ok(data[c - 4 - dn:c - 4], ctl):
            code = data[c - 4 - dn:c - 4]   # 两段都带 u32 长度前缀、机器码在前：[机器码长][机器码][控制段长][控制段]（UE4 Switch 着色器条目，八方旅人2，见 scan_ue）
        elif 0 < dn <= c and code_ok(data[c - dn:c], ctl): code = data[c - dn:c]   # 反向：机器码紧贴在控制段之前（暗黑2 SHAD 包）
        elif c + cn + dn <= len(data) and code_ok(data[c + cn:c + cn + dn], ctl): code = data[c + cn:c + cn + dn]   # 正向无头：计算着色器紧跟控制段（怪猎崛起 SDF）
        else: pend.append((c, ctl, dn)); continue
        put(c, ctl, code, '')
    # 控制段与机器码分表存放（异度之刃3 模型里的着色器表：一组控制段挨着放、机器码按同样顺序挨着放在后面，靠偏移表互指）：挨着找不到的控制段
    #   按出现顺序与没被认领的机器码头标记（78563412 + 12 个 0）依次配，要长度装得下且 code_ok；配不上的才算丢弃。不解析各家的偏移表
    if pend:
        hs = [h.start() for h in re.finditer(re.escape(HDR), data) if h.start() not in used]; j = 0; nt = 0
        for c, ctl, dn in pend:
            for k in range(j, len(hs)):
                h = hs[k]; nxt = hs[k + 1] if k + 1 < len(hs) else len(data)   # 机器码按表挨着放：配上的段不能越过下一个未认领的头（越过一定是配错，着色器线审）
                if h + dn <= nxt and code_ok(data[h:h + dn], ctl): put(c, ctl, data[h:h + dn], 'tbl'); j = k + 1; nt += 1; break
            else: stat['相邻但机器码不像指令（丢弃）'] += 1
        if nt: stat['分表配对'] += nt
    stat['相邻控制段+机器码'] += n
    return n
def scan_ue(path, data, rows, blobs, stat):
    """UE4 着色器条目（FShaderMapResourceCode 的每支代码）：[int32 存储长 n][n 字节][int32 原长 u][uint8 阶段 0..5]，n < u 时那 n 字节是 LZ4 块。
    原文以 LSLGS + P / C / V 开头（八方旅人2 全局着色器缓存 1594 条全是），压缩后这串字面量落在条目起点 +5 或 +6（LZ4 首个记号 1–2 字节之后），
    以它为锚只在附近试解，不在整个文件上逐字节试。认定 = 长度 / 原长 / 阶段字节自洽 + LZ4 恰好解出 u 字节且以 LSLGS 开头；解出的条目再按相邻对扫（长度前缀分支）"""
    import lz4.block
    n_ok = 0; p = data.find(b'LSLGS'); L = len(data)
    while p >= 0:
        for i in (p - 4, p - 5, p - 6, p - 7):
            if i < 0: continue
            n = struct.unpack_from('<i', data, i)[0]
            if not (16 <= n < (16 << 20)) or i + 9 + n > L: continue
            u = struct.unpack_from('<i', data, i + 4 + n)[0]
            if data[i + 8 + n] > 5 or not (n <= u < (64 << 20)): continue
            if n == u: b = bytes(data[i + 4:i + 4 + n])   # 压不小时原样存
            else:
                try: b = lz4.block.decompress(bytes(data[i + 4:i + 4 + n]), uncompressed_size=u)
                except Exception: continue
            if len(b) != u or b[:5] != b'LSLGS': continue
            n_ok += 1; scan_adj(path, b, rows, blobs, stat, f'ue{i:#x}+'); p = i + 9 + n - 1; break
        p = data.find(b'LSLGS', p + 1)
    if n_ok: stat['UE4 着色器条目'] += n_ok
def scan_ue_archive(path, data, rows, blobs, stat, oodle=None):
    """UE ShaderCodeArchive: version 2 (bounded arrays, then per-stage compressed records, the stage in each entry) or the unversioned older layout (Bloodstained: Ritual of the Night,
    unreal_pak.legacy_layout: the stage only in the record's own LSLG tag); records are LZ4 / zlib / Oodle via the game's own decoder.

    PAK decryption alone is insufficient: shared .ushaderbytecode archives
    store compressed records behind an entry table, unlike inline UE assets.
    Both layouts are read by the same code as pack/ue_pak.py (unreal_pak.legacy_layout / unpack_shader).
    """
    import unreal_pak
    off = 0
    def take(size):
        nonlocal off
        if size < 0 or off + size > len(data): raise ValueError('着色器存档截断或越界')
        value = data[off:off + size]; off += size; return value
    def count(): return struct.unpack('<I', take(4))[0]
    def array(size):
        n = count(); return take(n * size)
    old = unreal_pak.legacy_layout(bytes(data))
    if old:   # 无版本号旧布局（11-02 普查血污「着色器存档版本不支持」）：阶段在记录自己的 LSLG 标签里
        base, ents = old; recs = [(base + o, st, raw, None) for o, st, raw in ents]
    elif (v1 := unreal_pak.v1_layout(bytes(data))):   # 版本 1（11-02 普查 Minecraft Dungeons）：阶段在条目里
        base, ents = v1; recs = [(base + o, st, raw, fr) for o, st, raw, fr in ents]
    else:
        if count() != 2: raise ValueError('着色器存档版本不支持')
        for size in (20, 20, 16): array(size)
        entries = array(17)
        for size in (16, 4): array(size)
        recs = [(off + pos, stored, raw, freq) for pos, stored, raw, freq in struct.iter_unpack('<QIIB', entries)]
    for i, (at, stored, raw, freq) in enumerate(recs):
        if not 0 < raw <= 64 << 20 or not 0 < stored <= raw or at + stored > len(data):
            raise ValueError('着色器存档代码范围无效')
        record = data[at:at + stored]
        if stored != raw:   # 与出包抽取 pack/ue_pak.py 同一份解压（unreal_pak.unpack_shader）：Oodle 支交游戏自带解码器（霍格沃茨之遗，11-02）
            try: record = unreal_pak.unpack_shader(bytes(record), raw, oodle)
            except Exception as e: raise ValueError(f'着色器存档记录解不开：{e}') from None   # 含没有宿主（pkz_oodle 抛 RuntimeError）
        if freq is None: freq = unreal_pak.LSLG_FREQ.get(bytes(record[4:6])) if record[:4] == b'LSLG' else None
        want = {0:'SV', 1:'SH', 2:'SD', 3:'SP', 4:'SG', 5:'SC'}.get(freq)
        if len(record) != raw or want is None or record[:6] != b'LSLG' + want.encode():
            raise ValueError('着色器存档记录长度或阶段不符')
        rr, bb = [], {}; st = {0:'vs', 1:'hs', 2:'ds', 3:'ps', 4:'gs', 5:'cs'}[freq]
        scan_adj(path, record, rr, bb, stat, f'uearc{i:x}+')
        if len(rr) != 1 or rr[0][1] != st:   # 相邻扫描配不出唯一一对（11-02 血污：无头计算着色器、机器码在控制段前的片元）：按 LSLG 记录自己的结构取（与直连抽取同一份 uepak.lslg）
            got = _uepak().lslg(bytes(record)); key = got and key_of(got[1], got[2])
            if not key or got[0] != want: raise ValueError('着色器存档控制段与代码不能唯一配对')
            if st == 'cs' and got[2][:4] != bytes.fromhex('79563412') and 0 in struct.unpack_from('<3I', got[1], 0x748): raise ValueError('着色器存档里的计算着色器没有线程组')
            rr, bb = [(key, st, f'{path}@uearc{i:x}+lslg', 0)], {key: (got[2], got[1])}; stat['UE 存档条目按 LSLG 结构取'] += 1
        rows.extend(rr); blobs.update(bb); stat['UE 存档条目'] += 1
    stat['UE 着色器存档'] += 1
def _zlib_try(mv, i, lim, zdict=None, want=None):
    """从 i 起解一条 zlib 流。返回 (输出, 用掉的输入字节, 结局)：结局 'ok' 完整解完；'far' 流里回指了窗口之前的数据
    （invalid distance too far back：要接前一块的输出）；None 其他失败（假起点）。
    zdict 给了 = 续解：跳过 2 字节头按裸 deflate、以 zdict 作历史窗口，输入截到 lim。续解成立的判据（不能只看解出了东西，压坏的块也能解出垃圾）：
      want 给了（块头声明的原长）→ 输入恰好截到块尾、输出长度在 [want, want + max(256, want / 1024)]、截回 want（块尾填充多解出的几十字节不要）；没给 → 必须正常结束且紧跟的 4 字节等于输出的 adler32（标准 zlib 尾）。
    渐进喂（每次 256 KB、合计至多 16 MB）：原先一次给 16 MB，流解完后剩下的十几 MB 输入每次都被拷进 unused_data（暗黑三 46.8 万个流，抽取时间大半花在这份拷贝上）"""
    o = zlib.decompressobj() if zdict is None else zlib.decompressobj(-15, zdict=zdict)
    s0 = i if zdict is None else i + 2; fed = 0; parts = []; lim = min(16 << 20, lim - s0)
    try:
        while fed < lim and not o.eof: c = mv[s0 + fed:s0 + min(fed + (256 << 10), lim)]; parts.append(o.decompress(c)); fed += len(c)
        if zdict is not None and not o.eof: parts.append(o.flush())   # 分块同步刷新的块没有结束标记：把已解出的都取出来
    except zlib.error as e:
        return b'', 0, 'far' if 'too far back' in str(e) else None
    out = b''.join(parts); used = (s0 - i) + fed - len(o.unused_data)
    if not out: return b'', 0, None
    if zdict is None: return (out, used, 'ok') if o.eof else (b'', 0, None)
    if want is not None: return (out[:want], used, 'ok') if want <= len(out) <= want + max(256, want >> 10) else (b'', 0, None)   # 块尾的同步刷新 / 填充会多解出几十字节（暗黑3 实测 +13 / +93）：截回块头声明的原长；超出 max(256 字节, 原长 / 1024)（暗黑3 一块 16 KB 解出 2 MB、多 817）或不够长按坏块
    tail = bytes(mv[i + used:i + used + 4])
    return (out, used + 4, 'ok') if o.eof and tail == zlib.adler32(out).to_bytes(4, 'big') else (b'', 0, None)
def _chain_hdr(data, i):
    """78 xx 前紧挨的块头「u32 原长 + u16 压缩长（含 2 字节 zlib 头）」（暗黑3 Patch*.cpk 的分块格式）：说得通就返回 (原长, 块尾)，否则 None"""
    if i < 6: return None
    us = int.from_bytes(data[i - 6:i - 2], 'little'); cs = int.from_bytes(data[i - 2:i], 'little')
    return (us, i + cs) if 2 < cs and i + cs <= len(data) and 0 < us <= (16 << 20) else None
def scan_zlib(path, data, rows, blobs, stat, lo=0, hi=None, warm=0):
    """不认识的打包格式（暗黑三的 .cpk）：把文件里所有能解开的 zlib 流（78 01 / 78 9c / 78 da 开头）解开再扫。
    包内文件按块分别压缩，一个着色器可能跨块：每段解压结果前面拼上一段（按文件里的先后）的尾巴再扫，跨块的那对也能接上。
    分块共享窗口的连续 deflate（10-23 暗黑3 Patch2_6_5.cpk：块头 u32 原长 + u16 压缩长 + 78 da，后块回指前块输出）：单独解报
    「invalid distance too far back」的块，用文件里前一个解开的块的输出作历史窗口按裸 deflate 续解，输入截到下一个能独立解开的流起点。
    续解不了的（前面没有可接的块 / 续解再失败）是漏抽：计「【红】zlib 块续解失败」，shader_pack 按红中止（原先静默跳过，暗黑3 漏一支顶点着色器、真机首遇现编）。
    lo / hi：只认起点落在 [lo, hi) 的流（大文件按字节段并行，见 work_zlib）；warm：从 lo 往前多解这么多字节只为接上尾巴、不记结果。
    分段与整扫等价的依据：解开成功要过 zlib 头校验 + 整段 deflate + adler32，落在别的流中间的假起点几乎不可能解成功，所以各段找到的流就是整扫找到的那些。"""
    nz = 0; n = 0; nc = 0; mv = memoryview(data); hi = len(data) if hi is None else hi
    # 1) 各种头的起点按文件顺序逐个试解：成功的记下（起点、终点、输出）；回指过远的记下待续解
    got = []; far = []
    cand = sorted(set(m.start() for hdr in (b'\x78\xda', b'\x78\x9c', b'\x78\x01') for m in re.finditer(re.escape(hdr), data[max(0, lo - warm):hi + 1])))
    base = max(0, lo - warm); skip_to = -1
    for c in cand:
        i = base + c
        if i < skip_to: continue
        out, used, res = _zlib_try(mv, i, len(data))
        if res == 'ok': got.append((i, i + used, out)); skip_to = i + max(2, used)
        elif res == 'far' or (res is None and _chain_hdr(data, i)): far.append(i)   # 带块头却解不开的也进块链续解（块链上解不开 = 漏抽，要报红）
    # 2) 回指过远的块（按文件顺序，续解成功的立刻接进块链，连续几块依次接上）：
    #    落在已解开块中间的是假起点（压缩数据 / 贴图里碰巧出现 78 da）；离前一块终点 > CHAIN_GAP 字节（块头只有几个字节）的不在块链上，也按假起点计、不报红；
    #    在块链上（紧跟前一块）却续解不了的才是漏抽：计红
    CHAIN_GAP = 32
    starts = [g[0] for g in got]
    for i in far:
        k = bisect.bisect_right(starts, i) - 1
        prev = got[k] if k >= 0 else None
        if prev and prev[1] > i: continue   # 落在已解开块里
        if not prev or i - prev[1] > CHAIN_GAP: stat['回指过远的假起点（不在块链上）'] += 1; continue
        # 块头本身被认成流起点（暗黑3：原长 376 = 0x178 → 块头 78 01 00 00 …，真块在其后 6 字节）：其后紧跟 zlib 头且块头说得通的，按假起点计
        #   但它自己带说得通的块头、恰好紧跟前块 6 字节的，是真块（暗黑3 过场 cpk：块载荷以 78 01 开头，后面又碰巧跟着 …78 da）
        own = _chain_hdr(data, i)
        if not (own and i - prev[1] == 6) and data[i + 6:i + 7] == b'\x78' and _chain_hdr(data, i + 6): stat['回指过远的假起点（块头里的 78 xx）'] += 1; continue
        lim = starts[k + 1] if k + 1 < len(starts) else len(data)
        # 历史窗口 32 KB：前一块输出不够长时，沿块链往回接前几块的输出凑满
        win = prev[2]; kk = k
        while len(win) < 32768 and kk > 0 and got[kk][0] - got[kk - 1][1] <= CHAIN_GAP: kk -= 1; win = got[kk][2] + win
        win = win[-32768:]
        h = _chain_hdr(data, i)
        if h and h[1] <= lim: out, used, res = _zlib_try(mv, i, h[1], zdict=win, want=h[0])
        else: out, used, res = _zlib_try(mv, i, lim, zdict=win)
        if res == 'ok' and out:
            got.insert(k + 1, (i, i + used, out)); starts.insert(k + 1, i); nc += 1
        elif i >= lo and not (own and (ph := _chain_hdr(data, prev[0])) and ph[1] == i - 6):
            # 在块链上的证据要够硬才报红：块链格式（暗黑3 cpk）每块前有 6 字节块头，且前一块块头声明的压缩长恰好止于本块块头（前块终点 = 本块起点 − 6）。
            #   只看「紧跟前块 + 本处前 6 字节说得通」不够：「原长 ≤ 16 MB、压缩长 > 2」几乎任何字节都满足。
            #   10-23 异度神剑 3 bf3.ard 24 处全是假的：xbc1 容器头里的大小 / 哈希字段、zstd 条目数据里碰巧出现 78 9c / 78 01，离前块 5–30 字节——按假起点计、不报红
            stat['回指过远的假起点（紧跟前块但不在块链上）'] += 1
        elif i >= lo:
            stat['【红】zlib 块续解失败'] += 1
            if stat['【红】zlib 块续解失败'] <= 5: print(f'【红】zlib 块续解失败：{path}@{i:#x}（紧跟前块 {i - prev[1]} 字节，接前块窗口续解仍失败）', file=sys.stderr, flush=True)
    got.sort(key=lambda g: g[0])
    # 3) 按文件顺序扫，前一块的尾巴拼在前面（跨块着色器）
    tail = b''
    for i, e, out in got:
        _cover(path, i, e)   # 往前多解的那段（起点在上一段）也算已解开：它跨进本段的部分不报
        if i >= lo:
            nz += 1; buf = tail + out
            # 解出的是容器（xbc1 zlib 条目里的 SPCH，11-07 异度 3）：先按结构认领，相邻扫描跳过（偏移换算到拼了尾巴的 buf）
            own = {len(tail) + c for c in scan_spch(f'{path}@z{i:#x}', out, rows, blobs, stat)} if b'HCPS' in out else frozenset()
            if b'\x34\x12\x76\x98' in buf: n += scan_adj(path, buf, rows, blobs, stat, f'z{i:#x}+', owned=own)
        tail = out[-0x12000:]
    if nz: stat['zlib 流'] += nz
    if nc: stat['zlib 块续解（接前块窗口）'] += nc
    if n: stat['zlib 里的着色器'] += n
# 解不开数据块报告（第 3 项诊断，缺省关）：NXSH_UNDECODED=<目录> 时，叶子 / 顶层文件扫完后按 64 KiB 窗口算字节熵，
#   扣掉本进程里解开过的压缩流区间（zlib / zstd 帧 / CRILAYLA，见 _cover）和已知媒体格式（贴图 / 音频 / 视频 / 图片，按叶子开头魔数），
#   熵 > 7.5 bit/字节的连续窗口合成一段，写 <目录>/<pid>.tsv：路径 起点 长度 平均熵 段首 16 字节 叶子魔数。只报不改抽取结果
UND = os.environ.get('NXSH_UNDECODED'); _COVER = collections.defaultdict(list)
MEDIA = (b'BNTX', b'FWAV', b'BWAV', b'BARS', b'FSTM', b'FSTP', b'OggS', b'RIFF', b'\x89PNG', b'\xff\xd8\xff', b'CRID', b'AFS2', b'@UTF', b'BKHD', b'FSB5', b'KB2', b'BIK', b'FFNT', b'BFTTF', b'\x1aE\xdf\xa3',
         b'AKPK', b'TEX\0', b'\x57\xe0\xe0\x57', b'DDS ')   # 10-22 加：Wwise 音频包 AKPK、RE 引擎贴图 TEX、Havok 数据包、DDS 贴图（着色器线定）
# CPK 里的音视频条目（目录里的扩展名，或条目开头是 MEDIA / HCA（含高位掩码的 C8 C3 C1）/ ADX（80 00））：按 CPK 目录（cri_cpk.py）扣掉，不报
CPK_MEDIA_EXT = ('.usm', '.sfd', '.acb', '.awb', '.hca', '.adx', '.bik', '.wav', '.ogg', '.at9')
def _cpk_media(data):
    import cri_cpk
    for name, a, n in cri_cpk.entries(data):
        h = bytes(data[a:a + 4])
        if name.lower().endswith(CPK_MEDIA_EXT) or h in MEDIA or bytes(x & 0x7F for x in h[:3]) == b'HCA' or h[:2] == b'\x80\0': yield a, a + n
def _cover(path, a, b):
    if UND: _COVER[path].append((a, b))
def undecoded(path, data, lo=0, hi=None):
    if not UND: return
    import numpy as np
    hi = len(data) if hi is None else hi; W = 1 << 16
    if hi - lo < W: return
    head = bytes(data[:4])
    if head in MEDIA or bytes(data[4:8]) == b'ftyp': return
    cov = sorted(list(_COVER.get(path, ())) + (list(_cpk_media(data)) if head == b'CPK ' else []))
    def covered(a, b): return sum(max(0, min(b, y) - max(a, x)) for x, y in cov) * 4 >= (b - a) * 3   # 窗口四分之三以上落在解开过的流里（流起点前的容器头不算缺口）
    runs = []; cur = None
    for a in range(lo, hi - W + 1, W):
        if covered(a, a + W): ent = 0.0
        else:
            h = np.bincount(np.frombuffer(data, dtype=np.uint8, count=W, offset=a), minlength=256).astype(np.float64) / W
            nz = h[h > 0]; ent = float(-(nz * np.log2(nz)).sum())
        if ent > 7.5:
            if cur and cur[1] == a: cur[1] = a + W; cur[2] += ent
            else: cur = [a, a + W, ent]; runs.append(cur)
    if not runs: return
    os.makedirs(UND, exist_ok=True)
    with open(os.path.join(UND, f'{os.getpid()}.tsv'), 'a') as f:
        for a, b, e in runs: f.write(f'{path}\t{a}\t{b - a}\t{e / ((b - a) // W):.3f}\t{bytes(data[a:a + 16]).hex()}\t{head.hex()}\n')
SHAD_MSB = os.environ.get('S2A_SHAD_MSB') == '1'   # SHAD 排列号解码的进位顺序：缺省第一个宏为最低位（用参照缓存的配对覆盖率定，见 设计.md「程序配对来源」）
def shad_table(data):
    """暴雪 SHAD 着色器包（暗黑2 data/hd/shaders/<阶段>_<主干>_<后缀>.bin）的排列表：TXT[ 字符串表（头：魔数×2、个数 n、0、0x1c、字符串区相对起点、总长、n 个偏移）
    + SYM[ 排列宏表（每项 'SYM '、名字号、取值个数 nv、4、0x1c、0x1c、项长、nv 个取值字符串号——取值从项起 +28）。排列数 = 各宏取值数之积，排列号 i 按混合进制解出各宏取值；
    包里代码记录按偏移排序的第 i 个 = 排列 i（10-20：126 个文件排列数与代码头个数全部相等）。返回 [(宏名, [取值串…])…]，不是 SHAD 返回 None"""
    if data[:8] != b'SHADSHAD' or data[0x1c:0x24] != b'TXT[TXT[': return None
    o = 0x1c; n = struct.unpack_from('<I', data, o + 8)[0]
    offs = struct.unpack_from(f'<{n}I', data, o + 28); sb = o + struct.unpack_from('<I', data, o + 20)[0]
    strs = [data[sb + x: data.index(b'\0', sb + x)].decode('latin-1') for x in offs]
    p = data.index(b'SYM[SYM[', sb); m = struct.unpack_from('<I', data, p + 8)[0]; out = []; q = p
    for _ in range(m):
        q = data.index(b'SYM ', q + 4); name, nv = struct.unpack_from('<2I', data, q + 4)
        out.append((strs[name], [strs[v] for v in struct.unpack_from(f'<{nv}I', data, q + 28)]))
    return out
def shad_tag(table, i):
    order = table[::-1] if SHAD_MSB else table; d = {}
    for name, vals in order: nv = max(1, len(vals)); d[name] = vals[i % nv] if vals else ''; i //= nv
    return ','.join(f'{k}={d[k]}' for k, _ in table)
def scan_blob(path, data, rows, blobs, stat):
    try: shad = shad_table(data)
    except Exception: shad = None; stat['SHAD 排列表解析失败'] += 1
    n0 = len(rows)
    _scan_blob(path, data, rows, blobs, stat)
    if shad is None: return
    perm = 1
    for _, vals in shad: perm *= max(1, len(vals))
    new = sorted(range(n0, len(rows)), key=lambda j: int(rows[j][2].rsplit('@adj', 1)[1], 16) if '@adj' in rows[j][2] else -1)
    if len(new) != perm or any('@adj' not in rows[j][2] for j in new): stat['SHAD 排列数与代码记录数不符（不配对）'] += 1; return
    for i, j in enumerate(new):   # 来源改成 <文件>@shad<排列号>|宏=值,…（shbake 按主干配 vs / ps：共有宏取值一致即成程序）
        key, st, src, v = rows[j]; rows[j] = (key, st, f"{src.rsplit('@adj', 1)[0]}@shad{i}|{shad_tag(shad, i)}", i)
    stat['SHAD 包'] += 1
def _scan_blob(path, data, rows, blobs, stat):
    owned = set()   # 容器按结构认领的控制段（文件内偏移）：先解容器，相邻扫描最后跑、跳过它们
    if data[:4] == b'BAHS' and len(data) > 0x20: owned |= scan_bahs(path, data, rows, blobs, stat)
    if data[:4] == b'SDF\0': owned |= scan_sdf(path, data, rows, blobs, stat)
    owned |= scan_offhdr(path, data, rows, blobs, stat)
    # SPCH 不先判 `b'HCPS' in data`：大文件按 mmap 传进来（work 的 big_split），mmap 不支持子串 in（逐个取单字节和整串比），永远判不中，
    #   4.7 GB 的 0100F43008C44000 arc/data.trpfs 上还白走 30 秒；scan_spch 自己就按魔数 finditer，没有就是一遍扫描。RAW 的判断同理改 find
    owned |= scan_spch(path, data, rows, blobs, stat)
    if RAW and (data.find(b'BNSH\0\0\0\0') < 0 or path.startswith('nso:')): scan_raw(path, data, rows, blobs, stat)
    for k, m in enumerate(re.finditer(b'BNSH\0\0\0\0', data)):
        # 按头里的长度只切这一支（#711：原先先切到文件尾再截短，几 GB 的容器 mmap 每遇一处 BNSH 就拷一份到文件尾，Windows 提交上限下 MemoryError）
        o = m.start(); size = struct.unpack_from('<I', data, o + 0x1c)[0]; b = data[o:o + size] if 0 < size <= len(data) - o else data[o:]
        try: codes = bnsh_codes(b)
        except Exception: stat['BNSH 解析失败'] += 1; continue
        if codes is None: stat['BNSH 无 grsc'] += 1; continue
        stat['BNSH'] += 1
        for v, st, code, ctl, co in codes:
            owned.add(m.start() + co); key = key_of(ctl, code)
            if not key: stat['控制段与机器码长度对不上'] += 1; continue
            rows.append((key, st, f'{path}#{k}', v))
            if key not in blobs: blobs[key] = (code, ctl)
    scan_adj(path, data, rows, blobs, stat, owned=owned)
# zstd（.zs：动物森友会的界面包 / 模型包 / 字体包全是它）：直接用本机 libzstd，不引第三方 Python 包
_zstd = None
def _zstd_lib():
    global _zstd
    import ctypes
    if _zstd is None:
        # 打包版 App 的 libzstd 在 Runtime/lib（/opt/homebrew 只有出包机才有）：先按解释器位置找同级的 lib，再退系统路径。
        # 少了这一步，玩家机器上没装 Homebrew 就一律「找不到 libzstd」（10-27 Mac 启动器全量预编断在这里）
        cands = [os.environ.get('NXSH_ZSTD_LIB', '')]
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import zstd_lib
        cands += zstd_lib.lib_candidates()   # 仓库唯一的找法（含 Windows 官方发行包布局 dll\libzstd.dll）；下面是 App Runtime / 系统路径的退路
        py = os.path.dirname(os.path.abspath(sys.executable))
        for lib in (os.path.join(py, '..', 'lib'), os.path.join(py, '..', '..', 'lib'), os.path.join(py, '..', '..', '..', 'lib')):
            if os.path.isdir(lib):
                cands += [os.path.join(lib, n) for n in sorted(os.listdir(lib)) if n.startswith(('libzstd.dylib', 'libzstd.1.', 'libzstd.so'))]
        cands += ['/opt/homebrew/lib/libzstd.dylib', '/usr/local/lib/libzstd.dylib', 'libzstd.dylib', 'libzstd.so.1']
        for cand in cands:
            if not cand: continue
            try: _zstd = ctypes.CDLL(cand); break
            except OSError: pass
        if _zstd is None: raise RuntimeError('找不到 libzstd')
        _zstd.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong; _zstd.ZSTD_getFrameContentSize.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        _zstd.ZSTD_decompress.restype = ctypes.c_size_t; _zstd.ZSTD_decompress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        _zstd.ZSTD_isError.restype = ctypes.c_uint; _zstd.ZSTD_isError.argtypes = [ctypes.c_size_t]
        _zstd.ZSTD_findFrameCompressedSize.restype = ctypes.c_size_t; _zstd.ZSTD_findFrameCompressedSize.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        _zstd.ZSTD_getDictID_fromFrame.restype = ctypes.c_uint; _zstd.ZSTD_getDictID_fromFrame.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        _zstd.ZSTD_getDictID_fromDict.restype = ctypes.c_uint; _zstd.ZSTD_getDictID_fromDict.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        _zstd.ZSTD_createDCtx.restype = ctypes.c_void_p
        _zstd.ZSTD_decompress_usingDict.restype = ctypes.c_size_t
        _zstd.ZSTD_decompress_usingDict.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        global _ZBuf
        class _ZBuf(ctypes.Structure): _fields_ = [('p', ctypes.c_void_p), ('size', ctypes.c_size_t), ('pos', ctypes.c_size_t)]   # ZSTD_inBuffer / ZSTD_outBuffer
        _zstd.ZSTD_createDStream.restype = ctypes.c_void_p; _zstd.ZSTD_freeDStream.argtypes = [ctypes.c_void_p]; _zstd.ZSTD_initDStream.argtypes = [ctypes.c_void_p]
        _zstd.ZSTD_decompressStream.restype = ctypes.c_size_t; _zstd.ZSTD_decompressStream.argtypes = [ctypes.c_void_p, ctypes.POINTER(_ZBuf), ctypes.POINTER(_ZBuf)]
    return _zstd
ZSTD_BLOCK_IN = (128 << 10) + 3 + 18   # 解出帧的头几个字节最多要读到的压缩字节：帧头 ≤ 18 + 首块（块头 3 + 块内容 ≤ 128 KB）
def zstd_head(b, n=4):   # 不带字典号的 zstd 帧（b 为文件开头，至少 ZSTD_BLOCK_IN 字节或整个文件）只解出前 n 字节；解不开返回已解出的部分
    import ctypes
    z = _zstd_lib(); ds = z.ZSTD_createDStream(); z.ZSTD_initDStream(ds)
    try:
        src, dst = ctypes.create_string_buffer(b, len(b)), ctypes.create_string_buffer(n)
        i, o = _ZBuf(ctypes.cast(src, ctypes.c_void_p), len(b), 0), _ZBuf(ctypes.cast(dst, ctypes.c_void_p), n, 0)
        while o.pos < n and i.pos < i.size:
            r = z.ZSTD_decompressStream(ds, ctypes.byref(o), ctypes.byref(i))
            if z.ZSTD_isError(r) or r == 0: break
        return dst.raw[:o.pos]
    finally: z.ZSTD_freeDStream(ds)
# zstd 字典（王国之泪 romfs/Pack/ZsDic.pack.zs 里 3 本：帧头写字典号，不给字典解不开）：扫描前 find_zsdicts 从资源里收齐、写进目录，
#   经环境变量 NXSH_ZSDICT 交给各工作进程（spawn 起的进程不继承全局变量）；帧头字典号非 0 就按号取字典解
_zd = None; _zdctx = None
def _zdicts():
    global _zd
    if _zd is None:
        _zd = {}; d = os.environ.get('NXSH_ZSDICT')
        if d and os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith('.zsdict'): _zd[int(f[:-7])] = open(os.path.join(d, f), 'rb').read()
    return _zd
def _zdecompress(buf, n, src, slen):   # 按帧头字典号选字典；没字典号走普通解压；要的字典没收到返回错误码
    import ctypes
    global _zdctx
    z = _zstd_lib(); did = z.ZSTD_getDictID_fromFrame(src, slen)
    if not did: return z.ZSTD_decompress(buf, n, src, slen)
    d = _zdicts().get(did)
    if d is None: return ctypes.c_size_t(-1).value
    if _zdctx is None: _zdctx = z.ZSTD_createDCtx()
    return z.ZSTD_decompress_usingDict(_zdctx, buf, n, src, slen, d, len(d))
ZDICT_MAGIC = b'\x37\xa4\x30\xec'
def find_zsdicts(roots, outd):   # 资源里所有 zstd 字典：文件本身是字典，或小于 8 MB 的 SARC（可先普通 zstd 解开）里有字典成员
    z = _zstd_lib(); n = 0; os.makedirs(outd, exist_ok=True)
    # 逐个文件的打开 / 读放线程池并发（10-31 出包线：塞尔达 4 万多个文件串行探头 16 秒，抽取总墙钟 52 秒里 18 路工作进程全在干等；
    #   打开与读文件时线程放开 GIL，并发后受盘与内核限，不受解释器限）
    trees = [romfs_list.scan(root) for root in roots]
    paths = [os.path.join(dp, f) for t in trees for dp, dn, fn in t.walk() for f in fn]
    PJ = int(os.environ.get('NXSH_IO_J', '32'))
    def head(h):
        h = h[:18]
        return h[:4] == b'\x28\xb5\x2f\xfd' and bool(z.ZSTD_getDictID_fromFrame(h, len(h)))
    # 按需：先只看每个文件开头 18 字节探有没有带字典号的 zstd 帧；没有就不收（动森这类不用字典的款不必把小文件整读一遍；着色器线审，抽取墙钟增量 ≤ 10%）
    # 文件头取 RomFS 清单（romfs_list.heads：前 32 字节，同一份 RomFS 各阶段只读一次；打不开的文件同原先算「没有」）
    hd = {e.path: e.head for t in trees for e in romfs_list.heads(t.top, tree=t).files() if e.error is None and e.head is not None}
    if not os.listdir(outd) and not any(head(h) for h in hd.values()): return 0
    # 只把开头可能带字典的文件交给 dicts：字典本身、SARC、不带字典号的 zstd 帧（解开后可能是 SARC）；别的文件 dicts 整读完也只会返回空（#639：
    #   用到字典的款原先把每个 ≤ 8 MB 的文件都整读一遍）。头表里没有的（读头失败）照原样交给 dicts
    def maybe(p):
        h = hd.get(p)
        return h is None or h[:4] in (ZDICT_MAGIC, b'SARC') or (h[:4] == b'\x28\xb5\x2f\xfd' and not head(h))
    paths = [p for p in paths if maybe(p)]
    def dicts(p):   # → 这个文件里的字典（文件本身，或 SARC 成员）
        try:
            if os.path.getsize(p) > 8 << 20: return []
            with open(p, 'rb') as f:
                b = f.read(ZSTD_BLOCK_IN)
                # 不带字典号的 zstd 帧先只解开头 4 字节：不是 SARC 就不会有字典成员，不必整读整解（#639：0400486024DEC000 这类有 5.9 万个，解出来是 SARC 的只有 1 个）
                if b[:4] == b'\x28\xb5\x2f\xfd' and not z.ZSTD_getDictID_fromFrame(b, len(b)) and zstd_head(b) != b'SARC': return []
                b += f.read()
            if b[:4] == ZDICT_MAGIC: return [b]
            if b[:4] == b'\x28\xb5\x2f\xfd' and not z.ZSTD_getDictID_fromFrame(b, len(b)):
                try: b = zstd_dec(b)
                except Exception: return []
            if b[:4] == b'SARC': return [bytes(m.data) for m in nxfmt.Sarc(b).get_files() if bytes(m.data[:4]) == ZDICT_MAGIC]
        except Exception: pass
        return []
    def take(ds):   # 结果按文件顺序取、写字典在本线程：同一字典号先到先留，同串行版
        nonlocal n
        for d in ds:
            did = z.ZSTD_getDictID_fromDict(d, len(d))
            if did and not os.path.exists(os.path.join(outd, f'{did}.zsdict')): open(os.path.join(outd, f'{did}.zsdict'), 'wb').write(d); n += 1
    # 有界提交：同时在排队的任务不超过 4 × 读线程数（ex.map 一开始就把全部文件提交成任务，文件数到几十万时排队本身就占内存，#639）
    with cf.ThreadPoolExecutor(PJ) as ex:
        pend = collections.deque()
        for p in paths:
            pend.append(ex.submit(dicts, p))
            if len(pend) >= 4 * PJ: take(pend.popleft().result())
        while pend: take(pend.popleft().result())
    return n
def zstd_dec(data):
    import ctypes
    _zstd_lib(); n = _zstd.ZSTD_getFrameContentSize(data, len(data))
    if n >= 1 << 62 or n > 1 << 31: raise ValueError('zstd 帧没写解压后长度或过大')
    buf = ctypes.create_string_buffer(n); r = _zdecompress(buf, n, data, len(data))
    if _zstd.ZSTD_isError(r) or r != n: raise ValueError('zstd 解压失败')
    return buf.raw
def zstd_frame(data, i):   # data[i:] 起一个 zstd 帧：返回 (解压内容, 压缩长度)；帧头没写原长、过大、解不开都返回 None
    import ctypes
    z = _zstd_lib()
    for w in (1 << 20, 64 << 20):   # 先取 1 MB 窗口找帧尾，帧更长才取 64 MB（Trine 5 主程序 4795 个小帧，每个都复制 64 MB 要几百 GB 内存拷贝）；窗口盖住整帧时两者结果相同
        b = bytes(data[i:i + w]); cs = z.ZSTD_findFrameCompressedSize(b, len(b))
        if not z.ZSTD_isError(cs) or i + w >= len(data): break
    n = z.ZSTD_getFrameContentSize(b, len(b))
    if z.ZSTD_isError(cs) or n == (1 << 64) - 2 or (n < 1 << 62 and n > 256 << 20): return None
    if n == (1 << 64) - 1:   # 帧头没写原长（大乱斗 data.arc：原长记在归档自己的表里）：容量从小往大试，解到帧尾为止
        for cap in (1 << 20, 16 << 20, 256 << 20):
            buf = ctypes.create_string_buffer(cap); r = _zdecompress(buf, cap, b, cs)
            if not z.ZSTD_isError(r): return buf.raw[:r], cs
        return None
    buf = ctypes.create_string_buffer(n); r = _zdecompress(buf, n, b, cs)
    if z.ZSTD_isError(r) or r != n: return None
    return buf.raw, cs
def scan_zstd_frames(path, data, rows, blobs, stat, lo=0, hi=None):
    """顶层打包文件里逐条 zstd 压缩的条目（怪猎崛起 RE 引擎 re_chunk_*.pak：着色器在 SDF 文件里，7 万多个 zstd 帧，10-17 前一个都没抽到）：
    找起点在 [lo, hi) 的帧魔数，按帧头解开，每段照普通文件再走一遍 visit（里面还可能是 SARC / Yaz0）。解不开的跳过（魔数也可能出现在别的压缩数据里）
    10-21 起 RE 引擎 pak 由 re_pak 按条目表读（只取补丁链上的最新版，见 work_kpka），这里只剩认不出容器的打包文件。"""
    hi = len(data) if hi is None else hi; i = lo; n = 0
    while True:
        i = data.find(b'\x28\xb5\x2f\xfd', i, hi)
        if i < 0: break
        try: fr = zstd_frame(data, i)
        except Exception: fr = None
        if not fr: i += 4; continue
        out, cs = fr; n += 1; _cover(path, i, i + cs)
        if b'\x34\x12\x76\x98' in out or out[:4] in (b'SARC', b'Yaz0', b'BAHS'): visit(f'{path}@zs{i:#x}', out, rows, blobs, stat, 1, zl=False)
        i += cs
    if n: stat['内嵌 zstd 帧'] += n
def scan_nso_zstd(path, img, rows, blobs, stat):   # 主程序镜像里内嵌字典的 zstd 着色器帧（Trine 5）：字典与帧结构见 nso_zstd.py
    import nso_zstd
    zd = nso_zstd.dicts(img, lambda d: _zstd_lib().ZSTD_getDictID_fromDict(d, len(d)))
    if not zd: return
    _zdicts().update(zd); stat['主程序内嵌 zstd 字典'] += len(zd); i = img.find(b'\x28\xb5\x2f\xfd')
    while i >= 0:
        try: fr = zstd_frame(img, i)
        except Exception: fr = None
        sh = fr and nso_zstd.frame_shader(fr[0], code_ok); key = sh and sh != 'bad' and key_of(sh[1], sh[2])
        if key: rows.append((key, sh[0], f'{path}@zs{i:#x}', 0)); blobs.setdefault(key, (sh[2], sh[1])); stat['主程序 zstd 着色器帧'] += 1
        elif sh: stat['主程序 zstd 着色器帧对不上（丢弃）'] += 1
        i = img.find(b'\x28\xb5\x2f\xfd', i + (fr[1] if fr else 4))
# CRI CRILAYLA（CPK 里逐文件压缩；P5R 等 CRI 中间件游戏）：同目录 crilayla.c（按公开算法写），首次用时按源码内容哈希编成 <仓库>/build/shbake/libcrilayla_<哈希>.dylib
#   （NXSH_CRILAYLA 可直接给 .dylib 路径；不进仓库）。按魔数找起点，
#   头 +8 原长、+12 未压缩头偏移 → 压缩段总长 = 0x10 + 偏移 + 0x100；解开的照普通文件再走一遍 visit
_cri = None
def cri_lib_name():   # 按源码摘要命名：现编缓存与预编件同名
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'crilayla.c')
    return f"libcrilayla_{hashlib.sha256(open(src, 'rb').read()).hexdigest()[:12]}.dylib"
def cri_prebuilt():
    """启动器随发版预编的一份（S2A_PREBUILT_TOOLS/codecs/libcrilayla_<摘要>，launchers/windows/bundle_prepare_win.py）：同名在就用，不现编。
    玩家的 Windows 机器没有 clang：现编报 WinError 2，CRI 压缩的游戏（#95 女神异闻录4）抽取整单红"""
    tools = os.environ.get('S2A_PREBUILT_TOOLS')
    lib = os.path.join(tools, 'codecs', cri_lib_name()) if tools else None
    return lib if lib and os.path.isfile(lib) else None
def cri_compile():
    here = os.path.dirname(os.path.abspath(__file__)); src = os.path.join(here, 'crilayla.c')
    bd = os.path.join(here, '..', '..', '..', 'build', 'shbake'); os.makedirs(bd, exist_ok=True)
    lib = os.path.join(bd, cri_lib_name())
    if not os.path.exists(lib):
        import subprocess
        tmp = f'{lib}.{os.getpid()}.tmp'; subprocess.run(['clang', '-O2', '-shared', '-o', tmp, src], check=True)
        # 几个抽取进程同时首次编：库名按源码哈希定、内容相同，谁先换上都一样。Windows 上目标已被别的进程加载时 os.replace 报拒绝访问
        #   （11-06 Windows 出包机女神异闻录5：WinError 5，整单抽取红）：目标已在就用它、删自己的临时文件
        try: os.replace(tmp, lib)
        except OSError:
            if not os.path.exists(lib): raise
            try: os.remove(tmp)
            except OSError: pass
    return lib
def _cri_lib():
    import ctypes
    global _cri
    if _cri is None:
        lib = os.environ.get('NXSH_CRILAYLA') or cri_prebuilt() or cri_compile()
        _cri = ctypes.CDLL(lib)
        _cri.crilayla_dec.restype = ctypes.c_long; _cri.crilayla_dec.argtypes = [ctypes.c_char_p, ctypes.c_long, ctypes.c_char_p, ctypes.c_long]
    return _cri
def scan_crilayla(path, data, rows, blobs, stat, lo=0, hi=None):
    import ctypes
    hi = len(data) if hi is None else hi; i = lo; n = 0
    while True:
        i = data.find(b'CRILAYLA', i, hi)
        if i < 0: break
        us, ho = struct.unpack_from('<II', data, i + 8); tot = 0x10 + ho + 0x100
        if us > 512 << 20 or i + tot > len(data): stat['CRILAYLA 头不对'] += 1; i += 8; continue
        cap = 0x100 + us; out = ctypes.create_string_buffer(cap); r = _cri_lib().crilayla_dec(bytes(data[i:i + tot]), tot, out, cap)
        if r < 0: stat['CRILAYLA 失败'] += 1; i += 8; continue
        n += 1; _cover(path, i, i + tot); visit(f'{path}@cri{i:#x}', out.raw[:r], rows, blobs, stat, 1, zl=False); i += tot
    if n: stat['CRILAYLA'] += n
def scan_streams(path, data, rows, blobs, stat, lo=0, hi=None):
    """认不出容器的顶层文件里按魔数找内嵌的 gzip / xz / LZ4 帧（nxdecomp.STREAMS）：解开的照普通文件再走一遍 visit；解不开的跳过（魔数也可能出现在别的压缩数据里）"""
    import nxdecomp
    hi = len(data) if hi is None else hi
    for mg, name, dec in nxdecomp.STREAMS:
        i = lo; n = 0
        while True:
            i = data.find(mg, i, hi)
            if i < 0: break
            r = dec(data, i)
            if not r: i += len(mg); continue
            out, cs = r; n += 1; _cover(path, i, i + cs); visit(f'{path}@{name}{i:#x}', out, rows, blobs, stat, 1, zl=False); i += max(cs, len(mg))
        if n: stat[f'内嵌 {name}'] += n
def pkz_zstd(data, size):
    """PKZ 索引自带原长；帧可以不写长度，但解码容量只能取索引值。"""
    import ctypes
    z = _zstd_lib(); buf = ctypes.create_string_buffer(size)
    n = _zdecompress(buf, size, data, len(data))
    if z.ZSTD_isError(n) or n != size: raise ValueError('解压长度或 Zstandard 帧无效')
    return buf.raw

_OODLE = None
_UEPAK = None
def _uepak():   # translator/uepak.py（直连抽取那一侧的 Unreal 读法：LSLG 记录结构 uepak.lslg、宿主工具模式 Oodle）：按路径载入一次
    global _UEPAK
    if _UEPAK is None:
        import importlib.util
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'translator', 'uepak.py')
        spec = importlib.util.spec_from_file_location('uepak', p); _UEPAK = importlib.util.module_from_spec(spec); spec.loader.exec_module(_UEPAK)
    return _UEPAK

def pkz_oodle(data, size):
    """PKZ 的 Oodle* 成员：游戏自带 OodleLZ_Decompress，跑在 Mac 宿主的工具模式里（runtime/src/oodle_tool.c，DM_OODLE_SERVE），每个工作进程一个宿主。
    宿主与模块目录按 DM_OODLE_HOST / DM_OODLE_MODULES（主进程在 __main__ 里按资源目录补过缺省）；没有就抛错说明原因，pkz.read 转成 FormatError 判红"""
    global _OODLE
    if _OODLE is None:
        U = _uepak(); found, why = U.oodle_host_find()
        if not found: raise RuntimeError(why)
        _OODLE = U.OodleHost(*found)
    return _OODLE(data, size)

def _vendor(data):   # 厂商自家归档（11-02 着色器容器族 A 组）：各模块 recognize 认头、members 交出成员（加密 / 不支持返回 None）；big_split 也按它不分段
    import telltale, volition_vpp, idtech_idcl
    for m in (telltale, volition_vpp, idtech_idcl):
        if m.recognize(data): return m
def vendor_arc(path, data, rows, blobs, stat, depth, in_pkz):
    """认出厂商归档 → 逐成员再走 visit，返回 True（不再盲扫）；不认识返回 False。目录 / 解压不自洽计红行到标准错误、不退回盲扫（盲扫本来就配不出）"""
    m = _vendor(data)
    if not m or depth >= 6: return False
    name = m.__name__
    try:
        ms = m.members(data, oodle=pkz_oodle)   # 要 Oodle 的（id Tech 7）用游戏自带解码器，同 PKZ / UE pak
        if ms is None: stat[f'{name} 加密 / 不支持的变体（未解）'] += 1; return True
        stat[name] += 1
        for nm, b in ms: stat[f'{name} 成员'] += 1; visit(f'{path}//{nm}' if nm else f'{path}@{name}', b, rows, blobs, stat, depth + 1, in_pkz=in_pkz)
    except (ValueError, struct.error, zlib.error, RuntimeError) as e:   # RuntimeError：没有 Oodle 宿主（pkz_oodle）
        stat[f'{name} 读不了'] += 1; print(f'{name}：{path} 读不了（{e}）', file=sys.stderr, flush=True)
    return True
def visit(path, data, rows, blobs, stat, depth=0, zl=True, in_pkz=False):
    import pkz
    magic = bytes(data[:4])
    dat_members = None
    if magic == b'DAT\0' and not in_pkz:
        # 普通文件 / SARC 成员可能碰巧以 DAT 开头；只有完整索引合法才认作此容器。
        try: dat_members = pkz.dat_entries(data)
        except pkz.FormatError: magic = b''
    if magic in (b'pkzl', b'DAT\0') or (in_pkz and magic in pkz.STAGES):
        try:
            if depth >= 6: raise pkz.FormatError('PKZ / DAT 嵌套超过 6 层')
            if magic == b'pkzl':
                entries = pkz.entries(data, oodle=True); stat['PKZ'] += 1   # Oodle* 成员放行到 read()：有宿主就解，没有在那里报原因
                for i, member in enumerate(entries):
                    payload = pkz.read(data, member, pkz_zstd, pkz_oodle); stat['PKZ 成员'] += 1
                    if pkz.is_oodle(member.compression): stat['PKZ Oodle 成员（游戏解码器解出）'] += 1
                    visit(f'{path}//{member.name}@pkz{i}', payload, rows, blobs, stat, depth + 1, in_pkz=True)
            elif magic == b'DAT\0':
                entries = pkz.dat_entries(data) if dat_members is None else dat_members; stat['DAT'] += 1
                for i, name, offset, size in entries:
                    stat['DAT 成员'] += 1
                    if not size: stat['DAT 空成员'] += 1; continue
                    visit(f'{path}//{name}@dat{i}', data[offset:offset + size], rows, blobs, stat, depth + 1, in_pkz=True)
            else:
                stage, ctl, code = pkz.shader(data); key = key_of(ctl, code)
                if key is None: raise pkz.FormatError('着色器运行时键无效')
                rows.append((key, stage, path, 0)); blobs.setdefault(key, (code, ctl)); stat['PKZ/DAT 着色器'] += 1
        except pkz.FormatError as e:
            stat['【红】PKZ/DAT 解析失败'] += 1
            print(f'【红】PKZ/DAT 抽取：{path}：{e}', file=sys.stderr, flush=True)
        return   # 已识别容器不再盲扫压缩流 / 相邻对，避免重复与伪配对
    if vendor_arc(path, data, rows, blobs, stat, depth, in_pkz): return
    whole = False   # 整文件是一个 zstd / Yaz0（解开的是游戏自己的格式，不是认不出的打包文件）：不再盲搜内嵌 gzip / xz / LZ4（见下）
    if data[:4] == b'\x28\xb5\x2f\xfd':
        whole = True
        try: data = zstd_dec(data); stat['zstd'] += 1
        except Exception: stat['zstd 失败'] += 1; return
    if data[:4] == b'Yaz0':
        whole = True
        try: data = nxfmt.yaz0_decompress(data)
        except Exception: stat['Yaz0 失败'] += 1; return
    if depth < 6:   # 通用解压表：叶子开头就是 gzip / xz / LZMA / LZ4 帧 / Yay0 / LZ10 / LZ11 → 解开递归（见 nxdecomp.py）
        import nxdecomp
        r = nxdecomp.head(data)
        if r: stat[r[0]] += 1; visit(f'{path}@{r[0]}', r[1], rows, blobs, stat, depth + 1, zl, in_pkz=in_pkz); return
    if data[:4] == b'SARC' and depth < 6:
        try: arc = nxfmt.Sarc(data)
        except Exception: stat['SARC 失败'] += 1; return
        for f in arc.get_files(): visit(path + '//' + f.name, bytes(f.data), rows, blobs, stat, depth + 1, in_pkz=in_pkz)
        return
    stat['叶子文件'] += 1; scan_blob(path, data, rows, blobs, stat)
    if b'LSLGS' in data: scan_ue(path, data, rows, blobs, stat)
    # 内嵌压缩流只在没被整文件解开的顶层文件里搜：gzip / xz / LZ4（10-22 量：15 款 0 命中；塞尔达 4 万个整文件 Yaz0 里盲搜 10.5 GB、CPU +20%），
    #   zlib 流 / zstd 帧 / CRILAYLA 同样（#744：0400486024DEC000 的 10 万个整文件 zstd 里搜出 5 万多个内嵌帧、38 万个假起点，键 0 个；不搜后抽取 CPU −25%、结果一致）
    if zl and depth == 0 and not whole and b'BNSH\0\0\0\0' not in data and data[:4] != b'BAHS': scan_zlib(path, data, rows, blobs, stat); scan_zstd_frames(path, data, rows, blobs, stat); scan_crilayla(path, data, rows, blobs, stat); scan_streams(path, data, rows, blobs, stat)   # 认不出容器的顶层文件再按 zlib 流扫一遍（大文件这一遍在 work_zlib 里分段并行）
    undecoded(path, data); _COVER.pop(path, None)
def flush(blobs, outdir):   # 着色器字节追加进本进程的 src/p<进程号>.pk（srcpack.py 头注：逐支两个小文件九成时间耗在元数据上）
    import srcpack
    w = srcpack.writer(outdir)
    for key, (code, ctl) in blobs.items(): w.put(key, code, ctl)
    w.flush()
WWISE_AUDIT = os.environ.get('NXSH_WWISE_AUDIT') == '1'   # 核查：Wwise 音频包照扫，汇总时数「来自这些包的着色器记录」= 跳过规则的反例（普查定期开一批）
def top_wwise(p):   # 顶层文件是确证的 Wwise 音频包 → 'AKPK' / 'BKHD'，否则 None。只认文件头且核头内字段，不看扩展名 / 大小
    #   11-01 出包线：异度3 sound/*.pck（AKPK）4.1 GB 逐段 zlib 盲扫、零着色器；12 款现行根抽取记录 0 条来自这类文件。Wwise 包只装 WEM 音频与音频库，不含着色器
    #   AKPK（文件包）：'AKPK' u32 头长 u32 版本 1；头长 + 8 ≤ 文件长。BKHD（音频库）：'BKHD' u32 段长 u32 版本（Wwise 2008–2024 实际取值 < 0x200）；段长 + 8 ≤ 文件长
    try:
        with open(p, 'rb') as f: h = f.read(12)
        n = os.path.getsize(p)
    except OSError: return None
    if len(h) < 12: return None
    m, a, b = h[:4], *struct.unpack_from('<II', h, 4)
    if m == b'AKPK' and b == 1 and 0 < a and a + 8 <= n: return 'AKPK'
    if m == b'BKHD' and 0 < b < 0x200 and 0 < a and a + 8 <= n: return 'BKHD'
    return None
def skip_wwise(root, p, stat):   # 跳过的每个文件记进日志（款由调用方的日志定位，这里写路径与字节数）；核查模式不跳
    w = top_wwise(p)
    if not w or WWISE_AUDIT: return False
    stat['Wwise 音频包不扫'] += 1; stat['Wwise 音频包不扫（字节）'] += os.path.getsize(p)
    print(f'跳过 Wwise 音频包（{w}）：{_rel(p, root)}\t{os.path.getsize(p)} 字节', file=sys.stderr, flush=True)
    return True
BIG = 128 << 20   # 超过这么大的顶层文件：zlib 流扫描按 BIG 字节一段分给各进程（暗黑三 Common.cpk 2.5 GB 单进程扫 117 秒，整步被最大的文件卡住）
def big_split(p):   # 要分段扫 zlib 的大文件：顶层不是 zstd / Yaz0 / SARC（那些照常整读解开）
    try:
        if os.path.getsize(p) <= BIG: return False
        with open(p, 'rb') as f: m = f.read(0x80)
    except OSError: return False
    return m[:4] not in (b'\x28\xb5\x2f\xfd', b'Yaz0', b'SARC', b'pkzl') and not _vendor(m)   # 厂商归档（Telltale 465 MB 的 ttarch2）整读后按成员 visit
def work(args):
    root, files, outdir = args; rows, blobs, stat = [], {}, collections.Counter()
    for p in files:
        if skip_wwise(root, p, stat): continue
        try:
            with open(p, 'rb') as f:
                if f.read(4) == b'pkzl':   # 按索引逐成员解压；不整读大 PKZ，也不排盲扫分段作业
                    import mmap
                    with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
                        stat['顶层文件'] += 1; visit(_rel(p, root), data, rows, blobs, stat)
                    continue
            if big_split(p):   # 大文件 mmap 着整扫容器与相邻对（不整读进内存），zlib 流由 work_zlib 分段扫
                import mmap
                with open(p, 'rb') as f: data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
                stat['顶层文件'] += 1; stat['叶子文件'] += 1; scan_blob(_rel(p, root), data, rows, blobs, stat); continue
            data = open(p, 'rb').read()
        except Exception: stat['读失败'] += 1; continue
        stat['顶层文件'] += 1; visit(_rel(p, root), data, rows, blobs, stat)
    flush(blobs, outdir); return rows, stat
def work_zlib(args):   # 大文件的一段：只认起点在 [lo, hi) 的 zlib 流；往前多解 16 MB 接上跨段的尾巴（单个流不超过 16 MB，见 scan_zlib 的解压上限）
    import mmap
    root, p, lo, hi, outdir = args; rows, blobs, stat = [], {}, collections.Counter()
    with open(p, 'rb') as f: data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    # 不再因整个大文件里出现过 BNSH 就跳过流扫描（大乱斗 data.arc 17.6 GB 里有 4 个 BNSH，整份没扫 zstd 帧）：多扫的按键去重
    if data[:4] != b'BAHS': scan_zlib(_rel(p, root), data, rows, blobs, stat, lo, hi, 16 << 20); scan_zstd_frames(_rel(p, root), data, rows, blobs, stat, lo, hi); scan_crilayla(_rel(p, root), data, rows, blobs, stat, lo, hi); scan_streams(_rel(p, root), data, rows, blobs, stat, lo, hi)
    undecoded(_rel(p, root), data, lo, min(hi, len(data))); _COVER.pop(_rel(p, root), None)
    flush(blobs, outdir); return rows, stat
def work_pak(args):   # UE4 pak 的一批条目：按条目解出（Zlib 分块）再当普通文件 visit；不再把整个 pak 当未知文件扫 zlib 流（八方旅人2 3.3 GB、45 万个流一支也认不出）
    import unreal_pak as ue_pak
    p, eos, outdir = args[:3]; key = args[3] if len(args) > 3 else None
    rows, blobs, stat = [], {}, collections.Counter(); pk = ue_pak.Pak(p, key=key)
    for name, eo in eos:
        try: data = pk.read(eo, decode=pkz_oodle)   # Zlib / Gzip 读取器自己解；Oodle / LZ5 块交游戏自带解码器（宿主工具模式，同 PKZ；没宿主时在这里报出原因）
        except ue_pak.Unsupported as e:   # 加密索引链上的失败、条目损坏（Corrupt：解压长度不符 / 越界 / 截断，审计 #846 F-uepak-usz-slice）判红；未加密索引里「不支持」的条目沿用原有计数口径。
            fatal = pk.encrypted or isinstance(e, ue_pak.Corrupt)
            counter = '【红】pak 条目解码失败' if fatal else f'pak 条目不支持：{e}'
            stat[counter] += 1
            if stat[counter] <= 20: print(f'{"【红】" if fatal else ""}pak 条目不支持（{e}）：{os.path.basename(p)}:{name}', file=sys.stderr, flush=True)
            continue
        except Exception:
            stat['【红】pak 条目解码失败' if pk.encrypted or key is not None else 'pak 条目解码失败'] += 1; continue
        if name.lower().endswith('.ushaderbytecode'):
            try: scan_ue_archive('pak:' + name, data, rows, blobs, stat, oodle=pkz_oodle)
            except ValueError as e:
                stat['【红】pak 条目解码失败'] += 1
                print(f'【红】pak 着色器存档：{os.path.basename(p)}（{e}）', file=sys.stderr, flush=True)
        else: visit('pak:' + name, data, rows, blobs, stat, zl=pk.legacy)   # 旧版条目内 zlib 照旧扫描
    pk.close(); flush(blobs, outdir); return rows, stat
def _rel(p, root):   # 来源串里的路径一律 /（Windows 上 os.path.relpath 出 \，来源列与 Mac 不同、按来源分组的规则不认；11-05 Windows 出包机勇者斗恶龙 XI S）
    return os.path.relpath(p, root).replace(os.sep, '/')
def work_members(args):   # 带索引 / 分卷的厂商档案的一批条目（kitpak / hgpak 的 jobs）：逐条解出再当普通文件 visit（着色器由 scan_adj 等现有扫描配对）；来源 = <档案>//<条目名>
    import importlib
    root, mod, (p, part), outdir = args; m = importlib.import_module(mod); rows, blobs, stat = [], {}, collections.Counter()
    try:
        for nm, b in m.members(p, part, pkz_oodle):
            stat[f'{mod} 条目'] += 1; where = f'{_rel(p, root)}//{nm}'; sh = m.shader and m.shader(b)   # 头里写着控制段 / 机器码位置的（.nvb）按结构取，不靠相邻扫描
            if not sh: visit(where, b, rows, blobs, stat, 1); continue
            ctl, code = sh; key = key_of(ctl, code)
            if not key: raise ValueError(f'{nm}：控制段 / 机器码长度对不上')
            rows.append((key, {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf, 'cs') if code[:4] == bytes.fromhex('78563412') else 'cs', where, 0))
            blobs.setdefault(key, (code, ctl)); stat[f'{mod} 着色器'] += 1
    except (ValueError, RuntimeError) as e: stat['【红】厂商档案读不了'] += 1; print(f'【红】{mod}：{_rel(p, root)} 读不了（{e}）', file=sys.stderr, flush=True)   # RuntimeError：没有 Oodle 宿主
    flush(blobs, outdir); return rows, stat
def work_kpka(args):   # RE 引擎 pak 的一批条目（已按补丁链取最新版）：逐条解出再当普通文件 visit；来源 = kpka:<pak 文件名>@<路径哈希>
    import re_pak
    es, outdir = args; rows, blobs, stat = [], {}, collections.Counter(); fs = {}
    for p, h, off, csz, usz, attr in es:
        f = fs.get(p) or fs.setdefault(p, open(p, 'rb'))
        try: data = re_pak.read(f, off, csz, usz, attr)
        except re_pak.Unsupported as e: stat[f'RE pak 条目不支持：{e}'] += 1; continue
        except Exception: stat['RE pak 条目解码失败'] += 1; continue
        if b'\x34\x12\x76\x98' in data or data[:4] in (b'SARC', b'Yaz0', b'BAHS', b'\x28\xb5\x2f\xfd'): visit(f'kpka:{os.path.basename(p)}@{h:016x}', data, rows, blobs, stat, zl=False)
        else: undecoded(f'kpka:{os.path.basename(p)}@{h:016x}', data)   # 不进 visit 的条目（没有 NVN 魔数 / 容器魔数）也报：里面可能还有一层压缩
    flush(blobs, outdir); return rows, stat
def scan_unity(root, files, stat, known=None):
    """Unity 资源（unity_res.py）：先读 UnityFS 资源包（Shader 带类型树，记下借给播放器数据），再读不带类型树的序列化文件。
    每个代码块条目里的着色器来源记 unity:<文件>[//<包内文件>]@<对象>#<平台>.<分段>、变体号 = 条目号（同一条目的 vs + ps = 一个程序，「# 变体组」规则配）。返回 (rows, blobs)"""
    import unity_res
    rows, blobs, tt = [], {}, [None]
    def entries(name, b):
        for pid, plat, si, i, ent in unity_res.shader_entries(b, tt, stat):
            r = []; _scan_blob('e', ent, r, blobs, stat)
            for k, st, _, _ in r: rows.append((k, st, f'unity:{name}@{pid:x}#{plat}.{si}', i))
    heads = {}
    for p in files:   # known = 调用方给的文件头表（RomFS 清单前 32 字节，判下面两种文件够用）；表里没有的才读盘
        if known is not None and p in known: heads[p] = known[p]; continue
        try:
            with open(p, 'rb') as f: heads[p] = f.read(32)
        except OSError: pass
    for p in files:   # 资源包先（类型树在这里）
        if not unity_res.is_bundle(heads.get(p, b'')): continue
        # 只读映射 + 逐个节点解（unity_res.iter_bundle）：原先整个包读进内存、全部解开再每个节点复制一份，
        #   v0.3.0 Windows 8 GB 机 3.45 GB 的 Unity 游戏第一个文件就 MemoryError
        import mmap
        try:
            with open(p, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                for n, b in unity_res.iter_bundle(mm):
                    try: entries(f'{_rel(p, root)}//{n}', b)
                    except Exception: stat['UnityFS 包内文件不是序列化文件'] += 1
        except Exception as error:
            method = re.search(r'压缩方式 \d+（([^）]+)）', str(error))
            reason = method.group(1) if method else '其他'
            stat[f'UnityFS 解不开（{reason}）'] += 1
            continue
        stat['UnityFS 资源包'] += 1
    for p in files:   # 播放器数据：Unity 序列化文件 v17–40
        h = heads.get(p, b'')
        if len(h) < 20 or unity_res.is_bundle(h) or h[16] > 1: continue
        version = struct.unpack_from('>I', h, 8)[0]
        if not 17 <= version <= 40: continue
        if version < 22:
            declared_size = struct.unpack_from('>I', h, 4)[0]
        else:
            if len(h) < 32: continue   # 文件长在偏移 24 的 8 字节
            declared_size = struct.unpack_from('>Q', h, 24)[0]
        if declared_size != os.path.getsize(p): continue   # 头里记的文件长 = 实际长（动森 34 个文件头前几项碰巧像，这一项不像）
        try: entries(_rel(p, root), open(p, 'rb').read())
        except Exception: stat['Unity 序列化文件解析失败'] += 1
    return rows, blobs
def work_casc(args):
    import casc_flat
    cd, es, outdir = args; rows, blobs, stat = [], {}, collections.Counter()
    for e in es:
        try: data = casc_flat.read(cd, e)
        except Exception: stat['CASC 解码失败'] += 1; continue
        visit('casc:' + e[0], data, rows, blobs, stat)
    flush(blobs, outdir); return rows, stat
def nso_image(p):
    import lz4.block
    b = open(p, 'rb').read(); img = b''
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', b, off); csz = struct.unpack_from('<I', b, 0x60 + 4 * i)[0]; raw = b[fo:fo + csz]
        img += lz4.block.decompress(raw, uncompressed_size=sz) if (b[0xc] >> i) & 1 else raw
    return img
if __name__ == '__main__':
    a = sys.argv[1:]; nsos = []
    if not a or a[0] in ('-h', '--help') or a[0].startswith('-'):   # 10-16 L4：曾把 --help 当输出目录，在各树根下建出 --help/（index.tsv + src/）
        print('用法：nxsh_extract.py <输出目录> <资源目录…> [--nso <主程序 NSO>…] [--miss <目录>] [--raw]；输出目录不能以 - 开头', file=sys.stderr); sys.exit(0 if a and a[0] in ('-h', '--help') else 2)
    while '--nso' in a: i = a.index('--nso'); nsos.append(a[i + 1]); del a[i:i + 2]
    miss = None
    if '--miss' in a: i = a.index('--miss'); miss = a[i + 1]; del a[i:i + 2]   # 运行时落盘的缺失着色器目录（NX_SHADER_MISS_DIR）
    # 资源目录可写 @<列表文件>（一行一个；11-05 Windows 出包机怪猎崛起 273 个追加内容逐个放进命令行超过 Windows 32767 字符上限）
    outdir = a[0]; roots = [r for x in a[1:] for r in (open(x[1:], encoding='utf-8').read().splitlines() if x.startswith('@') else [x]) if r]; J = int(os.environ.get('J', '8')); os.makedirs(os.path.join(outdir, 'src'), exist_ok=True)
    # PKZ Oodle 成员的游戏解码器（pkz_oodle）：没设 DM_OODLE_MODULES 时按第一个资源目录的父目录（标准产物根）补上，工作进程继承环境变量
    if not os.environ.get('DM_OODLE_MODULES'):
        for rd in roots:
            cand = os.path.dirname(os.path.abspath(rd))
            if os.path.isfile(os.path.join(cand, 'main.fixups.tsv')): os.environ['DM_OODLE_MODULES'] = cand; break
    rows, stat = [], collections.Counter()
    # Trinity 容器：扫任何资源目录之前先把条目列全（一次抽取里 trpfs.tsv 只截断一次，后续目录追加）
    rep = os.path.join(outdir, 'trpfs.tsv')
    rf = open(rep, 'w')
    rf.write('# 包名\t包偏移\t文件哈希\t压缩\t长度\t数据偏移\n')
    try:
        for rd in roots:
            if os.path.isdir(rd):
                trpfs_report(os.path.join(rd, 'arc') if os.path.isdir(os.path.join(rd, 'arc')) else rd, outdir, stat, rf)
    finally:
        rf.close()
    # 字典目录：调用方给了 NXSH_ZSDICT 就往那里累加（tools/shscan.sh 分批扫：第一批小文件里收到的字典后面各批都用），没给用输出目录下 zsdict/
    zd = os.environ.get('NXSH_ZSDICT') or os.path.join(outdir, 'zsdict'); stat['zstd 字典'] = find_zsdicts(roots, zd); os.environ['NXSH_ZSDICT'] = zd
    import casc_flat
    for root in roots:
        # 同一次盘点走两遍（原先两次 os.walk 各盘点一次）
        tree = romfs_list.scan(root)
        # 文件头一次取齐（romfs_list.heads：前 32 字节，并行读、按内容身份落盘，同一份 RomFS 各阶段只读一次）：厂商档案 / Unity 判魔数都查这张表，
        #   不再各自把全部文件串行打开一遍（#606：Windows 30.4 万个文件，kitpak / hgpak / scan_unity 三遍逐个 open，停在「抽取 3/4」很久）
        hd = {e.path: e.head for e in romfs_list.heads(tree.top, tree=tree).files() if e.error is None and e.head is not None}
        cdirs = sorted(dp for dp, dn, fn in tree.walk() if 'build_manifest.psv' in fn)   # 扁平 CASC 归档（暴雪游戏）：按清单逐条解出再扫，归档文件本身不当普通文件扫
        files = sorted(os.path.join(dp, f) for dp, dn, fn in tree.walk() if dp not in cdirs for f in fn)
        import unreal_pak as ue_pak
        for pp in [f for f in files if f.lower().endswith('.pak') and ue_pak.is_pak(f)]:   # UE4 pak：按条目解出再扫，pak 本身不进普通文件 / zlib 分段扫描
            try:
                pk = ue_pak.Pak(pp, images=(open(p, 'rb').read() for p in nsos))
                E, key = pk.files, pk.key; pk.close()
            except ue_pak.Unsupported as e:
                # 索引加密 = 整个 pak 的条目都读不到、着色器全部漏抽：判红中止（同「zlib 块续解失败」）。其余整包不支持照旧计数、退回普通文件扫描，并打印路径
                if str(e) == '索引加密': stat['【红】pak 索引加密'] += 1; print(f'【红】pak 索引加密：{os.path.relpath(pp, root)}（条目读不到，里面的着色器会全部漏抽）', file=sys.stderr, flush=True)
                elif isinstance(e, ue_pak.Corrupt): stat['【红】pak 损坏'] += 1; print(f'【红】pak 损坏：{os.path.relpath(pp, root)}（{e}）', file=sys.stderr, flush=True)
                else: stat[f'pak 不支持：{e}'] += 1; print(f'pak 不支持（{e}），按普通文件扫：{os.path.relpath(pp, root)}', file=sys.stderr, flush=True)
                if str(e) == '索引加密' or isinstance(e, ue_pak.Corrupt): files.remove(pp)
                continue
            files.remove(pp); stat['pak'] += 1; stat['pak 条目'] += len(E)
            with cf.ProcessPoolExecutor(J) as ex:
                for r, s_ in ex.map(work_pak, [(pp, E[i::J * 8], outdir, key) for i in range(J * 8)]): rows += r; stat.update(s_)
        import re_pak
        kp = [f for f in files if f.lower().endswith('.pak') and re_pak.is_pak(f)]   # RE 引擎 pak：按补丁链取每个文件的最新版逐条解出再扫，pak 本身不进普通文件 / zlib 分段扫描
        for base, chain in re_pak.chains(kp).items():
            try: E, shadowed = re_pak.resolve(chain)
            except re_pak.Unsupported as e: stat[f'RE pak 不支持：{e}'] += 1; continue
            for p in chain: files.remove(p)
            stat['RE pak'] += len(chain); stat['RE pak 文件（取最新版）'] += len(E); stat['RE pak 被补丁换掉的旧版（不扫）'] += shadowed
            E.sort(key=lambda e: (e[0], e[2]))   # 同一 pak 内按偏移顺序读
            with cf.ProcessPoolExecutor(J) as ex:
                for r, s_ in ex.map(work_kpka, [(E[i::J * 8], outdir) for i in range(J * 8)]): rows += r; stat.update(s_)
        import kitpak, hgpak
        for m in (kitpak, hgpak):   # 带索引 / 分卷的厂商档案（11-02 着色器容器族 B 组：Unravel Two 的 kit! 索引 + 数据卷、No Man's Sky 的 HGPAK）：按条目切成任务逐条解出，档案本身不进普通文件 / 分段扫描
            try: E, taken = m.jobs(files, pkz_oodle, heads=hd)
            except (ValueError, RuntimeError) as e: stat['【红】厂商档案读不了'] += 1; print(f'【红】{m.__name__}：目录读不了（{e}）', file=sys.stderr, flush=True); continue
            if not taken: continue
            files = [f for f in files if f not in taken]; stat[m.__name__] += len(taken)
            with cf.ProcessPoolExecutor(J) as ex:
                for r, s_ in ex.map(work_members, [(root, m.__name__, e, outdir) for e in E]): rows += r; stat.update(s_)
        ur, ub = scan_unity(root, files, stat, hd)
        if ur: rows += ur; flush(ub, outdir); stat['Unity 着色器条目'] += len({(r[2], r[3]) for r in ur})
        for cd in cdirs:
            E = casc_flat.entries(cd); pick = [e for e in E if 'shader' in e[0].lower()] or E   # 路径带 shader 的优先（暗黑2 164 个包）；没有就全扫
            stat['CASC 条目'] += len(E); stat['CASC 扫的条目'] += len(pick)
            with cf.ProcessPoolExecutor(J) as ex:
                for r, s in ex.map(work_casc, [(cd, pick[i::J * 4], outdir) for i in range(J * 4)]): rows += r; stat.update(s)
        zt = [(root, p, lo, min(lo + BIG, os.path.getsize(p)), outdir) for p in files if big_split(p) and not (top_wwise(p) and not WWISE_AUDIT) for lo in range(0, os.path.getsize(p), BIG)]
        with cf.ProcessPoolExecutor(J) as ex:
            fz = [ex.submit(work_zlib, t) for t in sorted(zt, key=lambda t: t[1])]
            for r, s in ex.map(work, [(root, files[i::J * 8], outdir) for i in range(J * 8)]): rows += r; stat.update(s)
            for x in fz: r, s = x.result(); rows += r; stat.update(s)
    for p in nsos:
        blobs = {}; img = nso_image(p); scan_blob('nso:' + os.path.basename(p), img, rows, blobs, stat)
        scan_nso_zstd('nso:' + os.path.basename(p), img, rows, blobs, stat)
        flush(blobs, outdir)
    if miss and os.path.isdir(miss):
        blobs = {}
        for f in sorted(os.listdir(miss)):
            if not f.endswith('.ctl'): continue
            ctl = open(os.path.join(miss, f), 'rb').read(); code = open(os.path.join(miss, f[:-4] + '.code'), 'rb').read(); key = key_of(ctl, code)
            if key != f[:-4]: stat['缺失目录里键对不上的'] += 1; continue
            ty = struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf if code[:4] == bytes.fromhex('78563412') else 0
            st = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get(ty, 'cs'); stat['运行时落盘'] += 1
            rows.append((key, st, 'miss:' + f[:-4], 0)); blobs[key] = (code, ctl)
        flush(blobs, outdir)
    uniq = {}
    for key, st, src, v in rows: uniq.setdefault(key, (st, src, v))
    with open(os.path.join(outdir, 'index.tsv'), 'w') as f:
        f.write('# 键\t阶段\t首个来源\t变体号\n')
        for key in sorted(uniq): f.write('\t'.join(map(str, (key,) + uniq[key])) + '\n')
    # 全部阶段记录（不去重）：同一来源 + 变体号 = 一个程序（BNSH 的变体自带各阶段），离线批量翻译（ryu_judge --shbake）按它配 vs / ps
    with open(os.path.join(outdir, 'rows.tsv'), 'w') as f:
        f.write('# 键\t阶段\t来源\t变体号\n')
        for r in sorted(set(rows), key=lambda r: (r[2], r[3], r[1], r[0])): f.write('\t'.join(map(str, r)) + '\n')
    if WWISE_AUDIT:   # 跳过规则的反例：着色器记录的来源顶层文件是确证 Wwise 包（分母 = 本次扫到的 Wwise 包个数与字节）
        ww = {os.path.relpath(p, rd) for rd in roots if os.path.isdir(rd) for dp, dn, fn in romfs_list.walk(rd) for f in fn for p in [os.path.join(dp, f)] if top_wwise(p)}
        bad = [r for r in rows if str(r[2]).split('@')[0].split('#')[0].split('|')[0] in ww]
        stat['Wwise 核查：包个数'] = len(ww); stat['【红】Wwise 核查：来自音频包的着色器记录（跳过规则反例）' if bad else 'Wwise 核查：反例'] = len(bad)
        for r in bad[:20]: print(f'【红】Wwise 核查反例：{r[2]} → {r[0]}', file=sys.stderr, flush=True)
    print('统计', dict(stat)); print('阶段记录', len(rows), '唯一键', len(uniq), '按阶段', dict(collections.Counter(v[0] for v in uniq.values())))
    # 读不了的文件跳过、其余照抽（v0.3.1 拿不准不停；原先 10-23 定「漏抽是硬错误」退 1、整款出不了包）：漏的那部分着色器运行时首遇现编，
    #   按类计数写进 <输出目录>/degrade.tsv（graphics/tools/direct/extract.sh 并进抽取的降级汇总），逐条原因见上方【红】行
    skip = [(k, stat[k]) for k in ('【红】pak 索引加密', '【红】pak 损坏', '【红】pak 条目解码失败', '【红】zlib 块续解失败', '【红】PKZ/DAT 解析失败', '【红】厂商档案读不了') if stat[k]]
    with open(os.path.join(outdir, 'degrade.tsv'), 'w', encoding='utf-8') as f:
        for k, n in skip:
            f.write(f"extract\ts2x:{k[3:]}\t{n}\t\tS2Arm 抽取跳过读不了的部分，里面的着色器运行时首遇现编\n")
    if skip: print(f"【黄】抽取：跳过读不了的部分（{'、'.join(f'{k[3:]} {n}' for k, n in skip)}），其余照抽；这些着色器运行时首遇现编，逐条见上方", file=sys.stderr)
