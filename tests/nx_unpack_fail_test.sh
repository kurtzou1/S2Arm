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

# ---- 用例：并行读包的 AggregateException，缺密钥排在第二条（#772 F-nxunpack-leaf-first：兜底分类只顺着第一条 inner 走，记成 internal）----
S2A_NXUNPACK_TEST_THROW=agg-key run "$T/a1" "$K" "$T/oa" "$T/junk.bin"
ck "并行异常第二条才是缺密钥：分类 keys_missing、rc=1、不出调用栈" '[ "$(cat "$T/a1.rc")" = 1 ] && grep -q "【原因 keys_missing】" "$T/a1" && ! grep -q "Unhandled exception\|   at " "$T/a1"'

# ---- 用例：并行异常里带位置的哈希错（#787：原先只有一行原因，不说读到哪个文件 / 偏移）----
S2A_NXUNPACK_TEST_THROW=agg-hash run "$T/h1" "$K" "$T/oh" "$T/junk.bin"
ck "并行异常第二条是带位置的哈希错：rc=1、报哈希红、点名阶段 + 文件 + 偏移、不出调用栈" '[ "$(cat "$T/h1.rc")" = 1 ] && grep -q "源文件数据哈希校验不过" "$T/h1" && grep -q "读到坏块时在：建索引，文件 romfs/x.bin，文件内偏移 7" "$T/h1" && ! grep -q "Unhandled exception\|   at " "$T/h1"'

# ---- 用例：访问被拒（#792：原先落进 io「读源文件失败、文件被截断」，被拒的其实是我们自己的解包工作目录）----
S2A_NXUNPACK_TEST_THROW=denied-out run "$T/d1" "$K" "$T/od" "$T/junk.bin"
ck "写自己的工作目录被拒：分类 access_denied、点名是 S2Arm 的解包工作目录、不说源文件截断、rc=1" '[ "$(cat "$T/d1.rc")" = 1 ] && grep -q "【原因 access_denied】" "$T/d1" && grep -q "被拒的是S2Arm 自己的解包工作目录" "$T/d1" && ! grep -q "截断" "$T/d1"'
S2A_NXUNPACK_TEST_THROW=denied-src run "$T/d2" "$K" "$T/od2" "$T/junk.bin"
ck "源文件读被拒：分类 access_denied、点名是源文件" '[ "$(cat "$T/d2.rc")" = 1 ] && grep -q "【原因 access_denied】" "$T/d2" && grep -q "被拒的是源文件" "$T/d2"'

echo "-----"
echo "$([ "$fail" = 0 ] && echo "✓" || echo "✗") nx_unpack 解包失败回归：$((pass + fail)) 项，不通 $fail"
[ "$fail" = 0 ]
