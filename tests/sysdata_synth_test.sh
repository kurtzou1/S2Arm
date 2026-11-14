#!/bin/bash
# 门禁覆盖：pack/sysdata_synth.py pack/sysdata_mii.py tests/ngword_verify/* compat/tree/src/Ryujinx.Horizon/Sdk/Ngc/*
# 合成系统数据单测（pack/sysdata_synth.py 0100000000000823 屏蔽词表）：bash tests/sysdata_synth_test.sh，约 30 秒（首次编验证器）
# 期望（不跑合成器就能写出）：
#   文件清单 = 98 个固定名字（区域 0–17 与 common 各 ac_<r>_{b1,b2,not_b}_nx + trie_<r>_allow_{fwd,back}，加 ac_similar_form_nx、table_similar_form_nx、version.dat）；
#   可重复：两个目录各出一份逐字节相同、同一目录重出不变；每个 gzip 文件头 mtime（第 4–7 字节）= 0；version.dat 4 字节；未登记的号退出非 0；
#   验证器（tests/ngword_verify：编进 Ryujinx 的 Ngc 源码）读合成目录全过；读真机数据目录（有就读：S2A_NGWORD_REAL，缺省 mhrise 现行产物根）Import 也全过，作为验证器的对照
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
DOTNET=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DOTNET" ] || DOTNET=$(command -v dotnet || true)
# 读文件第 <偏移> 起 <长度> 个字节的十六进制（审计 P1-159：不靠 xxd，没有 xxd 时原先空串被当成「不符」，97 个全红）
hexat() { python3 -c 'import sys; f=open(sys.argv[1],"rb"); f.seek(int(sys.argv[2])); print(f.read(int(sys.argv[3])).hex())' "$1" "$2" "$3"; }
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
SY="python3 $H/pack/sysdata_synth.py"
want() { for r in $(seq 0 17) common; do for k in b1 b2 not_b; do echo "ac_${r}_${k}_nx"; done; for k in fwd back; do echo "trie_${r}_allow_${k}"; done; done
  printf '%s\n' ac_similar_form_nx table_similar_form_nx version.dat; }
want | LC_ALL=C sort > $T/want.txt
$SY 0100000000000823 $T/a > /dev/null && $SY 0100000000000823 $T/b > /dev/null; rc=$?
ck "合成退出码 0（${rc}）" '[ $rc = 0 ]'
ls $T/a | LC_ALL=C sort > $T/got.txt
ck "文件清单 = 98 个固定名字（实得 $(wc -l < $T/got.txt | tr -d ' ') 个）" '[ $(wc -l < $T/want.txt) = 98 ] && diff -q $T/want.txt $T/got.txt > /dev/null'
ck "两次合成逐字节相同" 'diff -r $T/a $T/b > /dev/null'
h0=$(cd $T/a && cat $(ls | LC_ALL=C sort) | shasum -a 256); $SY 0100000000000823 $T/a > /dev/null; h1=$(cd $T/a && cat $(ls | LC_ALL=C sort) | shasum -a 256)
ck "同一目录重出不变" '[ "$h0" = "$h1" ]'
gzbad=0; gzn=0; for f in $T/a/*; do [ "${f##*/}" = version.dat ] && continue; gzn=$((gzn + 1))
  [ "$(hexat "$f" 0 4)" = 1f8b0800 ] && [ "$(hexat "$f" 4 4)" = 00000000 ] || gzbad=$((gzbad + 1)); done
ck "gzip 头 1f8b0800 + mtime 0（${gzn} 个，不符 ${gzbad} 个）" '[ $gzn = 97 ] && [ $gzbad = 0 ]'
osbad=0; for f in $T/a/*; do [ "${f##*/}" = version.dat ] && continue
  [ "$(hexat "$f" 9 1)" = ff ] || osbad=$((osbad + 1)); done
ck "gzip OS 字节固定为 ff（不符 ${osbad} 个）" '[ $osbad = 0 ]'
ck "version.dat 4 字节" '[ $(wc -c < $T/a/version.dat) = 4 ]'
$SY 0100000000000999 $T/x > /dev/null 2>&1; rc=$?
ck "未登记的号退出非 0（${rc}）" '[ $rc != 0 ]'
if [ -z "$DOTNET" ]; then   # 没有 .NET SDK：验证器编不了，前面的合成检查照判；都通就退 75（这支只跑了一半），不把缺 SDK 记成代码红
  echo "sysdata_synth：没有 .NET SDK，验证器没跑（环境未就绪）"; [ $bad = 0 ] && exit 75; echo "sysdata_synth 单测有不通"; exit 1; fi
MSBUILDDISABLENODEREUSE=1 timeout 400 "$DOTNET" build -c Release "$H/tests/ngword_verify/NgWordVerify.csproj" --artifacts-path "$T/art" -nologo -v q 2>&1 | grep -E " error " | sort -u
V=$T/art/bin/NgWordVerify/release/NgWordVerify.dll
ck "验证器编译" '[ -f $V ]'
if [ -f $V ]; then
  "$DOTNET" $V $T/a empty | sed 's/^/    /'; rc=${PIPESTATUS[0]}
  ck "验证器读合成数据全过（${rc}）" '[ $rc = 0 ]'
  R=${S2A_NGWORD_REAL:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots/mhrise@现行/systemdata/0100000000000823}
  if [ -d "$R" ]; then
    ck "真机数据文件清单与固定名字一致（${R}）" 'ls "$R" | LC_ALL=C sort | diff -q - $T/want.txt > /dev/null'
    "$DOTNET" $V "$R" real | sed 's/^/    /'; rc=${PIPESTATUS[0]}
    ck "验证器读真机数据全过（对照，${rc}）" '[ $rc = 0 ]'
  else
    echo "【黄】没有真机数据目录 ${R}：跳过对照（S2A_NGWORD_REAL 指定）"
  fi
fi
# 0100000000000802 Mii 资源：6 个固定文件名、可重复、pack/sysdata_mii.py check 解析通过；反证：改掉一个条目的压缩长 → check 报红；真数据（有就读）check 也过
$SY 0100000000000802 $T/m1 > /dev/null && $SY 0100000000000802 $T/m2 > /dev/null; rc=$?
ck "Mii：合成 6 个固定文件（ShapeHigh/Mid + NXTexture{Low,Mid}{Linear,SRGB}），两次逐字节同（${rc}）" '[ $rc = 0 ] && [ "$(ls $T/m1 | tr "\n" " ")" = "NXTextureLowLinear.dat NXTextureLowSRGB.dat NXTextureMidLinear.dat NXTextureMidSRGB.dat ShapeHigh.dat ShapeMid.dat " ] && diff -r $T/m1 $T/m2 > /dev/null'
ck "Mii：解析器读合成数据全过" 'python3 $H/pack/sysdata_mii.py check $T/m1 > /dev/null'
python3 -c "import sys;p=sys.argv[1];b=bytearray(open(p,'rb').read());o=0x6c+88;b[o+8]^=1;open(p,'wb').write(b)" $T/m2/ShapeHigh.dat
ck "Mii 反证：改坏一个条目的压缩长 → 解析器报红" '! python3 $H/pack/sysdata_mii.py check $T/m2 > /dev/null'
RM=${S2A_MII_REAL:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots/mk8d@现行/systemdata/0100000000000802}
if [ -d "$RM" ] && [ ! -e "$RM.synth" ]; then ck "Mii：解析器读真数据也过（对照，${RM}）" 'python3 $H/pack/sysdata_mii.py check "$RM" > /dev/null'
else echo "【黄】没有真 Mii 数据目录 ${RM}：跳过对照（S2A_MII_REAL 指定）"; fi
# 0400000000000849 Switch 2 Mii 资源（期望手写：0802 的 6 个文件 + OunceTexture{High,Mid,Low}{Linear,SRGB} 6 个 = 12 个；Ounce 贴图与 NXTextureLowLinear 逐字节同（同一份空贴图）；
#   形状 / NX 贴图照 0802 的解析器读过；两次合成逐字节同；--ids 列出 0849）
$SY 0400000000000849 $T/o1 > /dev/null && $SY 0400000000000849 $T/o2 > /dev/null; rc=$?
ow="NXTextureLowLinear.dat NXTextureLowSRGB.dat NXTextureMidLinear.dat NXTextureMidSRGB.dat OunceTextureHighLinear.dat OunceTextureHighSRGB.dat OunceTextureLowLinear.dat OunceTextureLowSRGB.dat OunceTextureMidLinear.dat OunceTextureMidSRGB.dat ShapeHigh.dat ShapeMid.dat "
ck "0849：合成 12 个固定文件、两次逐字节同（${rc}）" '[ $rc = 0 ] && [ "$(ls $T/o1 | LC_ALL=C sort | tr "\n" " ")" = "$ow" ] && diff -r $T/o1 $T/o2 > /dev/null'
ck "0849：解析器读形状 / NX 贴图通过，Ounce 贴图与 NX 贴图同一份" 'python3 $H/pack/sysdata_mii.py check $T/o1 > /dev/null && for f in $T/o1/OunceTexture*.dat; do cmp -s "$f" $T/o1/NXTextureLowLinear.dat || exit 1; done'
ck "--ids 列出 0849" '$SY --ids | grep -qx 0400000000000849'
# 0100000000000806 旧版屏蔽词表（期望手写：0.txt–15.txt + common.txt + version.dat 共 18 个；每份 txt = FE FF BOM + UTF-16 大端的一行
#   「^s2arm0no0banned0words0placeholder$\n」；version.dat = 00 00 00 20；两次合成逐字节同；--ids 列出 0806）
$SY 0100000000000806 $T/n1 > /dev/null && $SY 0100000000000806 $T/n2 > /dev/null; rc=$?
nw="$(for i in $(seq 0 15); do printf '%s.txt ' $i; done)common.txt version.dat"
nw=$(echo $nw | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
ck "0806：合成 18 个固定文件、两次逐字节同（${rc}）" '[ $rc = 0 ] && [ "$(ls $T/n1 | LC_ALL=C sort | tr "\n" " ")" = "$nw" ] && diff -r $T/n1 $T/n2 > /dev/null'
want=$(python3 -c 'import sys; sys.stdout.write((b"\xfe\xff" + "^s2arm0no0banned0words0placeholder$\n".encode("utf-16-be")).hex())')   # 期望手写成十六进制：shell 取值会丢 UTF-16 里的 0 字节
ck "0806：每份 txt 是 BOM + UTF-16BE 的那一行，version.dat = 00000020" 'for f in $T/n1/*.txt; do [ "$(xxd -p "$f" | tr -d "\n")" = "$want" ] || exit 1; done; [ "$(xxd -p $T/n1/version.dat)" = 00000020 ]'
ck "--ids 列出 0806" '$SY --ids | grep -qx 0100000000000806'
[ $bad = 0 ] && echo "✓ sysdata_synth 单测全过" || { echo "sysdata_synth 单测有不通"; exit 1; }
