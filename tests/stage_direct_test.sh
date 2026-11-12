#!/bin/bash
# 直连着色器库阶段单测（pack/stage_direct.sh，假 direct_lib.sh，临时产物根，约 2 秒）：bash tests/stage_direct_test.sh
# 期望按规则手写：出库成功 → 提交、direct/keys.tsv 在、记键；同键 → 跳过、不再出库；游戏输入变 → 键变、重出；
# 配置前置拒绝 → 退出3、不调出库、不改现行/旧键；出库失败（基础设施，出库退 1）→ 退出1、【红】、现行不动、日志副本在 <根>/.failed/；
# 出库内容缺口（出库退 3，10-25 维护者）→ 退出 3、【黄】带出库日志里的「直连缺口：…」原文、现行不动、日志副本在 .failed/；
# 包键：带「 dual=<直连库键>」（只有直连，11-07；不再带通用着色器阶段键与客体代码表键）
# 安卓（S2A_PACK_PLAT=android，#783）：出库 / 发布目标都是 android；Vulkan 侧指纹 VkFp（graphics/tools/direct/vklib/dsh_vklib.py fp，这里是桩）只进安卓键——
#   只改 Vulkan 侧代码 → 安卓键变、重出；算不出 → 退出 1、【红】、现行不动；iOS 不算它、它变了 iOS 键不变；
#   安卓键不带 Metal 编译器版本（#1425 审）：上游导出的 S2A_TC_METAL 换了版本，安卓跳过、iOS 重出
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack $T/repo/tools $T/repo/graphics/nvn $T/repo/graphics/tools/direct $T/repo/graphics/tools/shbake $T/roots
cp "$H/pack/resource_input_key.py" $T/repo/pack/; cp "$H/pack/stage_keyfiles.sh" $T/repo/pack/; cp "$H/tools/stage_deps.py" $T/repo/tools/; cp -R "$H/tools/stage_deps_hook" $T/repo/tools/   # 各阶段实际读入进键（pack/stage_keyfiles.sh，10-30）
# romfs_list.py：仓库里唯一的 RomFS 遍历（11-03），被测脚本经它列 RomFS
mkdir -p $T/repo/graphics/nvn/tools; cp "$H/graphics/nvn/tools/romfs_list.py" $T/repo/graphics/nvn/tools/; cp "$H/graphics/nvn/tools/gfx_api.py" $T/repo/graphics/nvn/tools/   # 出包分流判法（假 main 不是 NSO → unknown，走 NVN 路径）
cp "$H/pack/roots.sh" "$H/pack/stage_direct.sh" "$H/pack/ipa_key.sh" "$H/pack/pkg_srcs.py" "$H/pack/pkg_inputs_key.py" "$H/pack/ue_pak.py" $T/repo/pack/; cp "$H/tools/toolchain.sh" "$H/tools/toolchain.env" "$H/tools/machine.sh" "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $T/repo/tools/
cp "$H/graphics/tools/shbake/pak_crypto.py" $T/repo/graphics/tools/shbake/
for f in run_knowledge.py fout_want.py se_want.py run_pairs.py pso_layout.py pso_layout.json runtime_only_lib.sh runtime_only_lib.py; do cp "$H/graphics/tools/direct/$f" $T/repo/graphics/tools/direct/; done   # 跑局知识快照进键（审计 #1534 P1-54；来源 S2A_PSO_SOURCES 指空目录，键规则在 tests/stage_direct_knowledge_test.sh 核）
echo n > $T/repo/graphics/nvn/x; echo s > $T/repo/graphics/tools/shbake/x
export DSX_LIB=$T/libdsx.dylib   # 调用方给了直连翻译库：stage_direct 不再现编（假仓库没有 graphics/dsx）
mkdir -p $T/repo/graphics/metal; echo m > $T/repo/graphics/metal/gal_prog.m   # 共享内存溢出改写源码也进阶段键（stage_direct.sh KT）
# Unit boundaries only; real profile preparation is covered in direct_profile_test.
# No Xcode/compiler is used by this fake-library transaction test.
mkdir -p $T/bin
cat > $T/bin/xcrun <<'EOF'
#!/bin/sh
[ "$*" = "-sdk iphoneos metal --version" ] && { echo "Apple metal version 32023.9 (metalfe-fixture)"; exit 0; }   # 合法版本行（#403：toolchain.sh 只认「Apple metal version <数字>」）
[ "$*" = "--sdk iphoneos --show-sdk-version" ] && { echo 27.0; exit 0; }   # tools/toolchain.sh 能力检查要 SDK 版本
exit 1
EOF
chmod +x $T/bin/xcrun; export PATH=$T/bin:$PATH
cat > $T/repo/pack/stage_direct_profile.sh <<'EOF'
[ "${FAKE_NOPROF:-0}" != 1 ] || { echo "【红】配置前置拒绝"; exit 3; }
exit 0
EOF
cat > $T/repo/pack/direct_profile_stage.py <<'EOF'
import json,os
print(json.dumps({"profile": os.path.dirname(__file__)+"/profile/0100",
                  "profile_key": os.environ.get("FAKE_PROFILE_KEY", "profile1")}))
EOF


# 假出库：FAKE_NOPROF=1 = 没有配置档（只打 🟡 行、不出表）；FAKE_FAIL=1 = 失败；每次调用记一行到 FAKE_CALLS
cat > $T/repo/graphics/tools/direct/direct_lib.sh <<'EOF'
O=$2; echo "${DSX_LIB-未设}" >> "$FAKE_CALLS.gal"; echo 1 >> "$FAKE_CALLS"; echo "${S2A_DIRECT_TARGETS-未设}" >> "$FAKE_CALLS.tgt"; echo "${S2A_DIRECT_PUBLISH-未设}" >> "$FAKE_CALLS.pub"; echo "${J:-未设}" >> "$FAKE_CALLS.j"   # 记下本次出几个平台的库、几路并行
[ "${FAKE_FAIL:-0}" = 1 ] && { echo "[直连库] 🔴 出库失败 rc=3"; exit 1; }
[ "${FAKE_GAP:-0}" = 1 ] && { echo "[直连库] 🟡 直连缺口：NVN 着色器 翻不了 1 支（0123456789abcdef：桩原因），现有出库不支持部分出库，本款这次走通用"; exit 3; }
[ "${FAKE_NOPROF:-0}" = 1 ] && { echo "[直连库] 🟡 0100 没有直连配置档，不出直连库"; exit 0; }
[ "${FAKE_VKHDR:-0}" = 1 ] && { mkdir -p "$O/vk" && printf '# key\tfile\n' > "$O/vk/vk_shaders.tsv" && : > "$O/keys.tsv"; echo "[直连库] 🟡 Vulkan 款 0100：RomFS 没有 SPIR-V，只出表头、全部设备首遇现编（vk/vk_shaders.tsv）"; exit 0; }
mkdir -p "$O/b-v1"; echo m > "$O/b-v1/aaaaaaaaaaaaaaaa_b.metallib"; echo aaaaaaaaaaaaaaaa > "$O/keys.tsv"
printf '# S2Arm 键\t直连键\ns2a0000000000001\taaaaaaaaaaaaaaaa\ns2a0000000000002\tbbbbbbbbbbbbbbbb\n' > "$O/key_map.tsv"
echo "[直连库] 🟢 0100 直连库 b-v1：并集 1，出库 1，没出成 0"
EOF
# 出库代码键按声明表算（pack/stage_keyfiles.sh + pack/stage_inputs/direct.tsv，10-26 键收窄）+ 翻译链号：假仓库只列它有的几个文件、假链号 v1
cp "$H/pack/stage_keyfiles.sh" $T/repo/pack/; mkdir -p $T/repo/pack/stage_inputs $T/repo/translator
printf '入\t%s\n' pack/stage_direct.sh pack/ue_pak.py graphics/metal/gal_prog.m > $T/repo/pack/stage_inputs/direct.tsv
printf 'def version(): return "v1"\n' > $T/repo/translator/dmsh_chain.py
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared FAKE_CALLS=$T/calls S2A_PSO_SOURCES=$T/nopso
mkdir -p $T/roots/acnh@s0/romfs $T/roots/acnh@s0/exefs; echo r > $T/roots/acnh@s0/romfs/f; echo main > $T/roots/acnh@s0/exefs/main; printf "title_id\t0100aaaa00000000\n" > $T/roots/acnh@s0/unpack.tsv; mkdir -p $T/roots/acnh@s0/shaders; echo ksh > $T/roots/acnh@s0/.stage_shaders
printf '# 客体代码\t抽取键\n1111111111111111\ts2a0000000000001\n2222222222222222\ts2a0000000000002\n3333333333333333\ts2a0000000000001\n4444444444444444\tref0000000000009\n' > $T/roots/acnh@s0/shaders/guest_keys.tsv; ln -s acnh@s0 $T/roots/acnh@现行
S() { bash $T/repo/pack/stage_direct.sh acnh; }
cur() { cd -P $T/roots/acnh@现行 && pwd; }
calls() { wc -l < $T/calls 2>/dev/null | tr -d ' '; }
# 现行的 RomFS 是只读共享存储（pack/roots.sh，11-03），已提交的版本不许改：「游戏输入变」按真实流程做——
#   开一个自持 RomFS 的阶段（ROOT_OWN_ROMFS=1，同界面布局阶段），在它的工作根里改，提交成新现行。文件从只读存储克隆来，原地改的先 chmod u+w
source $T/repo/pack/roots.sh
rin() { local w t; t=$(root_tag acnh ed); w=$(ROOT_OWN_ROMFS=1 root_begin acnh $t) && (cd "$w" && eval "$1") && root_commit acnh $t > /dev/null 2>&1 || echo "【红】改 RomFS 夹具失败：$1"; }
o=$(S 2>&1); r=$?; c=$(cur); k1=$(cat $c/.stage_direct 2>/dev/null)
ck "出 iOS 包（S2A_PACK_PLAT 缺省）：只出 iOS 库，S2A_DIRECT_TARGETS=ios（实 $(tail -1 $T/calls.tgt)）" '[ "$(tail -1 $T/calls.tgt)" = ios ]'
ck "出 iOS 包：发布 iOS 那份，S2A_DIRECT_PUBLISH=ios（实 $(tail -1 $T/calls.pub)；#897）" '[ "$(tail -1 $T/calls.pub)" = ios ]'
ck "出库成功 → 提交、direct/keys.tsv 在、记键、🟢（$(echo "$o" | tail -1 | cut -c1-60)）" '[ $r = 0 ] && [ -s $c/shaders/direct/keys.tsv ] && [ -n "$k1" ] && [ ! -e $c/direct.tmp ] && [[ "$o" == 🟢* ]]'
n0=$(calls); o=$(S 2>&1); r=$?
ck "同键 → 跳过、不再出库（出库 $n0 → $(calls) 次）" '[ $r = 0 ] && [ "$(calls)" = "$n0" ] && [[ "$o" == *跳过* ]]'
o=$(S2A_PSO_OS=26 S2A_PSO_ARCHS=applegpu_g19p S 2>&1); r=$?
ck "一包通用：换目标 iOS 大版本 / GPU 架构（S2A_PSO_OS=26、S2A_PSO_ARCHS=applegpu_g19p）→ 同键跳过、不重出（出库 $n0 → $(calls) 次；修前 iOS 大版本进键会整份重编）" '[ $r = 0 ] && [ "$(calls)" = "$n0" ] && [[ "$o" == *跳过* ]] && [ "$(cat "$(cur)/.stage_direct")" = "$k1" ]'
rin 'echo r2 > romfs/g'; o=$(S 2>&1); r=$?; c=$(cur); k2=$(cat $c/.stage_direct)
ck "游戏输入变（romfs 加文件）→ 键变（$k1 → ${k2}）、重出（出库 $(calls) 次）" '[ $r = 0 ] && [ "$k2" != "$k1" ] && [ "$(calls)" = $((n0 + 1)) ] && [ -s $c/shaders/direct/keys.tsv ]'
# The selected profile content digest must participate in the library cache key.
bkey=$(cat "$(cur)/.stage_direct"); nprof=$(calls)
o=$(FAKE_PROFILE_KEY=profile2 S 2>&1); r=$?; c=$(cur); profkey=$(cat "$c/.stage_direct")
ck "配置内容摘要改变 → 库键改变且重出（不靠输入 main/RomFS 变化）" '[ $r = 0 ] && [ "$profkey" != "$bkey" ] && [ "$(calls)" = $((nprof + 1)) ]'
# Restore the default selector key before the following rejection cases.
o=$(S 2>&1); k2=$(cat "$(cur)/.stage_direct")
rin 'echo r3 > romfs/h'; b=$(cur); n1=$(calls); o=$(FAKE_NOPROF=1 S 2>&1); r=$?; c=$(cur); k3=$(cat $c/.stage_direct)
ck "配置前置拒绝（边界stub） → 退出3、不调出库、不改现行/旧成功键" '[ $r = 3 ] && [ "$c" = "$b" ] && [ "$k3" = "$k2" ] && [ "$(calls)" = "$n1" ] && [[ "$o" == *配置前置拒绝* ]]'
o=$(FAKE_NOPROF=1 S 2>&1); r=$?
ck "再次拒绝，不把准备候选当成功缓存（出库 $n1 → $(calls) 次）" '[ $r = 3 ] && [ "$(calls)" = "$n1" ] && [ "$(cat "$(cur)/.stage_direct")" = "$k2" ]'
o=$(S 2>&1); k3=$(cat "$(cur)/.stage_direct"); n2=$(calls); echo ksh2 > $(cur)/.stage_shaders; o=$(S 2>&1); r=$?
ck "着色器阶段键变 → 直连库不重出（10-25：直连库键不含着色器阶段，两段并行；出库 $n2 → $(calls) 次）" '[ $r = 0 ] && [ "$(calls)" = "$n2" ] && [ "$(cat "$(cur)/.stage_direct")" = "$k3" ]'
rin 'echo r4 > romfs/i'; b=$(cur); o=$(FAKE_FAIL=1 S 2>&1); r=$?
ck "出库失败 → 退出 1、现行不动、【红】、日志副本在 .failed/" '[ $r = 1 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *【红】* ]] && [ -f $T/roots/.failed/acnh_direct_lib.log ] && [ -z "$(ls -d $T/roots/*.tmp 2>/dev/null)" ]'
rm -f $T/roots/.failed/acnh_direct_lib.log; o=$(FAKE_GAP=1 S 2>&1); r=$?
ck "出库内容缺口 → 退出 3（rc=${r}）、【黄】带缺口原文、现行不动、日志副本在 .failed/" '[ $r = 3 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *"【黄】acnh 直连缺口：NVN 着色器 翻不了 1 支（0123456789abcdef：桩原因）"* ]] && [[ "$o" != *【红】* ]] && [ -f $T/roots/.failed/acnh_direct_lib.log ] && [ -z "$(ls -d $T/roots/*.tmp 2>/dev/null)" ]'
# 包键：各阶段键原样拼 + 直连库键；尾部带进包资源输入键与系统数据戳（只有直连，11-07：不再带通用着色器阶段键，环境里留着旧的 S2A_DUAL 也不改包键）
source $T/repo/pack/ipa_key.sh; c=$(cur); for s in rewrite shaders uilayout romfsidx; do echo "k_$s" > $c/.stage_$s; done
p0=$(unset S2A_DUAL; ipa_pkg_key C1 $c); p1=$(S2A_DUAL=0 ipa_pkg_key C1 $c)   # 不给款名 = 不算包外进 App 的文件（随包表 / 图标在 tests/pkg_key_inputs_test.sh 核）
rk=$(python3 $T/repo/pack/resource_input_key.py $c)   # 进包资源输入键（审计 P1-54：romfs / aoc 内容抽样进包键），系统数据戳这里没有 = 空
k3=$(cat $c/.stage_direct)
ck "包键 = 「C1 k_rewrite k_uilayout k_romfsidx dual=<直连库键> res=<资源输入键> sys= in=<进包内容键 16 位>」（实 ${p0}）" '[ -n "$rk" ] && [[ "$p0" =~ ^"C1 k_rewrite k_uilayout k_romfsidx dual=$k3 res=$rk sys= in="[0-9a-f]{16}$ ]]'
ck "包键与环境里旧的 S2A_DUAL 无关（实 ${p1}）" '[ "$p1" = "$p0" ]'
# 抽取阶段（pack/stage_extract.sh，10-25「抽着色器只做一次」）的键进直连库键：抽取变了要重出
n3=$(calls); echo ex2 > $(cur)/.stage_extract; o=$(S 2>&1); r=$?
ck "抽取阶段键变 → 直连库重出（出库 $n3 → $(calls) 次）" '[ $r = 0 ] && [ "$(calls)" = $((n3 + 1)) ]'
rin 'echo mac > romfs/macpkg'; o=$(S2A_PACK_PLAT=macos S 2>&1); r=$?
ck "出 Mac 版 App（S2A_PACK_PLAT=macos）：只出 Mac 库，S2A_DIRECT_TARGETS=mac（10-31：iOS 那份无人读；实 $(tail -1 $T/calls.tgt)，rc=${r}）" '[ $r = 0 ] && [ "$(tail -1 $T/calls.tgt)" = mac ]'
ck "出 Mac 版 App：发布 Mac 那份，S2A_DIRECT_PUBLISH=mac（实 $(tail -1 $T/calls.pub)；#897：修前包里是 iOS 库）" '[ "$(tail -1 $T/calls.pub)" = mac ]'
rin 'chmod u+w romfs/macpkg; echo mac2 > romfs/macpkg'; o=$(S2A_PACK_PLAT=macos S2A_DIRECT_PUBLISH=ios S 2>&1)
ck "调用方给 S2A_DIRECT_PUBLISH=ios 出 Mac 版：不收，仍发布 mac（实 $(tail -1 $T/calls.pub)）" '[ "$(tail -1 $T/calls.pub)" = mac ]'
mkdir -p $T/repo/graphics/tools/direct/vklib; cat > $T/repo/graphics/tools/direct/vklib/dsh_vklib.py <<'EOF'
import os, sys
open(os.environ['FAKE_CALLS'] + '.vkfp', 'a').write('1\n')
if os.environ.get('FAKE_VKFP_FAIL') == '1': sys.exit('[RED] 桩：算不出指纹')
print(os.environ.get('FAKE_VKFP', '00000000000000aa'))
EOF
vk() { cat $T/calls.vkfp 2> /dev/null | wc -l | tr -d ' '; }
na=$(calls); o=$(S2A_PACK_PLAT=android S 2>&1); r=$?; ka=$(cat "$(cur)/.stage_direct")
ck "安卓（S2A_PACK_PLAT=android，rc=${r}）：出库目标 android、发布 android（实 $(tail -1 $T/calls.tgt) / $(tail -1 $T/calls.pub)），算了 1 次 VkFp（实 $(vk)；前面苹果各例一次没算）" '[ $r = 0 ] && [ "$(tail -1 $T/calls.tgt)" = android ] && [ "$(tail -1 $T/calls.pub)" = android ] && [ "$(vk)" = 1 ] && [ "$(calls)" = $((na + 1)) ]'
o=$(S2A_PACK_PLAT=android S 2>&1); r=$?
ck "安卓同键 → 跳过（出库 $((na + 1)) → $(calls) 次）" '[ $r = 0 ] && [ "$(calls)" = $((na + 1)) ] && [[ "$o" == *跳过* ]]'
o=$(S2A_PACK_PLAT=android FAKE_VKFP=00000000000000bb S 2>&1); r=$?; kb=$(cat "$(cur)/.stage_direct")
ck "安卓：只改 Vulkan 侧代码（VkFp 变）→ 键变（$ka → ${kb}）、重出" '[ $r = 0 ] && [ "$kb" != "$ka" ] && [ "$(calls)" = $((na + 2)) ]'
b=$(cur); o=$(S2A_PACK_PLAT=android FAKE_VKFP_FAIL=1 S 2>&1); r=$?
ck "安卓：VkFp 算不出（rc=${r}）→ 退出 1、【红】点名 Vulkan 侧指纹、现行不动、不调出库" '[ $r = 1 ] && [[ "$o" == *"【红】acnh 算不出 Vulkan 侧指纹"* ]] && [ "$(cur)" = "$b" ] && [ "$(calls)" = $((na + 2)) ]'
# 上游已解析工具链（S2A_TC_RESOLVED=1 + DEVELOPER_DIR + S2A_TC_METAL，tools/toolchain.sh 直接沿用）：macOS 上出安卓包就是这样，Linux 上一键出包导出了也一样
tc() { S2A_TC_RESOLVED=1 DEVELOPER_DIR=$T S2A_TC_METAL="Apple metal version $1 (fixture)" "${@:2}"; }
o=$(tc 1.0 env S2A_PACK_PLAT=android FAKE_VKFP=00000000000000bb bash $T/repo/pack/stage_direct.sh acnh 2>&1); r=$?; o2=$(tc 2.0 env S2A_PACK_PLAT=android FAKE_VKFP=00000000000000bb bash $T/repo/pack/stage_direct.sh acnh 2>&1); r2=$?
ck "安卓键不带 Metal 编译器版本（#1425 审）：上游导出 S2A_TC_METAL、换版本 1.0 / 2.0（rc=${r} / ${r2}）→ 安卓键不变（$kb → $(cat "$(cur)/.stage_direct")）、两次都跳过、不调出库" '[ $r = 0 ] && [ $r2 = 0 ] && [ "$(cat "$(cur)/.stage_direct")" = "$kb" ] && [ "$(calls)" = $((na + 2)) ] && [[ "$o" == *跳过* ]] && [[ "$o2" == *跳过* ]]'
nf=$(vk); o=$(S 2>&1); ki=$(cat "$(cur)/.stage_direct"); ni=$(calls); o=$(FAKE_VKFP=00000000000000cc S 2>&1); r=$?
ck "iOS：不算 VkFp（$nf → $(vk) 次）；VkFp 变了 iOS 键不变、跳过" '[ $r = 0 ] && [ "$(vk)" = "$nf" ] && [ "$(cat "$(cur)/.stage_direct")" = "$ki" ] && [ "$(calls)" = "$ni" ] && [[ "$o" == *跳过* ]]'
o=$(tc 1.0 bash $T/repo/pack/stage_direct.sh acnh 2>&1); r=$?; o2=$(tc 2.0 bash $T/repo/pack/stage_direct.sh acnh 2>&1); r2=$?; kj=$(cat "$(cur)/.stage_direct")
ck "反证 iOS：同样换 Metal 编译器版本 1.0 → 2.0（rc=${r} / ${r2}）→ iOS 键变（→ ${kj}）、两次都重出（出库 $ni → $(calls) 次）" '[ $r = 0 ] && [ $r2 = 0 ] && [ "$kj" != "$ki" ] && [ "$(calls)" = $((ni + 2)) ]'
# 并行路数（10-25 维护者「多核要适配机器的核心数」）：没给 J / S2A_CPU_BAKE 时按 S2A_JOBS 开满
jn() { rin "chmod u+w romfs/f; echo $1 >> romfs/f"; env -u J -u S2A_CPU_BAKE S2A_JOBS=18 bash $T/repo/pack/stage_direct.sh acnh >/dev/null 2>&1; tail -1 $T/calls.j; }
ck "S2A_JOBS=18：J=18（实 $(jn a)）" '[ "$(tail -1 $T/calls.j)" = 18 ]'
# #1233 P2-53：同路径同长度变内容，两个真实阶段必须各自失效并调用后端；不改原断言。
mkdir -p "$(cur)/aoc/1"
rin "printf 'a\\n' > romfs/p253-small.bin"; printf 'd\n' > "$(cur)/aoc/1/p253-small.bin"
rin "python3 -c 'import pathlib; pathlib.Path(\"romfs/p253-large.bin\").write_bytes(b\"A\" * (3 * 65536))'"
o=$(S 2>&1); r=$?; p253k=$(cat "$(cur)/.stage_direct" 2>/dev/null)
ck "P2-53 合成输入基线提交（rc=${r}）" '[ $r = 0 ] && [ -n "$p253k" ]'
p253_changed() {
  local previous=$p253k count_before=$(calls)
  o=$(S 2>&1); r=$?; p253k=$(cat "$(cur)/.stage_direct" 2>/dev/null)
  ck "P2-53 $1：同长度变字节应重做（rc=${r}）" '[ $r = 0 ] && [ "$p253k" != "$previous" ] && [ "$(calls)" = "$((count_before + 1))" ]'
}
rin "chmod u+w romfs/p253-small.bin; printf 'b\\n' > romfs/p253-small.bin"; p253_changed 'romfs'
printf 'e\n' > "$(cur)/aoc/1/p253-small.bin"; p253_changed 'aoc'
rin "chmod u+w romfs/p253-large.bin; python3 -c 'f = open(\"romfs/p253-large.bin\", \"r+b\"); f.write(b\"B\"); f.close()'"
p253_changed '大文件首块'
rin "chmod u+w romfs/p253-large.bin; python3 -c 'f = open(\"romfs/p253-large.bin\", \"r+b\"); f.seek(-1, 2); f.write(b\"C\"); f.close()'"
p253_changed '大文件尾块'
p253before=$(calls); rin 'touch romfs/p253-small.bin'; o=$(S 2>&1); r=$?
ck "P2-53 只变mtime：原键跳过" '[ $r = 0 ] && [ "$(cat "$(cur)/.stage_direct")" = "$p253k" ] && [ "$(calls)" = "$p253before" ] && [[ "$o" == *跳过* ]]'
o=$(S 2>&1); r=$?
ck "P2-53 内容不变再次调用：仍跳过" '[ $r = 0 ] && [ "$(calls)" = "$p253before" ] && [[ "$o" == *跳过* ]]'

# 11-05 抽取缺口 → 运行时现编空库（维护者：直连库编不出也照出包）：期望按 graphics/nvn/lib_pack.inc 格式手写——lib.idx 48 字节：魔数 S2ALIB\0\0、版本 1、0 条、0 分片、
#   链号（夹具 dmsh_chain 是 "v1"）补零到 12 字节；inputs.tsv 写 game <程序号>；shader_map.tsv / keys.tsv 在且为空；runtime_only.txt 带缺口原因；不调离线出库；
#   tools/direct_shards.py check（独立读法）对它退 0
rin 'mkdir -p extract && echo "直连库失败：直连抽取 0 支着色器（缺口：桩）" > extract/direct_gap.txt && printf "title_id\t0100aaaa00000000\n" > unpack.tsv'
nrt=$(calls); o=$(S 2>&1); r=$?; c=$(cur); D=$c/shaders/direct
hdr=$(python3 -c 'import struct,sys; h=open(sys.argv[1],"rb").read(); print(len(h), h[:8]==b"S2ALIB\0\0", *struct.unpack_from("<III",h,8), h[24:36].rstrip(b"\0").decode())' "$D/b-v1/lib.idx" 2> /dev/null)
ck "抽取缺口 → 运行时现编空库：退 0（rc=${r}）、不调出库（$nrt → $(calls)）、lib.idx「${hdr}」、inputs / 空映射表 / 原因都在、打黄" \
   '[ $r = 0 ] && [ "$(calls)" = "$nrt" ] && [ "$hdr" = "48 True 1 0 0 v1" ] && grep -qx "game	0100AAAA00000000" "$D/b-v1/inputs.tsv" && [ -f "$D/shader_map.tsv" ] && [ ! -s "$D/shader_map.tsv" ] && [ -f "$D/keys.tsv" ] && grep -q "直连抽取 0 支着色器" "$D/runtime_only.txt" && [ -f "$D/shader_facts.tsv" ] && [ -f "$D/shader_pairs.tsv" ] && [[ "$o" == *"离线 0 支、运行时首遇现编"* ]]'
ck "运行时现编空库过分片核对（tools/direct_shards.py check 退 0）" 'python3 "$H/tools/direct_shards.py" check "$c" > /dev/null 2>&1'
rin 'rm -f extract/direct_gap.txt'; nfix=$(calls); o=$(S 2>&1); r=$?; c=$(cur)
ck "抽取修好（缺口标记没了、游戏输入不变）→ 键变、重调离线出库（$nfix → $(calls)）、不再是空库" '[ $r = 0 ] && [ "$(calls)" = $((nfix + 1)) ] && [ ! -e "$c/shaders/direct/runtime_only.txt" ] && [ -s "$c/shaders/direct/keys.tsv" ]'

# Vulkan 款只出表头（11-05 r4 Minecraft：出包不起局后 RomFS 没 SPIR-V，keys.tsv 空、只有 vk/vk_shaders.tsv）→ 也算出了库：现行带 shaders/direct/vk/vk_shaders.tsv
rin 'echo vk > romfs/vkhdr'; o=$(FAKE_VKHDR=1 S 2>&1); r=$?; c=$(cur)
ck "Vulkan 只出表头 → 退 0、现行 shaders/direct/vk/vk_shaders.tsv 在（rc=${r}）" '[ $r = 0 ] && [ -s "$c/shaders/direct/vk/vk_shaders.tsv" ] && [ -f "$c/shaders/direct/keys.tsv" ]'

# 启动器内置工具（S2A_PREBUILT_TOOLS，11-06）：调用方没给 DSX_LIB → 用内置的 dsx/libdsx.dylib、不现编（假仓库没有 graphics/dsx Makefile，现编必红）
mkdir -p $T/pre/dsx && : > $T/pre/dsx/libdsx.dylib; rin 'echo pre > romfs/pre'
o=$(env -u DSX_LIB S2A_PREBUILT_TOOLS=$T/pre bash $T/repo/pack/stage_direct.sh acnh 2>&1); r=$?
ck "内置工具在 → DSX_LIB 取内置 libdsx、不现编（rc=${r}，实 $(tail -1 $T/calls.gal)）" '[ $r = 0 ] && [ "$(tail -1 $T/calls.gal)" = "$T/pre/dsx/libdsx.dylib" ]'

_root_rm $T   # 现行 RomFS 存储整棵只读，裸 rm -rf 删不掉（pack/roots.sh）
[ $bad = 0 ] && echo "直连库阶段单测：全通" || echo "直连库阶段单测：有不通"
exit $bad
