#!/usr/bin/env python3
"""外部公开着色器 / 管线清单 → 我方管线种子目录（tools/patch_pack.py 第三参，进社区统一包 g/<程序号>，玩家出包时管线种子阶段当来源）。
用法：ext_pso_collect.py <镜像根> <种子目录> [--sources tools/ext_pso_sources.tsv]
  镜像根下每个来源一个本地检出（目录名 = 来源名字，调用方先 git pull）；来源与许可见 tools/ext_pso_sources.tsv，NOTICE「着色器清单数据」同步署名。
为什么：别的项目公开了按款录的预建清单（同一种键：sha256(控制段 + 代码)，graphics/tools/direct/pso_seed.py 同口径），我方没跑过的场景也能在首局加载时后台预建。
收什么：S（着色器键）/ C（计算着色器键）原样（mng 的完整哈希键取前 16 位，同一种键）；R（渲染管线，pso_skey 十六进制）与我方等长的原样，
  别的长度按对方结构版本转（conv_nx / conv_mng；用我方众包种子验过命中 91–99%），转不了的按字段写原因计数；其余行类（如 V）不收、按类计数。别的游戏版本的键不在这里滤：出包时 pso_seed.py 按本包直连库的键滤。
输出：<种子目录>/<程序号>/ext_<名字>.tsv，首行「# source: repo= commit= license= author= path=」（patch_pack.seed_source 读，致谢与追溯），行序同上游、去重；
  内容没变不重写（社区包同输入同字节）；这个来源里已没有的款，删掉它的 ext_<名字>.tsv（只删本工具写的这一种文件名）。最后一行一句读数，按来源分。"""
import argparse, collections, json, os, re, struct, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(r'[0-9a-f]{16}(_b)?$')
TID = re.compile(r'0[0-9A-F]{15}$')
FULL = re.compile(r'[0-9a-f]{64}-[0-9a-f]+_b$')   # mng 的 S / C 键：完整 sha256(控制段 + 代码) + 「-<翻译链号>_b」


# ---- R 行转换（cmdr 侧映射规格 11-19：nxnative 各结构版本 / MacNativeGames 544 字节结构 → 我方 432 字节 pso_skey，偏移由 clang offsetof 核过）----
#   转出的必须与设备对同一管线算出的键逐字节相同：只做不靠着色器反射的那部分规范化（同 nvn_mtl.m pso_key_norm）+ 高级混合位清零（同 pso_key_fill）
LAY = json.load(open(ROOT / 'graphics/tools/direct/pso_layout.json', encoding='utf-8'))
INTF = set(LAY['uint_formats']) | set(LAY['sint_formats'])
K = 88                                                   # pso_key 在 pso_skey 里的偏移（vs[24] fs[24] 4 个 u8 fz_desc[34] + 2 填充）
CFMT, BLEN, CHMASK, A2C, FC = K + 16, K + 60, K + 64, K + 68, K + 69
BLEND, ATTR, STREAM, MERGED = K + 72, K + 136, K + 200, 50
assert (CFMT, BLEN, BLEND, MERGED) == (LAY['cfmt'], LAY['blend_en'], LAY['blend0'], LAY['merged']) and LAY['skey_size'] == 432, '我方 pso_skey 布局变了：按 nvn_pso_skey.h 重核本段偏移'
ADV = ((1 << 64) - 1) ^ ((1 << 37) - 1)                  # blend_st 第 37–47 位：高级混合（我方进键前清零）
u32 = lambda b, o: struct.unpack_from('<I', b, o)[0]


def norm(b):
    b = bytearray(b)
    if b[MERGED]: return bytes(b)
    blen, chm = u32(b, BLEN), u32(b, CHMASK)
    for i in range(8):
        cf = u32(b, CFMT + 4 * i); o = BLEND + 8 * i
        if not cf: chm &= ~(0xf << (4 * i)); blen &= ~(1 << i); b[o:o + 8] = bytes(8); continue
        if not (blen >> i & 1) or cf in INTF: blen &= ~(1 << i); b[o:o + 8] = bytes(8); continue
        struct.pack_into('<Q', b, o, struct.unpack_from('<Q', b, o)[0] & ~0x7 & ~ADV)
    struct.pack_into('<I', b, BLEN, blen); struct.pack_into('<I', b, CHMASK, chm)
    return bytes(b)


def conv_nx(hx):
    """nxnative R（864 / 880 / 1008 / 1024 位）→ (我方 864 位 | None, 不收原因)。前 432 字节与我方同序；432 起依次 atest、logic（880 起）、高 16 个顶点属性（1008 起）、border（1024）"""
    # 单条不合法只跳这一条、计数（11-20：上游两份清单各有一条 841 位的 R 行，截断丢了一位，fromhex 抛错让整份收集退出、种子停更）
    if not re.fullmatch(r'(?:[0-9a-f]{2})+', hx): return None, f'nxnative 不是整字节十六进制（{len(hx)} 位）'
    raw = bytes.fromhex(hx); n = len(raw)
    if n < 432 or n not in (432, 440, 504, 512): return None, f'nxnative 未知结构（{n} 字节）'
    if u32(raw, A2C) > 1: return None, 'a2c 非 0 / 1（会落进我方 fc / at / msoff）'
    if n >= 440 and u32(raw, 432): return None, 'alpha 测试开（我方键存比较函数 1..7，对方只记开关）'
    b = bytearray(raw[:432])
    if n >= 504 and raw[440:504] != bytes(64):           # 高 16 个属性我方不进键；它们独占的流也不进
        used = {u32(b, ATTR + 4 * a) >> 27 for a in range(16) if u32(b, ATTR + 4 * a)}
        for s in range(16):
            if s not in used: b[STREAM + 8 * s:STREAM + 8 * s + 8] = bytes(8)
    return norm(bytes(b)).hex(), None                    # logic / border：我方不进键，丢


PACKED = re.compile(r'^([0-9a-f_-]{0,80}):([0-9a-f_-]{0,80}):((?:[0-9a-f]{2}|z[0-9a-f]+\.)*)$')   # MacNativeGames 压缩写法（连续零写 z<个数>.）
VAR = re.compile(r'^([0-9a-f]{64})(?:-[0-9a-f]{12})?_b$')


def conv_mng(text):
    """MacNativeGames R（明文 1088 位或压缩写法；544 字节：vs[80] fs[80] 头 40 字节 pso_key 344 字节）→ (我方 864 位 | None, 不收原因)"""
    m = PACKED.match(text)
    if m:
        vs, fs, rest = m.groups()
        text = vs.encode().hex().ljust(160, '0') + fs.encode().hex().ljust(160, '0') + re.sub(r'z([0-9a-f]+)\.', lambda z: '00' * int(z.group(1), 16), rest)
    if len(text) != 1088 or not re.fullmatch(r'[0-9a-f]+', text): return None, 'MacNativeGames 结构长度不对'
    raw = bytes.fromhex(text); names = []
    for o in (0, 80):
        nm = raw[o:o + 80].split(b'\0')[0].decode('latin1'); v = VAR.match(nm)
        if nm and not v: return None, 'MacNativeGames 着色器名认不得'
        names.append((v.group(1)[:16] + '_b').encode().ljust(24, b'\0') if nm else bytes(24))
    a2c = u32(raw, 200 + 68)
    if a2c & 0xc0: return None, 'a2c 主机函数位（对方 VR / 合成用，我方没有）'
    if a2c & 0x0c: return None, 'a2c MetalFX 拷贝位（对方自加附件上的超分管线，我方没有）'
    out = bytearray(432); out[0:24], out[24:48] = names; out[48:88] = raw[160:200]; out[88:432] = raw[200:544]
    out[A2C:A2C + 4] = bytes([a2c & 1, 0, 0, 0])          # 分层 / 顶点边框 / HDR 位：我方不进键
    return norm(bytes(out)).hex(), None


def sources(path):
    src, maps = [], collections.defaultdict(dict)
    for line in open(path, encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if f[0] == '来源' and len(f) == 5: src.append(dict(name=f[1], repo=f[2], license=f[3], fmt=f[4]))
        elif f[0] == '映射' and len(f) == 4: maps[f[1]][f[2]] = f[3].upper()
    return src, maps


GAME = re.compile(r'(?:^|\s)game=(0[0-9A-Fa-f]{15})(?:\s|$)')   # 首行带程序号的清单（hermit 的 shared shader list：「# … game=<程序号> engine=…」）


def nx_files(mirror):
    """nxnative 格式的清单在仓库里任意位置都认（11-20：MacNativeGames 的 games/*/runtime/games/<程序号>/、hermit 的 games/<名>/shader_list[-<构建>].tsv、
    各分叉与派生仓库各放各的）：「<程序号>/pso_manifest.tsv」，或首行写着 game=<程序号> 的 .tsv。→ [(程序号, 上游相对路径, 文件, 'nxnative')]"""
    out = []
    for p in sorted(mirror.rglob('*.tsv')):
        rel = p.relative_to(mirror)
        if rel.parts[0] == '.git' or not p.is_file(): continue
        if p.name == 'pso_manifest.tsv' and TID.match(p.parent.name.upper()): out.append((p.parent.name.upper(), str(rel), p, 'nxnative')); continue
        try:
            with open(p, encoding='utf-8', errors='replace') as fh: first = fh.readline(4096)
        except OSError: continue
        m = GAME.search(first) if first.startswith('#') else None
        if m: out.append((m.group(1).upper(), str(rel), p, 'nxnative'))
    return out


def files(mirror, s, maps):
    """→ [(程序号, 上游相对路径, 文件, 格式)]；同一款可有多份（调用方合并去重）"""
    if s['fmt'] == 'nxnative':
        return nx_files(mirror)
    if s['fmt'] == 'mng':   # assets 下的 mng 格式按映射表认目录；runtime 下的 nxnative 格式按路径里的程序号认
        out = [(tid, str((mirror / 'games' / d / 'assets/shader_list.tsv').relative_to(mirror)), mirror / 'games' / d / 'assets/shader_list.tsv', 'mng')
               for d, tid in sorted(maps[s['name']].items()) if (mirror / 'games' / d / 'assets/shader_list.tsv').is_file()]
        return out + nx_files(mirror)
    raise SystemExit(f'【红】来源 {s["name"]} 格式 {s["fmt"]} 认不得')


def rows(p, rlen, why, fmt, conv):
    seen, keep = set(), []
    for line in open(p, encoding='utf-8', errors='replace'):
        if not line.strip() or line.startswith('#'): continue
        f = line.rstrip('\n').split('\t'); k = f[0]
        if k in ('S', 'C') and len(f) >= 2 and FULL.match(f[1]): f[1] = f[1][:16] + '_b'   # mng：完整 sha256 + 翻译链号 → 我方键 = 同一 sha256 前 16 位（旷野之息实测 16/26 落在同版本键表里）
        if k == 'R' and len(f) >= 2 and len(f[1]) != rlen:   # 对方别的结构：按来源格式转
            hx, bad = (conv_mng if fmt == 'mng' else conv_nx)(f[1]) if re.fullmatch(r'[0-9a-f:z._-]+', f[1]) else (None, 'R 行不是十六进制')
            if bad: why[f'R 行（{bad}）'] += 1; continue
            f[1] = hx; conv['R'] += 1
        ok = (k in ('S', 'C') and len(f) >= 2 and KEY.match(f[1])) or (k == 'R' and len(f) >= 2 and len(f[1]) == rlen and re.fullmatch(r'[0-9a-f]+', f[1]))
        if not ok:
            why[f'{k} 行'] += 1; continue
        r = '\t'.join(f[:3] if k == 'S' else f[:2])
        if r not in seen: seen.add(r); keep.append(r)
    return keep


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('mirror_root', type=Path); ap.add_argument('seeds', type=Path)
    ap.add_argument('--sources', type=Path, default=ROOT / 'tools/ext_pso_sources.tsv')
    a = ap.parse_args()
    sk = subprocess.run([sys.executable, str(ROOT / 'graphics/tools/direct/pso_layout.py'), 'skey-size'], capture_output=True, text=True)
    if sk.returncode or not sk.stdout.strip().isdigit(): raise SystemExit(f'【红】量不出管线键字节数（pso_layout.py skey-size）：{sk.stderr.strip()[-200:]}')
    rlen = 2 * int(sk.stdout.strip())
    src, maps = sources(a.sources); notes = []
    # 跨来源去重（11-20）：按来源表先后，后面的来源只写前面没有的行——分叉 / 派生仓库多半整份带着上游的清单，只留它独有的那几行，
    #   云端包不重复存同一行，署名也只记在真正贡献这些行的来源名下
    before = collections.defaultdict(set)
    for s in src:
        mirror = a.mirror_root / s['name']
        head = subprocess.run(['git', '-C', str(mirror), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if head.returncode: notes.append(f'{s["name"]}：没有本地检出（{mirror}），跳过'); continue
        commit = head.stdout.strip()[:12]; why = collections.Counter(); conv = collections.Counter(); n = changed = 0; got = set()
        per = {}   # 程序号 → ([上游相对路径…], [行…])：同一款多份文件（hermit 按引擎 / 构建分份、MacNativeGames 两种路径）合成一份，按行去重、保留先后
        for tid, rel, p, fmt in files(mirror, s, maps):
            keep = rows(p, rlen, why, fmt, conv)
            if not keep: continue
            rels, acc = per.setdefault(tid, ([], []))
            rels.append(rel); have = set(acc); acc.extend(r for r in keep if r not in have)
        for tid, (rels, keep) in sorted(per.items()):
            keep = [r for r in keep if r not in before[tid]]
            if not keep: continue
            before[tid].update(keep)
            got.add(tid); n += len(keep)
            rel = rels[0] + (f'（另 {len(rels) - 1} 份同款合并）' if len(rels) > 1 else '')
            text = f'# source: repo={s["repo"]} commit={commit} license={s["license"]} author={s["name"]} path={rel}\n' \
                   f'# 外部公开清单（只有标识与管线描述）：tools/ext_pso_collect.py 生成，勿手改；出包时按本包直连库的键滤\n' + '\n'.join(keep) + '\n'
            out = a.seeds / tid / f'ext_{s["name"]}.tsv'
            if out.is_file() and out.read_text(encoding='utf-8') == text: continue
            out.parent.mkdir(parents=True, exist_ok=True); tmp = out.with_name(out.name + f'.{os.getpid()}.tmp')
            tmp.write_text(text, encoding='utf-8'); os.replace(tmp, out); changed += 1
        gone = [d for d in (a.seeds.iterdir() if a.seeds.is_dir() else []) if (d / f'ext_{s["name"]}.tsv').is_file() and d.name.upper() not in got]
        for d in gone: (d / f'ext_{s["name"]}.tsv').unlink()
        notes.append(f'{s["name"]}@{commit}：{len(got)} 款 {n} 行（其中 R 行转换收 {conv["R"]}；改写 {changed} 份、撤 {len(gone)} 份）' + (f'；不收 {dict(why)}' if why else ''))
    print('外部管线清单：' + '；'.join(notes))


if __name__ == '__main__':
    main()
