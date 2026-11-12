#!/bin/bash
# 抽取阶段单测（pack/stage_extract.sh + 真的 graphics/tools/direct/extract.sh、pack/ue_pak.py；两个抽取器换成记账的假脚本，临时产物根，约 3 秒）：bash tests/stage_extract_test.sh
# 期望按规则手写：首次 → 提交、extract/ok 与两份抽取在、记键、两个抽取器各跑 1 次且拿到 J 与配置档（DM_GAME）；同键 → 跳过、不再抽；
#   游戏输入变（romfs 加文件）/ 配置档内容键变 → 键变、重抽；romfs 有 .pak → 先跑 ue_pak（这个 .pak 不是 Unreal pak → 0 个存档），shader_split 拿到 DM_UE_SHADERS；
#   直连抽取失败 → 照常提交、退出 0、extract/direct_gap.txt 写「直连库失败：<原因>」、打黄（11-05 运行时现编兜底，原先退 3 整款出不了包）；S2Arm 抽取失败 → v0.3.1 起也照常提交、退出 0、只用直连抽取的结果、degrade.extract.tsv 记 s2x_failed（原先退 1 整款停，#711）；日志副本在 .failed/；Vulkan 款 → 跳过、不抽；
#   两边抽取合起来 0 支（10-29 神之天平 外传：运行时 GLSLC 款）→ 退出 3、红行「直连库失败：直连抽取 0 支着色器（缺口：<切分器的红行>」（原先退 0，出库到最后「一个键都没出」整包停住）；
#   GLSLC 离线编出了 .glslc → shader_split 拿到 DM_GLSLC_CAPTURE=extract/glslc_capture、要编时先编宿主；离线编失败 → 退出 3、红行带原因
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
export S2A_JOBS=6
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack $T/repo/tools $T/repo/graphics/tools/direct $T/repo/graphics/tools/shbake $T/repo/translator $T/repo/graphics/nvn/games $T/repo/graphics/nvn/tools $T/roots
cp "$H/pack/resource_input_key.py" $T/repo/pack/; cp "$H/pack/stage_keyfiles.sh" $T/repo/pack/; cp "$H/tools/stage_deps.py" $T/repo/tools/; cp -R "$H/tools/stage_deps_hook" $T/repo/tools/   # 各阶段实际读入进键（pack/stage_keyfiles.sh，10-30）
cp "$H/pack/roots.sh" "$H/pack/srcs.sh" "$H/pack/stage_extract.sh" "$H/pack/ue_pak.py" $T/repo/pack/; cp "$H/tools/clonedir.py" "$H/tools/host_build.sh" "$H/tools/plock.sh" "$H/tools/flock_hold.py" "$H/tools/machine.sh" "$H/tools/nostall.py" "$H/tools/progress.sh" "$H/tools/nospace.sh" $T/repo/tools/
cp "$H/graphics/tools/direct/extract.sh" $T/repo/graphics/tools/direct/; cp "$H/graphics/tools/shbake/pak_crypto.py" "$H/graphics/tools/shbake/unreal_pak.py" "$H/graphics/tools/shbake/zstd_lib.py" $T/repo/graphics/tools/shbake/
# romfs_list.py：仓库里唯一的 RomFS 遍历（11-03），被测脚本经它列 RomFS
cp "$H/graphics/nvn/tools/romfs_list.py" $T/repo/graphics/nvn/tools/
cp "$H/graphics/nvn/tools/gfx_api.py" $T/repo/graphics/nvn/tools/
for f in translator/uepak.py translator/unityfs.py graphics/nvn/games/game.py graphics/nvn/tools/nso_syms.py graphics/nvn/tools/lz4blk.py; do echo x > $T/repo/$f; done   # 只进键，假抽取器不导入
# 假抽取器：记一行「工具 J DM_GAME DM_UE_SHADERS」（另记一行「splitcap DM_GLSLC_CAPTURE」），出最小产物；FAKE_FAIL=split 时 shader_split 失败；
#   FAKE_FAIL=zero：shader_split 照常退 0、打运行时 GLSLC 的红行、表里 0 行，S2Arm 抽取 rows.tsv 只有表头（两边都 0 支）
cat > $T/repo/translator/shader_split.py <<'EOF'
import os, sys
open(os.environ['FAKE_CALLS'], 'a').write(f"split {os.environ.get('J')} {os.environ.get('DM_GAME')} {os.environ.get('DM_UE_SHADERS', '')}\nsplitcap {os.environ.get('DM_GLSLC_CAPTURE', '-')}\n")
if os.environ.get('FAKE_FAIL') == 'split': print('[RED] Data/x: Unity serialized file without type trees'); sys.exit(1)
os.makedirs(sys.argv[3], exist_ok=True); open(os.path.join(sys.argv[3], 'vs.pkg'), 'w').write('p')
if os.environ.get('FAKE_FAIL') == 'zero': print('[RED] main holds GLSL sources and imports glslcCompile, but there are no captured GLSLC outputs in x/glslc_capture: the shaders the game compiles at run time will have no translation')
for p in sys.argv[4:7]: open(p, 'w').write('# t\npackage\tindex\tstage\tdm_ctl_sha16\tsource\n' + ('' if os.environ.get('FAKE_FAIL') == 'zero' else 'vs.pkg\t0\tvertex\t0123456789abcdef\tmain\n'))
EOF
cat > $T/repo/graphics/tools/shbake/nxsh_extract.py <<'EOF'
import os, sys
a = sys.argv[2:sys.argv.index('--nso')] if '--nso' in sys.argv else sys.argv[2:]   # 资源目录（@<列表文件> 展开成一行一个，同 nxsh_extract.py）
roots = [r for x in a for r in (open(x[1:], encoding='utf-8').read().splitlines() if x.startswith('@') else [x]) if r]
open(os.environ['FAKE_CALLS'], 'a').write(f"s2x {os.environ.get('J')} {len(roots)} {' '.join(os.path.basename(r) for r in roots)}\n")
if os.environ.get('FAKE_FAIL') == 's2x': sys.exit('fake s2x fail')
os.makedirs(os.path.join(sys.argv[1], 'src'), exist_ok=True); open(os.path.join(sys.argv[1], 'rows.tsv'), 'w').write('# 键\t阶段\t来源\t变体号\n' + ('' if os.environ.get('FAKE_FAIL') == 'zero' else 'r\n'))
EOF
# 解码器要不要 C#（stage_extract.sh 编宿主前判）：用真工具；占位 main 不是 NSO → 答 no（不带 C#，同改前）
cp "$H/translator/oodle_needs_sdk.py" $T/repo/translator/
# 假离线编：--need 按 FAKE_GLSLC 答 yes / no；FAKE_GLSLC=1 时往输出目录写一份 .glslc，FAKE_FAIL=glslc 时打红行退 1
cat > $T/repo/translator/glslc_offline.py <<'EOF'
import os, sys
if sys.argv[1] == '--need': print('yes' if os.environ.get('FAKE_GLSLC') else 'no'); sys.exit(0)
open(os.environ['FAKE_CALLS'], 'a').write(f"glslc {os.environ.get('J')} {sys.argv[1]}\n")
if os.environ.get('FAKE_FAIL') == 'glslc': print('[RED] GLSLC 工具模式失败（1/1 路）：宿主退出 134'); sys.exit(1)
if not os.environ.get('FAKE_GLSLC'): print('GLSLC 离线编：不需要（main 里没有 GLSL 源码）'); sys.exit(0)
os.makedirs(sys.argv[2], exist_ok=True); open(os.path.join(sys.argv[2], 'glslc_0.glslc'), 'wb').write(b'x'); print('GLSLC 离线编：subsdk0 的 glslcCompile 编成 1 支')
EOF
cat > $T/repo/pack/stage_direct_profile.sh <<'EOF'
exit 0
EOF
cat > $T/repo/pack/direct_profile_stage.py <<'EOF'
import json, os
print(json.dumps({"profile": os.path.dirname(__file__) + "/profile/0100", "profile_key": os.environ.get("FAKE_PROFILE_KEY", "profile1")}))
EOF
# 抽取代码键按声明表算（pack/stage_keyfiles.sh + pack/stage_inputs/extract.tsv，10-26 键收窄）：假仓库只列它有的抽取器
cp "$H/pack/stage_keyfiles.sh" $T/repo/pack/; mkdir -p $T/repo/pack/stage_inputs
printf '入\t%s\n' pack/stage_extract.sh graphics/tools/direct/extract.sh translator/shader_split.py translator/glslc_offline.py graphics/tools/shbake/nxsh_extract.py > $T/repo/pack/stage_inputs/extract.tsv
# 假 Makefile：stage_extract.sh 在 romfs 有 .pak 或要离线编 GLSLC 时会 make -C "$R" -s host；stub repo 没真工具链，给一个记账的目标
printf '.PHONY: host\nhost:\n\t@echo host >> $(FAKE_CALLS)\n' > $T/repo/Makefile
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared FAKE_CALLS=$T/calls
mkdir -p $T/roots/acnh@s0/romfs $T/roots/acnh@s0/exefs $T/roots/acnh@s0/aoc/1; echo r > $T/roots/acnh@s0/romfs/f; echo main > $T/roots/acnh@s0/exefs/main; echo d > $T/roots/acnh@s0/aoc/1/f
printf 'title_id\t0100aaaa00000000\n' > $T/roots/acnh@s0/unpack.tsv; ln -s acnh@s0 $T/roots/acnh@现行
S() { bash $T/repo/pack/stage_extract.sh acnh; }
cur() { cd -P $T/roots/acnh@现行 && pwd; }
n() { grep -c "^$1 " $T/calls 2>/dev/null || echo 0; }
# 现行的 RomFS 是只读共享存储（pack/roots.sh，11-03），已提交的版本不许改：「游戏输入变」按真实流程做——
#   开一个自持 RomFS 的阶段（ROOT_OWN_ROMFS=1，同界面布局阶段），在它的工作根里改，提交成新现行。文件从只读存储克隆来，原地改的先 chmod u+w
source $T/repo/pack/roots.sh
rin() { local w t; t=$(root_tag acnh ed); w=$(ROOT_OWN_ROMFS=1 root_begin acnh $t) && (cd "$w" && eval "$1") && root_commit acnh $t > /dev/null 2>&1 || echo "【红】改 RomFS 夹具失败：$1"; }
o=$(S 2>&1); r=$?; c=$(cur); k1=$(cat $c/.stage_extract 2>/dev/null)
ck "首次：提交、extract/ok 与两份抽取在、记键（rc=${r}，$(echo "$o" | tail -1 | cut -c1-60)）" '[ $r = 0 ] && [ -f $c/extract/ok ] && [ -f $c/extract/pkg/vs.pkg ] && [ -f $c/extract/s2x/rows.tsv ] && [ -n "$k1" ]'
ck "两个抽取器各 1 次，合计 J=6（S2A_JOBS）：S2Arm ⌈6/2⌉ = 3、直连抽取 6 − 3 = 3（11-04 两路并行合计不超 J），配置档 DM_GAME=0100AAAA00000000（实 $(tr '\n' ';' < $T/calls)）" '[ "$(n split)" = 1 ] && [ "$(n s2x)" = 1 ] && grep -q "^split 3 0100AAAA00000000 " $T/calls && grep -q "^s2x 3 " $T/calls'
ck "追加内容并进 S2Arm 抽取（资源目录 2 个 = romfs、aoc/1，经 @列表文件；实 $(grep ^s2x $T/calls | head -1 | cut -d' ' -f3-)）" '[ "$(grep ^s2x $T/calls | head -1 | cut -d" " -f3-)" = "2 romfs 1" ]'
o=$(S 2>&1); r=$?
ck "同键 → 跳过、不再抽（split $(n split) 次）" '[ $r = 0 ] && [ "$(n split)" = 1 ] && [[ "$o" == *跳过* ]]'
rin 'echo r2 > romfs/g'; o=$(S 2>&1); r=$?; k2=$(cat $(cur)/.stage_extract)
ck "游戏输入变 → 键变（$k1 → ${k2}）、重抽（split $(n split) 次）" '[ $r = 0 ] && [ "$k2" != "$k1" ] && [ "$(n split)" = 2 ]'
o=$(FAKE_PROFILE_KEY=profile2 S 2>&1); r=$?; k3=$(cat $(cur)/.stage_extract)
ck "配置档内容键变 → 键变、重抽（split $(n split) 次）" '[ $r = 0 ] && [ "$k3" != "$k2" ] && [ "$(n split)" = 3 ]'
rin 'echo notpak > romfs/x.pak'; o=$(S 2>&1); r=$?; c=$(cur)
ck "romfs 有 .pak → 先跑 ue_pak（$(tail -1 $c/extract/ue_pak.log 2>/dev/null | cut -c1-40)），shader_split 拿到 DM_UE_SHADERS=extract/ue_shaders" '[ $r = 0 ] && grep -q "写出着色器代码存档 0 个" $c/extract/ue_pak.log && grep "^split " $T/calls | tail -1 | grep -q "/extract/ue_shaders$"'
rin 'echo r3 > romfs/h'; b=$(cur); o=$(FAKE_FAIL=split S 2>&1); r=$?
# 10-26 空洞骑士：只给直连用的直连抽取抽不出 → 退出 3（refresh 据此只出通用包），红行「直连库失败：」带切分器的原因
ck "直连抽取失败 → 照常提交（11-05 运行时现编兜底）：退出 0（rc=${r}）、现行换新、extract/direct_gap.txt 带原因、【黄】抽取缺口、日志副本在 .failed/（$(echo "$o" | grep -a 抽取缺口 | cut -c1-90)）" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && grep -q "直连库失败：直连抽取失败（Data/x: Unity serialized fi" "$(cur)/extract/direct_gap.txt" && [[ "$o" == *"【黄】acnh 抽取缺口：直连库失败：直连抽取失败"* ]] && [ -f $T/roots/.failed/acnh_extract.log ]'
ck "直连抽取失败：degrade.extract.tsv 记 offline_zero 1、带玩家提示（实得 $(grep -v '^#' $(cur)/degrade.extract.tsv 2> /dev/null | cut -f1-4 | tr '\n\t' '; ' | cut -c1-80)）" '[ "$(grep -v "^#" $(cur)/degrade.extract.tsv | cut -f2,3 | tr "\n\t" "; ")" = "offline_zero 1;" ] && grep -q "第一次进新场景会卡一下" $(cur)/degrade.extract.tsv'
rin 'echo r3b > romfs/h2'; b=$(cur); o=$(FAKE_FAIL=s2x S 2>&1); r=$?   # 上一条照常提交了：换输入让这条真去重抽
c=$(cur)
ck "S2Arm 抽取失败 → 降级继续（v0.3.1）：退出 0（rc=${r}）、现行换新、extract/s2x/rows.tsv 只有表头、extract.log 有🟡" '[ $r = 0 ] && [ "$c" != "$b" ] && [ "$(grep -cv "^#" $c/extract/s2x/rows.tsv)" = 0 ] && grep -q "🟡 S2Arm 抽取没跑成" $c/extract.log'
ck "S2Arm 抽取失败：degrade.extract.tsv 记 partial 1 + s2x_failed 1，原因带 s2x.log 原文（实得 $(grep -v '^#' $c/degrade.extract.tsv 2> /dev/null | cut -f1-3 | tr '\n\t' '; ')）" '[ "$(grep -v "^#" $c/degrade.extract.tsv | cut -f1-3 | tr "\n\t" "; ")" = "extract partial 1;extract s2x_failed 1;" ] && grep -q "fake s2x fail" $c/degrade.extract.tsv'
# 10-29 神之天平 外传：运行时 GLSLC 款两边都抽到 0 支 → 与直连抽取失败同一口径（退 3、红行写缺口类别、通用照出），不再一路出库到「一个键都没出」整包停住
rin 'rm -f romfs/x.pak'; b=$(cur); h0=$(grep -c ^host $T/calls); o=$(FAKE_FAIL=zero S 2>&1); r=$?
ck "两边抽取 0 支 → 照常提交：退出 0（rc=${r}）、现行换新、direct_gap.txt 写「直连抽取 0 支着色器」带切分器红行（$(cat "$(cur)/extract/direct_gap.txt" 2> /dev/null | cut -c1-120)）" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && grep -q "直连库失败：直连抽取 0 支着色器（缺口：" "$(cur)/extract/direct_gap.txt" && [[ "$o" == *"【黄】acnh 抽取缺口：直连库失败：直连抽取 0 支着色器"* ]]'
ck "没有 .pak、不需要离线编（--need no）→ 不编宿主、shader_split 不带 DM_GLSLC_CAPTURE（编宿主 $h0 → $(grep -c ^host $T/calls) 次、$(grep ^splitcap $T/calls | tail -1)）" '[ "$(grep -c ^host $T/calls)" = "$h0" ] && [ "$(grep ^splitcap $T/calls | tail -1)" = "splitcap -" ]'
rin 'echo r4 > romfs/i'; o=$(FAKE_GLSLC=1 S 2>&1); r=$?; c=$(cur)
ck "要离线编 → 先编宿主、glslc_offline 拿到 J（与 S2Arm 抽取并行时分到 6 − 3 = 3）与产物根、shader_split 拿到 DM_GLSLC_CAPTURE=extract/glslc_capture（rc=${r}，$(grep ^splitcap $T/calls | tail -1)）" '[ $r = 0 ] && [ "$(grep -c ^host $T/calls)" = $((h0 + 1)) ] && grep "^glslc" $T/calls | tail -1 | grep -q "^glslc 3 " && grep ^splitcap $T/calls | tail -1 | grep -q "/extract/glslc_capture$" && [ -f $c/extract/glslc_capture/glslc_0.glslc ]'
rin 'echo r5 > romfs/j'; b=$(cur); o=$(FAKE_GLSLC=1 FAKE_FAIL=glslc S 2>&1); r=$?
ck "离线编失败 → 照常提交：退出 0（rc=${r}）、现行换新、direct_gap.txt 写「GLSLC 离线编失败」" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && grep -q "直连库失败：GLSLC 离线编失败（GLSLC 工具模式失败（1/1 路）：宿主退出 134；" "$(cur)/extract/direct_gap.txt"'
# 内置宿主：发版 App 自带已编好的宿主（pack/jobs/core.py 设 S2A_BUNDLED_HOST）→ 不编宿主（issue #8 根因修复）
rin 'echo r6 > romfs/k'; h1=$(grep -c ^host $T/calls); touch $T/fake_host; o=$(FAKE_GLSLC=1 S2A_BUNDLED_HOST=$T/fake_host S 2>&1); r=$?
ck "有内置宿主（S2A_BUNDLED_HOST）→ 不编宿主、跳过 host_build（编宿主 $h1 → $(grep -c ^host $T/calls) 次，$(echo "$o" | grep -a '使用发版' | cut -c1-60)）" '[ $r = 0 ] && [ "$(grep -c ^host $T/calls)" = "$h1" ] && [[ "$o" == *"使用发版 App 内置 Mac 宿主"* ]]'
# P2-53 合成输入基线提交：回到原来的测试位置
# #1233 P2-53：同路径同长度变内容，两个真实阶段必须各自失效并调用后端；不改原断言。
mkdir -p "$(cur)/aoc/1"
rin "printf 'a\\n' > romfs/p253-small.bin"; printf 'd\n' > "$(cur)/aoc/1/p253-small.bin"
rin "python3 -c 'import pathlib; pathlib.Path(\"romfs/p253-large.bin\").write_bytes(b\"A\" * (3 * 65536))'"
o=$(S 2>&1); r=$?; p253k=$(cat "$(cur)/.stage_extract" 2>/dev/null)
ck "P2-53 合成输入基线提交（rc=${r}）" '[ $r = 0 ] && [ -n "$p253k" ]'
p253_changed() {
  local previous=$p253k count_before=$(n split)
  o=$(S 2>&1); r=$?; p253k=$(cat "$(cur)/.stage_extract" 2>/dev/null)
  ck "P2-53 $1：同长度变字节应重做（rc=${r}）" '[ $r = 0 ] && [ "$p253k" != "$previous" ] && [ "$(n split)" = "$((count_before + 1))" ]'
}
rin "chmod u+w romfs/p253-small.bin; printf 'b\\n' > romfs/p253-small.bin"; p253_changed 'romfs'
printf 'e\n' > "$(cur)/aoc/1/p253-small.bin"; p253_changed 'aoc'
rin "chmod u+w romfs/p253-large.bin; python3 -c 'f = open(\"romfs/p253-large.bin\", \"r+b\"); f.write(b\"B\"); f.close()'"
p253_changed '大文件首块'
rin "chmod u+w romfs/p253-large.bin; python3 -c 'f = open(\"romfs/p253-large.bin\", \"r+b\"); f.seek(-1, 2); f.write(b\"C\"); f.close()'"
p253_changed '大文件尾块'
p253before=$(n split); rin 'touch romfs/p253-small.bin'; o=$(S 2>&1); r=$?
ck "P2-53 只变mtime：原键跳过" '[ $r = 0 ] && [ "$(cat "$(cur)/.stage_extract")" = "$p253k" ] && [ "$(n split)" = "$p253before" ] && [[ "$o" == *跳过* ]]'
o=$(S 2>&1); r=$?
ck "P2-53 内容不变再次调用：仍跳过" '[ $r = 0 ] && [ "$(n split)" = "$p253before" ] && [[ "$o" == *跳过* ]]'

cp "$H/graphics/nvn/tools/gfx_api.py" $T/gfx_api.py; printf 'import sys\nprint("vulkan\\tvk")\n' > $T/repo/graphics/nvn/tools/gfx_api.py; (cd $T/repo && git -c user.email=t@t -c user.name=t commit -qam vk)
n0=$(n split); o=$(S 2>&1); r=$?
ck "Vulkan 款 → 跳过、不抽（split $n0 → $(n split) 次）" '[ $r = 0 ] && [ "$(n split)" = "$n0" ] && [[ "$o" == *跳过* ]]'
# 10-31 Mac 游戏库在 ~/Library/Application Support/ 下：DM_UE_SHADERS=$X/... 没加引号被拆词，env 把「Support/.../ue_shaders」当命令跑，直连抽取全挂
SP="$T/Application Support"; mkdir -p "$SP/r/romfs" "$SP/r/exefs"; echo r > "$SP/r/romfs/f"; echo main > "$SP/r/exefs/main"
o=$(bash $T/repo/graphics/tools/direct/extract.sh "$SP/r" "$SP/x" 2>&1); r=$?
ck "产物根 / 输出目录带空格 → 直连抽取照常、shader_split 拿到完整 DM_UE_SHADERS（rc=${r}，$(grep "^split " $T/calls | tail -1 | cut -d" " -f4-)）" '[ $r = 0 ] && [ "$(grep "^split " $T/calls | tail -1 | cut -d" " -f4-)" = "$SP/x/ue_shaders" ]'

# 本轮上下文：运行两份完整阶段；计算入口与克隆交接分开计数，NVN/VK/GL均覆盖。
cp "$H/pack/stage_direct.sh" $T/repo/pack/; cp "$H"/graphics/tools/direct/{run_knowledge,fout_want,pso_layout,run_pairs,se_want}.py "$H"/graphics/tools/direct/pso_layout.json $T/repo/graphics/tools/direct/   # stage_direct.sh 现出跑局知识快照（审计 #1534 P1-54）
cp "$H/tools/toolchain.sh" "$H/tools/toolchain.env" $T/repo/tools/
printf 'def version(): return "fixture1"\n' > $T/repo/translator/dmsh_chain.py
printf '入\t%s\n' pack/stage_direct.sh graphics/tools/direct/direct_lib.sh > $T/repo/pack/stage_inputs/direct.tsv
cat > $T/repo/graphics/tools/direct/direct_lib.sh <<'ONCE_LIB'
mkdir -p "$2/b-fixture"; echo k > "$2/keys.tsv"; echo x > "$2/b-fixture/x.metallib"
echo '[直连库] fixture'
ONCE_LIB
mkdir -p "$T/bin"; P253_ORIGINAL_PATH=$PATH; export PATH="$T/bin:$PATH"
cat > $T/bin/xcrun <<'ONCE_XCRUN'
#!/bin/sh
[ "$*" = "-sdk iphoneos metal --version" ] && { echo 'Apple metal version 32023.9 (metalfe-fixture)'; exit 0; }
[ "$*" = "--sdk iphoneos --show-sdk-version" ] && { echo 27.0; exit 0; }
exit 1
ONCE_XCRUN
chmod +x $T/bin/xcrun
cp $T/repo/pack/resource_input_key.py $T/repo/pack/resource_input_key_impl.py
cat > $T/repo/pack/resource_input_key.py <<'ONCE_WRAPPER'
import os, pathlib, runpy, sys
with open(os.environ['ONCE_CALLS'], 'a') as out:
    out.write(('KR' if len(sys.argv)==2 else 'clone')+'\n')
# 对原helper真正的read()逐次记字节，inventory/stat不计输入读数。
real_open=pathlib.Path.open
class InputReader:
    def __init__(self,f): self.f=f
    def __enter__(self): self.f.__enter__(); return self
    def __exit__(self,*args): return self.f.__exit__(*args)
    def __getattr__(self,n): return getattr(self.f,n)
    def read(self,*args):
        data=self.f.read(*args)
        with real_open(pathlib.Path(os.environ['ONCE_CALLS']+'.bytes'),'a') as log: log.write(str(len(data))+'\n')
        return data

def traced_open(p,*args,**kwargs):
    f=real_open(p,*args,**kwargs); name=str(p)
    return InputReader(f) if ('/romfs/' in name or '/aoc/' in name or name.endswith('/exefs/main')) and 'r' in (args[0] if args else kwargs.get('mode','r')) else f
pathlib.Path.open=traced_open
impl=pathlib.Path(__file__).with_name('resource_input_key_impl.py')
exec(compile(impl.read_bytes(),str(impl),'exec'),globals())
ONCE_WRAPPER
for api in nvn vulkan gl; do
  printf 'print("%s\\tfixture")\n' "$api" > $T/repo/graphics/nvn/tools/gfx_api.py
  (cd $T/repo && git add -A && git -c user.email=t@t -c user.name=t commit -qm "once-$api")
  g=once_$api; mkdir -p "$T/roots/$g@s0/romfs" "$T/roots/$g@s0/exefs"
  echo original > "$T/roots/$g@s0/romfs/f"; echo main > "$T/roots/$g@s0/exefs/main"
  printf 'title_id\t0100aaaa00000000\n' > "$T/roots/$g@s0/unpack.tsv"; ln -s "$g@s0" "$T/roots/$g@现行"
  export ONCE_CALLS=$T/count-$api; : > "$ONCE_CALLS"
  o=$(S2A_RESOURCE_KEY_ONCE_FILE="$T/run-$api" bash $T/repo/pack/stage_extract.sh "$g" 2>&1); xrc=$?
  o2=$(S2A_RESOURCE_KEY_ONCE_FILE="$T/run-$api" DSX_LIB="$T/not-built" bash $T/repo/pack/stage_direct.sh "$g" 2>&1); drc=$?
  c2=$(cd -P "$T/roots/$g@现行" && pwd)
  ck "once $api 两阶段成功、KR计算入口1次（extract=$xrc direct=$drc calc=$(grep -c '^KR$' "$ONCE_CALLS") clone=$(grep -c '^clone$' "$ONCE_CALLS");$(echo "$o $o2" | tail -1 | cut -c1-90)）" '[ $xrc = 0 ] && [ $drc = 0 ] && [ "$(grep -c "^KR$" "$ONCE_CALLS")" = 1 ] && [ -f "$c2/shaders/direct/keys.tsv" ]'
  # 真实roots协议的后续阶段桩：输入不动，只提交一份guest映射，再开始下一轮刷新。
  : > "$ONCE_CALLS.extra.bytes"
  before_bytes=0
  tail_out=$(ONCE_CALLS="$ONCE_CALLS.extra" S2A_RESOURCE_KEY_ONCE_FILE= bash -c 'source "$1"; W=$(root_begin "$2" after_direct) || exit; mkdir -p "$W/shaders/direct"; echo guest > "$W/shaders/direct/guest_key.tsv"; root_commit "$2" after_direct' test "$T/repo/pack/roots.sh" "$g" 2>&1); tail_rc=$?
  again=$(ONCE_CALLS="$ONCE_CALLS.extra" S2A_RESOURCE_KEY_ONCE_FILE= bash "$T/repo/pack/stage_extract.sh" "$g" 2>&1); again_rc=$?
  after_bytes=$(awk '{s+=$1} END {print s+0}' "$ONCE_CALLS.extra.bytes")
  ck "clone $api 直连后额外阶段提交再抽取：实际资源读取0字节（stage=$tail_rc extract=$again_rc bytes=$((after_bytes-before_bytes))）" '[ $tail_rc = 0 ] && [ $again_rc = 0 ] && [ "$after_bytes" = "$before_bytes" ]'
  # 其他阶段确实改了main：不能复用克隆时、写入前的KR（一次性上下文必须等提交验证）。
  input_calls="$ONCE_CALLS.input"; : > "$input_calls.bytes"
  o5=$(ONCE_CALLS="$input_calls" S2A_RESOURCE_KEY_ONCE_FILE="$T/input-$api" bash "$T/repo/pack/stage_extract.sh" "$g" 2>&1); irc0=$?
  old_input_key=$(cut -f3 "$T/input-$api")
  o6=$(ONCE_CALLS="$input_calls" S2A_RESOURCE_KEY_ONCE_FILE="$T/input-$api" bash -c 'source "$1"; W=$(root_begin "$2" changed_main) || exit; printf "MAIN\n" > "$W/exefs/main"; root_commit "$2" changed_main' test "$T/repo/pack/roots.sh" "$g" 2>&1); irc1=$?
  o7=$(ONCE_CALLS="$input_calls" S2A_RESOURCE_KEY_ONCE_FILE="$T/input-$api" bash "$T/repo/pack/stage_extract.sh" "$g" 2>&1); irc2=$?
  new_input_key=$(cut -f3 "$T/input-$api"); changed_bytes=$(awk '{s+=$1} END {print s+0}' "$input_calls.bytes")
  ck "clone $api 后续阶段改main：只重读5字节且KR变化（rc=$irc0/$irc1/$irc2 bytes=${changed_bytes}）" '[ $irc0 = 0 ] && [ $irc1 = 0 ] && [ $irc2 = 0 ] && [ "$changed_bytes" = 5 ] && [ "$new_input_key" != "$old_input_key" ]'
  # 新增刷新单列账本，原下面的计数和断言不变。
  c2=$(cd -P "$T/roots/$g@现行" && pwd)
  # 新根未经过资源clone交接，不能盲复用同轮旧字符串。
  fresh=$T/roots/$g@foreign; python3 "$H/tools/clonedir.py" "$c2" "$fresh"; echo changed > "$fresh/romfs/f"
  ln -sfn "$g@foreign" "$T/roots/$g@现行"
  o3=$(S2A_RESOURCE_KEY_ONCE_FILE="$T/run-$api" DSX_LIB="$T/not-built" bash $T/repo/pack/stage_direct.sh "$g" 2>&1); frc=$?
  ck "once $api 未认证新根重新核算（rc=$frc calc=$(grep -c '^KR$' "$ONCE_CALLS")）" '[ $frc = 0 ] && [ "$(grep -c "^KR$" "$ONCE_CALLS")" = 2 ]'
  printf 'truncated\n' > "$T/run-$api"
  o4=$(S2A_RESOURCE_KEY_ONCE_FILE="$T/run-$api" DSX_LIB="$T/not-built" bash $T/repo/pack/stage_direct.sh "$g" 2>&1); brc=$?
  ck "once $api 损坏上下文回到同一helper（rc=$brc calc=$(grep -c '^KR$' "$ONCE_CALLS")）" '[ $brc = 0 ] && [ "$(grep -c "^KR$" "$ONCE_CALLS")" = 3 ]'
done
unset ONCE_CALLS
export PATH=$P253_ORIGINAL_PATH; unset P253_ORIGINAL_PATH

# P2-53 摘要memo：真实输入读取计数、保留mtime的同长写、真实root_begin克隆交接。
"${S2A_PYTHON:-${S2A_PY:-python3}}" - "$H" <<'P253_MEMO_TESTS'
import importlib.util, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import sys
REPO=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('resource_key_under_test',REPO/'pack/resource_input_key.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
class ResourceMemo(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='resource-key-memo-');self.addCleanup(self.tmp.cleanup);self.base=Path(self.tmp.name).resolve();self.root=self.base/'roots/fixture@seed';(self.root/'exefs').mkdir(parents=True);(self.root/'romfs/sub').mkdir(parents=True);(self.root/'aoc/1').mkdir(parents=True);(self.root/'exefs/main').write_bytes(b'main-input');(self.root/'romfs/a').write_bytes(b'AA');(self.root/'romfs/sub/large').write_bytes(b'L'*196608);(self.root/'aoc/1/zero').write_bytes(b'');self.addCleanup(patch.stopall);patch.dict(os.environ,{'S2A_JOBS':'1'}).start()
 def measured(self):
  real=Path.open;counter={'opens':0,'bytes':0,'key_assemblies':0};root=self.root
  class Reader:
   def __init__(self,f):self.f=f
   def __enter__(self):self.f.__enter__();return self
   def __exit__(self,*args):return self.f.__exit__(*args)
   def read(self,*args):v=self.f.read(*args);counter['bytes']+=len(v);return v
   def __getattr__(self,n):return getattr(self.f,n)
  def opening(p,*args,**kwargs):
   f=real(p,*args,**kwargs)
   if p.is_relative_to(root) and (str(p.relative_to(root))=='exefs/main' or p.is_relative_to(root/'romfs') or p.is_relative_to(root/'aoc')) and 'r' in (args[0] if args else kwargs.get('mode','r')):counter['opens']+=1;return Reader(f)
   return f
  real_sha=mod.hashlib.sha256
  def hashing(data=b'',*args,**kwargs):
   if data==b's2arm-resource-inputs-v1\0':counter['key_assemblies']+=1
   return real_sha(data,*args,**kwargs)
  with patch.object(Path,'open',opening),patch.object(mod.hashlib,'sha256',hashing):key=mod.resource_key(root)
  return key,counter
 def clone(self):
  env=dict(os.environ,S2A_ROOTS=str(self.root.parent),S2A_ROOTS_SHARED=str(self.base/'unrelated-shared'),S2A_ROOTS_NO_BOOT='1');(self.root.parent/'fixture@现行').symlink_to(self.root.name)
  out=subprocess.check_output(['bash','-c','source "$1"; ROOT_OWN_ROMFS=1 root_begin fixture next','test',str(REPO/'pack/roots.sh')],env=env,text=True);return Path(out.strip())
 def test_warm_reads_no_input_bytes(self):
  k,c=self.measured();self.assertEqual(c['bytes'],len(b'main-input')+2+131072);k2,c2=self.measured();self.assertEqual(k,k2);self.assertEqual(c2,{'opens':0,'bytes':0,'key_assemblies':0})
 def test_same_length_write_preserving_mtime_only_rereads_changed(self):
  old,_=self.measured();p=self.root/'romfs/a';st=p.stat();p.write_bytes(b'BB');os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns));new,c=self.measured();self.assertNotEqual(old,new);self.assertEqual(c,{'opens':1,'bytes':2,'key_assemblies':1})
 def test_membership_and_rename(self):
  old,_=self.measured();p=self.root/'romfs/a';p.rename(self.root/'romfs/renamed');new,c=self.measured();self.assertNotEqual(old,new);self.assertEqual(c['bytes'],2);(self.root/'romfs/empty').write_bytes(b'');added,c=self.measured();self.assertNotEqual(new,added);self.assertEqual(c['bytes'],0);(self.root/'romfs/empty').unlink();self.assertEqual(self.measured()[0],new)
 def test_mtime_only_rereads_but_keeps_key(self):
  old,_=self.measured();p=self.root/'romfs/a';st=p.stat();os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns+1000000000));new,c=self.measured();self.assertEqual(old,new);self.assertEqual(c['bytes'],2)
 def test_true_clone_inherit_and_rename(self):
  key,_=self.measured();source=self.root;target=self.clone();mod.inherit_cache(source,target);self.root=target;other,c=self.measured();self.assertEqual(key,other);self.assertEqual(c['bytes'],0);renamed=target.with_suffix('');target.rename(renamed);self.root=renamed;self.assertEqual(self.measured()[1]['bytes'],0);p=renamed/'romfs/a';p.write_bytes(b'CC');new,c=self.measured();self.assertNotEqual(key,new);self.assertEqual(c['bytes'],2)
 def test_source_change_rejects_clone_inheritance(self):
  self.measured();source=self.root;target=self.clone();p=source/'romfs/a';st=p.stat();p.write_bytes(b'BB');os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns));self.assertRaises((ValueError,OSError),mod.inherit_cache,source,target)
 def test_unrelated_clone_marker_rejected(self):
  self.measured();target=self.clone();(target/'.root_base').write_text('unrelated');self.assertRaises((ValueError,OSError),mod.inherit_cache,self.root,target)
 def test_corrupt_cache_recomputed(self):
  key,c=self.measured();memo=mod.memo_path(self.root);memo.write_text('{incomplete');other,c2=self.measured();self.assertEqual(key,other);self.assertEqual(c2,c)
 def test_symlink_resource_rejected(self):
  self.measured();(self.root/'romfs/link').symlink_to(self.root/'romfs/a');self.assertRaises((ValueError,OSError),mod.resource_key,self.root)
 def test_workers_follow_environment(self):
  for i in range(10):(self.root/'romfs'/str(i)).write_bytes(b'Z')
  real=mod.ThreadPoolExecutor;seen=[]
  def pool(*args,**kwargs):seen.append(kwargs['max_workers']);return real(*args,**kwargs)
  with patch.dict(os.environ,{'S2A_JOBS':'8'}),patch.object(mod,'ThreadPoolExecutor',pool):self.measured()
  self.assertEqual(seen,[8])
 def test_main_same_length_change_is_full_rehashed(self):
  old,_=self.measured();p=self.root/'exefs/main';st=p.stat();p.write_bytes(b'MAIN-input');os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns));new,c=self.measured();self.assertNotEqual(old,new);self.assertEqual(c,{'opens':1,'bytes':10,'key_assemblies':1})
 def test_target_write_before_handoff_rejected(self):
  key,_=self.measured();target=self.clone();p=target/'romfs/a';st=p.stat();p.write_bytes(b'BB');os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns));self.assertRaises((ValueError,OSError),mod.inherit_cache,self.root,target,key)
 def test_new_source_memo_cannot_replace_fixed_snapshot(self):
  key,_=self.measured();target=self.clone();p=self.root/'romfs/a';st=p.stat();p.write_bytes(b'BB');os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns));self.measured();self.assertRaises((ValueError,OSError),mod.inherit_cache,self.root,target,key)
 def test_read_failure_does_not_publish_new_key(self):
  self.measured();p=self.root/'romfs/a';p.write_bytes(b'BB');real=Path.open
  def failure(path,*args,**kwargs):
   if path==p:raise OSError('original simulated read failure')
   return real(path,*args,**kwargs)
  with patch.object(Path,'open',failure):self.assertRaises(OSError,mod.resource_key,self.root)
  self.assertEqual(self.measured()[1]['bytes'],2)
 def test_replaced_inode_rehashed(self):
  key,_=self.measured();p=self.root/'romfs/a';st=p.stat();other=self.root/'romfs/replacement';other.write_bytes(b'BB');os.utime(other,ns=(st.st_atime_ns,st.st_mtime_ns));other.replace(p);new,c=self.measured();self.assertNotEqual(key,new);self.assertEqual(c['bytes'],2)
 def test_original_sample_key_bytes_unchanged(self):
  import hashlib
  h=hashlib.sha256(b's2arm-resource-inputs-v1\0');h.update(hashlib.sha256(b'main-input').digest())
  for name,data,size in [('aoc/1/zero',b'',0),('romfs/a',b'AA',2),('romfs/sub/large',b'L'*131072,196608)]:
   n=name.encode();h.update(len(n).to_bytes(8,'little')+n+size.to_bytes(8,'little')+hashlib.sha256(data).digest())
  self.assertEqual(self.measured()[0],h.hexdigest()[:16])
 def test_same_inputs_across_real_clone_assemble_only_once(self):
  first,c1=self.measured();target=self.clone();mod.inherit_cache(self.root,target,first);self.root=target;second,c2=self.measured();self.assertEqual(first,second);self.assertEqual(c1['key_assemblies']+c2['key_assemblies'],1);self.assertEqual(c2['bytes'],0)
 def test_only_generated_orphan_memo_is_reclaimed(self):
  key,_=self.measured();source=self.root;old=mod.memo_path(source);target=self.clone();mod.inherit_cache(source,target,key);unknown=old.parent/'keep-user-note.json';unknown.write_text('{"payload":0}');shutil.rmtree(source);self.root=target;(target/'romfs/a').write_bytes(b'BB');self.measured();self.assertFalse(old.exists());self.assertTrue(unknown.exists())
 def test_foreign_helper_hash_even_with_valid_checksum_is_miss(self):
  import json, hashlib
  key, cold=self.measured(); path=mod.memo_path(self.root); doc=json.loads(path.read_text());doc['payload']['helper_sha']='0'*64;doc['checksum']=hashlib.sha256(mod.encoded(doc['payload'])).hexdigest();path.write_text(json.dumps(doc));other,counts=self.measured();self.assertEqual(other,key);self.assertEqual(counts['bytes'],cold['bytes'])
 def test_real_helper_source_change_invalidates_memo(self):
  import json, hashlib
  key,cold=self.measured();changed=self.base/'other_resource_helper.py';changed.write_bytes((REPO/'pack/resource_input_key.py').read_bytes()+b'\n# source-version-negative\n');spec=importlib.util.spec_from_file_location('other_resource_helper',changed);other=importlib.util.module_from_spec(spec);spec.loader.exec_module(other);self.assertIsNone(other.load_memo(self.root));self.assertEqual(other.resource_key(self.root),key);self.assertEqual(json.loads(mod.memo_path(self.root).read_text())['payload']['helper_sha'],hashlib.sha256(changed.read_bytes()).hexdigest())
 def replay_result(self,relative,data):
  self.measured();source=self.root;work=self.clone();dest=work/relative;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
  env=dict(os.environ,S2A_ROOTS=str(source.parent),S2A_ROOTS_SHARED=str(self.base/'unrelated-shared'),S2A_ROOTS_NO_BOOT='1')
  command='source "$1"; W=$(root_begin fixture newer) || exit; echo marker > "$W/other_stage"; root_commit fixture newer || exit; _root_replay "$2" "$(root_cur fixture)" "$3"'
  subprocess.check_call(['bash','-c',command,'test',str(REPO/'pack/roots.sh'),str(work),relative],env=env);self.root=work;return self.measured()
 def test_real_replay_clone_retains_unchanged_input_digests(self):
  key,c=self.replay_result('shaders/direct/guest_key.tsv',b'newguest');self.assertEqual(c['bytes'],0);self.assertEqual(c['key_assemblies'],0)
 def test_real_replay_changed_input_only_rehashes_changed_file(self):
  key,c=self.replay_result('romfs/a',b'BB');self.assertEqual(c['bytes'],2);self.assertEqual(c['key_assemblies'],1)
 def test_optional_clone_cache_failure_does_not_abort_root(self):
  repo=self.base/'cache-fails-repo';(repo/'pack').mkdir(parents=True);(repo/'tools').mkdir();shutil.copy(REPO/'pack/roots.sh',repo/'pack/roots.sh');shutil.copy(REPO/'tools/clonedir.py',repo/'tools/clonedir.py');shutil.copy(REPO/'tools/plock.sh',repo/'tools');shutil.copy(REPO/'tools/flock_hold.py',repo/'tools');(repo/'pack/resource_input_key.py').write_text('raise SystemExit(7)\n')
  (self.root.parent/'fixture@现行').symlink_to(self.root.name);env=dict(os.environ,S2A_ROOTS=str(self.root.parent),S2A_ROOTS_SHARED=str(self.base/'unrelated-shared'),S2A_ROOTS_NO_BOOT='1');out=subprocess.check_output(['bash','-c','source "$1"; W=$(root_begin fixture fallback) || exit; test -f "$W/.root_pid" || exit; root_commit fixture fallback || exit; root_cur fixture','test',str(repo/'pack/roots.sh')],env=env,text=True);self.assertTrue((Path(out.strip())/'romfs/a').is_file())
if __name__=='__main__':unittest.main(argv=['resource-memo'],verbosity=2)

P253_MEMO_TESTS
[ $? = 0 ] || bad=1
[ -n "${KEEP:-}" ] || _root_rm $T   # 现行 RomFS 存储整棵只读，裸 rm -rf 删不掉（pack/roots.sh）
# KF 清单里的每个文件在本仓库真实存在（10-25：清单里留着已删掉的 s2a_progress.py，夹具照清单造假文件、单测照绿，main 上抽取阶段取不到对象号、所有正式包退成纯通用）
KF=$(sed -n '/^KF="/,/"$/p' "$H/pack/stage_extract.sh" | tr -d '"' | sed 's/^KF=//')
miss=$(for f in $KF; do git -C "$H" rev-parse -q --verify "HEAD:$f" > /dev/null || git -C "$H" ls-files --error-unmatch "$f" > /dev/null 2>&1 || echo "$f"; done)
ck "KF 清单里的文件都在仓库里（缺：${miss:-无}）" '[ -z "$miss" ]'
[ $bad = 0 ] && echo "抽取阶段单测：全通" || echo "抽取阶段单测：有不通"
exit $bad
