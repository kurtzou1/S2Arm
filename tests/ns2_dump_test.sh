#!/bin/bash
# pack/ns2_dump.py 单测：合成一个最小 Switch 2 导出目录（base / updates / dlc，假 NSO 头 + 真 npdm 结构），不要游戏文件。
# 期望值都按导出目录的约定手写，不跑被测实现推：程序号来自 npdm ACI0、exefs 取最新更新、全量 romfs（含与本体逐字节相同的文件）只用更新、本体独有旧版本文件不收、
#   差量更新本体叠更新、DLC 序号 = 标题号 − 程序号 − 0x1000、合成 nacp 存档属主 = 程序号、键相同复用、ZBIC / 只差大小写报红。
# ZBIC（NSO 标志 0x80）另用真 nx_unpack + ZbicTest --emit 合成的真 ZBIC 样本核端到端：产物与 Normalize 期望逐字节相同（0xBF → 0x38、0xFF → 0x78）、
#   键相同复用、nx_unpack 程序变了重做（键里带它的程序哈希）、S2A_NX_UNPACK 缺位 / ZBIC 数据损坏报红且不留产物。
# 另核 pack/oneclick/oneclick.sh 认导出目录的那段（源包文件夹本身或下一层有 base/exefs/main.npdm）。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 真 ZBIC 用例要真 nx_unpack（--nso-normalize）与真 ZBIC 样本；构建产物放 <仓库根>/build/ns2_dump_test
OUT=$H/build/ns2_dump_test; mkdir -p "$OUT"
timeout 500 dotnet build "$H/pack/nx_unpack/nx_unpack.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "不通 nx_unpack 编译（期望编过）"; exit 1; }
timeout 500 dotnet build "$H/tests/nx_unpack_zbic/ZbicTest.csproj" -c Release --artifacts-path "$OUT/artz" -v quiet -nologo >> "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "不通 ZbicTest 编译（期望编过）"; exit 1; }
NXD=$(find "$OUT/art/bin" -name nx_unpack.dll | head -1); ZB=$(find "$OUT/artz/bin" -name ZbicTest.dll | head -1); [ -n "$NXD" ] && [ -n "$ZB" ] || { echo "不通 没找到构建产物"; exit 1; }
printf '#!/bin/bash\nexec dotnet "%s" "$@"\n' "$NXD" > "$T/nxu"; chmod +x "$T/nxu"
printf '#!/bin/bash\n# 另一份程序（字节不同、行为相同）：验键里带 nx_unpack 程序哈希、换了重做\nexec dotnet "%s" "$@"\n' "$NXD" > "$T/nxu2"; chmod +x "$T/nxu2"
dotnet "$ZB" --emit "$T/zbic.nso" "$T/zbic-exp.nso" > /dev/null || { echo "不通 --emit 0xBF 样本"; exit 1; }
dotnet "$ZB" --emit "$T/zbicff.nso" "$T/zbicff-exp.nso" FF > /dev/null || { echo "不通 --emit 0xFF 样本"; exit 1; }
export NXU="$T/nxu" NXU2="$T/nxu2"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（lz4，同 pack_rewrite_test.sh）：被测 ns2_dump 解 LZ4 段用出包 Python 的 lz4，gate-host 的系统 python3 没有
"$PY" - "$H/pack/ns2_dump.py" "$T" <<'PY'
import os, struct, subprocess, sys
tool, T = sys.argv[1], sys.argv[2]
TID = 0x040074A01BF12000
ok = bad = 0
def chk(name, cond, got=''):
    global ok, bad
    if cond: ok += 1
    else: bad += 1; print(f'✗ {name}：{got}')
def w(p, b):
    os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(b)
def npdm(tid):
    b = bytearray(0x200); b[:4] = b'META'; struct.pack_into('<II', b, 0x70, 0x100, 0x40)
    b[0x100:0x104] = b'ACI0'; struct.pack_into('<Q', b, 0x110, tid); return bytes(b)
def nso(build, flags=0x3F, text=b''):   # text：放进第一段的字节（不压缩，段压缩位 0–2 清掉）
    b = bytearray(0x100); b[:4] = b'NSO0'; struct.pack_into('<I', b, 0x0C, flags & ~7 if text else flags); b[0x40:0x50] = build
    if text: struct.pack_into('<III', b, 0x10, 0x100, 0, len(text)); struct.pack_into('<I', b, 0x60, len(text))
    return bytes(b) + text
def run(*a):
    r = subprocess.run([sys.executable, tool, *a], capture_output=True, text=True); return r.returncode, r.stdout + r.stderr
def mk(root, full=True):
    w(f'{root}/.listing', b'x'); w(f'{root}/base/exefs/main', nso(b'\x11' * 16)); w(f'{root}/base/exefs/main.npdm', npdm(TID))
    w(f'{root}/base/exefs/.listing', b'x'); w(f'{root}/base/romfs/A/a.bin', b'base-a'); w(f'{root}/base/romfs/B/b.bin', b'base-b'); w(f'{root}/base/romfs/S/old.Product.100.bin', b'stale')
    for v in ('65536', '458752'):   # 两个更新：要取数值最大的 458752，不是字典序
        u = f'{root}/updates/{v}'
        w(f'{u}/exefs/main', nso(bytes([int(v) % 251]) * 16)); w(f'{u}/exefs/main.npdm', npdm(TID)); w(f'{u}/exefs/sdk', nso(b'\x22' * 16))
        w(f'{u}/romfs/A/a.bin', b'upd-a-' + v.encode()); w(f'{u}/romfs/C/c.bin', b'upd-c')
        if full: w(f'{u}/romfs/B/b.bin', b'base-b')   # 全量：未改文件与本体逐字节相同；本体独有的旧版本文件不在更新里
    w(f'{root}/dlc/040074a01bf13001/0/romfs/d.bin', b'dlc1'); w(f'{root}/dlc/040074a01bf13001/.listing', b'x')
    w(f'{root}/dlc/0100000000001001/0/romfs/x.bin', b'other')   # 别的游戏的 DLC：跳过

# ① 全量更新
d = f'{T}/Game'; mk(d); o = f'{T}/x1'
rc, out = run(d, o); chk('① 退出 0', rc == 0, out)
u = dict(l.rstrip('\n').split('\t', 1) for l in open(f'{o}/unpack.tsv'))
chk('① title_id', u['title_id'] == '040074a01bf12000', u['title_id'])
chk('① update 取数值最大', u['update'] == '458752', u['update'])
chk('① name 缺省取目录名', u['name'] == 'Game', u['name'])
chk('① builds 来自更新 exefs', u['builds'] == 'main:' + (bytes([458752 % 251]) * 16).hex() + ' sdk:' + ('22' * 16), u['builds'])
chk('① exefs 不带 .listing', sorted(os.listdir(f'{o}/exefs')) == ['main', 'main.npdm', 'sdk'], os.listdir(f'{o}/exefs'))
chk('① romfs 全量只用更新', open(f'{o}/romfs/B/b.bin', 'rb').read() == b'base-b' and open(f'{o}/romfs/A/a.bin', 'rb').read() == b'upd-a-458752')
chk('① 本体独有旧版本文件不收', not os.path.exists(f'{o}/romfs/S/old.Product.100.bin'))
chk('① 不打差量黄字', '差量' not in out, out)
chk('① aoc 序号 1', u['aoc'] == '1' and open(f'{o}/aoc/1/d.bin', 'rb').read() == b'dlc1', u['aoc'])
chk('① 别的游戏 DLC 不收', not os.path.exists(f'{o}/aoc/0') and len(os.listdir(f'{o}/aoc')) == 1)
chk('① aoc.tsv', open(f'{o}/aoc.tsv').read() == 'idx\ttitle_id\tversion\tfiles\tbytes\n1\t040074a01bf13001\t0\t1\t4\n', open(f'{o}/aoc.tsv').read())
n = open(f'{o}/ctl/control.nacp', 'rb').read()
chk('① nacp 0x4000 字节', len(n) == 0x4000, len(n))
chk('① nacp 存档属主 = 程序号', struct.unpack_from('<Q', n, 0x3078)[0] == TID)
chk('① nacp 标题 16 份', all(n[i * 0x300:i * 0x300 + 4] == b'Game' for i in range(16)))
chk('① nacp 支持语言只声明美式英语（#401：留 0 = 一种都不支持，系统语言原样给游戏）', struct.unpack_from('<I', n, 0x302C)[0] == 1, hex(struct.unpack_from('<I', n, 0x302C)[0]))
chk('① nacp 账号存档 128/64 MB', struct.unpack_from('<qq', n, 0x3080) == (0x08000000, 0x04000000))
chk('① 没留 .tmp', not os.path.exists(o + '.tmp'))
chk('① 没挂临时存储 / 本机存档 / 缓存存储就不声明', struct.unpack_from('<q', n, 0x3168)[0] == 0 and struct.unpack_from('<qq', n, 0x3090) == (0, 0) and struct.unpack_from('<q', n, 0x3170)[0] == 0)
# ①b 游戏代码挂临时存储（塞尔达时之笛：合成件没声明 → OpenSaveDataFileSystem 2002-1002、游戏 Break）：按导入名声明；LZ4 压缩段也认
import lz4.block
db = f'{T}/TmpSave'; mk(db); sym = b'\0_ZN2nn2fs21MountTemporaryStorageEPKc\0_ZN2nn2fs19MountDeviceSaveDataEPKc\0'
w(f'{db}/updates/458752/exefs/main', nso(b'\x55' * 16, 0x3F, sym))
comp = lz4.block.compress(b'pad' * 64 + b'\0_ZN2nn2fs17MountCacheStorageEPKc\0', store_size=False)   # subsdk0 第一段 LZ4 压缩
sd = bytearray(nso(b'\x56' * 16)); struct.pack_into('<III', sd, 0x10, 0x100, 0, 3 * 64 + 35); struct.pack_into('<I', sd, 0x60, len(comp)); struct.pack_into('<I', sd, 0x0C, 0x39)
w(f'{db}/updates/458752/exefs/subsdk0', bytes(sd) + comp); ob = f'{T}/xb'
rc, out = run(db, ob); nb = open(f'{ob}/ctl/control.nacp', 'rb').read()
chk('①b 退出 0', rc == 0, out)
chk('①b 临时存储 128 MB', struct.unpack_from('<q', nb, 0x3168)[0] == 0x08000000, struct.unpack_from('<q', nb, 0x3168))
chk('①b 本机存档 128/64 MB', struct.unpack_from('<qq', nb, 0x3090) == (0x08000000, 0x04000000), struct.unpack_from('<qq', nb, 0x3090))
chk('①b LZ4 段里的缓存存储也认', struct.unpack_from('<qqq', nb, 0x3170) == (0x08000000, 0x04000000, 0x0C000000), struct.unpack_from('<qqq', nb, 0x3170))
chk('①b 账号存档照旧', struct.unpack_from('<qq', nb, 0x3080) == (0x08000000, 0x04000000))
chk('①b 说明行列出', '临时存储' in out and '本机存档' in out and '缓存存储' in out, out)
d2 = f'{T}/SdkOnly'; mk(d2); w(f'{d2}/updates/458752/exefs/sdk', nso(b'\x57' * 16, 0x3F, sym)); o2 = f'{T}/x2b'   # 只有系统库 sdk 里有这些名字（它定义全部 nn::fs 函数）：不算
rc, out = run(d2, o2); n2 = open(f'{o2}/ctl/control.nacp', 'rb').read()
chk('①c 只在 sdk 里不声明', rc == 0 and struct.unpack_from('<q', n2, 0x3168)[0] == 0 and struct.unpack_from('<qq', n2, 0x3090) == (0, 0), out)
# ② 键相同复用；源变了重做
m0 = os.stat(f'{o}/unpack.tsv').st_mtime_ns
rc, out = run(d, o); chk('② 复用', rc == 0 and '复用' in out and os.stat(f'{o}/unpack.tsv').st_mtime_ns == m0, out)
w(f'{d}/updates/458752/romfs/C/c2.bin', b'new'); rc, out = run(d, o)
chk('② 源变了重做', rc == 0 and os.path.exists(f'{o}/romfs/C/c2.bin'), out)
# ③ 差量更新：本体叠更新、打黄
d3 = f'{T}/Delta'; mk(d3, full=False); o3 = f'{T}/x3'; rc, out = run(d3, o3, '--name', 'dk')
chk('③ 退出 0', rc == 0, out)
chk('③ 本体文件保留', open(f'{o3}/romfs/B/b.bin', 'rb').read() == b'base-b' and os.path.exists(f'{o3}/romfs/S/old.Product.100.bin'))
chk('③ 更新覆盖', open(f'{o3}/romfs/A/a.bin', 'rb').read() == b'upd-a-458752')
chk('③ 黄字说明差量', '🟡' in out and '差量' in out, out)
chk('③ --name', 'name\tdk\n' in open(f'{o3}/unpack.tsv').read())
# ④ ZBIC 报红、不留产物
d4 = f'{T}/Zbic'; mk(d4); w(f'{d4}/updates/458752/exefs/main', nso(b'\x33' * 16, 0x80 | 0x3F)); o4 = f'{T}/x4'
rc, out = run(d4, o4); chk('④ ZBIC 红', rc != 0 and 'ZBIC' in out and not os.path.exists(o4), out)
# ④d 设了 S2A_NX_UNPACK：ZBIC 交它 --nso-normalize 解（假程序：输出 = b'NORM' + 输入），解包目录 exefs/main 就是它的输出，并打一行说明
fake = f'{T}/fake_nxu'
open(fake, 'w').write('#!/bin/sh\n[ "$1" = --nso-normalize ] || exit 9\n{ printf NORM; cat "$2"; } > "$3"\n'); os.chmod(fake, 0o755)
src_main = open(f'{d4}/updates/458752/exefs/main', 'rb').read(); o4d = f'{T}/x4d'
r = subprocess.run([sys.executable, tool, d4, o4d], capture_output=True, text=True, env=dict(os.environ, S2A_NX_UNPACK=fake))
chk('④d ZBIC 交 nx_unpack 解', r.returncode == 0 and open(f'{o4d}/exefs/main', 'rb').read() == b'NORM' + src_main and 'ZBIC 压缩，已用 nx_unpack 解' in r.stdout, r.stdout + r.stderr)
# ④e 真 ZBIC 样本 + 真 nx_unpack（S2A_NX_UNPACK 指包装脚本，shell 侧 dotnet build + ZbicTest --emit 备好）：
#   端到端退出 0、产物与 Normalize 期望逐字节相同、标志 0xbf → 0x38；键相同复用；nx_unpack 程序变了（键里带它的程序哈希）重做
nxu, nxu2 = os.environ['NXU'], os.environ['NXU2']
def runx(*a, nx=nxu):
    r = subprocess.run([sys.executable, tool, *a], capture_output=True, text=True, env=dict(os.environ, S2A_NX_UNPACK=nx)); return r.returncode, r.stdout + r.stderr
d4e = f'{T}/ZbicReal'; mk(d4e); w(f'{d4e}/updates/458752/exefs/main', open(f'{T}/zbic.nso', 'rb').read()); o4e = f'{T}/x4e'
rc, out = runx(d4e, o4e); chk('④e 真 ZBIC 整理退出 0', rc == 0, out)
got4e = open(f'{o4e}/exefs/main', 'rb').read() if os.path.isfile(f'{o4e}/exefs/main') else b''
chk('④e 产物与 Normalize 期望逐字节相同', got4e == open(f'{T}/zbic-exp.nso', 'rb').read())
chk('④e 标志 0xbf → 0x38', got4e[0xC:0x10] == b'\x38\0\0\0', got4e[0xC:0x10].hex())
m4e = os.stat(f'{o4e}/unpack.tsv').st_mtime_ns if os.path.isfile(f'{o4e}/unpack.tsv') else 0
rc, out = runx(d4e, o4e); chk('④e 键相同复用', rc == 0 and '复用' in out and m4e and os.stat(f'{o4e}/unpack.tsv').st_mtime_ns == m4e, out)
rc, out = runx(d4e, o4e, nx=nxu2); chk('④e nx_unpack 程序变了重做', rc == 0 and '复用' not in out and open(f'{o4e}/exefs/main', 'rb').read() == got4e, out)
# ④f 0xFF（ZBIC + 0x40，塞尔达 main 的值）：解成段不压缩、0x40 保留 → 标志 0x78
d4f = f'{T}/ZbicFF'; mk(d4f); w(f'{d4f}/updates/458752/exefs/main', open(f'{T}/zbicff.nso', 'rb').read()); o4f = f'{T}/x4f'
rc, out = runx(d4f, o4f); got4f = open(f'{o4f}/exefs/main', 'rb').read() if os.path.isfile(f'{o4f}/exefs/main') else b''
chk('④f 0xFF → 0x78', rc == 0 and got4f == open(f'{T}/zbicff-exp.nso', 'rb').read() and got4f[0xC:0x10] == b'\x78\0\0\0', out)
# ④g S2A_NX_UNPACK 指了但不存在的路径：报红、不留产物
rc, out = runx(d4e, f'{T}/x4g', nx=f'{T}/no-such-nxu'); chk('④g nx_unpack 缺位报红', rc != 0 and 'nx_unpack' in out and not os.path.exists(f'{T}/x4g'), out)
# ④h ZBIC 数据损坏（段首字节改掉）：nx_unpack 退出非 0 → 报红、不留产物
zbad = bytearray(open(f'{T}/zbic.nso', 'rb').read()); zbad[0x108] ^= 0xAA
d4h = f'{T}/ZbicBad2'; mk(d4h); w(f'{d4h}/updates/458752/exefs/main', bytes(zbad))
rc, out = runx(d4h, f'{T}/x4h'); chk('④h ZBIC 数据损坏报红', rc != 0 and 'ZBIC' in out and not os.path.exists(f'{T}/x4h'), out)
# ④b 0x40 位（raiders main 0x7f）透传；0x100 以上未知位报红
d4b = f'{T}/Bit6'; mk(d4b); w(f'{d4b}/updates/458752/exefs/main', nso(b'\x44' * 16, 0x7F)); o4b = f'{T}/x4b'
rc, out = run(d4b, o4b); chk('④b 0x7f 收', rc == 0 and open(f'{o4b}/exefs/main', 'rb').read()[0xC] == 0x7F, out)
d4c = f'{T}/Bit8'; mk(d4c); w(f'{d4c}/updates/458752/exefs/main', nso(b'\x45' * 16, 0x13F))
rc, out = run(d4c, f'{T}/x4c'); chk('④c 0x100 位红', rc != 0 and '不认识' in out, out)
# ⑤ 只差大小写报红
d5 = f'{T}/Case'; mk(d5); w(f'{d5}/updates/458752/romfs/a/A.BIN', b'x'); w(f'{d5}/updates/458752/romfs/a/a.bin', b'y')
rc, out = run(d5, f'{T}/x5')
# 本机卷不分大小写时第二个文件写不出两份，这一项只在分大小写的卷上有意义
if len(os.listdir(f'{d5}/updates/458752/romfs/a')) == 2: chk('⑤ 只差大小写红', rc != 0 and '大小写' in out, out)
# ⑦ 本体没带 romfs、DLC 直接 dlc/<标题号>/romfs
d7 = f'{T}/NoBaseRom'; mk(d7); import shutil; shutil.rmtree(f'{d7}/base/romfs')
os.rename(f'{d7}/dlc/040074a01bf13001/0/romfs', f'{d7}/dlc/040074a01bf13001/romfs'); os.rmdir(f'{d7}/dlc/040074a01bf13001/0'); o7 = f'{T}/x7'
rc, out = run(d7, o7); chk('⑦ 退出 0', rc == 0, out)
chk('⑦ romfs 用更新、不打差量黄字', open(f'{o7}/romfs/A/a.bin', 'rb').read() == b'upd-a-458752' and '差量' not in out, out)
chk('⑦ DLC 无 <n> 层', open(f'{o7}/aoc/1/d.bin', 'rb').read() == b'dlc1' and '1\t040074a01bf13001\t0\t1\t4' in open(f'{o7}/aoc.tsv').read(), open(f'{o7}/aoc.tsv').read())
# ⑧ 导出带了控制分区：用原件（标题 / 中文名 / 显示版本 / 图标），不写 README.synth；没带的 ① 有 README.synth
chk('① 合成标 README.synth', os.path.isfile(f'{o}/ctl/README.synth'))
d8 = f'{T}/WithCtl'; mk(d8); n8 = bytearray(0x4000); n8[0:6] = b'DK Ban'; n8[14 * 0x300:14 * 0x300 + 6] = '大金剛'.encode()[:6]; n8[0x3060:0x3065] = b'1.2.0'
w(f'{d8}/updates/458752/control/control.nacp', bytes(n8)); w(f'{d8}/updates/458752/control/icon_AmericanEnglish.dat', b'JPG'); o8 = f'{T}/x8'
rc, out = run(d8, o8); u8 = dict(l.rstrip('\n').split('\t', 1) for l in open(f'{o8}/unpack.tsv'))
chk('⑧ 原件 nacp', rc == 0 and open(f'{o8}/ctl/control.nacp', 'rb').read() == bytes(n8), out)
chk('⑧ 标题 / 版本取原件', u8['name'] == 'DK Ban' and u8['display_version'] == '1.2.0' and u8['name_zh'] == '大金', u8)
chk('⑧ 图标', open(f'{o8}/icon.jpg', 'rb').read() == b'JPG')
chk('⑧ 无 README.synth', not os.path.exists(f'{o8}/ctl/README.synth'))
# ⑨ 原件只有标题、0x3000 起全 0（某款 Switch 2 更新包元数据带的控制数据）：标题照原件，补启动账号 1、归属号 = 程序号、账号存档 128 / 64 MB；语言位仍 0（#465 按宿主语言）
d9 = f'{T}/TitleOnly'; mk(d9); n9 = bytearray(0x4000); n9[0:6] = b'Pokoti'; n9[0x200:0x206] = b'Publsh'
w(f'{d9}/updates/458752/control/control.nacp', bytes(n9)); o9 = f'{T}/x9'
rc, out = run(d9, o9); g9 = open(f'{o9}/ctl/control.nacp', 'rb').read()
chk('⑨ 标题照原件', rc == 0 and g9[0:6] == b'Pokoti' and g9[0x200:0x206] == b'Publsh', out)
chk('⑨ 补存档字段、语言位 0', g9[0x3025] == 1 and struct.unpack_from('<Q', g9, 0x3078)[0] == 0x040074A01BF12000 and struct.unpack_from('<q', g9, 0x3080)[0] == 0x08000000
    and struct.unpack_from('<q', g9, 0x3088)[0] == 0x04000000 and struct.unpack_from('<I', g9, 0x302C)[0] == 0, g9[0x3020:0x3090].hex())
# ⑥ 识别：本身 / 下一层；不是导出目录退出 1
rc, out = run('--detect', d); chk('⑥ 本身', rc == 0 and out.startswith('040074A01BF12000\t'), out)
os.makedirs(f'{T}/lib/040074A01BF12000'); os.rename(d, f'{T}/lib/040074A01BF12000/Game')
rc, out = run('--detect', f'{T}/lib/040074A01BF12000'); chk('⑥ 下一层', rc == 0 and out.strip().endswith('/Game'), out)
rc, out = run('--detect', f'{T}/x1'); chk('⑥ 非导出目录退出 1', rc == 1, out)
print(f'ns2_dump：{ok} 过 / {bad} 红'); sys.exit(1 if bad else 0)
PY
r=$?
# oneclick.sh 认导出目录：那段在源包文件夹本身或下一层找 base/exefs/main.npdm，交给 pack/ns2_dump.py
grep -q 'for d in "$SRC" "$SRC"/\*/; do d=${d%/}; \[ -f "$d/base/exefs/main.npdm" \]' "$H/pack/oneclick/oneclick.sh" \
  && grep -q '"$PY" "$P/ns2_dump.py" "$NS2D" "$B/extract" 2>&1' "$H/pack/oneclick/oneclick.sh" || { echo "✗ oneclick.sh 没接 ns2_dump.py"; r=1; }
# 审计 P1-54（11-06）：整理键认得出「同一秒内换成同大小的文件」——两份导出目录只差一个文件、大小相同、修改时间相差 0.5 秒 → 键必须不同
K=$(mktemp -d); mkdir -p $K/a/base $K/b/base; printf 'AAAA' > $K/a/base/f; printf 'BBBB' > $K/b/base/f
"$PY" - "$H/pack" "$K" <<'PYEOF' || { echo "✗ 整理键：同一秒内换同大小的文件，键没变"; r=1; }
import os, sys; sys.path.insert(0, sys.argv[1]); import ns2_dump
k = sys.argv[2]; t = 1_700_000_000_000_000_000
os.utime(f'{k}/a/base/f', ns=(t, t)); os.utime(f'{k}/b/base/f', ns=(t + 500_000_000, t + 500_000_000))
sys.exit(0 if ns2_dump.src_key(f'{k}/a') != ns2_dump.src_key(f'{k}/b') else 1)
PYEOF
rm -rf $K
[ $r = 0 ] && echo "✓ t_ns2_dump"
exit $r
