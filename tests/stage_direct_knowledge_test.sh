#!/bin/bash
# 跑局知识进阶段键单测（审计 #1534 P1-54：pack/stage_direct.sh 的 know- 键 + pack/stage_direct_seed.sh 轻阶段；假 direct_lib.py、真 run_knowledge / pso_seed，临时产物根，约 10 秒）
#   bash tests/stage_direct_knowledge_test.sh
# 期望按「什么改产物」手写（直连库只用配对 / 片元整数输出变体 / 采样模拟变体三张表；种子表只用 seen 行 + 直连库键），每步与上一步比：
#   操作                                               直连键   种子键   直连出库调用
#   ① 基线（S A、R1 浮点画布、P(A,C)、P(B,D)）           —        —        1 次；种子表 2 行（S A、R1）
#   ② 不变再跑                                          不变     不变     不加（两段都打跳过）
#   ③ 同内容复制一份来源、改修改时间、调换 P 行先后      不变     不变     不加
#   ④ 新 R 行（片元不要整数输出、不采样模拟）            不变     变       不加；种子表 +1 行
#   ⑤ 新 R 行（画布 0 = 无符号整数格式 → fout_want +1）  变       变       +1
#   ⑥ 新 P 行（两支都在库里）                           变       变       +1；出库拿到的快照 pairs.tsv 有这一对
#   ⑦ 格式坏的行（坏键 P、短 R、杂行）                  不变     不变     不加
#   ⑧ 与路径 / 机器无关：同一份 pso_seed/ 拷到两处不同路径（= Mac 与Windows 出包机）经 S2A_PSO_SOURCES 只算键 → 两处直连键、种子键都与现行逐字相同；
#      家目录 ~/Documents/wire 里多一条 P 行 → 键不变（出包不读文稿）
#   ⑨ 包键（S2A_DUAL=1）带「+seed=<种子键>」
#   ⑩ 只调换 S / R 行先后（种子表行序 = 首用序，是产物的一部分）→ 直连键不变、种子键变（如实：行序会改随包种子表）
#   ⑪ Mac 局收局并进种子目录（tools/pso_seed_keep.sh）：首次建表、再并只补新行不改旧行序、没新行不动文件、本机没有表退 0；--all 一次性迁移文稿里每一款、不收 .bak 目录
#   ⑫ 种子工具失败 → 种子段退 0、打【黄】、现行种子表留着、不记键；修好再跑重新生成（审计 #1592 P1-100）
#   反证：fixture 里的 stage_direct.sh 去掉「KT="$KT know-$KNK"」一行（= 修前只按游戏输入与代码进键）→ 新 P 行直连键不变
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack/stage_inputs $T/repo/tools $T/repo/graphics/nvn/tools $T/repo/translator $T/repo/graphics/tools/direct $T/repo/graphics/tools/shbake $T/repo/graphics/metal $T/roots $T/bin
cp "$H/pack/roots.sh" "$H/pack/stage_direct.sh" "$H/pack/stage_direct_seed.sh" "$H/pack/stage_keyfiles.sh" "$H/pack/resource_input_key.py" "$H/pack/ue_pak.py" \
   "$H/pack/ipa_key.sh" "$H/pack/pkg_srcs.py" "$H/pack/pkg_inputs_key.py" $T/repo/pack/
mkdir -p $T/repo/pack/orch && cp "$H/pack/orch/current.py" $T/repo/pack/orch/   # roots.sh 写现行指针 / 迁移老库（pack/orch/current.py）
cp "$H/tools/toolchain.sh" "$H/tools/toolchain.env" "$H/tools/machine.sh" "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" "$H/tools/stage_deps.py" $T/repo/tools/; cp -R "$H/tools/stage_deps_hook" $T/repo/tools/
cp "$H/graphics/nvn/tools/romfs_list.py" "$H/graphics/nvn/tools/gfx_api.py" $T/repo/graphics/nvn/tools/; cp "$H/graphics/tools/shbake/pak_crypto.py" $T/repo/graphics/tools/shbake/
mkdir -p "$T/repo/tools"; cp "$H/tools/pool_workers.py" "$H/tools/progress.py" "$T/repo/tools/"   # romfs_list / pak_crypto 经它取核数（#1332：核数唯一来源）
for f in run_knowledge.py fout_want.py se_want.py run_pairs.py pso_layout.py pso_layout.json pso_seed.py; do cp "$H/graphics/tools/direct/$f" $T/repo/graphics/tools/direct/; done
echo m > $T/repo/graphics/metal/gal_prog.m; printf 'def version(): return "v1"\n' > $T/repo/translator/dmsh_chain.py
printf '入\t%s\n' pack/stage_direct.sh pack/ue_pak.py graphics/metal/gal_prog.m graphics/tools/direct/run_knowledge.py > $T/repo/pack/stage_inputs/direct.tsv
printf '入\t%s\n' pack/stage_direct_seed.sh graphics/tools/direct/pso_seed.py graphics/tools/direct/pso_layout.json > $T/repo/pack/stage_inputs/direct_seed.tsv
cat > $T/bin/xcrun <<'EOF'
#!/bin/sh
[ "$*" = "-sdk iphoneos metal --version" ] && { echo "Apple metal version 32023.9 (metalfe-fixture)"; exit 0; }
[ "$*" = "--sdk iphoneos --show-sdk-version" ] && { echo 27.0; exit 0; }
exit 1
EOF
chmod +x $T/bin/xcrun; export PATH=$T/bin:$PATH DSX_LIB=$T/libdsx.dylib
# 假 Xcode 目录（tools/toolchain.sh 先要选中一个存在的 Xcode 目录，再经上面的 xcrun 替身问 SDK / Metal 版本）：不依赖本机装没装 Xcode，Linux 门禁机同样走通
mkdir -p $T/Xcode.app/Contents/Developer; export S2A_DEVELOPER_DIR=$T/Xcode.app/Contents/Developer
printf 'exit 0\n' > $T/repo/pack/stage_direct_profile.sh
printf 'import json,os\nprint(json.dumps({"profile": os.path.dirname(__file__)+"/profile/0100", "profile_key": "profile1"}))\n' > $T/repo/pack/direct_profile_stage.py
# 假出库：库键 A B C D；记调用次数；把拿到的跑局知识快照（S2A_RUN_KNOWLEDGE）的配对表留一份看
cat > $T/repo/graphics/tools/direct/direct_lib.py <<'EOF'
import os, shutil, sys
O = sys.argv[2]; C = os.environ['FAKE_CALLS']; open(C, 'a').write('1\n')
kn = os.environ.get('S2A_RUN_KNOWLEDGE') or sys.exit('没交快照')
shutil.copy(kn + '/pairs.tsv', C + '.pairs')
os.makedirs(O + '/b-v1', exist_ok=True); open(O + '/b-v1/lib.idx', 'w').write('m\n'); open(O + '/keys.tsv', 'w').write(''.join(k * 16 + '\n' for k in 'abcd')); open(O + '/shader_map.tsv', 'w').write('# map\n')
open(O + '/direct_lib.json', 'w').write('{"title": "0100AAAA00000000", "pso_seed": "gen"}\n')
print('[直连库] 🟢 0100AAAA00000000 直连库 b-v1：并集 4，出库 4，没出成 0')
EOF
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
# 假仓库不读本机配置（11-09：门禁 / 维护方机器设了 S2A_MACHINE_LOCAL，machine.local 里 S2A_PY=$HOME/…/venv 在 HOME 换成临时目录后指向不存在的 Python，12 例全红）
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared FAKE_CALLS=$T/calls S2A_RUN_ROOT=$T/run HOME=$T/home; unset S2A_PSO_SOURCES S2A_MACHINE_LOCAL S2A_PY
mkdir -p $T/roots/acnh@s0/romfs $T/roots/acnh@s0/exefs $T/home; echo r > $T/roots/acnh@s0/romfs/f; echo main > $T/roots/acnh@s0/exefs/main; echo ksh > $T/roots/acnh@s0/.stage_shaders
printf 'title_id\t0100aaaa00000000\n' > $T/roots/acnh@s0/unpack.tsv; printf '%s\n' acnh@s0 > $T/roots/acnh@现行
SD=$T/run/s2arm/pso_seed/0100AAAA00000000; mkdir -p $SD
A=aaaaaaaaaaaaaaaa B=bbbbbbbbbbbbbbbb C=cccccccccccccccc D=dddddddddddddddd
R() { python3 - "$T/repo/graphics/tools/direct/pso_layout.json" "$@" <<'EOF'   # R <顶点键> <片元键> [画布 0 像素格式] → 一条 R 行（同 t_run_knowledge.py 的造法）
import json, struct, sys
L = json.load(open(sys.argv[1])); vs, fs = sys.argv[2:4]; cf = int(sys.argv[4]) if len(sys.argv) > 4 else 0
b = bytearray(L['skey_size']); b[0:24] = (vs + '_b').encode().ljust(24, b'\0'); o, w = L['fs']; b[o:o + w] = (fs + '_b').encode().ljust(w, b'\0'); b[L['cfmt']:L['cfmt'] + 4] = struct.pack('<I', cf)
print('R\t' + b.hex())
EOF
}
R1=$(R $A $B); R2=$(R $A $D); R3=$(R $A $C 13); R4=$(R $B $C)
cur() { cd -P $T/roots/$(cat $T/roots/acnh@现行) && pwd; }
calls() { wc -l < $T/calls 2> /dev/null | tr -d ' '; }
rows() { grep -vc '^#' "$(cur)/shaders/direct/pso_manifest.tsv" 2> /dev/null; }
S() { OD=$(bash $T/repo/pack/stage_direct.sh acnh 2>&1); RD=$?; OS=$(bash $T/repo/pack/stage_direct_seed.sh acnh 2>&1); RS=$?; KD=$(cat "$(cur)/.stage_direct"); KS=$(cat "$(cur)/.stage_direct_seed" 2> /dev/null); }
step() { KD0=$KD KS0=$KS N0=$(calls) M0=$(rows); S; }
same() { [ $RD = 0 ] && [ $RS = 0 ] && [ "$KD" = "$KD0" ] && [ "$KS" = "$KS0" ] && [ "$(calls)" = "$N0" ] && [[ "$OD" == *跳过* ]] && [[ "$OS" == *跳过* ]]; }
printf 'S\t%s_b\t0\n%s\nP\t%s\t%s\nP\t%s\t%s\n' $A "$R1" $A $C $B $D > $SD/job1.tsv
S; ck "① 基线：两段退 0（${RD} / ${RS}）、出库 1 次、种子表 2 行（S A、R1；实 $(rows)）、记直连键 / 种子键（${KD} / ${KS}）" '[ $RD = 0 ] && [ $RS = 0 ] && [ "$(calls)" = 1 ] && [ "$(rows)" = 2 ] && [ -n "$KD" ] && [ -n "$KS" ] && [ -s "$(cur)/knowledge/direct/pairs.tsv" ] && [ -s "$(cur)/knowledge/seed/seen.tsv" ]'
step; ck "② 不变再跑 → 直连键 / 种子键不变、两段都跳过、不出库" 'same'
cp $SD/job1.tsv $SD/job1_copy.tsv; touch -t 202001010000 $SD/job1.tsv; printf 'S\t%s_b\t0\n%s\nP\t%s\t%s\nP\t%s\t%s\n' $A "$R1" $B $D $A $C > $SD/job1.tsv
step; ck "③ 同内容复制一份、改修改时间、调换 P 行先后 → 键都不变（${KD} / ${KS}）、不出库" 'same'
printf '%s\n' "$R2" > $SD/job2.tsv
step; ck "④ 新 R 行（A→D，浮点画布）→ 直连键不变（${KD0} → ${KD}）、种子键变（${KS0} → ${KS}）、不出库、种子表 ${M0} → $(rows) 行" '[ $RD = 0 ] && [ $RS = 0 ] && [ "$KD" = "$KD0" ] && [ "$KS" != "$KS0" ] && [ "$(calls)" = "$N0" ] && [ "$(rows)" = $((M0 + 1)) ] && [[ "$OD" == *跳过* ]]'
printf '%s\n' "$R3" > $SD/job3.tsv
step; ck "⑤ 新 R 行（A→C，画布 0 无符号整数 → fout_want +1）→ 直连键变（${KD0} → ${KD}）、种子键变、出库 +1" '[ $RD = 0 ] && [ $RS = 0 ] && [ "$KD" != "$KD0" ] && [ "$KS" != "$KS0" ] && [ "$(calls)" = $((N0 + 1)) ] && [ "$(grep -vc "^#" "$(cur)/knowledge/direct/fout_want.tsv")" = 1 ]'
printf 'P\t%s\t%s\n' $C $D > $SD/job4.tsv
step; ck "⑥ 新 P 行（C→D）→ 直连键变（${KD0} → ${KD}）、种子键变、出库 +1、出库拿到的快照有 C→D" '[ $RD = 0 ] && [ $RS = 0 ] && [ "$KD" != "$KD0" ] && [ "$KS" != "$KS0" ] && [ "$(calls)" = $((N0 + 1)) ] && grep -qx "P	$C	$D" $T/calls.pairs'
printf 'P\tnot-a-key\t%s\nR\t00ff\nQ\tjunk\nS\tshort\n' $D > $SD/job5.tsv
step; ck "⑦ 格式坏的行（坏键 P、短 R、杂行、两列 S）→ 键都不变、不出库" 'same'
# ⑧ 同一份 pso_seed/ 在两处不同路径（Mac / Windows 出包机）只算键（S2A_STAGE_KEYS）；家目录文稿里多一条 P 行
mkdir -p $T/mac/run/s2arm/pso_seed $T/tianyan/data/sync/pso_seed; cp -R $SD $T/mac/run/s2arm/pso_seed/; cp -R $SD $T/tianyan/data/sync/pso_seed/
mkdir -p $T/home/Documents/wire/0100AAAA00000000; printf 'P\t%s\t%s\n' $B $C > $T/home/Documents/wire/0100AAAA00000000/pso_user.tsv
keys() { rm -f $T/k.tsv; S2A_ROOT_CUR=$(cur) S2A_STAGE_KEYS=$T/k.tsv "$@" bash $T/repo/pack/stage_direct.sh acnh > /dev/null 2>&1; S2A_ROOT_CUR=$(cur) S2A_STAGE_KEYS=$T/k.tsv "$@" bash $T/repo/pack/stage_direct_seed.sh acnh > /dev/null 2>&1; cut -f2 $T/k.tsv | tr '\n' ' '; }
KM=$(keys env S2A_PSO_SOURCES=$T/mac/run/s2arm/pso_seed/0100AAAA00000000); KT=$(keys env S2A_PSO_SOURCES=$T/tianyan/data/sync/pso_seed/0100AAAA00000000); KH=$(keys env)
ck "⑧ 同一份 pso_seed/ 两处路径：Mac「${KM}」= Windows 出包机「${KT}」= 现行「${KD} ${KS} 」逐字相同；文稿里多一条 P 行也不变（${KH}）" '[ "$KM" = "$KT" ] && [ "$KM" = "$KD $KS " ] && [ "$KH" = "$KM" ]'
source $T/repo/pack/ipa_key.sh; pk=$(S2A_DUAL=1 ipa_pkg_key C1 "$(cur)")
ck "⑨ 包键带「+seed=<种子键>」（${pk:0:80}…）" '[[ "$pk" == *"dual=$KD+seed=$KS "* ]]'
printf '%s\nS\t%s_b\t0\nP\t%s\t%s\nP\t%s\t%s\n' "$R1" $A $B $D $A $C > $SD/job1.tsv; printf '%s\nS\t%s_b\t0\nP\t%s\t%s\nP\t%s\t%s\n' "$R1" $A $B $D $A $C > $SD/job1_copy.tsv
step; ck "⑩ 只调换 S / R 行先后 → 直连键不变、种子键变（种子表行序 = 首用序，首行 $(grep -v '^#' "$(cur)/shaders/direct/pso_manifest.tsv" | head -1 | cut -c1-1)）、不出库" '[ $RD = 0 ] && [ $RS = 0 ] && [ "$KD" = "$KD0" ] && [ "$KS" != "$KS0" ] && [ "$(calls)" = "$N0" ] && [ "$(grep -v "^#" "$(cur)/shaders/direct/pso_manifest.tsv" | head -1 | cut -c1)" = R ]'
# 反证：去掉 know- 进键那一行（= 修前），新 P 行不让直连键变
sed -i.bak '/^KT="\$KT know-\$KNK"$/d' $T/repo/pack/stage_direct.sh; nl=$(grep -c 'know-\$KNK' $T/repo/pack/stage_direct.sh); (cd $T/repo && git -c user.email=t@t -c user.name=t commit -qam neg)
S; printf 'P\t%s\t%s\n' $D $A > $SD/job6.tsv; step
ck "反证：去掉 know- 进键行（剩 ${nl} 处）→ 新 P 行（D→A）直连键不变（${KD0} → ${KD}）、不出库（修前的漏：知识变了、阶段照跳过）" '[ "$nl" = 0 ] && [ "$KD" = "$KD0" ] && [ "$(calls)" = "$N0" ]'
# ⑪ Mac 局收局并进种子目录（tools/pso_seed_keep.sh，B4）：程序号读 main.npdm；首次建 mac_<本机名>.tsv；再并只补新行、旧行序不动；没有新行不动文件；本机没有表只记一行、退 0
mkdir -p $T/mods; python3 -c 'import struct,sys; b=bytearray(0x100); b[:4]=b"META"; b[0x70:0x74]=struct.pack("<I",0x80); b[0x80:0x84]=b"ACI0"; b[0x90:0x98]=struct.pack("<Q",0x0100BBBB00000000); open(sys.argv[1],"wb").write(bytes(b))' $T/mods/main.npdm
cp "$H/tools/pso_seed_keep.sh" "$H/tools/addr_need.py" "$H/tools/nso_plain.py" $T/repo/tools/ 2> /dev/null; source $T/repo/tools/pso_seed_keep.sh; MK=$T/run/s2arm/pso_seed/0100BBBB00000000/mac_$(pso_seed_mac_name).tsv
printf 'S\t%s_b\t0\n%s\n' $A "$R1" > $T/pu.tsv; k1=$(DM_PSO_USER=$T/pu.tsv pso_seed_keep_mac $T/mods); c1=$(cat "$MK" 2> /dev/null)
printf 'P\t%s\t%s\nS\t%s_b\t0\n' $C $D $A >> $T/pu.tsv; printf 'R\tlocal-only\n' >> "$MK"; k2=$(DM_PSO_USER=$T/pu.tsv pso_seed_keep_mac $T/mods)
touch -t 202001010000.00 "$MK"; mt() { python3 -c "import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)" "$1"; }; m2=$(mt "$MK"); k3=$(DM_PSO_USER=$T/pu.tsv pso_seed_keep_mac $T/mods); m3=$(mt "$MK")
k4=$(DM_PSO_USER=$T/没有.tsv pso_seed_keep_mac $T/mods); r4=$?
ck "⑪ Mac 局收局并进 pso_seed/0100BBBB00000000/mac_<本机名>.tsv：首次 2 行（${k1##*（}）；再并只补 P(C,D)、旧行与本地多的一行原序不动；没有新行不动文件（${k3##*：}）；本机没有表退 0（k2「${k2: -40}」、mtime ${m2} → ${m3}、r4 ${r4}、k4「${k4: -40}」）" \
  '[ "$c1" = "$(printf "S\t%s_b\t0\n%s" $A "$R1")" ] && [ "$(cat "$MK")" = "$(printf "S\t%s_b\t0\n%s\nR\tlocal-only\nP\t%s\t%s" $A "$R1" $C $D)" ] && [[ "$k2" == *"3 → 4 行"* ]] && [[ "$k3" == *没有新行* ]] && [ "$m3" = "$m2" ] && [ $r4 = 0 ] && [[ "$k4" == *不拷* ]]'
mkdir -p $T/home/Documents/wire/0100AAAA00000000.bak; printf 'P\tbak\n' > $T/home/Documents/wire/0100AAAA00000000.bak/pso_user.tsv
o=$(bash $T/repo/tools/pso_seed_keep.sh --all); r=$?; MA=$SD/mac_$(pso_seed_mac_name).tsv
ck "⑪ 一次性迁移（--all，rc=${r}）：文稿 wire/<程序号>/pso_user.tsv 并进 pso_seed/<程序号>/mac_<本机名>.tsv（P(B,C) 1 行）、不收 .bak 目录" '[ $r = 0 ] && [ "$(cat "$MA")" = "$(printf "P\t%s\t%s" $B $C)" ] && [ ! -e $T/run/s2arm/pso_seed/0100AAAA00000000.bak ] && [ "$(grep -c 管线种子来源 <<< "$o")" = 1 ]'
# ⑫ 种子表是锦上添花（审计 #1592 P1-100）：pso_seed.py 失败 → 种子段退 0、打一行【黄】写明缺了什么、现行照样提交（已有的种子表留着）、不记种子键；
#   修好后再跑 → 重新生成（多出新 R 行）、记键。原先退 1，pack/refresh.sh 整次刷新停、这一次包不出
M0=$(rows); R5=$(R $B $D); printf '%s\n' "$R5" >> $SD/job1.tsv; cp $T/repo/graphics/tools/direct/pso_seed.py $T/pso_seed.real   # R5：全新的 R 行（B→D 前面没用过）
printf 'import sys\nsys.exit("模拟种子工具坏了")\n' > $T/repo/graphics/tools/direct/pso_seed.py
OS=$(bash $T/repo/pack/stage_direct_seed.sh acnh 2>&1); RS=$?
ck "⑫ 种子工具失败：种子段退 0（${RS}）、打【黄】写明缺的是首局预建、种子表照旧 ${M0} 行（实 $(rows)）、不记种子键" '[ $RS = 0 ] && [[ "$OS" == *【黄】*acnh*种子表这次没生成*模拟种子工具坏了*首局管线预建* ]] && [ "$(rows)" = "$M0" ] && [ ! -e "$(cur)/.stage_direct_seed" ]'
cp $T/pso_seed.real $T/repo/graphics/tools/direct/pso_seed.py
OS=$(bash $T/repo/pack/stage_direct_seed.sh acnh 2>&1); RS=$?
ck "⑫ 修好再跑：重新生成、种子表 +1 行（${M0} → $(rows)）、记种子键" '[ $RS = 0 ] && [ "$(rows)" = $((M0 + 1)) ] && [ -s "$(cur)/.stage_direct_seed" ]'
source $T/repo/pack/roots.sh; _root_rm $T
[ $bad = 0 ] && echo "跑局知识进阶段键单测：全通" || echo "跑局知识进阶段键单测：有不通"
exit $bad
