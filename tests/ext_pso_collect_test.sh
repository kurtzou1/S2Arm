#!/bin/bash
# 外部公开管线清单收集（tools/ext_pso_collect.py）+ 社区包署名（tools/patch_pack.py seed_source）单测：假镜像两种格式，期望全部手写
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/extpso.XXXXXX"); trap 'rm -rf "$T"' EXIT
python3 - "$R" "$T" <<'PY'
import gzip, json, os, re, subprocess, sys
from pathlib import Path
R, T = Path(sys.argv[1]), Path(sys.argv[2]); fails = 0
def ck(ok, what):
    global fails; print(('通 ' if ok else '不通 ') + what); fails += 0 if ok else 1
sk = int(subprocess.run([sys.executable, str(R / 'graphics/tools/direct/pso_layout.py'), 'skey-size'], capture_output=True, text=True).stdout)
r_ok, r_bad = 'R\t' + 'ab' * sk, 'R\t' + 'ab' * (sk + 8)
def repo(name, files):
    d = T / 'm' / name; d.mkdir(parents=True)
    for rel, text in files.items(): (d / rel).parent.mkdir(parents=True, exist_ok=True); (d / rel).write_text(text)
    for c in (['init', '-q'], ['add', '-A'], ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x']): subprocess.run(['git', '-C', str(d)] + c, check=True)
    return subprocess.run(['git', '-C', str(d), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()[:12]
full = 'e4b5b0967a3cd0b3' + 'f' * 48
c1 = repo('nx', {'dm/games/0100AAAA00000000/pso_manifest.tsv': f'# h\nS\t1111222233334444_b\t0\nS\t1111222233334444_b\t0\nC\t5555666677778888_b\n{r_ok}\n{r_bad}\nM\tx\t1\n',
                 'dm/games/notatitle/pso_manifest.tsv': 'S\t9999999999999999_b\t0\n'})
c2 = repo('mng', {'games/kirby/assets/shader_list.tsv': f'# h\nV\t{"a"*64}\t{{}}\nS\t{full}-b7530f698e76_b\t1\tt\nC\t{full}-b7530f698e76_b\tm\nR\t3536\n',
                  'games/other/assets/shader_list.tsv': f'S\t{full}-1_b\t0\tt\n'})
src = T / 'src.tsv'; src.write_text('来源\tnx\thttps://e.x/nx\tMIT\tnxnative\n来源\tmng\thttps://e.x/mng\tMIT\tmng\n映射\tmng\tkirby\t0100BBBB00000000\n')
seeds = T / 'seeds'; (seeds / '0100CCCC00000000').mkdir(parents=True); own = 'S\t0000000000000001_b\t0\n'; (seeds / '0100CCCC00000000/zc_crowd.tsv').write_text(own)
run = lambda: subprocess.run([sys.executable, str(R / 'tools/ext_pso_collect.py'), str(T / 'm'), str(seeds), '--sources', str(src)], capture_output=True, text=True)
o = run(); ck(o.returncode == 0, f'① 收集退出 0（{o.stdout.strip()[-160:]}{o.stderr.strip()[-200:]}）')
nx = (seeds / '0100AAAA00000000/ext_nx.tsv').read_text()
ck(nx == f'# source: repo=https://e.x/nx commit={c1} license=MIT author=nx path=dm/games/0100AAAA00000000/pso_manifest.tsv\n# 外部公开清单（只有标识与管线描述）：tools/ext_pso_collect.py 生成，勿手改；出包时按本包直连库的键滤\n'
          f'S\t1111222233334444_b\t0\nC\t5555666677778888_b\n{r_ok}\n', '② nxnative：首行来源、S 去重、C 与等长 R 原样、别的长度 R 与 M 行不收')
ck(not (seeds / 'NOTATITLE').exists() and not (seeds / 'notatitle').exists(), '③ 不是程序号的目录不收')
mg = (seeds / '0100BBBB00000000/ext_mng.tsv').read_text().split('\n')[2:]
ck(mg == ['S\te4b5b0967a3cd0b3_b\t1', 'C\te4b5b0967a3cd0b3_b', ''], f'④ mng：完整哈希键取前 16 位、V / 编码不同的 R 不收、没映射的目录不收（{mg}）')
ck((seeds / '0100CCCC00000000/zc_crowd.tsv').read_text() == own, '⑤ 我方种子文件不动')
t0 = (seeds / '0100AAAA00000000/ext_nx.tsv').stat().st_mtime_ns; o = run()
ck((seeds / '0100AAAA00000000/ext_nx.tsv').stat().st_mtime_ns == t0 and '改写 0 份' in o.stdout, '⑥ 再跑内容没变不重写')
sys.path.insert(0, str(R / 'tools')); import patch_pack
items = {r['path']: r for r in patch_pack.seed_rows(str(seeds))}
e = items.get('dm/games/0100AAAA00000000/pso_manifest.tsv', {}); m = items.get('0100CCCC00000000/zc_crowd.tsv', {})
ck((e.get('repo'), e.get('commit'), e.get('license'), e.get('author'), e.get('gids')) == ('https://e.x/nx', c1, 'MIT', 'nx', ['0100AAAA00000000']), '⑦ 社区包条目：外部清单署名取首行来源')
ck((m.get('repo'), m.get('commit'), m.get('author')) == ('S2Arm/pso-seeds', '', 'S2Arm'), '⑧ 我方种子署名不变')
(T / 'm/nx/dm/games/0100AAAA00000000/pso_manifest.tsv').unlink(); subprocess.run(['git', '-C', str(T / 'm/nx'), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'rm'], check=True)
o = run(); ck(not (seeds / '0100AAAA00000000/ext_nx.tsv').exists() and (seeds / '0100CCCC00000000/zc_crowd.tsv').exists() and '撤 1 份' in o.stdout, '⑨ 上游删了的款撤掉本工具写的文件、别的不动')
# ---- R 行转换（期望手算：按 nvn_pso_skey.h 偏移拼一条我方键，再按对方结构摆字节）----
import struct, importlib.util
spec = importlib.util.spec_from_file_location('epc', R / 'tools/ext_pso_collect.py'); epc = importlib.util.module_from_spec(spec); spec.loader.exec_module(epc)
ours = bytearray(432); ours[0:18] = b'1111222233334444_b'; ours[24:42] = b'5555666677778888_b'
struct.pack_into('<I', ours, 104, 70); struct.pack_into('<I', ours, 148, 1); struct.pack_into('<I', ours, 152, 0xf)   # cfmt[0] = 70（非整数格式）、blend_en 位 0、chmask
blend = (0x5 << 3) | (1 << 40) | 0x3                                                         # 因子位 + 高级混合位 40 + target 位
struct.pack_into('<Q', ours, 160, blend); want = bytearray(ours); struct.pack_into('<Q', want, 160, 0x5 << 3); want = bytes(want).hex()
h880 = bytes(ours) + struct.pack('<II', 0, 7)                                                # atest 0、logic 7（丢）
ck(epc.conv_nx(h880.hex()) == (want, None), '⑩ nxnative 880：取前 432 字节、清高级混合位与 target 位、logic 丢')
ck(epc.conv_nx((bytes(ours) + struct.pack('<II', 1, 0)).hex())[0] is None, '⑪ nxnative 880 alpha 测试开 → 不收')
ck(epc.conv_nx((bytes(ours) + bytes(8) + bytes(64) + struct.pack('<II', 1, 0)).hex()) == (want, None), '⑫ nxnative 1024：border 丢、其余同 880')
vs, fs = 'e4b5b0967a3cd0b3' + 'a' * 48 + '-b7530f698e76_b', '0123456789abcdef' + 'b' * 48 + '_b'
m = bytearray(544); m[0:len(vs)] = vs.encode(); m[80:80 + len(fs)] = fs.encode(); m[200:544] = ours[88:432]
w2 = bytearray(bytes.fromhex(want)); w2[0:24] = b'e4b5b0967a3cd0b3_b'.ljust(24, b'\0'); w2[24:48] = b'0123456789abcdef_b'.ljust(24, b'\0')
ck(epc.conv_mng(bytes(m).hex()) == (bytes(w2).hex(), None), '⑬ MacNativeGames 明文 1088：着色器名取 sha256 前 16 位 + _b、pso_key 照搬后规范化')
packed = vs + ':' + fs + ':' + re.sub('(00)+', lambda z: f'z{len(z.group(0)) // 2:x}.', bytes(m[160:544]).hex())
ck(epc.conv_mng(packed) == (bytes(w2).hex(), None), '⑭ MacNativeGames 压缩写法展开后同明文')
m2 = bytearray(m); struct.pack_into('<I', m2, 200 + 68, 0x4)
ck(epc.conv_mng(bytes(m2).hex())[0] is None, '⑮ MacNativeGames a2c MetalFX 位 → 不收')
# 11-20 更多上游：MacNativeGames 的 runtime 路径（nxnative 格式）、hermit 式首行 game= 的清单、同款多份合并。期望手写
d3 = T / 'm3'; srcs3 = T / 'src3.tsv'; seeds3 = T / 'seeds3'
def repo3(name, files):
    d = d3 / name; d.mkdir(parents=True)
    for rel, text in files.items(): (d / rel).parent.mkdir(parents=True, exist_ok=True); (d / rel).write_text(text)
    for c in (['init', '-q'], ['add', '-A'], ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x']): subprocess.run(['git', '-C', str(d)] + c, check=True)
repo3('mng', {'games/la/runtime/games/0100DDDD00000000/pso_manifest.tsv': 'S\t2222333344445555_b\t5\n'})
repo3('hm', {'games/one/shader_list.tsv': f'# shared shader list\tgame=0100EEEE00000000\tengine=x\nS\t3333444455556666_b\t1\n{r_ok}\n',
             'games/one/shader_list-1.0.1.tsv': f'# shared shader list\tgame=0100eeee00000000\tengine=y\n{r_ok}\nS\t7777888899990000_b\t0\n',
             'games/two/notes.tsv': 'S\t4444555566667777_b\t0\n'})
srcs3.write_text('来源\tmng\thttps://e.x/mng\tMIT\tmng\n来源\thm\thttps://e.x/hm\tMIT\tnxnative\n')
o = subprocess.run([sys.executable, str(R / 'tools/ext_pso_collect.py'), str(d3), str(seeds3), '--sources', str(srcs3)], capture_output=True, text=True)
rt = seeds3 / '0100DDDD00000000/ext_mng.tsv'
ck(o.returncode == 0 and rt.is_file() and rt.read_text().split('\n')[2:] == ['S\t2222333344445555_b\t5', ''] and 'path=games/la/runtime/games/0100DDDD00000000/pso_manifest.tsv' in rt.read_text(),
   f'⑯ MacNativeGames runtime 路径下的 nxnative 格式清单也收（{o.stdout.strip()[-120:]}{o.stderr.strip()[-160:]}）')
hm = seeds3 / '0100EEEE00000000/ext_hm.tsv'
hl = hm.read_text().split('\n') if hm.is_file() else []
ck(hl[2:] == [r_ok, 'S\t7777888899990000_b\t0', 'S\t3333444455556666_b\t1', ''] and 'path=games/one/shader_list-1.0.1.tsv（另 1 份同款合并）' in hl[0],
   f'⑰ 首行 game= 认程序号（大小写都认）、同款两份按路径序合成一份、行去重、首行注明合并（{hl[:1]}）')
ck(sorted(x.name for x in seeds3.iterdir()) == ['0100DDDD00000000', '0100EEEE00000000'], '⑱ 首行没有 game=、也不在程序号目录下的 .tsv 不收')
# 跨来源去重：上游 up 与分叉 fk 同款，fk 只多一行 → fk 的文件只有那一行；fk 与上游完全相同的款不出文件。期望手写
d4 = T / 'm4'; s4 = T / 'seeds4'
def repo4(name, files):
    d = d4 / name; d.mkdir(parents=True)
    for rel, text in files.items(): (d / rel).parent.mkdir(parents=True, exist_ok=True); (d / rel).write_text(text)
    for c in (['init', '-q'], ['add', '-A'], ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x']): subprocess.run(['git', '-C', str(d)] + c, check=True)
same = 'S\t1111222233334444_b\t0\n'
repo4('up', {'dm/games/0100AAAA00000000/pso_manifest.tsv': same, 'dm/games/0100BBBB00000000/pso_manifest.tsv': same})
repo4('fk', {'dm/games/0100AAAA00000000/pso_manifest.tsv': same + 'S\t9999888877776666_b\t2\n', 'dm/games/0100BBBB00000000/pso_manifest.tsv': same})
(T / 'src4.tsv').write_text('来源\tup\thttps://e.x/up\tMIT\tnxnative\n来源\tfk\thttps://e.x/fk\tMIT\tnxnative\n')
o = subprocess.run([sys.executable, str(R / 'tools/ext_pso_collect.py'), str(d4), str(s4), '--sources', str(T / 'src4.tsv')], capture_output=True, text=True)
fa = s4 / '0100AAAA00000000/ext_fk.tsv'
ck(fa.is_file() and fa.read_text().split('\n')[2:] == ['S\t9999888877776666_b\t2', ''] and not (s4 / '0100BBBB00000000/ext_fk.tsv').exists()
   and (s4 / '0100AAAA00000000/ext_up.tsv').read_text().split('\n')[2:] == ['S\t1111222233334444_b\t0', ''],
   f'⑲ 跨来源去重：分叉只留独有的行，与上游完全相同的款不出文件（{o.stdout.strip()[-140:]}）')
# ---- 单条坏数据只跳这一条（11-20 巡检：上游两份清单各有一条 841 位 R 行，截断丢一位，fromhex 抛错整份收集退出）----
odd = (bytes(ours) + struct.pack('<II', 0, 7)).hex()[:-1]   # 880 位（440 字节）结构截掉最后一位 = 879 位
ck(epc.conv_nx(odd) == (None, 'nxnative 不是整字节十六进制（879 位）'), '⑳ 奇数位 R 行：不抛错，返回不收原因（位数 879 = 440×2−1，手算）')
c5 = repo('nx5', {'dm/games/0100FFFF00000000/pso_manifest.tsv': f'S\t1111222233334444_b\t0\n{r_ok}\nR\t{odd}\nR\t{h880.hex()}\n'})
src5 = T / 'src5.tsv'; src5.write_text('来源\tnx5\thttps://e.x/nx5\tMIT\tnxnative\n'); seeds5 = T / 'seeds5'
o = subprocess.run([sys.executable, str(R / 'tools/ext_pso_collect.py'), str(T / 'm'), str(seeds5), '--sources', str(src5)], capture_output=True, text=True)
got = (seeds5 / '0100FFFF00000000/ext_nx5.tsv').read_text().split('\n')[2:] if o.returncode == 0 else o.stderr[-300:]
ck(o.returncode == 0 and got == ['S\t1111222233334444_b\t0', r_ok, 'R\t' + want, ''] and "'R 行（nxnative 不是整字节十六进制（879 位））': 1" in o.stdout,
   f'㉑ 整份照收：坏的那 1 条计数跳过，好的 S / 等长 R / 880 转换 R 三条都收（{got}；{o.stdout.strip()[-200:]}）')
print(f'ext_pso_collect：{21 - fails}/21 通过'); sys.exit(1 if fails else 0)
PY
