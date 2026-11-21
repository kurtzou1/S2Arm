#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* tests/nx_unpack_fail/*
# nx_unpack 解包失败三类的回归单测（#633）：容器/密钥/压缩包出问题时，只允许「一行能照做的红字 + 非 0 退出」，
#   不允许再把异常冒到 CLR（rc=134 / SIGABRT），也不允许 --inspect 把不同原因折叠成同一句话。
# 合成样本：自造 PFS0（不用游戏文件、不用 keys），只覆盖容器解析与错误路径；密钥内容一律零值假数据。
#   期望：全部用例通过（含 #772 并行异常分类），，退出 0。产物在 <仓库根>/build/nx_unpack_fail_test。
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd)
OUT=$ROOT/build/nx_unpack_fail_test; rm -rf "$OUT"; mkdir -p "$OUT"
PKG=$ROOT/pack/nx_unpack/nx_unpack.csproj
[ -f "$PKG" ] || { echo "不通 找不到 $PKG"; exit 1; }
timeout 500 dotnet build "$PKG" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
B=$(find "$OUT/art/bin" -name nx_unpack.dll | head -1); [ -n "$B" ] || { echo "不通 没找到 nx_unpack.dll"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck() { if eval "$2"; then pass=$((pass+1)); echo "通 $1"; else fail=$((fail+1)); echo "不通 $1"; fi; }
run() { log=$1; shift; timeout 180 dotnet "$B" "$@" > "$log" 2>&1; echo $? > "$log.rc"; }

# 假 keys：只给 header_key（零值），足够让读取器起来；不含任何真密钥
mkdir -p "$T/k1" "$T/k2"
printf 'header_key = %032d\n' 0 > "$T/k1/prod.keys"
K=$T/k1/prod.keys

# ---- 合成容器 ----
python3 - "$T" <<'PY'
import struct, sys, os
T = sys.argv[1]
def pfs0(path, entries):
    names = b""; noffs = []
    for n, _ in entries:
        noffs.append(len(names)); names += n.encode() + b"\0"
    hdr = b"PFS0" + struct.pack("<III", len(entries), len(names), 0)
    ents = b""; body = b""; at = 0
    for (n, blob), no in zip(entries, noffs):
        ents += struct.pack("<QQII", at, len(blob), no, 0); body += blob; at += len(blob)
    open(path, "wb").write(hdr + ents + names + body)
HEX = "00112233445566778899aabbccddeeff"
def ncz_head(sections, tail):
    out = b"\x00" * 0x4000 + b"NCZSECTN" + struct.pack("<q", len(sections))
    for off, size, ctype in sections:
        out += struct.pack("<qqqq", off, size, ctype, 0) + b"\x00" * 16 + b"\x00" * 16
    return out + tail
# 1) 名字不是 32 位内容号（修前：e.Name[..32] 越界 → SIGABRT rc=134）
pfs0(os.path.join(T, "shortname.nsp"), [("short.nca", b"\x00" * 0x400), (HEX + ".nca", b"\x11" * 0x400)])
# 2) 32 hex 的 .ncz 但内容不足 0x4000（NCZ 头读不全）
pfs0(os.path.join(T, "shortncz.nsp"), [(HEX + ".ncz", b"\x00" * 0x100)])
# 3) 0x4000 处不是 NCZSECTN
pfs0(os.path.join(T, "badmagic.nsp"), [(HEX + ".ncz", b"\xAA" * 0x5000)])
# 4) NCZBLOCK 单块压缩长度离谱（0x7fffffff）
bad = ncz_head([(0x4000, 0x1000, 3)], b"NCZBLOCK" + bytes([2, 1, 0, 20]) + struct.pack("<Iq", 1, 0x1000) + struct.pack("<I", 0x7FFFFFFF))
pfs0(os.path.join(T, "badblock.nsp"), [(HEX + ".ncz", bad)])
# 5) NCZ 块数据超出文件末尾（声明 2 块、只给 1 块）
short = ncz_head([(0x4000, 0x2000, 3)], b"NCZBLOCK" + bytes([2, 1, 0, 16]) + struct.pack("<Iq", 2, 0x2000) + struct.pack("<II", 0x40, 0x40) + b"\x00" * 0x40)
pfs0(os.path.join(T, "cutblock.nsp"), [(HEX + ".ncz", short)])
# 8) 随包票据（#1511）：两张通用票据同一 rights id（0102…10）+ 一张个人化票据（rights id ff…）；假标题密钥零值；没有内容文件
def tik(rid, personal=False):
    t = bytearray(0x2c0); t[0x281] = 1 if personal else 0; t[0x2a0:0x2b0] = rid; return bytes(t)
RID = bytes(range(1, 17))
pfs0(os.path.join(T, "tickets.nsp"), [("a.tik", tik(RID)), ("b.tik", tik(RID)), ("p.tik", tik(b"\xff" * 16, True))])
# 6) 根本不是容器
open(os.path.join(T, "junk.bin"), "wb").write(bytes(range(256)) * 16)
# 7) title.keys：一条格式正确（假 rights id / 假 title key，零值）+ 一条坏行
open(os.path.join(T, "k2", "prod.keys"), "w").write("header_key = " + "0" * 32 + "\n")
open(os.path.join(T, "k2", "title.keys"), "w").write(
    "0100000000000000000000000000000b=" + "0" * 32 + "\n" + "这不是一行 title key\n")
# 9) 截断容器：PFS0 里唯一的内容声明 0x1000 字节、文件只留到它的一半（11-01 七龙珠 电光炸裂 ZERO 一个 21 KB 的截断 DLC）
pfs0(os.path.join(T, "cut.nsp"), [(HEX + ".nca", b"\x22" * 0x1000)])
with open(os.path.join(T, "cut.nsp"), "r+b") as f: f.truncate(os.path.getsize(os.path.join(T, "cut.nsp")) - 0x800)
# 10) 卡带镜像（xci）安全分区自己解 HFS0（11-01 沙排3 整合版：塞进来的内容前段哈希没重算）：一个 32 位内容号命名、内容是垃圾的 .nca；
#     goodhash.xci 前段哈希写对，badhash.xci 写错（全 0）
import hashlib
def hfs0(files):
    names = b"".join(n.encode() + b"\0" for n, _, _ in files); hdr = b"HFS0" + struct.pack("<II", len(files), len(names)) + b"\0" * 4
    ent, data, so = b"", b"", 0
    for n, body, h in files:
        ent += struct.pack("<QQII", len(data), len(body), so, 0x200) + b"\0" * 8 + h; data += body; so += len(n) + 1
    return hdr + ent + names + data
def xci(path, good):
    body = bytes(range(256)) * 4
    sec = hfs0([(HEX + ".nca", body, hashlib.sha256(body[:0x200]).digest() if good else b"\0" * 32)])
    root = hfs0([("secure", sec, hashlib.sha256(sec[:0x200]).digest())])
    head = bytearray(0xf000); head[0x100:0x104] = b"HEAD"; struct.pack_into("<QQ", head, 0x130, 0xf000, 0x200)
    open(path, "wb").write(bytes(head) + root)
xci(os.path.join(T, "goodhash.xci"), True); xci(os.path.join(T, "badhash.xci"), False)
# 8) 显式 --title-keys 指一个不存在的路径
# 11) 稀疏本体 NCA（带板载更新的修订版卡带：本体程序段 0 为 SparseInfo Generation=1、MetaSize=0 空稀疏段，须叠上更新才能读）：
#     用最小纯 Python AES-128（无外部依赖）和全假测试密钥合成 3 份真 LibHac 可读容器：
#     - sparse_base.nsp：只有稀疏本体（含 Meta + Sparse Program）
#     - sparse_with_update.nsp：稀疏本体 + 同容器完整 AArch64 更新
#     - sparse_wrong_gen1.nsp：gen 0 正常 Meta + gen 0 稀疏本体 + gen 1 错密钥 Meta（验证 SiblingDecrypts 不把稀疏段当损坏误报 content_damaged）
SBOX = [
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]
def xtime(a): return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1)
def aes_rk(key):
    w = [list(key[i:i+4]) for i in range(0, 16, 4)]
    for i in range(4, 44):
        t = w[i-1][:]
        if i % 4 == 0:
            t = [SBOX[x] for x in (t[1:] + t[:1])]; t[0] ^= RCON[i // 4 - 1]
        w.append([w[i-4][j] ^ t[j] for j in range(4)])
    return [[b for col in w[r*4:(r+1)*4] for b in col] for r in range(11)]
def aes_enc(rk, blk):
    s = [blk[i] ^ rk[0][i] for i in range(16)]
    for r in range(1, 11):
        s = [SBOX[x] for x in s]
        s = [s[0],s[5],s[10],s[15], s[4],s[9],s[14],s[3], s[8],s[13],s[2],s[7], s[12],s[1],s[6],s[11]]
        if r < 10:
            ns = []
            for c in range(0, 16, 4):
                a0,a1,a2,a3 = s[c:c+4]; t = a0 ^ a1 ^ a2 ^ a3
                ns += [a0^t^xtime(a0^a1), a1^t^xtime(a1^a2), a2^t^xtime(a2^a3), a3^t^xtime(a3^a0)]
            s = ns
        s = [s[i] ^ rk[r][i] for i in range(16)]
    return bytes(s)
def aes_xts_enc(key32, data):
    rk1, rk2 = aes_rk(key32[:16]), aes_rk(key32[16:]); out = bytearray()
    for sec in range(len(data) // 0x200):
        t = int.from_bytes(aes_enc(rk2, sec.to_bytes(16, "big")), "little")
        chunk = data[sec*0x200:(sec+1)*0x200]
        for i in range(0, 0x200, 16):
            tb = t.to_bytes(16, "little")
            y = aes_enc(rk1, bytes(a ^ b for a, b in zip(chunk[i:i+16], tb)))
            out.extend(a ^ b for a, b in zip(y, tb))
            t = ((t << 1) & ((1 << 128) - 1)) ^ (0x87 if (t >> 127) & 1 else 0)
    return bytes(out)
def aes_ctr(key16, offset, data):
    rk = aes_rk(key16); base = offset >> 4; out = bytearray()
    for i in range(0, len(data), 16):
        ks = aes_enc(rk, (base + i // 16).to_bytes(16, "big")); blk = data[i:i+16]
        out.extend(a ^ b for a, b in zip(blk, ks[:len(blk)]))
    return bytes(out)
def pfs0_blob(entries):
    names = b""; noffs = []
    for n, _ in entries: noffs.append(len(names)); names += n.encode() + b"\0"
    hdr = b"PFS0" + struct.pack("<III", len(entries), len(names), 0); ents = b""; body = b""; at = 0
    for (_, blob), no in zip(entries, noffs):
        ents += struct.pack("<QQII", at, len(blob), no, 0); body += blob; at += len(blob)
    return hdr + ents + names + body
def pfs0_sec(pfs_data, ctr_key, start_blk=6):
    bsz = 0x1000; l0 = b"".join(hashlib.sha256(pfs_data[i:i+bsz]).digest() for i in range(0, len(pfs_data), bsz))
    l1_off = max(0x1000, (len(l0) + 0xfff) & ~0xfff)
    raw = l0.ljust(l1_off, b"\0") + pfs_data; padded = raw.ljust((len(raw) + 0x1ff) & ~0x1ff, b"\0")
    fs = bytearray(0x200); struct.pack_into("<HBBBB", fs, 0, 2, 1, 2, 3, 0)
    fs[8:0x28] = hashlib.sha256(l0).digest(); struct.pack_into("<II", fs, 0x28, bsz, 2)
    struct.pack_into("<QQQQ", fs, 0x30, 0, len(l0), l1_off, len(pfs_data))
    return bytes(fs), aes_ctr(ctr_key, start_blk * 0x200, padded)
def make_nca(ctype, tid, fs_hdr, body, start_blk=6, end_blk=None, key32=b"\x11"*32, kak=b"\x33"*16, ctr_key=b"\x44"*16, kg1=0):
    hdr = bytearray(0xC00); hdr[0x200:0x204] = b"NCA3"; hdr[0x204] = 1; hdr[0x205] = ctype; hdr[0x206] = kg1
    struct.pack_into("<QQ", hdr, 0x208, 0xC00 + len(body), tid)
    struct.pack_into("<IIII", hdr, 0x240, start_blk, end_blk if end_blk is not None else start_blk + len(body) // 0x200, 1, 0)
    hdr[0x280:0x2A0] = hashlib.sha256(fs_hdr).digest(); hdr[0x320:0x330] = aes_enc(aes_rk(kak), ctr_key); hdr[0x400:0x600] = fs_hdr
    return aes_xts_enc(key32, bytes(hdr)) + body
def make_cnmt(tid, ver, ctype_meta, entries, app_tid=None):
    hdr = bytearray(0x20); struct.pack_into("<QIBBHHH", hdr, 0, tid, ver, ctype_meta, 0, 0x10, len(entries), 0)
    ext = bytearray(0x10); struct.pack_into("<QI", ext, 0, tid + 0x800 if ctype_meta == 0x80 else app_tid, 0)
    body = bytearray()
    for nca_b, ct in entries:
        h = hashlib.sha256(nca_b).digest(); ent = bytearray(0x38)
        ent[0:0x20] = h; ent[0x20:0x30] = h[:16]; ent[0x30:0x36] = len(nca_b).to_bytes(6, "little"); ent[0x36] = ct; body.extend(ent)
    return bytes(hdr + ext + body + b"\0" * 0x20)
os.makedirs(os.path.join(T, "ks"), exist_ok=True)
open(os.path.join(T, "ks", "prod.keys"), "w").write(
    "header_key = " + "11" * 32 + "\nkey_area_key_application_00 = " + "33" * 16 + "\nkey_area_key_application_01 = " + "55" * 16 + "\n")
sp_fs = bytearray(0x200); struct.pack_into("<HBBBB", sp_fs, 0, 2, 1, 2, 3, 0); sp_fs[8:0x28] = b"\xaa" * 0x20
struct.pack_into("<II", sp_fs, 0x28, 0x10000, 2); struct.pack_into("<QQQQ", sp_fs, 0x30, 0, 0x20, 0x10000, 0x10000)
struct.pack_into("<QQ4sIIIQH", sp_fs, 0x148, 0, 0, b"BKTR", 1, 0, 0, 0xC00, 1)
prog_sp = make_nca(0, 0x0100123400000000, bytes(sp_fs), b"", start_blk=0x10, end_blk=0x110)
prog_sp_id = hashlib.sha256(prog_sp).hexdigest()[:32]
base_cnmt = make_cnmt(0x0100123400000000, 0, 0x80, [(prog_sp, 1)])
mfs, mbody = pfs0_sec(pfs0_blob([("Application_0100123400000000.cnmt", base_cnmt)]), b"\x44" * 16)
base_meta = make_nca(1, 0x0100123400000000, mfs, mbody); base_meta_id = hashlib.sha256(base_meta).hexdigest()[:32]
npdm = bytearray(0x80); npdm[0:4] = b"META"; npdm[0x0c] = 1
nso = bytearray(0x60); nso[0:4] = b"NSO0"; nso[0x40:0x50] = bytes(range(16))
ufs, ubody = pfs0_sec(pfs0_blob([("main.npdm", bytes(npdm)), ("main", bytes(nso))]), b"\x44" * 16)
upd_prog = make_nca(0, 0x0100123400000800, ufs, ubody); upd_prog_id = hashlib.sha256(upd_prog).hexdigest()[:32]
upd_cnmt = make_cnmt(0x0100123400000800, 65536, 0x81, [(upd_prog, 1)], app_tid=0x0100123400000000)
umfs, umbody = pfs0_sec(pfs0_blob([("Patch_0100123400000800.cnmt", upd_cnmt)]), b"\x44" * 16)
upd_meta = make_nca(1, 0x0100123400000800, umfs, umbody); upd_meta_id = hashlib.sha256(upd_meta).hexdigest()[:32]
# gen 1 Meta：用 0x66 加密，但 ks/prod.keys 里 key_area_key_application_01 是 0x55 → 触发 2002-4644
bad_meta = make_nca(1, 0x0100123400000800, umfs, umbody, kak=b"\x66" * 16, kg1=2); bad_meta_id = hashlib.sha256(bad_meta).hexdigest()[:32]
pfs0(os.path.join(T, "sparse_base.nsp"), [(prog_sp_id + ".nca", prog_sp), (base_meta_id + ".cnmt.nca", base_meta)])
pfs0(os.path.join(T, "sparse_with_update.nsp"), [(prog_sp_id + ".nca", prog_sp), (base_meta_id + ".cnmt.nca", base_meta), (upd_prog_id + ".nca", upd_prog), (upd_meta_id + ".cnmt.nca", upd_meta)])
pfs0(os.path.join(T, "sparse_wrong_gen1.nsp"), [(prog_sp_id + ".nca", prog_sp), (base_meta_id + ".cnmt.nca", base_meta), (bad_meta_id + ".cnmt.nca", bad_meta)])
print("fixtures ok")
PY

# ---- 用例：完整解包路径（修前 rc=134 的那条）----
run "$T/l1" "$K" "$T/o1" "$T/shortname.nsp"
ck "名字不是内容号：rc=1、不出调用栈（修前 rc=134 + Unhandled exception）"    '[ "$(cat "$T/l1.rc")" = 1 ] && ! grep -q "Unhandled exception" "$T/l1"'
ck "名字不是内容号：点名跳过（认不出内容号就对不上清单）" 'grep -q "名字不是「32 位内容号" "$T/l1"'

run "$T/l2" "$K" "$T/o2" "$T/shortncz.nsp"
ck "NCZ 不足 0x4000：rc=1、不出调用栈" '[ "$(cat "$T/l2.rc")" = 1 ] && ! grep -q "Unhandled exception" "$T/l2"'

run "$T/l3" "$K" "$T/o3" "$T/badmagic.nsp"
ck "NCZ magic 坏：rc=1 且点名「不是 NCZSECTN」" '[ "$(cat "$T/l3.rc")" = 1 ] && grep -q "不是 NCZSECTN" "$T/l3"'

run "$T/l4" "$K" "$T/o4" "$T/badblock.nsp"
ck "NCZ 块压缩长度离谱：rc=1 且点名块长与块大小" '[ "$(cat "$T/l4.rc")" = 1 ] && grep -q "压缩长度.*不合理（块大小" "$T/l4"'

run "$T/l5" "$K" "$T/o5" "$T/cutblock.nsp"
ck "NCZ 块数据超出文件末尾：rc=1 且点名「超出文件末尾」" '[ "$(cat "$T/l5.rc")" = 1 ] && grep -q "超出文件末尾" "$T/l5"'

run "$T/l6" "$K" "$T/o6" "$T/junk.bin"
ck "不是容器：rc=1 且点名「既不是卡带镜像」" '[ "$(cat "$T/l6.rc")" = 1 ] && grep -q "既不是卡带镜像" "$T/l6"'

# ---- 用例：坏源文件只跳过并点名（11-01 出包线：一个截断 DLC 让本体 + 更新整款解不了）----
#   截断的内容跳过、打黄字；给的文件里没有本体 → 照样报红退 1，红字末尾点名跳过的坏源文件（修前：截断直接报红退出，没有黄字也没有点名）
run "$T/l7" "$K" "$T/o7" "$T/cut.nsp"
ck "截断容器：黄字「已跳过被截断的内容」、rc=1、红字点名跳过的坏源文件" '[ "$(cat "$T/l7.rc")" = 1 ] && grep -q "🟡 源文件损坏，已跳过被截断的内容：cut.nsp 被截断" "$T/l7" && grep -q "🔴 基础程序应恰好 1 个.*跳过的坏源文件：cut.nsp 被截断" "$T/l7"'
#   两个坏文件一起给（截断 + 不是容器）：两个都跳过、都点名，不在第一个坏文件处停下（修前：第一个坏文件就退出，第二个不看）
run "$T/l8" "$K" "$T/o8" "$T/cut.nsp" "$T/junk.bin"
ck "截断 + 不是容器：两个都打黄字跳过、红字两个都点名" '[ "$(cat "$T/l8.rc")" = 1 ] && grep -q "🟡 源文件损坏，已跳过：.*既不是卡带镜像" "$T/l8" && grep -q "跳过的坏源文件：cut.nsp 被截断.*；.*既不是卡带镜像" "$T/l8"'

# ---- 用例：卡带镜像 HFS0 前段哈希不符（沙排3 整合版）——不再整份读不了：对不上的内容改核 NCA，核不过才跳过并点名 ----
run "$T/l9" "$K" "$T/o9" "$T/badhash.xci"
ck "xci 前段哈希不符：黄字点名 HFS0 前段哈希不符、rc=1、红字带跳过的坏源文件（修前：整份分区读不了）" '[ "$(cat "$T/l9.rc")" = 1 ] && grep -q "HFS0 前段哈希不符" "$T/l9" && grep -q "跳过的坏源文件：badhash.xci 安全分区 1 个内容" "$T/l9" && ! grep -q "Unhandled exception" "$T/l9"'
run "$T/l10" "$K" "$T/o10" "$T/goodhash.xci"
ck "xci 前段哈希对得上：不走 NCA 兜底核对（不出 HFS0 前段哈希不符）、rc=1（没有本体）" '[ "$(cat "$T/l10.rc")" = 1 ] && ! grep -q "HFS0 前段哈希不符" "$T/l10" && ! grep -q "Unhandled exception" "$T/l10"'

# ---- 用例：--inspect 路径（普查用的入口，退出码 3 是调用方契约，原因必须另外有一行）----
run "$T/i1" "$K" --inspect "$T/junk.bin"
ck "--inspect 不是容器：rc=3 保留契约文案" '[ "$(cat "$T/i1.rc")" = 3 ] && head -1 "$T/i1" | grep -q "could not be decrypted"'
ck "--inspect 不是容器：另起一行给出原因（修前只有折叠的一句）" 'grep -q "【原因 source】" "$T/i1"'

run "$T/i2" "$K" --inspect "$T/cutblock.nsp"
ck "--inspect 坏 NCZ：rc=3 + 原因行不折叠" '[ "$(cat "$T/i2.rc")" = 3 ] && grep -q "【原因 " "$T/i2"'
ck "--inspect 坏 NCZ：原因为 NCZ 相关（不是笼统的密钥）" 'grep -qE "【原因 (container_invalid|out_of_range|io)" "$T/i2"'

# ---- 用例：title.keys（prod.keys 里没有 title key，只能靠票据或它）----
run "$T/t1" "$T/k2/prod.keys" --inspect "$T/junk.bin"
ck "title.keys 自动读：prod.keys 同目录的 title.keys 被载入 1 条、坏行跳过 1 行"    'grep -q "标题密钥.*1 条已载入" "$T/t1" && grep -q "1 行格式不对跳过" "$T/t1"'
ck "title.keys 不打印密钥值（只报条数）" '! grep -qE "=0{32}|key *=" "$T/t1"'
# --inspect 的 stdout 是调用方 json.load 的契约（oneclick / 普查）：标题密钥这类提示只能走 stderr（#1186 转：两份 Wonder 原件因此 JSONDecodeError）
timeout 180 dotnet "$B" "$T/k2/prod.keys" --inspect "$T/junk.bin" > "$T/t1o" 2> "$T/t1e"
ck "--inspect 的 stdout 只留给 JSON：标题密钥提示在 stderr、不在 stdout" 'grep -q "标题密钥.*1 条已载入" "$T/t1e" && ! grep -q "标题密钥" "$T/t1o"' 

run "$T/t2" "$K" --inspect "$T/junk.bin" --title-keys="$T/none/such/title.keys"
ck "--title-keys 指的文件不在：rc=2（用法错，不冒作 3 = 容器读不出）且点名路径" '[ "$(cat "$T/t2.rc")" = 2 ] && grep -q "指的文件不在" "$T/t2"'

# ---- 用例：随包票据每张一行（#1511：玩家看不出读取器有没有用上包里的 .tik）：期望手写——
#   a.tik → rights id 0102…10、标题密钥已载入；b.tik 同 rights id → 已有（来自随包票据 a.tik）、不再用；p.tik 个人化 → 【红】跳过、点名 rights id ff…；不打密钥值
run "$T/tk" "$K" "$T/otk" "$T/tickets.nsp"
ck "随包票据 a.tik：rights id 0102…10 标题密钥已载入" 'grep -q "随包票据 a.tik：rights id 0102030405060708090A0B0C0D0E0F10，标题密钥已载入" "$T/tk"'
ck "随包票据 b.tik：同 rights id 已有（来自随包票据 a.tik），不再用" 'grep -q "随包票据 b.tik：rights id 0102030405060708090A0B0C0D0E0F10，已有同 rights id 的标题密钥（随包票据 a.tik），这张不再用" "$T/tk"'
ck "个人化票据 p.tik：跳过并点名 rights id" 'grep -q "p.tik 不是通用票据，跳过（rights id FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF）" "$T/tk"'
timeout 180 dotnet "$B" "$K" --inspect "$T/tickets.nsp" > "$T/tko" 2> "$T/tke"
ck "--inspect：票据行在 stderr、stdout 不混进票据行" 'grep -q "随包票据 a.tik" "$T/tke" && ! grep -q "随包票据" "$T/tko"'

# ---- 用例：并行读包的 AggregateException，缺密钥排在第二条（#772 F-nxunpack-leaf-first：兜底分类只顺着第一条 inner 走，记成 internal）----
S2A_NXUNPACK_TEST_THROW=agg-key run "$T/a1" "$K" "$T/oa" "$T/junk.bin"
ck "并行异常第二条才是缺密钥：分类 keys_missing、rc=1、不出调用栈" '[ "$(cat "$T/a1.rc")" = 1 ] && grep -q "【原因 keys_missing】" "$T/a1" && ! grep -q "Unhandled exception\|   at " "$T/a1"'

# ---- 用例：分区头魔数不对（#1511：2002-4644 PartitionSignatureVerificationFailed，解出来是乱码 = 密钥不对）——不当哈希不符降级重跑、不报 hash_mismatch ----
S2A_NXUNPACK_TEST_THROW=magic run "$T/m1" "$K" "$T/om" "$T/junk.bin"
ck "分区头魔数不对：分类 keys_wrong、rc=1、不出「校验跳过」与 hash_mismatch、不出调用栈" '[ "$(cat "$T/m1.rc")" = 1 ] && grep -q "【原因 keys_wrong】" "$T/m1" && ! grep -q "校验跳过\|hash_mismatch\|哈希校验不过" "$T/m1" && ! grep -q "Unhandled exception\|   at " "$T/m1"'

# ---- 用例：并行异常里带位置的哈希错（#787：原先只有一行原因，不说读到哪个文件 / 偏移）----
S2A_NXUNPACK_TEST_THROW=agg-hash run "$T/h1" "$K" "$T/oh" "$T/junk.bin"
ck "并行异常第二条是带位置的哈希错：rc=1、报哈希红、点名阶段 + 文件 + 偏移、不出调用栈" '[ "$(cat "$T/h1.rc")" = 1 ] && grep -q "源文件数据哈希校验不过" "$T/h1" && grep -q "读到坏块时在：建索引，文件 romfs/x.bin，文件内偏移 7" "$T/h1" && ! grep -q "Unhandled exception\|   at " "$T/h1"'

# ---- 用例：访问被拒（#792：原先落进 io「读源文件失败、文件被截断」，被拒的其实是我们自己的解包工作目录）----
S2A_NXUNPACK_TEST_THROW=denied-out run "$T/d1" "$K" "$T/od" "$T/junk.bin"
ck "写自己的工作目录被拒：分类 access_denied、点名是 S2Arm 的解包工作目录、不说源文件截断、rc=1" '[ "$(cat "$T/d1.rc")" = 1 ] && grep -q "【原因 access_denied】" "$T/d1" && grep -q "被拒的是S2Arm 自己的解包工作目录" "$T/d1" && ! grep -q "截断" "$T/d1"'
S2A_NXUNPACK_TEST_THROW=denied-src run "$T/d2" "$K" "$T/od2" "$T/junk.bin"
ck "源文件读被拒：分类 access_denied、点名是源文件" '[ "$(cat "$T/d2.rc")" = 1 ] && grep -q "【原因 access_denied】" "$T/d2" && grep -q "被拒的是源文件" "$T/d2"'

# ---- 用例：原件路径不在（诊断#24fb13：原先落进 io「文件被截断、换一份完整的」，原件其实是挪走了 / 外置盘没连上）----
run "$T/m1" "$K" "$T/om" "$T/no-such-drive/game.nsp"
ck "原件路径不在：分类 source_missing、说原件挪走或盘没连上、不说截断、rc=1" '[ "$(cat "$T/m1.rc")" = 1 ] && grep -q "【原因 source_missing】" "$T/m1" && grep -q "所在的磁盘没连上" "$T/m1" && ! grep -q "截断" "$T/m1"'

# ---- Windows 挂载卷：RomFS 发布拒绝按目录改名退避；非 Windows 不重试 ----
run "$T/p1" --test-romfs-publish "$T/publish"
ck "发布拒绝句柄等待后成功；非 Windows 直接失败；持续拒绝按 9 档退避并给出路径建议，暂存保留" '[ "$(cat "$T/p1.rc")" = 0 ] && grep -qE "Windows 同盘句柄(测试|对照)：" "$T/p1" && grep -q "负对照：windows=false 的直接发布遇一次 E_ACCESSDENIED 即原样失败" "$T/p1" && grep -q "负控：持续拒绝 → 按 dirrename 重试 9 次（总等待 60.8 秒）后报红" "$T/p1"'

# ---- 用例：任天堂稀疏本体 NCA（修订版卡带：本体程序段 0 为空稀疏段，ExeFS 在更新包里）----
KS=$T/ks/prod.keys
timeout 180 dotnet "$B" "$KS" --inspect "$T/sparse_base.nsp" > "$T/sp1.out" 2> "$T/sp1.err"; echo $? > "$T/sp1.rc"
ck "稀疏本体单独 --inspect：rc=0、不出校验跳过/content_damaged/keys_wrong、JSON 含 base(guestIsa=unknown)" '[ "$(cat "$T/sp1.rc")" = 0 ] && ! grep -q "校验跳过\|content_damaged\|keys_wrong" "$T/sp1.err" && python3 -c "import json,sys; p=json.load(open(sys.argv[1]))[\"packages\"]; assert len(p)==1 and p[0][\"type\"]==\"base\" and p[0][\"guestIsa\"]==\"unknown\"" "$T/sp1.out"'

timeout 180 dotnet "$B" "$KS" --inspect "$T/sparse_with_update.nsp" > "$T/sp2.out" 2> "$T/sp2.err"; echo $? > "$T/sp2.rc"
ck "稀疏本体 + 更新同容器 --inspect：rc=0、不出校验跳过、base(unknown) + update(aarch64)" '[ "$(cat "$T/sp2.rc")" = 0 ] && ! grep -q "校验跳过\|content_damaged\|keys_wrong" "$T/sp2.err" && python3 -c "import json,sys; p={x[\"type\"]:x for x in json.load(open(sys.argv[1]))[\"packages\"]}; assert set(p)=={\"base\",\"update\"} and p[\"base\"][\"guestIsa\"]==\"unknown\" and p[\"update\"][\"guestIsa\"]==\"aarch64\"" "$T/sp2.out"'

run "$T/sp3" "$KS" "$T/osp3" --exefs-only "$T/sparse_with_update.nsp"
ck "稀疏本体 + 更新 --exefs-only 解包：rc=0、解出 main 与 main.npdm" '[ "$(cat "$T/sp3.rc")" = 0 ] && [ -s "$T/osp3/exefs/main" ] && [ -s "$T/osp3/exefs/main.npdm" ]'

run "$T/sp4" "$KS" "$T/osp4" "$T/sparse_base.nsp"
ck "稀疏本体无更新单独解包：rc=1、明确提示稀疏本体需配合更新包、不误报 content_damaged/keys_wrong/校验跳过" '[ "$(cat "$T/sp4.rc")" = 1 ] && grep -q "稀疏本体" "$T/sp4" && grep -q "更新" "$T/sp4" && ! grep -q "校验跳过\|content_damaged\|keys_wrong" "$T/sp4"'

run "$T/sp5" "$KS" --inspect "$T/sparse_wrong_gen1.nsp"
ck "同容器含稀疏本体 + 另一代密钥错误：SiblingDecrypts 不把稀疏段当损坏，仍归 keys_wrong（非 content_damaged）" '[ "$(cat "$T/sp5.rc")" = 3 ] && grep -q "【原因 keys_wrong】" "$T/sp5" && ! grep -q "【原因 content_damaged】" "$T/sp5"'

echo "-----"
echo "$([ "$fail" = 0 ] && echo "✓" || echo "✗") nx_unpack 解包失败回归：$((pass + fail)) 项，不通 $fail"
[ "$fail" = 0 ]
