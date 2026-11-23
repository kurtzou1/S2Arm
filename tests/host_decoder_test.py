#!/usr/bin/env python3
"""pack/orch/host_decoder.py（要不要游戏自带解码器 Oodle / LZ5）单测：python3 tests/host_decoder_test.py
夹具按各格式公开布局手写最小文件头（不跑被测实现推期望），期望按头注判法手写：
  ① Unreal pak 版本 11、尾部方法名表有 Oodle → 要；同版本只有 Zlib → 不要
  ② Unreal pak 版本 4（旧版，方法在逐条目标志里）→ 要（11-05 勇者斗恶龙 XI S pakchunk0/1-Switch.pak 是版本 4）
  ③ IoStore .utoc 方法名表有 Oodle → 要；只有 Zlib → 不要
  ④ Trinity：data.trpfs（ONEPACK）+ data.trpfd → 要；只有 .trpfs 没有 .trpfd → 不要
  ⑤ PKZ 一个 OodleKraken 成员 → 要；只有 None 成员 → 不要
  ⑨ HGPAK（无人深空）：压缩档案、末块存储长 ≠ 原长 0x80 也 ≠ 0x20000 → 要；末块存储长 = 原长（原样存）→ 不要；不压缩的档案 → 不要
  ⑩ id Tech 资源包（IDCL 12）：着色器条目压缩方式 2 → 要；着色器条目不压缩 → 不要；压缩的是非着色器条目 → 不要
  ⑥ 追加内容目录里的也算；空目录 / 不存在的目录 → 不要
  ⑦ 本模块的 ONEPACK = shader_split.py 的 ONEPACK（同一魔数两处，钉住不漂）
  ⑧ Windows 一键出包：解包后要游戏解码器 → 编 gamedec、设 DM_OODLE_HOST / DM_OODLE_MODULES 往下走；gamedec 编不出 → 退 75、之后不起轻阶段（oneclick_win.host_decoder_gate）
  ⑪ uepak.oodle_host_find：宿主是 gamedec 时模块目录认 exefs/main；Mac 宿主照旧要 main.fixups.tsv
  ⑫ Windows 一键出包的运行时 GLSLC 门（oneclick_win.glslc_need / glslc_gate；11-05 普查 c1105_r4 GRID Autosport 跑到直连库才报「没有 Mac 宿主」rc=1）：
     替身判据（同 glslc_offline 主流程）——需要且认出源码 → 要；需要但认不出源码（运行时现编）→ 不要；不需要 → 不要（且不去找源码）。
     门：要 → 不退回 Mac、照常往下并置 S2A_GLSLC_RUNTIME_ONLY=1（11-08 DQB2：跳过出包期离线编，运行时现编）、计时表最后一步是「判运行时 GLSLC」；不要 → 照常往下、不置；设了 DM_GLSLC_HOST → 不判、照常往下"""
import os, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
os.environ['S2A_ROMFS_WALK'] = 'off'
from pack.orch import host_decoder, oneclick_win   # noqa: E402

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

MAGIC = 0x5A6F12E1   # Unreal pak 尾部魔数
def pak_v11(methods):   # 版本 ≥ 8 的尾部（0xcd 字节）：加密 u8、魔数、版本、索引偏移 / 长、SHA-1 20、5 个方法名各 32 字节
    names = b''.join(m.encode().ljust(32, b'\0') for m in methods + [''] * (5 - len(methods)))
    return b'\0' * 64 + b'\0' + struct.pack('<IIQQ', MAGIC, 11, 0, 0) + b'\0' * 20 + names
def pak_v4():   # 旧版尾部（0x2d 字节）：加密 u8、魔数、版本、索引偏移 / 长、SHA-1
    return b'\0' * 64 + b'\0' + struct.pack('<IIQQ', MAGIC, 4, 0, 0) + b'\0' * 20
def utoc(methods):   # FIoStoreTocHeader 144 字节（版本 3：没有种子 / 溢出表），0 个条目、0 个块，之后是方法名表（每名 32 字节）
    h = bytearray(144); h[:16] = b'-==--==--==--==-'; h[16] = 3
    struct.pack_into('<9I', h, 20, 144, 0, 0, 12, len(methods), 32, 65536, 0, 1)
    return bytes(h) + b''.join(m.encode().ljust(32, b'\0') for m in methods)
def pkz_file(methods):   # 头 32 字节：pkzl、u64 文件长、u32 条目数 / 索引偏移 / 名字表长；每条 32 字节（名偏移、方法名偏移、原长、偏移、存储长）
    names = b''; off = {}
    for s in ['a', *methods]:
        if s not in off: off[s] = len(names); names += s.encode() + b'\0'
    n = len(methods); table = 32; data_at = table + 32 * n + len(names)
    rows = b''.join(struct.pack('<IIQQQ', off['a'], off[m], 4, data_at, 4) for m in methods)
    body = rows + names + b'DATA'
    return b'pkzl' + b'\0' * 4 + struct.pack('<Q', 32 + len(body)) + struct.pack('<III', n, table, len(names)) + b'\0' * 4 + body

CH = 0x20000
def hgpak_file(csz, comp=1):   # 头：HGPAK 魔数、u64 版本 2 / 文件数 / 块数 / 压缩 / 数据起点 D；1 个文件 {16 字节哈希, 偏移 D, 长 CH + 0x80}；块存储长表；块按 16 对齐接在 D 后
    n, c = 1, len(csz) if comp else 0; D = (0x30 + 32 * n + 8 * c + 15) & ~15
    h = b'HGPAK\0\0\0' + struct.pack('<5Q', 2, n, c, comp, D) + struct.pack('<16sQQ', b'h' * 16, D, CH + 0x80) + (struct.pack(f'<{c}Q', *csz) if comp else b'')
    h = h.ljust(D, b'\0'); body = b''.join(b'z' * ((s + 15) & ~15) for s in csz) if comp else b'z' * (CH + 0x80)
    return h + body
def idcl_file(kind, how):   # 头 0x80：IDCL 12；+0x20 条目数 1 / 依赖 0 / 依赖索引 0 / 字符串索引 2；+0x38 字符串表长、偏移 0x80、依赖 0、条目 0xC0、特殊 0、依赖索引 0xB0、数据 0x150
    strs = kind.encode() + b'\0x\0'
    h = bytearray(0x80); h[:8] = b'IDCL' + struct.pack('<I', 12)
    struct.pack_into('<4I', h, 0x20, 1, 0, 0, 2); struct.pack_into('<7Q', h, 0x38, len(strs), 0x80, 0, 0xC0, 0, 0xB0, 0x150)
    st = struct.pack('<QQQ', 2, 0, len(kind) + 1) + strs
    e = bytearray(0x90); struct.pack_into('<Q', e, 0x20, 0); struct.pack_into('<3Q', e, 0x38, 0x150, 4, 8); e[0x70] = how
    return bytes(h) + st.ljust(0x30, b'\0') + struct.pack('<QQ', 0, 1) + bytes(e) + b'DATA'

def case(files, aoc=None):
    with tempfile.TemporaryDirectory() as t:
        for rel, b in files.items(): p = Path(t, 'romfs', rel); p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b)
        for rel, b in (aoc or {}).items(): p = Path(t, 'aoc', '0', rel); p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b)
        Path(t, 'romfs').mkdir(exist_ok=True)
        return len(host_decoder.need([str(Path(t, 'romfs')), str(Path(t, 'aoc', '0')), str(Path(t, 'nope'))]))

chk('① pak 版本 11 有 Oodle → 要', 1, case({'Game/Paks/a.pak': pak_v11(['Oodle'])}))
chk('① pak 版本 11 只有 Zlib → 不要', 0, case({'Game/Paks/a.pak': pak_v11(['Zlib'])}))
chk('② 旧版 pak 版本 4 → 要', 2, case({'J/Paks/pakchunk0-Switch.pak': pak_v4(), 'J/Paks/pakchunk1-Switch.pak': pak_v4()}))
chk('③ .utoc 有 Oodle → 要', 1, case({'Game/Paks/g.utoc': utoc(['Zlib', 'Oodle'])}))
chk('③ .utoc 只有 Zlib → 不要', 0, case({'Game/Paks/g.utoc': utoc(['Zlib'])}))
chk('④ Trinity .trpfs + .trpfd → 要', 1, case({'arc/data.trpfs': b'ONEPACK\0' + b'\0' * 24, 'arc/data.trpfd': b'\0' * 32}))
chk('④ 只有 .trpfs 没有 .trpfd → 不要', 0, case({'arc/data.trpfs': b'ONEPACK\0' + b'\0' * 24}))
chk('⑤ PKZ 有 OodleKraken 成员 → 要', 1, case({'root_000.pkz': pkz_file(['OodleKraken', 'None'])}))
chk('⑤ PKZ 只有 None 成员 → 不要', 0, case({'root_000.pkz': pkz_file(['None'])}))
chk('⑨ HGPAK 末块存储长 0x40（≠ 原长 0x80、≠ 0x20000）→ 要', 1, case({'GAMEDATA/PCBANKS/NMSARC.Shaders.pak': hgpak_file([CH, 0x40])}))
chk('⑨ HGPAK 两块都原样存（0x20000 + 原长 0x80）→ 不要', 0, case({'GAMEDATA/PCBANKS/NMSARC.A.pak': hgpak_file([CH, 0x80])}))
chk('⑨ HGPAK 不压缩 → 不要', 0, case({'GAMEDATA/PCBANKS/NMSARC.B.pak': hgpak_file([], comp=0)}))
chk('⑩ IDCL 着色器条目 Oodle（2）→ 要', 1, case({'base/gameresources.resources': idcl_file('renderProgResource', 2)}))
chk('⑩ IDCL 着色器条目不压缩 → 不要', 0, case({'base/gameresources.resources': idcl_file('renderProgResource', 0)}))
chk('⑩ IDCL 压缩的是非着色器条目 → 不要', 0, case({'base/gameresources.resources': idcl_file('image', 2)}))
chk('⑥ 追加内容里的 Oodle pak 也算', 1, case({'x.bin': b'\0' * 40}, aoc={'Paks/dlc.pak': pak_v11(['Oodle'])}))
chk('⑥ 普通文件 / 空 RomFS → 不要', 0, case({'x.bin': b'\0' * 40, 'y.bntx': b'BNTX' + b'\0' * 60}))
import ast   # shader_split.py 导入时要 DM_GAME，不导入，按源码取常量
ss = ast.parse((R / 'translator/shader_split.py').read_text(encoding='utf-8'))
chk('⑦ ONEPACK 与 shader_split 同一魔数', [n.value.value for n in ss.body if isinstance(n, ast.Assign) and getattr(n.targets[0], 'id', '') == 'ONEPACK'], [host_decoder.ONEPACK])

with tempfile.TemporaryDirectory() as t:
    x = Path(t, 'extract'); (x / 'romfs/J/Paks').mkdir(parents=True); (x / 'romfs/J/Paks/p.pak').write_bytes(pak_v4())
    real = oneclick_win.gamedec
    def no_build(run): raise oneclick_win.Fail('gamedec_build.log：rc=1；编译错', 1)
    oneclick_win.gamedec = no_build; run = oneclick_win.Run(Path(t, 'out'))
    try: oneclick_win.host_decoder_gate(run, x); got = None
    except oneclick_win.Fail as e: got = (e.code, 'gamedec 编不出' in str(e))
    run.timing.close()
    chk('⑧ 一键出包：要游戏解码器、gamedec 编不出 → 退 75、点名原因', (75, True), got)
    chk('⑧ 计时表最后一步是「编游戏解码器」（之后不再起步骤）', '编游戏解码器', Path(t, 'out', 'timing.tsv').read_text(encoding='utf-8').splitlines()[-1].split('\t')[0])
    exe = Path(t, 'bin/gamedec_x/gamedec.exe')
    oneclick_win.gamedec = lambda run: exe; run = oneclick_win.Run(Path(t, 'out1'))
    for k in ('DM_OODLE_HOST', 'DM_OODLE_MODULES'): os.environ.pop(k, None)
    try: oneclick_win.host_decoder_gate(run, x); got = 'ok'
    except oneclick_win.Fail as e: got = e.code
    run.timing.close()
    chk('⑧ 要游戏解码器、gamedec 编得出 → 照常往下，DM_OODLE_HOST = gamedec、DM_OODLE_MODULES = 解包目录', ('ok', str(exe), str(x)), (got, os.environ.get('DM_OODLE_HOST'), os.environ.get('DM_OODLE_MODULES')))
    for k in ('DM_OODLE_HOST', 'DM_OODLE_MODULES'): os.environ.pop(k, None)
    oneclick_win.gamedec = real
    (x / 'romfs/J/Paks/p.pak').unlink(); run = oneclick_win.Run(Path(t, 'out2'))
    try: oneclick_win.host_decoder_gate(run, x); got = 'ok'
    except oneclick_win.Fail as e: got = e.code
    run.timing.close()
    chk('⑧ 不要游戏解码器 → 照常往下、不设 DM_OODLE_HOST', ('ok', None), (got, os.environ.get('DM_OODLE_HOST')))
    import uepak
    (x / 'exefs').mkdir(); (x / 'exefs/main').write_bytes(b'NSO0'); exe.parent.mkdir(parents=True); exe.write_bytes(b'')
    os.environ['DM_OODLE_HOST'] = str(exe)
    chk('⑪ oodle_host_find：宿主是 gamedec 时模块目录认 exefs/main（不要 main.fixups.tsv）', ((str(exe), str(x)), ''), uepak.oodle_host_find(str(x / 'romfs')))
    os.environ['DM_OODLE_HOST'] = str(Path(t, 'bin/s2arm-host')); Path(t, 'bin/s2arm-host').write_bytes(b'')
    chk('⑪ oodle_host_find：Mac 宿主照旧要 main.fixups.tsv', True, uepak.oodle_host_find(str(x / 'romfs'))[0] is None)
    del os.environ['DM_OODLE_HOST']
    # ⑭ 宿主先退（D-66PR 等：Windows 往已关的管道写 / 冲缓冲报 EINVAL [Errno 22]，POSIX 报 BrokenPipe）：收尾不抛、私有目录照删；
    #   解码报「宿主解码失败 + 宿主输出」而不是裸 OSError。替身管道按 Windows 的报法抛 OSError(22)
    import tempfile as _tf
    class DeadPipe:
        def write(self, b): raise OSError(22, 'Invalid argument')
        def flush(self): raise OSError(22, 'Invalid argument')
        def close(self): raise OSError(22, 'Invalid argument')
    class Proc:
        def __init__(self): self.stdin, self.waited, self.killed = DeadPipe(), False, False
        def poll(self): return None
        def wait(self, t): self.waited = True
        def kill(self): self.killed = True
    proc, priv = Proc(), _tf.mkdtemp(prefix='oodle-host-test-')
    try: uepak.OodleHost._close(proc, priv); got = 'ok'
    except OSError as e: got = f'OSError {e.errno}'
    chk('⑭ 宿主已退时收尾：不抛 / 仍等进程 / 私有目录删掉', ('ok', True, False), (got, proc.waited, os.path.isdir(priv)))
    h = uepak.OodleHost.__new__(uepak.OodleHost); h.p, h.err, h.n = Proc(), _tf.TemporaryFile(), 0
    h.err.write('宿主最后一行：模块加载失败'.encode()); h.err.flush()
    try: h.decode(b'x' * 16, 64); got = 'ok'
    except ValueError as e: got = ('ValueError', 'failed on a 16 → 64 byte stream' in str(e), '宿主最后一行' in str(e))
    except OSError as e: got = f'OSError {e.errno}'
    chk('⑭ 宿主已退时解码：报解码失败并带宿主输出（不是裸 OSError）', ('ValueError', True, True), got)
    h.err.close()

class FakeG:   # glslc_offline 替身：need() / all_sources() 的答案由夹具给，记下 all_sources 被调过没有
    def __init__(self, mod, srcs): self.mod, self.srcs, self.asked = mod, srcs, False
    class nso_syms:
        @staticmethod
        def load(p): return b'img:' + os.path.basename(p).encode()
    @staticmethod
    def romfs_nros(root): return []
    def need(self, exefs, img, nros): return (self.mod, '' if self.mod else '夹具：不需要')
    def all_sources(self, img, nros): self.asked = True; return self.srcs

with tempfile.TemporaryDirectory() as t:
    x = Path(t, 'extract'); (x / 'exefs').mkdir(parents=True); (x / 'exefs/main').write_bytes(b'NSO0')
    g = FakeG('subsdk1', [('main@0x10', b'#version 450\n'), ('main@0x90', b'#version 450\n')])
    chk('⑫ 判据：需要且认出 2 支源码 → 要（点名模块与支数）', True, (oneclick_win.glslc_need(x, g) or '').startswith('subsdk1 带 glslcCompile') and '2 支' in oneclick_win.glslc_need(x, g))
    chk('⑫ 判据：需要但认不出源码（运行时现编）→ 不要', None, oneclick_win.glslc_need(x, FakeG('subsdk1', [])))
    g0 = FakeG(None, [('main@0x10', b'#version 450\n')])
    chk('⑫ 判据：不需要 → 不要、不去找源码', (None, False), (oneclick_win.glslc_need(x, g0), g0.asked))
    real = oneclick_win.glslc_need
    def gate(answer, host=None, out='o'):
        oneclick_win.glslc_need = lambda xx: answer; os.environ.pop('DM_GLSLC_HOST', None); os.environ.pop('S2A_GLSLC_RUNTIME_ONLY', None)
        if host: os.environ['DM_GLSLC_HOST'] = host
        run = oneclick_win.Run(Path(t, out))
        try: oneclick_win.glslc_gate(run, x); got = 'ok'
        except oneclick_win.Fail as e: got = (e.code, '交回 Mac' in str(e))
        got = (got, os.environ.pop('S2A_GLSLC_RUNTIME_ONLY', None))
        run.timing.close(); os.environ.pop('DM_GLSLC_HOST', None)
        tm = Path(t, out, 'timing.tsv').read_text(encoding='utf-8').splitlines()
        return got, (tm[-1].split('\t')[0] if tm else '')
    chk('⑫ 门：要 → 照常往下、置运行时现编、计时表最后一步是「判运行时 GLSLC」', (('ok', '1'), '判运行时 GLSLC'), gate('subsdk1 带 glslcCompile，认出 5 支', out='g1'))
    chk('⑫ 门：不要 → 照常往下、不置', (('ok', None), '判运行时 GLSLC'), gate(None, out='g2'))
    chk('⑫ 门：设了 DM_GLSLC_HOST → 不判、照常往下、不置', (('ok', None), ''), gate('要', host=str(Path(t, 's2arm-host')), out='g3'))
    oneclick_win.glslc_need = real

# Mac 刷新与抽取共用的保守容器判据：Trinity 必须先等改写产物，不能只在 Windows 的精确判据里识别。
with tempfile.TemporaryDirectory(prefix='decoder need ') as t:
    romfs = Path(t, 'romfs with spaces', 'nested'); romfs.mkdir(parents=True)
    def mac_decoder_need():
        return subprocess.run(['bash', '-c', 'source "$1/pack/decoder_need.sh"; decoder_need "$1" "$2"',
                               'decoder-test', str(R), str(romfs.parent)],
                              env=dict(os.environ, PY=sys.executable), capture_output=True, text=True).returncode
    for name in ('data.trpfs', 'DATA.TRPFS', 'archive.pak', 'archive.pkz', 'archive.utoc', 'gameresources.resources'):
        entry = romfs / name; entry.touch()
        chk(f'⑬ Mac 容器判据：{name} → 要解码器 / 等改写', 0, mac_decoder_need())
        entry.unlink()
    for name in ('data.trpfd', 'ordinary.bin'):
        entry = romfs / name; entry.touch()
        chk(f'⑬ Mac 容器判据：只有 {name} → 不要', 1, mac_decoder_need())
        entry.unlink()

print(f'{"✓" if not bad else "✗"} host_decoder：{bad} 不通')
sys.exit(1 if bad else 0)
