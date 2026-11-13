#!/bin/bash
# 系统数据阶段单测（pack/stage_sysdata.sh + 共享实现 + pack/sysdata_need.py，假字体 / 临时产物根）：bash tests/stage_sysdata_test.sh
# 10-25 维护者：系统数据每款都提供，不按逐款需求表判断（数码宝贝港版没登记 0823 起局 Break）。期望按规则手写：
#   ① 任意一款（不在任何表里）、产物根和玩家目录都没有 → 退出 0、不报红黄；合成 0802（6 个文件，sysdata_mii.py check 通过）与 0823（98 个文件）进新现行，
#      旁边各有 .synth；字体、时区照在
#   ② 玩家目录（S2A_SYSDATA）给了真的 0802 → 换成真的（逐字节同来源）、0802.synth 去掉；0823 仍是合成的
#   ③ 再跑 → 跳过、现行不动；③b 玩家目录的 0802 换了内容（同名同大小）→ 换成新的，换完再跑跳过（审计 #1534 P1-54）
#   ④ 玩家目录里 0802 是空目录 → 不认，照样用合成的；④b 只有 ._ / .DS_Store 同空目录；③c 只有 ._ 附属文件变了 → 再跑照旧跳过
#   ⑤ 玩家目录有 0801（没有合成器的号）→ 拷进；没有 0801 → 不提供、不报红
#   ⑥ 产物根里已有真的 0823 → 留着，不换成合成的
#   ⑦ 需求表不参与判断：S2A_SYSDATA_NEED 指向一张「本构建不要任何系统数据」的表 → 照样提供 0802 / 0823
# 旧代码反证：STAGE=<旧版 stage_sysdata.sh> NEED=<旧版 sysdata_need.py> bash tests/stage_sysdata_test.sh（旧版按表：表外的款只打【黄】、不合成 → ① 不通）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack $T/repo/tools $T/roots $T/fonts $T/sd/0100000000000801 $T/sd/0100000000000802 $T/sd_empty/0100000000000802
cp "$H/pack/roots.sh" "$H/pack/sysdata_synth.py" "$H/pack/sysdata_mii.py" $T/repo/pack/; cp "${NEED:-$H/pack/sysdata_need.py}" $T/repo/pack/sysdata_need.py
cp -R "$H/pack/stages" $T/repo/pack/
cp "${STAGE:-$H/pack/stage_sysdata.sh}" $T/repo/pack/stage_sysdata.sh; cp "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $T/repo/tools/
printf 'font' > $T/fonts/a.bfttf; printf 'errmsg-v1' > $T/sd/0100000000000801/version.dat; printf 'real' > $T/sd/0100000000000802/ShapeHigh.dat
printf '# 程序号\t构建号\t版本\t系统数据号\t用途\t依据\n0100CCCC00000000\t11223344\t1.0\t-\t-\t单测：本构建不要\n' > $T/need.tsv
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_FONTS=$T/fonts; unset S2A_SYSDATA S2A_SYSDATA_NEED
mk() {   # mk <款> <程序号> <构建号前 4 字节>：产物根 <款>@s0（时区已在、无字体）并设现行
  local d=$T/roots/$1@s0; mkdir -p $d/exefs $d/systemdata/010000000000080E; printf 'title_id\t%s\ndisplay_version\t9.9\n' "$2" > $d/unpack.tsv
  python3 -c "import sys;open(sys.argv[1],'wb').write(b'\0'*0x40+bytes.fromhex(sys.argv[2])+b'\0'*12+b'\0'*32)" $d/exefs/main "$3"; echo tz > $d/systemdata/010000000000080E/binaryList.txt; ln -s $1@s0 $T/roots/$1@现行
}
S() { bash $T/repo/pack/stage_sysdata.sh "$1"; }
c() { cd -P $T/roots/$1@现行 && pwd; }
n() { ls "$(c "$1")/systemdata/$2" 2> /dev/null | wc -l | tr -d ' '; }
mk g 0100AAAA00000000 11223344
o=$(S g 2>&1); r=$?
ck "① 表外的款、两处都没有 → 不报红黄（rc=${r}）、合成 0802 $(n g 0100000000000802) 个 / 0823 $(n g 0100000000000823) 个文件、各带 .synth" '[ $r = 0 ] && [[ "$o" != *【红】* ]] && [[ "$o" != *【黄】* ]] && [ "$(n g 0100000000000802)" = 6 ] && [ "$(n g 0100000000000823)" = 98 ] && [ -f "$(c g)/systemdata/0100000000000802.synth" ] && [ -f "$(c g)/systemdata/0100000000000823.synth" ]'
ck "① 合成 Switch 2 Mii 资源 0849 $(n g 0400000000000849) 个文件、带 .synth" '[ "$(n g 0400000000000849)" = 12 ] && [ -f "$(c g)/systemdata/0400000000000849.synth" ]'
ck "① 合成的 0802 解析器读一遍通过；字体、时区照在" 'python3 $T/repo/pack/sysdata_mii.py check "$(c g)/systemdata/0100000000000802" > /dev/null && [ -f "$(c g)/systemdata/fonts/a.bfttf" ] && [ -f "$(c g)/systemdata/010000000000080E/binaryList.txt" ]'
o=$(S2A_SYSDATA=$T/sd S g 2>&1); r=$?
ck "② 玩家给了真的 0802 → 换成真的、去掉 .synth；0823 仍合成（rc=${r}）" '[ $r = 0 ] && [ "$(cat "$(c g)/systemdata/0100000000000802/ShapeHigh.dat")" = real ] && [ ! -e "$(c g)/systemdata/0100000000000802.synth" ] && [ -f "$(c g)/systemdata/0100000000000823.synth" ]'
ck "⑤ 玩家目录有 0801 → 拷进、内容同来源" 'cmp -s "$(c g)/systemdata/0100000000000801/version.dat" $T/sd/0100000000000801/version.dat'
b=$(c g); o=$(S2A_SYSDATA=$T/sd S g 2>&1); r=$?
ck "③ 再跑 → 跳过、现行不动（rc=${r}）" '[ $r = 0 ] && [ "$(c g)" = "$b" ] && [[ "$o" == *跳过* ]]'
# ③b 审计 #1534 P1-54：玩家目录的 0802 换了新转储（同名同大小、内容不同）→ 换成新的；再跑 → 跳过
printf 'REAL' > $T/sd/0100000000000802/ShapeHigh.dat; b=$(c g); o=$(S2A_SYSDATA=$T/sd S g 2>&1); r=$?
ck "③b 玩家目录 0802 内容换了 → 产物根换成新的、现行换版本（rc=${r}）" '[ $r = 0 ] && [ "$(c g)" != "$b" ] && [ "$(cat "$(c g)/systemdata/0100000000000802/ShapeHigh.dat")" = REAL ]'
b=$(c g); o=$(S2A_SYSDATA=$T/sd S g 2>&1); r=$?
ck "③b 换完再跑 → 跳过、现行不动（rc=${r}）" '[ $r = 0 ] && [ "$(c g)" = "$b" ] && [[ "$o" == *跳过* ]]'
# ③c exFAT / FAT 上 macOS 在旁边放 ._<名>（存扩展属性，内容随属性变）、访达写 .DS_Store：不是系统数据，变了也不算玩家目录换了 → 再跑照旧跳过
printf 'x1' > $T/sd/0100000000000802/._ShapeHigh.dat; : > $T/sd/0100000000000802/.DS_Store; S2A_SYSDATA=$T/sd S g > /dev/null 2>&1
printf 'x2' > $T/sd/0100000000000802/._ShapeHigh.dat; b=$(c g); o=$(S2A_SYSDATA=$T/sd S g 2>&1); r=$?
ck "③c 玩家目录里只有 ._ 附属文件变了 → 跳过、现行不动（rc=${r}）" '[ $r = 0 ] && [ "$(c g)" = "$b" ] && [[ "$o" == *跳过* ]]'
mk e 0100EEEE00000000 22222222
o=$(S2A_SYSDATA=$T/sd_empty S e 2>&1); r=$?
ck "④ 玩家目录里 0802 是空目录 → 不认、用合成的（rc=${r}）" '[ $r = 0 ] && [ -f "$(c e)/systemdata/0100000000000802.synth" ] && [ "$(n e 0100000000000802)" = 6 ]'
ck "⑤ 没有 0801 → 不提供、不报红" '[ ! -e "$(c e)/systemdata/0100000000000801" ] && [[ "$o" != *【红】* ]]'
# ④b 玩家目录 0802 里只有系统附属文件（._ShapeHigh.dat、.DS_Store）→ 同空目录，不认、用合成的
mkdir -p $T/sd_junk/0100000000000802; printf 'x' > $T/sd_junk/0100000000000802/._ShapeHigh.dat; : > $T/sd_junk/0100000000000802/.DS_Store
mk j 0100DDDD00000000 44444444
o=$(S2A_SYSDATA=$T/sd_junk S j 2>&1); r=$?
ck "④b 玩家目录 0802 只有 ._ / .DS_Store → 不认、用合成的（rc=${r}）" '[ $r = 0 ] && [ -f "$(c j)/systemdata/0100000000000802.synth" ] && [ "$(n j 0100000000000802)" = 6 ]'
mk k 0100FFFF00000000 33333333; mkdir -p $T/roots/k@s0/systemdata/0100000000000823; echo real > $T/roots/k@s0/systemdata/0100000000000823/real.dat
o=$(S k 2>&1); r=$?
ck "⑥ 产物根已有真的 0823 → 留着、不换成合成的（rc=${r}）" '[ $r = 0 ] && [ "$(cat "$(c k)/systemdata/0100000000000823/real.dat")" = real ] && [ ! -e "$(c k)/systemdata/0100000000000823.synth" ] && [ "$(n k 0100000000000823)" = 1 ]'
mk t 0100CCCC00000000 11223344
o=$(S2A_SYSDATA_NEED=$T/need.tsv S t 2>&1); r=$?
ck "⑦ 需求表说本构建不要 → 照样提供 0802 / 0823（rc=${r}）" '[ $r = 0 ] && [ "$(n t 0100000000000802)" = 6 ] && [ "$(n t 0100000000000823)" = 98 ]'
# ⑧–⑩ 字体缺省开源（维护者 10-30）：不给 S2A_FONTS、没装 App（S2A_APP_FONTS_DIRS 指空目录）→ 用开源字体目录 S2A_OPENFONTS_DIR；
#   戳（.generator.sha256）= 生成器 pack/fonts/make_open_fonts.py 的 sha256 且有 7 个 .bfttf 才直接用，否则调 S2A_PYTHON 跑生成器现做
mkdir -p $T/repo/pack/fonts $T/of $T/noapp; cp "$H/pack/fonts/make_open_fonts.py" $T/repo/pack/fonts/
GH=$(shasum -a 256 $T/repo/pack/fonts/make_open_fonts.py | cut -d' ' -f1)
for i in 1 2 3 4 5 6 7; do printf 'open%s' $i > $T/of/f$i.bfttf; done; echo "$GH" > $T/of/.generator.sha256; echo ofl > $T/of/OFL-NotoSans.txt
printf '#!/bin/bash\nmkdir -p "$2"; for i in 1 2 3 4 5 6 7; do printf gen$i > "$2/g$i.bfttf"; done\n' > $T/fakegen; chmod +x $T/fakegen
F0() { env -u S2A_FONTS S2A_APP_FONTS_DIRS=$T/noapp S2A_OPENFONTS_DIR=$T/of "$@"; }
mk f8 0100F8F800000000 44444444
o=$(F0 S2A_PYTHON=false bash $T/repo/pack/stage_sysdata.sh f8 2>&1); r=$?
ck "⑧ 不给字体、戳对 → 用开源字体目录的 7 个、不现做（rc=${r}）" '[ $r = 0 ] && [ "$(ls "$(c f8)/systemdata/fonts" | wc -l | tr -d " ")" = 7 ] && [ "$(cat "$(c f8)/systemdata/fonts/f3.bfttf")" = open3 ] && [[ "$o" != *现做* ]]'
b=$(c f8); o=$(F0 S2A_PYTHON=false bash $T/repo/pack/stage_sysdata.sh f8 2>&1); r=$?
ck "⑧ 再跑 → 跳过（字体目录另有许可文本不算不齐）、现行不动（rc=${r}）" '[ $r = 0 ] && [ "$(c f8)" = "$b" ] && [[ "$o" == *跳过* ]]'
echo stale > $T/of/.generator.sha256; mk f9 0100F9F900000000 55555555
o=$(F0 S2A_PYTHON=$T/fakegen bash $T/repo/pack/stage_sysdata.sh f9 2>&1); r=$?
ck "⑨ 戳过期 → 跑生成器现做、换进位、戳 = 生成器哈希（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *现做* ]] && [ "$(cat "$(c f9)/systemdata/fonts/g5.bfttf")" = gen5 ] && [ "$(cat $T/of/.generator.sha256)" = "$GH" ] && [ ! -e $T/of/f1.bfttf ] && ! ls -d $T/of.tmp.* > /dev/null 2>&1'
echo stale > $T/of/.generator.sha256; mk fa 0100FAFA00000000 66666666
o=$(F0 S2A_PYTHON=false bash $T/repo/pack/stage_sysdata.sh fa 2>&1); r=$?
ck "⑩ 戳过期且生成器失败 → 报红、退非 0、不留临时目录（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *【红】*开源替代字体* ]] && ! ls -d $T/of.tmp.* > /dev/null 2>&1'
# ⑪ 拷字体失败要报原因（审计：玩家只见「拷字体失败」）：PATH 前插假 cp，只对拷进 systemdata/fonts/ 的那次动手脚，其余照真 cp
#   ⑪a 克隆复制（-c）报 clonefile failed: Cross-device link（#290 原文：旧 macOS 字体源与库不同卷）、普通复制能成 → 退 0、字体在、黄行带第一次的原因
#   ⑪b 两次都报 Permission denied → 退非 0、红行「拷字体失败：」后带两次 cp 的原文
mkdir -p $T/fakecp; printf '#!/bin/bash\nfor a in "$@"; do last=$a; done\ncase "$last" in */systemdata/fonts/) case "$1:$FAKECP" in -c:*) echo "cp: $2: clonefile failed: Cross-device link" >&2; exit 1 ;; *:both) echo "cp: $last: Permission denied" >&2; exit 1 ;; esac ;; esac\nexec /bin/cp "$@"\n' > $T/fakecp/cp; chmod +x $T/fakecp/cp
if [ "$(uname -s)" = Darwin ]; then
  mk fc 0100FCFC00000000 77777777
  o=$(PATH=$T/fakecp:$PATH FAKECP=clone S fc 2>&1); r=$?
  ck "⑪a 克隆复制失败、普通复制成 → 退 0、字体在、黄行带原因（rc=${r}）" '[ $r = 0 ] && [ -f "$(c fc)/systemdata/fonts/a.bfttf" ] && [[ "$o" == *【黄】*克隆复制失败*"Cross-device link"* ]]'
  mk fd 0100FDFD00000000 88888888
  o=$(PATH=$T/fakecp:$PATH FAKECP=both S fd 2>&1); r=$?
  ck "⑪b 两次都失败 → 退非 0、红行带两次原因（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *"【红】拷字体失败："*"Cross-device link"*"普通复制："*"Permission denied"* ]]'
fi
# ⑫ 只模拟 cp 失败。递归克隆可能先留下半份目标目录，普通复制必须写到正确层级。
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$T/fakesd" "$T/source with space/0100000000000801/subdir"
  sd_source="$T/source with space"
  printf 'cross-volume' > "$sd_source/0100000000000801/subdir/sample.dat"
  cat > "$T/fakesd/cp" <<'EOF'
#!/bin/bash
for arg in "$@"; do last=$arg; done
case "$last" in
  */systemdata/0100000000000801)
    if [ "$1" = -c ]; then
      mkdir -p "$last" && printf 'partial' > "$last/clone-leftover"
      printf 'cp: clonefile failed: %s\n' "${TEST_SYSDATA_CLONE_ERR:-Cross-device link}" >&2
      exit 1
    fi
    if [ "${TEST_SYSDATA_DENY:-0}" = 1 ]; then printf 'cp: Permission denied\n' >&2; exit 1; fi ;;
esac
exec /bin/cp "$@"
EOF
  chmod +x "$T/fakesd/cp"
  mk sd 0100DADA00000000 99999999
  o=$(PATH=$T/fakesd:$PATH S2A_SYSDATA="$sd_source" S sd 2>&1); r=$?
  ck "⑫a 目录克隆跨卷失败 → 清理半份目标、普通复制成功、黄行带原因（rc=${r}）" '[ $r = 0 ] && cmp -s "$(c sd)/systemdata/0100000000000801/subdir/sample.dat" "$sd_source/0100000000000801/subdir/sample.dat" && [ ! -e "$(c sd)/systemdata/0100000000000801/clone-leftover" ] && [[ "$o" == *【黄】*克隆复制失败*"Cross-device link"* ]]'
  mk sf 0100DADA00000001 aaaaaaaa
  b=$(c sf); o=$(PATH=$T/fakesd:$PATH S2A_SYSDATA="$sd_source" TEST_SYSDATA_DENY=1 S sf 2>&1); r=$?
  ck "⑫b 两次复制都失败 → 保留两次错误、现行不动（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *【红】*拷系统数据*"Cross-device link"*"普通复制："*"Permission denied"* ]] && [ "$(c sf)" = "$b" ]'
  mk sg 0100DADA00000002 bbbbbbbb
  o=$(PATH=$T/fakesd:$PATH S2A_SYSDATA="$sd_source" TEST_SYSDATA_CLONE_ERR='Operation not supported' S sg 2>&1); r=$?
  ck "⑫c 同卷不支持克隆 → 仍可普通复制、黄行带原因（rc=${r}）" '[ $r = 0 ] && cmp -s "$(c sg)/systemdata/0100000000000801/subdir/sample.dat" "$sd_source/0100000000000801/subdir/sample.dat" && [[ "$o" == *【黄】*克隆复制失败*"Operation not supported"* ]]'
fi
chmod -R u+w $T; rm -rf $T; [ $bad = 0 ] && echo "stage_sysdata 单测全过" || { echo "stage_sysdata 单测有不通"; exit 1; }
