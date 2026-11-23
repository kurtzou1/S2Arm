#!/usr/bin/env python3
# Unreal Engine game files for the shader tools: pak files (version 11, UE 4.26 and later; Octopath Traveler 0 is UE5), shader code archives (.ushaderbytecode version 2) and the job files the Mac host decodes Oodle with
# (DM_OODLE_JOB, dm/host/hle_oodle.c). Octopath Traveler 0 keeps everything in one pak, Octopath_Traveler0/Content/Paks/pakchunk0-Switch.pak (1.5 GB, 159,757 files): its index is AES-256 encrypted,
# its files are stored or Oodle-compressed in blocks. Its two shader code archives are stored, but every shader inside is Oodle-compressed (Mermaid, block header 8C 0A), which no decoder in this
# repository can undo, so the game's own OodleLZ_Decompress decodes them in the Mac host (the NSP script's decode_ue_shaders, for any game with Unreal paks).
# Unreal Engine 4.27 (DRAGON QUEST VII Reimagined) keeps its packages in IoStore containers (.utoc / .ucas) and the rest in pakchunk0-Switch.pak (3,972 files, index not encrypted), among them
#   two stored shader code archives (ShaderArchive-Global-SF_GLSL_SWITCH, 1,764 shaders, and ShaderArchive-DOLL_Chunk0-SF_GLSL_SWITCH, 63,185): every shader in them is an LZ4 block, the
#   engine's default shader compression since 4.26, decoded here (lz4_shaders) without the host.
# Unreal Engine 5.6 (FINAL FANTASY RESONANCE) has no shader code archive in its pak (FFRS-Switch.pak holds configs only): the cooker converted both libraries into its IoStore container
#   (FFRS-Switch.utoc / .ucas, Oodle in 64 KB blocks, not encrypted) as one ShaderCodeLibrary chunk each (the tables) and one ShaderCode chunk per group of shaders, every group Oodle-compressed
#   on its own (Toc, io_archive). Both layers need the game's decoder, which runs in the Mac host's tool mode (OodleHost); the libraries come out as version 2 archives with every shader decoded.
# The AES key is in main (Unreal embeds it): the 32-byte window of main's read-only or data segment that decrypts the index start to its mount point ("../graphics/"; Octopath Traveler 0: one window of
#   116,287 tried). It is only kept in memory, never printed or written.
# Pak footer (version 11, the last 0xdd bytes): encryption key GUID (16), encrypted index flag (u8), magic 0x5A6F12E1, version (u32), index offset (u64), index size (u64), index SHA-1 (20),
#   5 compression method names (32 bytes each).
# Index: mount point (FString), entry count (i32), path hash seed (u64), path hash index (i32 flag, then u64 offset, u64 size, SHA-1), full directory index (the same, encrypted like the index),
#   encoded entries (i32 size + bytes), the count of unencoded entries (0 here). Directory index: i32 count, then per directory its name (FString) and its files (i32 count, then name + i32 offset into
#   the encoded entries). FString: i32 length with the NUL, UTF-8; a negative length is UTF-16.
# Encoded entry: u32 bits (0-5 compression block size >> 11, 0x3f = a u32 follows; 6-21 block count; 22 encrypted; 23-28 compression method, 1-based; 29 stored size fits 32 bits; 30 raw size fits
#   32 bits; 31 offset fits 32 bits), then offset, raw size, stored size (compressed entries only) and, for several blocks or an encrypted one, each block's u32 stored size. The data starts after
#   the FPakEntry the pak repeats in front of it (53 bytes, + 4 + 16 per block when compressed); blocks follow each other, 16-aligned when encrypted.
# Older paks (version 4, UE 4.18: DRAGON QUEST XI S, pakchunk0-Switch.pak 6.6 GB / 264,844 files and pakchunk1-Switch.pak 7.2 GB / 147,824 files, the update's *_0_P.pak beside them) keep the
#   legacy layout. Footer (the last 0x2d bytes): encrypted index flag (u8), magic, version, index offset, index size, SHA-1. Index: mount point, entry count, then per file its name (relative to the
#   mount point) and its FPakEntry: offset, stored size, raw size (i64 each), compression flags (i32), SHA-1 (20), for a compressed file the block count (i32) and each block's start and end
#   (i64, from the file start before version 5, from the entry after), the encrypted flag (u8) and the compression block size (u32). The FPakEntry is repeated in front of the data.
#   The compression flags are no names: 1 zlib, 2 gzip, 4 custom; DRAGON QUEST XI S's engine uses 3, which is LZ5 2.0 (main exports LZ5_*; every block starts with its level, 0x2d = 45), and only the
#   game's own decoder reads it (hle_oodle.c, through a decode function given to Pak.read); zlib and gzip blocks are inflated here.
#   Versions 5 to 7 keep the same index (SAMURAI SHODOWN, UE 4.2x, version 7, zlib): 5 makes the block starts relative to the entry, 6 only adds delete records, 7 puts the encryption key
#   GUID in front of the footer, which leaves its last 0x2d bytes as they were.
#   Borderlands 3 (Gearbox, version 6, all 85 indexes AES-encrypted) writes a compact FPakEntry instead (Pak.legacy_files): offset u64, stored and raw size u32, flags u8 (4 = custom: Oodle),
#   the blocks when compressed, flags u8; no SHA-1, no block size. Shaders inline as in DRAGON QUEST XI S (Engine/GlobalShaderCache-GLSL_SWITCH.bin and the materials).
# Shader code archive (version 2): shader map hashes (20 bytes each), shader hashes (20 each), shader map entries {u32 first index, u32 shader count, u32 first preload, u32 preload count}, shader
#   entries {u64 offset, u32 size, u32 raw size, u8 frequency} (17 bytes, packed), preload entries (16 each), shader indices (u32): each array is a u32 count and its elements; the code follows,
#   offsets relative to its start. A shader whose size differs from its raw size is compressed.
# Usage: uepak.py list <pak> <main NSO> <out tsv>                       every file in the pak: path, raw size, stored size, compression, encrypted, blocks
#        uepak.py job <RomFS> <main NSO> <work dir> [<Mac host> <rewritten modules>]   the shader code archives of every pak, and an Oodle job of their Oodle-compressed shaders (LZ4 ones
#                                                                       decoded at once); IoStore shader libraries (UE 5.6) decoded at once through the game's Oodle in the host (OodleHost)
#        uepak.py finish <work dir> <out dir>                           after the host has run the job: the archives with every shader decoded
import json, os, struct, sys
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，listdir 同 os.listdir）；RomFS 文件按路径读经 romfs_list.open_file / read_file
#   （盘上有就同 open；RomFS 不落散文件、只有 romfs.std 镜像时从镜像读）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'nvn', 'tools')); import romfs_list

PAK_MAGIC, ARCHIVE_VERSION = 0x5A6F12E1, 2
JOB_MAGIC, OUT_MAGIC = 0x4a4f4d44, 0x524f4d44   # "DMOJ", "DMOR" (hle_oodle.c)
FREQ = {0: 'vs', 1: 'hs', 2: 'ds', 3: 'ps', 4: 'gs', 5: 'cs'}   # EShaderFrequency (the archive's frequency census: 0 vertex, 3 pixel, 5 compute)

def aes_decrypt(key, data):
    """AES-256 ECB decryption through the OS (graphics/tools/shbake/pak_crypto.py: CommonCrypto on macOS, BCrypt on Windows)"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../graphics/tools/shbake')); import pak_crypto
    return pak_crypto.aes_ecb(key, data)

_M, _K0, _K1, _K2 = (1 << 64) - 1, 0xc3a5c85c97cb3127, 0xb492b66fbe98f273, 0x9ae16a3b2f90404f
def _rot(v, s): return ((v >> s) | (v << (64 - s))) & _M if s else v
def _f64(s, i): return struct.unpack_from('<Q', s, i)[0]
def _bswap(v): return int.from_bytes((v & _M).to_bytes(8, 'little'), 'big')
def _h16(u, v, mul=0x9ddfea08eb382d69):
    a = ((u ^ v) * mul) & _M; a ^= a >> 47
    b = ((v ^ a) * mul) & _M; b ^= b >> 47
    return (b * mul) & _M
def _weak(s, i, a, b):
    w, x, y, z = _f64(s, i), _f64(s, i + 8), _f64(s, i + 16), _f64(s, i + 24)
    a = (a + w) & _M; b = _rot((b + a + z) & _M, 21); c = a
    a = (a + x + y) & _M; b = (b + _rot(a, 44)) & _M
    return ((a + z) & _M, (b + c) & _M)
def city64(s):
    """CityHash64 (Google's CityHash 1.1, the one Unreal's Core links; checked against python-cityhash 0.4.10 on 1,500 random inputs of 0 to 299 bytes)"""
    n = len(s)
    if n <= 16:
        if n >= 8:
            mul = _K2 + n * 2; a = (_f64(s, 0) + _K2) & _M; b = _f64(s, n - 8)
            return _h16((_rot(b, 37) * mul + a) & _M, ((_rot(a, 25) + b) * mul) & _M, mul)
        if n >= 4:
            mul = _K2 + n * 2
            return _h16((n + (struct.unpack_from('<I', s, 0)[0] << 3)) & _M, struct.unpack_from('<I', s, n - 4)[0], mul)
        if n:
            y, z = s[0] + (s[n >> 1] << 8), n + (s[n - 1] << 2); v = ((y * _K2) ^ (z * _K0)) & _M
            return ((v ^ (v >> 47)) * _K2) & _M
        return _K2
    mul = _K2 + n * 2
    if n <= 32:
        a = (_f64(s, 0) * _K1) & _M; b = _f64(s, 8); c = (_f64(s, n - 8) * mul) & _M; d = (_f64(s, n - 16) * _K2) & _M
        return _h16((_rot((a + b) & _M, 43) + _rot(c, 30) + d) & _M, (a + _rot((b + _K2) & _M, 18) + c) & _M, mul)
    if n <= 64:
        a = (_f64(s, 0) * _K2) & _M; b = _f64(s, 8); c = _f64(s, n - 24); d = _f64(s, n - 32)
        e = (_f64(s, 16) * _K2) & _M; f = (_f64(s, 24) * 9) & _M; g = _f64(s, n - 8); h = (_f64(s, n - 16) * mul) & _M
        u = (_rot((a + g) & _M, 43) + (_rot(b, 30) + c) * 9) & _M; v = (((a + g) ^ d) + f + 1) & _M
        w = (_bswap((u + v) * mul) + h) & _M; x = (_rot((e + f) & _M, 42) + c) & _M
        y = ((_bswap((v + w) * mul) + g) * mul) & _M; z = (e + f + c) & _M
        a = (_bswap((x + z) * mul + y) + b) & _M; b = ((z + a) * mul + d + h) & _M; b = ((b ^ (b >> 47)) * mul) & _M
        return (b + x) & _M
    x = _f64(s, n - 40); y = (_f64(s, n - 16) + _f64(s, n - 56)) & _M; z = _h16((_f64(s, n - 48) + n) & _M, _f64(s, n - 24))
    v = _weak(s, n - 64, n, z); w = _weak(s, n - 32, (y + _K1) & _M, x); x = (x * _K1 + _f64(s, 0)) & _M
    left, i = (n - 1) & ~63, 0
    while left:
        x = (_rot((x + y + v[0] + _f64(s, i + 8)) & _M, 37) * _K1) & _M
        y = (_rot((y + v[1] + _f64(s, i + 48)) & _M, 42) * _K1) & _M
        x ^= w[1]; y = (y + v[0] + _f64(s, i + 40)) & _M; z = (_rot((z + w[0]) & _M, 33) * _K1) & _M
        v = _weak(s, i, (v[1] * _K1) & _M, (x + w[0]) & _M); w = _weak(s, i + 32, (z + w[1]) & _M, (y + _f64(s, i + 16)) & _M)
        z, x = x, z; i += 64; left -= 64
    return _h16((_h16(v[0], w[0]) + (y ^ (y >> 47)) * _K1 + z) & _M, (_h16(v[1], w[1]) + x) & _M)

def nso_image(path):
    """A decompressed NSO image and its (read-only start, data end)"""
    import lz4.block
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xc)[0]; segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img), segs[1][1], segs[2][1] + segs[2][2]

def oodle_host_find(near=None):
    """宿主工具模式的两样输入（S2Arm：runtime/src/oodle_tool.c，协议同上游 dm/host/hle_oodle.c）→ (宿主可执行文件, 模块目录)，找不到 → (None, 原因)。
    DM_OODLE_HOST：Mac 宿主，缺省 = 本仓库 build/s2arm-host（存在才算）；或 Windows 出包机的 gamedec（pack/gamedec：ARMeilleure 执行同一段游戏解码代码，同一协议，
    文件名以 gamedec 开头）。DM_OODLE_MODULES：Mac 宿主要改写模块目录（main.fixups.tsv / main.patched.bin / main.npdm 所在处），gamedec 要游戏原样 main 所在的
    产物根（<根>/exefs/main）；缺省 = near（RomFS 或资源目录）的父目录——标准产物根就是这个布局（<根>/romfs 与 <根>/main.fixups.tsv、<根>/exefs 并排）"""
    host = os.environ.get('DM_OODLE_HOST')
    if not host:
        cand = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build', 's2arm-host')
        host = os.path.normpath(cand) if os.path.isfile(cand) else None
    need = os.path.join('exefs', 'main') if host and os.path.basename(host).lower().startswith('gamedec') else 'main.fixups.tsv'
    mods = os.environ.get('DM_OODLE_MODULES')
    if not mods and near:
        parent = os.path.dirname(os.path.abspath(near))
        if os.path.isfile(os.path.join(parent, need)): mods = parent
    why = []
    if not host: why.append('没有 Mac 宿主：设 DM_OODLE_HOST=<build/s2arm-host>（make host 编出）')
    elif not os.path.isfile(host): why.append(f'DM_OODLE_HOST={host} 不存在')
    if not mods: why.append(f'没有{"产物根" if need != "main.fixups.tsv" else "改写模块目录"}：设 DM_OODLE_MODULES=<{need} 所在目录>' + (f'（{near} 的父目录里没有 {need}）' if near else ''))
    elif not os.path.isfile(os.path.join(mods, need)): why.append(f'DM_OODLE_MODULES={mods} 里没有 {need}')
    return (None, '；'.join(why)) if why else ((host, mods), '')

class OodleHost:
    """The game's own decoder (OodleLZ_Decompress, or LZ5_decompress_safe for DRAGON QUEST XI S) in the Mac host's tool mode (DM_OODLE_SERVE, runtime/src/oodle_tool.c), called as
    decode(compressed, raw length). The one place that starts the tool host: shader_split.oodle and the pak readers all go through it.
    host = the Mac host built for the game, modules = its rewritten modules (an artifact root), env = the host's environment (default: this process's).
    LZ5 is served after the SDK starts, so the host brings up its C# service layer (the SDK connects to system services): like the GLSLC tool (glslc_offline.run_host) it gets the game
    data at the artifact root (S2A_GAME_DATA) and a private documents / Ryujinx data / shader cache folder, never the machine's shared ~/Documents/S2A (11-01: without them the
    services found no game data and the SDK Broke; the shared save folders were mounted)"""
    def __init__(self, host, modules, env=None):
        import subprocess, tempfile
        self.err = tempfile.TemporaryFile()
        self.priv = tempfile.mkdtemp(prefix='oodle-host-')
        e = dict(env or os.environ, DM_OODLE_SERVE='1', S2A_AUTOPLAY='0', S2A_DOCS=self.priv, S2A_RYU_DATA=os.path.join(self.priv, 'ryu'),
                 NXGAL_SHADER_CACHE_DIR=os.path.join(self.priv, 'gal'))
        e.setdefault('S2A_GAME_DATA', str(modules))
        self.p = subprocess.Popen([str(host), str(modules)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, env=e)
        self.n = 0
        import multiprocessing.util   # 进程池工作进程退出走 os._exit、不跑 atexit；Finalize 在工作进程与主进程退出时都跑：宿主收掉、私有目录删掉，不漏在 TMPDIR
        self._fin = multiprocessing.util.Finalize(self, OodleHost._close, args=(self.p, self.priv), exitpriority=10)
    def output(self):
        """宿主输出的末 3000 字（进报错行）；设了 DM_OODLE_LOG_DIR 时把完整输出另存为 <目录>/oodle_host.<进程号>.log 并在头一行写明（11-01：只留末尾，
        勇者斗恶龙 XI S 普查里看不到宿主为什么没起来；extract.py 把它设成抽取目录，失败时随其它 .log 留进 .failed）"""
        self.err.seek(0); full = self.err.read().decode(errors='replace'); head = ''
        d = os.environ.get('DM_OODLE_LOG_DIR')
        if d:
            p = os.path.join(d, f'oodle_host.{os.getpid()}.log')
            try:
                with open(p, 'w') as f: f.write(full)
                head = f'（宿主完整输出 {len(full)} 字：{p}）\n'
            except OSError as e: head = f'（宿主完整输出没存下：{e}）\n'
        return head + full[-3000:]
    def decode(self, comp, n):
        """→ the n bytes, or None when the decoder rejected the stream (the host answers 0 and keeps serving). The host gone or a wrong length → ValueError with its output"""
        try:
            self.p.stdin.write(struct.pack('<QQ', len(comp), n)); self.p.stdin.write(comp); self.p.stdin.flush()
            got = struct.unpack('<Q', self.p.stdout.read(8))[0]
        except (OSError, struct.error): got = None   # 宿主已退：POSIX 报 BrokenPipe，Windows 往已关的管道写报 EINVAL（[Errno 22]）；都按宿主没了、带它的输出报
        if got == 0 and n: return None
        if got != n: raise ValueError(f'the game\'s decoder in the Mac host failed on a {len(comp)} → {n} byte stream; ---- host output ----\n' + self.output())
        self.n += 1
        return self.p.stdout.read(n)
    def __call__(self, comp, n):
        out = self.decode(comp, n)
        if out is None: raise ValueError(f'the game\'s decoder in the Mac host rejected a {len(comp)} → {n} byte stream; ---- host output ----\n' + self.output())
        return out
    @staticmethod
    def _close(p, priv):
        import shutil
        if p.poll() is None:
            # 宿主恰在 poll 之后退出时，关 stdin 冲缓冲会撞上已关的管道（Windows 报 EINVAL、POSIX 报 BrokenPipe）：收尾不能抛，
            #   否则盖掉真正的错（D-66PR / D-C4FW 等 5 张：报错只剩 _close 里的 [Errno 22]，宿主为什么退看不到）
            try: p.stdin.close()
            except OSError: pass
            try: p.wait(10)
            except Exception: p.kill()
        shutil.rmtree(priv, ignore_errors=True)
    def close(self):
        self._fin()

class R:
    def __init__(self, b, o=0): self.b, self.o = b, o
    def take(self, fmt):
        v = struct.unpack_from(fmt, self.b, self.o); self.o += struct.calcsize(fmt); return v if len(v) > 1 else v[0]
    def raw(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def fstr(self):
        n = self.take('<i')
        if n < 0: return self.raw(-2 * n).decode('utf-16-le')[:-1]
        return self.raw(n)[:-1].decode('utf-8', 'replace') if n else ''

# pak 的尾部 / 索引 / 条目 / 密钥 / 解块只在 graphics/tools/shbake/unreal_pak.py（11-01 出包线收成一份：原先这里、pack/ue_pak.py、那边各写一遍，无主之地3 紧凑条目只补进两份）。
#   这里留 shader_split.py 与本文件 job / list 用的老接口：footer 元组、按名字取的 Pak、旧版版本集合
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../graphics/tools/shbake')); import unreal_pak as UP
LEGACY = (4, 5, 6, 7, 8, 9)   # shader_split.py ue_legacy_jobs 收的旧版 pak 版本（条目内联 zlib 着色器，走游戏解码器；8 / 9 = 压缩方式按名字表，BRAVELY DEFAULT Ⅱ 版本 8）

def _footer(f):
    f.seek(0, 2); ft = UP.footer(f, f.tell())
    if ft is None: raise ValueError('no pak footer')
    return ft

def pak_version(f):
    return _footer(f)['version']

def footer(f):
    """(encrypted index, index offset, index size, compression method names by number from 1, version)"""
    ft = _footer(f)
    if ft['version'] not in LEGACY and ft['version'] != 11: raise ValueError(f'pak version {ft["version"]}, only {", ".join(map(str, LEGACY))} and 11 are read')
    return ft['enc'], ft['off'], ft['size'], ft['methods'] or [UP.LEGACY_METHODS.get(i, f'flags {i}') for i in range(1, 8)], ft['version']

class Pak:
    """unreal_pak.Pak 按名字取：files = {名字: 句柄}（版本 11 名字去掉开头的 /；旧版 = {名字: 条目 dict}，shader_split 读 raw），entry(名字)、read(名字, decode)"""
    def __init__(self, path, key=None, images=()):
        self.p = UP.Pak(path, key=key, images=images); self.path = path
        self.key, self.version, self.mount, self.methods = self.p.key, self.p.version, self.p.mount, self.p.methods
        if self.p.legacy: self._h = dict(self.p.files); self.files = {n: self.p.entry(h) for n, h in self._h.items()}
        else: self._h = {n.lstrip('/'): h for n, h in self.p.files}; self.files = dict(self._h)
    def entry(self, path): return self.p.entry(self._h[path])
    def read(self, path, decode=None): return self.p.read(self._h[path], decode=decode)

def archive(b):
    """A shader code archive's tables: {'maps': [(first index, count)], 'shaders': [(offset, size, raw size, frequency)], 'indices': [...], 'code': start of the code}"""
    r = R(b)
    if r.take('<I') != ARCHIVE_VERSION: raise ValueError('not a version 2 shader code archive')
    nmap = r.take('<I'); r.raw(20 * nmap); nsh = r.take('<I'); r.raw(20 * nsh)
    maps = [r.take('<IIII')[:2] for _ in range(r.take('<I'))]
    shaders = [r.take('<QIIB') for _ in range(r.take('<I'))]
    r.raw(16 * r.take('<I'))
    n = r.take('<I'); indices = list(struct.unpack_from(f'<{n}I', b, r.o)); r.o += 4 * n
    return dict(maps=maps, shaders=shaders, indices=indices, code=r.o)

def decoded_archive(b, raws):
    """The archive with every shader replaced by its decoded bytes (raws, in entry order): the same tables, each entry's size = its raw size, the code laid out again
    (the preload entries keep their old file ranges; only the shader tools read these copies)"""
    a = archive(b); r = R(b); r.take('<I')
    for elem in (20, 20, 16): r.raw(elem * r.take('<I'))
    head, ents_at = b[:r.o + 4], r.o + 4; n = len(a['shaders']); tail_at = ents_at + 17 * n
    ents, off = bytearray(), 0
    for (_, _, raw, fr), d in zip(a['shaders'], raws):
        if len(d) != raw: raise ValueError(f'decoded shader of {len(d)} bytes, the archive says {raw}')
        ents += struct.pack('<QIIB', off, raw, raw, fr); off += raw
    return head + bytes(ents) + b[tail_at:a['code']] + b''.join(raws)

def lz4_shaders(b, a):
    """Every shader of an archive decoded as an LZ4 block (Unreal Engine 4.26 and later compress shaders with LZ4 unless the project picks another format: DRAGON QUEST VII Reimagined's
    64,949), or None when one of the compressed ones is no LZ4 block that decodes to its raw size as an LSLG record (Octopath Traveler 0's Oodle: the game's own decoder is needed)"""
    import lz4.block
    out = []
    for off, size, raw, _ in a['shaders']:
        c = b[a['code'] + off:a['code'] + off + size]
        if size == raw: out.append(c); continue
        try: d = lz4.block.decompress(c, uncompressed_size=raw)
        except Exception: return None
        if len(d) != raw or d[:4] != b'LSLG': return None
        out.append(d)
    return out

TOC_MAGIC, IO_SHADER_LIBRARY, IO_SHADER_CODE = b'-==--==--==--==-', 8, 9   # EIoChunkType in Unreal Engine 5 (TOC version 4 and later; 4.27 numbers its chunk types otherwise)

class Toc:
    """An IoStore container: the .utoc's chunk table and compression blocks, the data in the .ucas beside it (<name>_s<n>.ucas for partitions after the first). A chunk is a range of the
    container's uncompressed stream, which is cut into blocks of one size, each stored or compressed on its own (method index 0 = stored, else the TOC's method names from 1).
    Header (FIoStoreTocHeader, 144 bytes): magic, u8 version, u8, u16, u32 header size, entry count, block count, block entry size (12), method count, method name length, block size,
    directory index size, partition count, u64 container ID, encryption key GUID (16), u8 flags (1 compressed, 2 encrypted, 4 signed, 8 indexed), u8, u16, u32 perfect hash seed count,
    u64 partition size, u32 count of chunks without a perfect hash, then reserved words. After it: chunk IDs (12 bytes: u64 hash, u16 index, u8, u8 type), offsets and lengths
    (5 + 5 bytes, big-endian), the perfect hash seeds and overflow list (u32 each), the blocks (5-byte offset, 3-byte stored size, 3-byte raw size, u8 method; little-endian), the method names"""
    def __init__(self, path, key=None):
        b = romfs_list.read_file(path)
        if b[:16] != TOC_MAGIC: raise ValueError(f'{path}: not an IoStore TOC')
        self.path, self.key, self.version = path, key, b[16]
        hsz, n, nblk, bsz, nmeth, mlen, self.block_size, _, nparts = struct.unpack_from('<9I', b, 20)
        if bsz != 12: raise ValueError(f'{path}: compression block entries of {bsz} bytes')
        self.encrypted = b[80] >> 1 & 1
        nseeds = struct.unpack_from('<I', b, 84)[0] if self.version >= 4 else 0
        self.part_size = struct.unpack_from('<Q', b, 88)[0] if self.version >= 3 and nparts > 1 else 1 << 64
        nover = struct.unpack_from('<I', b, 96)[0] if self.version >= 5 else 0
        if self.encrypted and not key: raise ValueError(f'{path}: the container is encrypted and no key was given')
        o = hsz; self.ids = [b[o + 12 * i:o + 12 * i + 12] for i in range(n)]; o += 12 * n
        self.ranges = [(int.from_bytes(b[o + 10 * i:o + 10 * i + 5], 'big'), int.from_bytes(b[o + 10 * i + 5:o + 10 * i + 10], 'big')) for i in range(n)]; o += 10 * n + 4 * nseeds + 4 * nover
        self.blocks = []
        for i in range(nblk):
            e = b[o + 12 * i:o + 12 * i + 12]
            self.blocks.append((int.from_bytes(e[:5], 'little'), int.from_bytes(e[5:8], 'little'), int.from_bytes(e[8:11], 'little'), e[11]))
        o += 12 * nblk
        self.methods = [b[o + mlen * i:o + mlen * (i + 1)].rstrip(b'\0').decode('latin1') for i in range(nmeth)]
        self.index = {c: i for i, c in enumerate(self.ids)}; self.files = {}
    def of_type(self, t):
        """Indices of the chunks of one EIoChunkType (Unreal Engine 5 numbering: TOC version 4 and later)"""
        return [i for i, c in enumerate(self.ids) if c[11] == t] if self.version >= 4 else []
    def ucas(self, part):
        if part not in self.files: self.files[part] = romfs_list.open_file(self.path[:-5] + ('.ucas' if not part else f'_s{part}.ucas'))
        return self.files[part]
    def read(self, i, decode=None):
        """Chunk i's bytes; Oodle blocks need decode(block bytes, raw length) → bytes (the game's own decoder, OodleHost)"""
        off, ln = self.ranges[i]; first = off // self.block_size; out = []
        for k in range(first, (off + ln - 1) // self.block_size + 1 if ln else first):
            at, size, raw, m = self.blocks[k]; f = self.ucas(at // self.part_size); f.seek(at % self.part_size)
            d = f.read((size + 15) & ~15 if self.encrypted else size)
            if self.encrypted: d = aes_decrypt(self.key, d)[:size]
            meth = self.methods[m - 1] if m else ''
            if not meth: out.append(d[:raw])
            elif meth == 'Oodle':
                if not decode: raise ValueError(f'{self.path}: chunk {i} is Oodle-compressed and no decoder was given')
                out.append(decode(d, raw))
            elif meth == 'Zlib': import zlib; out.append(zlib.decompress(d))
            elif meth == 'LZ4': import lz4.block; out.append(lz4.block.decompress(d, uncompressed_size=raw))
            else: raise ValueError(f'{self.path}: compression method {meth} is not read')
        s = off - first * self.block_size
        return b''.join(out)[s:s + ln]

def io_library_name(toc, i, names):
    """A shader library chunk's archive name: Unreal makes its chunk ID from CityHash64 of "<library>-<format>" lowercased, in UTF-16 (FINAL FANTASY RESONANCE: global-sf_glsl_switch-sp_glsl_switch
    → be76feab0415c156, the hash's bytes in memory order), names = the candidate "ShaderArchive-<library>-<format>" names (the RomFS manifests list them); a chunk none matches is named by its ID"""
    h = toc.ids[i][:8]
    for n in names:
        if city64(n[len('ShaderArchive-'):].lower().encode('utf-16-le')).to_bytes(8, 'little') == h: return n
    return f'ShaderArchive-IoStore-{h.hex()}'

def io_priority(paths):
    """IoStore containers in Unreal's mount priority, highest first: a patch container (<name>_P.utoc, <name>_<n>_P.utoc: the higher n the later the patch) before the base ones.
    The same chunk ID in two containers is the higher one's (LEGO Horizon Adventures 1.4.0: Glow-Switch_0_P.utoc carries a new shader library 4c99307a…, its groups stay in Glow-Switch.utoc)"""
    import re
    def key(p):
        m = re.search(r'(?:_(\d+))?_P$', os.path.splitext(os.path.basename(p))[0])
        return (0, -int(m.group(1) or 0), p) if m else (1, 0, p)
    return sorted(paths, key=key)

def io_archive(toc, i, decode, pool=()):
    """An IoStore shader library (Unreal Engine 5: FIoStoreShaderCodeArchive) as a version 2 shader code archive with every shader decoded, the form the shader tools read.
    The library chunk: u32 version (1), shader map hashes (20 bytes each), shader hashes (20 each), the shader groups' chunk IDs (12 each), shader map entries {u32 first index, u32 shader count},
    shader entries (u64: frequency in bits 0-3, group in 4-33, offset in the group's decoded bytes from bit 34), group entries {u32 first index, u32 shader count, u32 raw size, u32 stored size},
    shader indices (u32): each a u32 count and its elements. Each group is one ShaderCode chunk holding its shaders end to end, Oodle-compressed as a whole when its stored size is below its raw
    size (FINAL FANTASY RESONANCE: 5,919 groups of 74,244 shaders); a shader runs to the next shader's offset in its group, or to the group's end.
    pool: every mounted container, highest priority first (io_priority; the library's own one among them): a group chunk is the highest container's that has it, as Unreal resolves a chunk ID
    across mounts — a patch's library keeps its unchanged groups in the base container, and a patch can bring a new group for a base library. No pool: the library's own container only"""
    r = R(toc.read(i, decode))
    if r.take('<I') != 1: raise ValueError(f'{toc.path}: shader library chunk {i} is not version 1')
    maph = r.raw(20 * r.take('<I')); nsh = r.take('<I'); shh = r.raw(20 * nsh)
    gids = [r.raw(12) for _ in range(r.take('<I'))]
    maps = [r.take('<II') for _ in range(r.take('<I'))]
    n = r.take('<I'); ents = struct.unpack_from(f'<{n}Q', r.b, r.o); r.o += 8 * n
    groups = [r.take('<IIII') for _ in range(r.take('<I'))]
    k = r.take('<I'); idx = struct.unpack_from(f'<{k}I', r.b, r.o); r.o += 4 * k
    if r.o != len(r.b) or n != nsh or len(gids) != len(groups): raise ValueError(f'{toc.path}: shader library chunk {i} does not parse')
    code = [None] * n
    for g, (gid, (first, cnt, raw, stored)) in enumerate(zip(gids, groups)):
        at = next((t for t in (pool or (toc,)) if gid in t.index), None)
        if at is None: raise ValueError(f'{toc.path}: shader group {g} has no chunk (in none of the {len(pool) or 1} containers)')
        d = at.read(at.index[gid], decode)
        if len(d) != stored: raise ValueError(f'{toc.path}: shader group {g} is {len(d)} bytes, its entry says {stored}')
        if stored < raw: d = decode(d, raw)
        mine = sorted(((ents[s] >> 34, s) for s in idx[first:first + cnt]))
        for (at, s), (nxt, _) in zip(mine, mine[1:] + [(raw, None)]):
            if (ents[s] >> 4) & 0x3FFFFFFF != g: raise ValueError(f'{toc.path}: shader {s} is listed in group {g} but names another')
            code[s] = d[at:nxt]
    if any(c is None for c in code): raise ValueError(f'{toc.path}: {sum(c is None for c in code)} shaders in no group')
    out, off = bytearray(struct.pack('<II', ARCHIVE_VERSION, len(maph) // 20) + maph + struct.pack('<I', n) + shh + struct.pack('<I', len(maps))), 0
    for a, c in maps: out += struct.pack('<IIII', a, c, 0, 0)
    out += struct.pack('<I', n)
    for e, c in zip(ents, code): out += struct.pack('<QIIB', off, len(c), len(c), e & 0xF); off += len(c)
    out += struct.pack('<I', 0) + struct.pack(f'<I{len(idx)}I', len(idx), *idx)
    return bytes(out) + b''.join(code)

def io_shader_tocs(romfs):
    """The IoStore containers under the RomFS that hold Unreal Engine 5 shader libraries"""
    out = []
    for dp, _, fs in romfs_list.walk(romfs):
        for f in fs:
            if not f.endswith('.utoc'): continue
            try:
                if Toc(os.path.join(dp, f), b'\0' * 32).of_type(IO_SHADER_LIBRARY): out.append(os.path.join(dp, f))
            except (OSError, ValueError, struct.error): pass
    return sorted(out)

def archive_names(romfs):
    """The shader code archive names ("ShaderArchive-<library>-<format>") the RomFS's manifests list (Unreal's Manifest_UFSFiles_<platform>.txt)"""
    import re
    names = set()
    for f in romfs_list.listdir(romfs):
        if f.startswith('Manifest_') and f.endswith('.txt'):
            names |= set(re.findall(r'(ShaderArchive-[\w-]+?)\.ushaderbytecode', romfs_list.read_file(os.path.join(romfs, f)).decode('utf-8', errors='replace')))
    return sorted(names)

def paks(romfs):
    """Every pak under the RomFS"""
    return sorted(os.path.join(dp, f) for dp, _, fs in romfs_list.walk(romfs) for f in fs if f.endswith('.pak'))

def unreal_paks(romfs, legacy=None):
    """The paks under the RomFS that Unreal wrote (its magic in the footer; legacy None = any version, True = the legacy versions, False = the others): with version 11 the NSP script decodes
    the shader code archives (decode_ue_shaders); legacy paks keep the shaders inline in the cooked packages, which shader_split.py reads through the game's decoder (ue_legacy_jobs)"""
    out = []
    for p in paks(romfs):
        try:
            with romfs_list.open_file(p) as f: ver = pak_version(f)
        except (OSError, ValueError, struct.error): continue   # shorter than a footer, or no Unreal pak
        if legacy is None or (ver in LEGACY) == legacy: out.append(p)
    return out

def job(romfs, main_nso, work, decode=None):
    """The shader code archives of every pak under the RomFS into <work>/archives, and one Oodle job (<work>/oodle.job) of every compressed shader in them; <work>/job.json lists them.
    The shader libraries of IoStore containers (Unreal Engine 5.6, FINAL FANTASY RESONANCE: no archive in the pak) go there already decoded: their container blocks and shader groups are
    Oodle-compressed, two layers, so they need decode (OodleHost: the game's decoder over a pipe) rather than the job"""
    os.makedirs(os.path.join(work, 'archives'), exist_ok=True)
    img, lo, hi = nso_image(main_nso); listing, recs = [], []
    tocs = io_shader_tocs(romfs)
    if tocs and not decode: raise ValueError(f'{tocs[0]}: IoStore shader libraries need the game\'s decoder (decode)')
    names = archive_names(romfs)
    pool = []   # every container, highest priority first: a library's groups can sit in another container
    for tp in io_priority(os.path.join(dp, f) for dp, _, fs in romfs_list.walk(romfs) for f in fs if f.endswith('.utoc')):
        try: pool.append(Toc(tp))
        except (OSError, ValueError, struct.error): pass
    done = set()
    for t in [o for o in pool if o.path in tocs]:
        tp = t.path
        for i in t.of_type(IO_SHADER_LIBRARY):
            if t.ids[i] in done: continue   # a higher-priority container (the patch) has this library
            done.add(t.ids[i])
            name = io_library_name(t, i, names) + '.ushaderbytecode'; b = io_archive(t, i, decode, pool)
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            listing.append(dict(name=name, pak=os.path.relpath(tp, romfs), path=f'chunk {t.ids[i].hex()}', shaders=len(archive(b)['shaders']), compressed=0, compression='IoStore, decoded'))
    for pak in unreal_paks(romfs, legacy=False):
        p = Pak(pak, images=[img])   # 索引加密时按 SHA-1 在 main 里找密钥（pak_crypto，进程内缓存）
        for path in sorted(x for x in p.files if x.endswith('.ushaderbytecode')):
            b = p.read(path); a = archive(b); name = os.path.basename(path)
            comp = [i for i, (_, size, raw, _) in enumerate(a['shaders']) if size != raw]
            raws = lz4_shaders(b, a)
            if comp and raws: b = decoded_archive(b, raws); comp, how = [], 'LZ4'   # decoded here: the Oodle job gets none of them
            else: how = 'Oodle' if comp else ''
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            for i in comp:
                off, size, raw, _ = a['shaders'][i]; recs.append((name, i, b[a['code'] + off:a['code'] + off + size], raw))
            listing.append(dict(name=name, pak=os.path.relpath(pak, romfs), path=path, shaders=len(a['shaders']), compressed=len(comp), compression=how))
    with open(os.path.join(work, 'oodle.job'), 'wb') as f:
        f.write(struct.pack('<II', JOB_MAGIC, len(recs)))
        for _, _, c, raw in recs: f.write(struct.pack('<II', len(c), raw)); f.write(c)
    json.dump(dict(archives=listing, records=[(n, i) for n, i, _, _ in recs]), open(os.path.join(work, 'job.json'), 'w'), indent=1)
    return listing, len(recs)

def finish(work, out):
    """The decoded archives into out, from <work>/oodle.job.out (the host's results, in job order)"""
    meta = json.load(open(os.path.join(work, 'job.json')))
    b = open(os.path.join(work, 'oodle.job.out'), 'rb').read() if meta['records'] else struct.pack('<II', OUT_MAGIC, 0)   # no Oodle shader: no host run
    magic, n = struct.unpack_from('<II', b)
    if magic != OUT_MAGIC or n != len(meta['records']): raise ValueError('the job output does not match the job')
    o, dec = 8, {}
    for name, i in meta['records']:
        l = struct.unpack_from('<I', b, o)[0]; o += 4
        if not l: raise ValueError(f'{name}: shader {i} was not decoded')
        dec[(name, i)] = b[o:o + l]; o += l
    os.makedirs(out, exist_ok=True)
    for x in meta['archives']:
        src = open(os.path.join(work, 'archives', x['name']), 'rb').read(); a = archive(src)
        raws = [dec.get((x['name'], i)) or src[a['code'] + off:a['code'] + off + size] for i, (off, size, _, _) in enumerate(a['shaders'])]
        tmp = os.path.join(out, x['name'] + '.partial'); open(tmp, 'wb').write(decoded_archive(src, raws)); os.replace(tmp, os.path.join(out, x['name']))
    return [x['name'] for x in meta['archives']]

def lslg(s):
    """A decoded Switch shader (LSLG): 'LSLG', a stage tag (SV vertex, SP pixel, SC compute, ...), a header with the shader's source name, then u32 code length, the code area,
    u32 control length and the control section (0x880 bytes), and a short tail (24 or 29 bytes). → (tag, control section, code area), or None if the layout differs"""
    if s[:4] != b'LSLG': return None
    k = s.find(b'\x34\x12\x76\x98')
    if k < 8 or k + 0x708 > len(s): return None   # the code length sits at control + 0x704: a shorter candidate is not this layout (Borderlands 3: 428-byte stream)
    nctl, ncode = struct.unpack_from('<I', s, k - 4)[0], struct.unpack_from('<I', s, k + 0x704)[0]
    c = k - 4 - ncode
    # 代码区为空不是着色器（11-01 无主之地3 Geranium.pak：Oodle 流的字面量里有 LSLG 与一段控制段，代码长字段 0，裸 LSLG 路径把它认成一支空代码的像素着色器、校验报红）
    if ncode == 0 or c < 4 or struct.unpack_from('<I', s, c - 4)[0] != ncode or k + nctl > len(s): return None
    return s[4:6].decode('latin1'), s[k:k + nctl], s[c:c + ncode]

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'list':
        img, lo, hi = nso_image(sys.argv[3])
        p = Pak(sys.argv[2], images=[img])
        with open(sys.argv[4], 'w') as f:
            f.write('path\traw\tstored\tmethod\tencrypted\tblocks\n')
            for path in sorted(p.files):
                e = p.entry(path); f.write(f"{path}\t{e['raw']}\t{e['size']}\t{e['method'] or 'none'}\t{e['encrypted']}\t{len(e['blocks'])}\n")
        used = sorted({p.entry(x)['method'] for x in p.files} - {''})
        print(f'pak version {p.version}, mount {p.mount}, {len(p.files)} files, compression {used}')
    elif cmd == 'job':
        dec = OodleHost(*sys.argv[5:7]) if len(sys.argv) > 6 else None
        try: listing, n = job(*sys.argv[2:5], decode=dec)
        finally:
            if dec: dec.close()
        for x in listing: print(f"{x['name']}: {x['shaders']} shaders, {x['compressed']} compressed")
        print(f'{n} records in {os.path.join(sys.argv[4], "oodle.job")}')
    elif cmd == 'finish':
        print('decoded:', ', '.join(finish(*sys.argv[2:4])))
    else: sys.exit(__doc__ or 'usage: uepak.py list | job | finish (see the header)')
