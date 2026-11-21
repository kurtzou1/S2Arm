#!/bin/bash
# 计算管线随包归档单测（graphics/tools/direct/cs_pipelines.py + pack/stage_direct_cpso.sh；要本机 Metal 工具链与 GPU，约 30 秒）：bash graphics/tools/direct/tests/t_cs_pipelines.sh
# 夹具：合成直连库目录——shader_map.tsv 里计算键 A、B、D 与片元键 P；库容器（lib.idx + lib.000.pak，格式同 graphics/nvn/lib_pack_core.inc）里 A、B、P 三键的种类 0 指向同一段批库
#   （s<A>_main0 各加 1、s<B>_main0 各加 2，fn_prefix「s<键>_」+ entry main0，同 dsh 批库），D 在表里、库里没有。
# 期望（不跑被测实现就写得出）：
#   ① 出 2 个文件，名字 = 「c」+ sha256("<键>_b") 前 40 位（shasum 现算，同设备 par_ckey(cs, 0)），P、D 没有文件；读数行「计算着色器 2 支（…库里缺 1 支…）」
#   ①b 归档只带本支函数、不背整段批库：A 的归档里没有字符串 s<B>_main0，读数「其中按整段库出 0」（metal-tt 会把交给它的库原样装进归档；
#      反证：同一夹具强制按整段出（把批库交给 metal-tt 本身，下面 ③ 的整段对照）A 的归档里有 s<B>_main0）
#   ② 设备同一描述（只设 computeFunction + FailOnBinaryArchiveMiss，t_cs_pipelines.m）：A 的归档 + A 的函数命中且派发结果逐个 +1；B 同理 +2
#   ③ 反证：A 的归档 + B 的函数不命中；按上一个系统大版本出的不命中；只出别的架构的不命中；本机架构 + 别的架构出一个文件照样命中
#   ④ 再跑同参数：缓存命中 2、现编 0，文件逐字节相同
#   ⑤ metal-tt 失败（S2A_METAL_TT 换成退 1 的假工具、空缓存）：退出 3、0 个文件、读数「失败 2 支」
#   ⑥ 阶段 pack/stage_direct_cpso.sh（假产物根、S2A_PACK_PLAT=macos、S2A_PSO_ARCHS=本机架构）：现行根出 pipelines/ 两个文件、记键；再跑跳过；目标架构变了重跑
set -u; H=$(cd "$(dirname "$0")/../../../.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_cs_pipelines.XXXXXX"); trap 'rm -rf "$T"' EXIT
n=0; fail=0
ck() { n=$((n + 1)); if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=$((fail + 1)); fi; }
S2A_TC_QUIET=1 source "$H/tools/toolchain.sh" > /dev/null 2>&1 || { echo "✗ 统一工具链解析失败（tools/toolchain.sh）"; echo "t_cs_pipelines：0 项，失败 1"; exit 1; }
for t in metal metallib metal-tt; do xcrun -sdk macosx -f "$t" > /dev/null 2>&1 || { echo "✗ 本机没有 Metal 工具链（${t}）"; echo "t_cs_pipelines：0 项，失败 1"; exit 1; }; done
clang -fobjc-arc -O1 -o "$T/gpu_arch" "$H/graphics/tools/shbake/gpu_arch.m" -framework Metal -framework Foundation 2> /dev/null && ARCH=$("$T/gpu_arch") && [ -n "$ARCH" ] \
  || { echo "✗ 取不到本机 GPU 架构"; echo "t_cs_pipelines：0 项，失败 1"; exit 1; }
clang -fobjc-arc -O1 -o "$T/probe" "$H/graphics/tools/direct/tests/t_cs_pipelines.m" -framework Metal -framework Foundation 2> "$T/cc.log" \
  || { echo "✗ 编探针失败：$(head -3 "$T/cc.log")"; echo "t_cs_pipelines：0 项，失败 1"; exit 1; }
MAJ=$(sw_vers -productVersion | cut -d. -f1)
OTHER=$(awk -F'\t' -v v="$MAJ" -v a="$ARCH" '$1 == "macos" && $2 == v && $5 == "出" && $3 != a { print $3; exit }' "$H/pack/pso_targets.tsv")
A=00000a0000000001 B=00000b0000000002 P=00000c0000000003 D=00000d0000000004
F=$T/fx/shaders/direct; mkdir -p "$F/b-t1"
printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void s%s_main0(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 1.0; }\nkernel void s%s_main0(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 2.0; }\n' $A $B > "$T/batch.metal"
xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$T/batch.metal" -o "$T/batch.air" && xcrun -sdk macosx metallib "$T/batch.air" -o "$T/batch.metallib" \
  || { echo "✗ 夹具批库编不出"; echo "t_cs_pipelines：0 项，失败 1"; exit 1; }
printf 'cs.bin\t0\tcompute\t%s\tfx\ncs.bin\t1\tcompute\t%s\tfx\nps.bin\t0\tpixel\t%s\tfx\ncs.bin\t2\tcompute\t%s\tfx\n' $A $B $P $D > "$F/shader_map.tsv"
python3 - "$F/b-t1" "$T/batch.metallib" $A $B $P <<'EOF'
import json, struct, sys
out, seg, keys = sys.argv[1], open(sys.argv[2], 'rb').read(), sys.argv[3:]
pak, recs = bytearray(seg), []
for k in keys:
    j = json.dumps({'fn_prefix': f's{k}_', 'entry': 'main0', 'stage': 'compute'}).encode()
    recs += [(int(k, 16), 0, 0, len(seg)), (int(k, 16), 1, len(pak), len(j))]; pak += j
recs.sort()
hd = bytearray(48); hd[:8] = b'S2ALIB\0\0'; struct.pack_into('<III', hd, 8, 1, len(recs), 1); hd[24:26] = b't1'
idx = hd + struct.pack('<QQ', len(pak), 0) + b''.join(struct.pack('<QBBHIQ', k, kind, 0, 0, ln, off) for k, kind, off, ln in recs)
open(out + '/lib.idx', 'wb').write(idx); open(out + '/lib.000.pak', 'wb').write(pak)
EOF
cfile() { printf '%s_b' "$1" | shasum -a 256 | cut -c1-40 | sed 's/^/c/;s/$/.metalarchive/'; }
FA=$(cfile $A) FB=$(cfile $B)
CS() { python3 "$H/graphics/tools/direct/cs_pipelines.py" "$F" "$1" --plat macos "${@:2}"; }
probe() { "$T/probe" "$1" "$T/batch.metallib" "s$2_main0" "$3" 2>&1; }

# ① ②
o=$(CS "$T/o1" --os "$MAJ" --arch "$ARCH" --cache "$T/cache" -j 2 2>&1); r=$?
ck "① 退出 0、恰好 2 个文件且就是 A / B 的 par_ckey 名（实：$(ls "$T/o1" 2> /dev/null | tr '\n' ' ')）" '[ $r = 0 ] && [ "$(ls "$T/o1" | sort)" = "$(printf "%s\n" "$FA" "$FB" | sort)" ]'
ck "① 读数：计算着色器 2 支、库里缺 1 支、出 2 支（$(tail -1 <<< "$o" | cut -c1-120)）" '[[ "$(tail -1 <<< "$o")" == *"计算着色器 2 支（表里有、库里缺 1 支不算），出 2 支"* ]]'
ck "①b A 的归档不带 B 的函数（单函数模块出），读数「其中按整段库出 0」" '! grep -aq "s${B}_main0" "$T/o1/$FA" && grep -aq "s${A}_main0" "$T/o1/$FA" && [[ "$(tail -1 <<< "$o")" == *"其中按整段库出 0"* ]]'
printf '{"generator":"MetalFramework","version":[0,1,0],"libraries":{"paths":[{"label":"L","path":"%s"}]},"pipelines":{"render_pipelines":[],"compute_pipelines":[{"compute_function":"alias:L#s%s_main0"}]}}' "$T/batch.metallib" $A > "$T/whole.mtlp-json"
xcrun -sdk macosx metal-tt -arch "$ARCH" -macos-version-min "$MAJ.0" "$T/whole.mtlp-json" -o "$T/whole.bin" > /dev/null 2>&1
ck "①b 反证：整段批库交给 metal-tt 出的 A 归档里有 s<B>_main0（$(wc -c < "$T/whole.bin" 2> /dev/null) 字节，单函数出的 $(wc -c < "$T/o1/$FA") 字节）、照样命中（$(probe "$T/whole.bin" $A 1)）" 'grep -aq "s${B}_main0" "$T/whole.bin" && [ "$(probe "$T/whole.bin" $A 1)" = "hit=1 run=1" ]'
ck "② A 的归档 + A 的函数：命中、派发各 +1（$(probe "$T/o1/$FA" $A 1)）" '[ "$(probe "$T/o1/$FA" $A 1)" = "hit=1 run=1" ]'
ck "② B 的归档 + B 的函数：命中、派发各 +2（$(probe "$T/o1/$FB" $B 2)）" '[ "$(probe "$T/o1/$FB" $B 2)" = "hit=1 run=1" ]'
# ③
ck "③ 反证：A 的归档 + B 的函数不命中（$(probe "$T/o1/$FA" $B 2)）" '[ "$(probe "$T/o1/$FA" $B 2)" = "hit=0 run=-" ]'
CS "$T/o2" --os $((MAJ - 1)) --arch "$ARCH" > /dev/null 2>&1
ck "③ 反证：按系统大版本 $((MAJ - 1)) 出的不命中（$(probe "$T/o2/$FA" $A 1)）" '[ "$(probe "$T/o2/$FA" $A 1)" = "hit=0 run=-" ]'
if [ -n "$OTHER" ]; then
  CS "$T/o3" --os "$MAJ" --arch "$OTHER" > /dev/null 2>&1
  ck "③ 反证：只出别的架构 ${OTHER} 的不命中（$(probe "$T/o3/$FA" $A 1)）" '[ -s "$T/o3/$FA" ] && [ "$(probe "$T/o3/$FA" $A 1)" = "hit=0 run=-" ]'
  CS "$T/o4" --os "$MAJ" --arch "$OTHER" --arch "$ARCH" > /dev/null 2>&1
  ck "③ 本机 ${ARCH} + ${OTHER} 出进一个文件：命中（$(probe "$T/o4/$FA" $A 1)；$(wc -c < "$T/o4/$FA") 字节，单架构 $(wc -c < "$T/o1/$FA")）" '[ "$(probe "$T/o4/$FA" $A 1)" = "hit=1 run=1" ] && [ "$(wc -c < "$T/o4/$FA")" -gt "$(wc -c < "$T/o1/$FA")" ]'
else ck "③ 目标表里本机大版本 ${MAJ} 有第二个 macOS 架构（跨架构反证要用）" 'false'; fi
# ④
o=$(CS "$T/o5" --os "$MAJ" --arch "$ARCH" --cache "$T/cache" 2>&1); r=$?
ck "④ 再跑：缓存命中 2、现编 0、文件逐字节相同（$(tail -1 <<< "$o" | grep -o '缓存命中[^）]*')）" '[ $r = 0 ] && [[ "$o" == *"缓存命中 2、现编 0"* ]] && cmp -s "$T/o1/$FA" "$T/o5/$FA" && cmp -s "$T/o1/$FB" "$T/o5/$FB"'
# ⑤
printf '#!/bin/sh\necho "fake metal-tt: broken" >&2; exit 1\n' > "$T/badtt"; chmod +x "$T/badtt"
o=$(S2A_METAL_TT=$T/badtt CS "$T/o6" --os "$MAJ" --arch "$ARCH" --cache "$T/cache6" 2>&1); r=$?
ck "⑤ metal-tt 失败：退出 3、0 个文件、读数失败 2 支（退出 ${r}，$(ls "$T/o6" 2> /dev/null | wc -l | tr -d ' ') 个文件）" '[ $r = 3 ] && [ -z "$(ls "$T/o6")" ] && [[ "$(tail -1 <<< "$o")" == *"失败 2 支"* ]]'
# ⑥ 阶段：假产物根（只有直连库目录与直连库阶段键），私有根
RT=$T/roots; mkdir -p "$RT/fx@v1/shaders"; cp -R "$F" "$RT/fx@v1/shaders/"; echo k1 > "$RT/fx@v1/.stage_direct"; printf 'title_id\t0100aaaa00000000\n' > "$RT/fx@v1/unpack.tsv"; printf '%s\n' fx@v1 > "$RT/fx@现行"
ST() { S2A_ROOTS=$RT S2A_ROOTS_SHARED=$T/shared S2A_RUN_ROOT=$T/run S2A_PACK_PLAT=macos S2A_MAC_OS=$MAJ S2A_PSO_ARCHS="$1" J=2 bash "$H/pack/stage_direct_cpso.sh" fx 2>&1; }
cur() { cd -P "$RT/$(cat "$RT/fx@现行")" && pwd; }
o=$(ST "$ARCH"); r=$?
ck "⑥ 阶段出归档：退出 ${r}、现行根 pipelines/ 恰是 A / B 两个、记了键（$(tail -1 <<< "$o" | cut -c1-140)）" \
   '[ $r = 0 ] && [ "$(ls "$(cur)/shaders/direct/pipelines" 2> /dev/null | sort)" = "$(printf "%s\n" "$FA" "$FB" | sort)" ] && [ -s "$(cur)/.stage_direct_cpso" ]'
ck "⑥ 阶段出的归档按设备描述命中（$(probe "$(cur)/shaders/direct/pipelines/$FA" $A 1)）、缓存落在直连缓存 store/cpso/" '[ "$(probe "$(cur)/shaders/direct/pipelines/$FA" $A 1)" = "hit=1 run=1" ] && [ "$(find "$T/run/s2arm/cache/direct/0100AAAA00000000/store/cpso" -name "*.e" | wc -l | tr -d " ")" = 2 ]'
k1=$(cat "$(cur)/.stage_direct_cpso"); o=$(ST "$ARCH"); r=$?
ck "⑥ 同目标再跑：跳过（$(tail -1 <<< "$o" | cut -c1-80)）" '[ $r = 0 ] && [[ "$(tail -1 <<< "$o")" == *跳过* ]] && [ "$(cat "$(cur)/.stage_direct_cpso")" = "$k1" ]'
if [ -n "$OTHER" ]; then o=$(ST "$ARCH $OTHER"); r=$?
  ck "⑥ 目标多一个架构：重跑、键变（$(tail -1 <<< "$o" | cut -c1-80)）" '[ $r = 0 ] && [[ "$(tail -1 <<< "$o")" != *跳过* ]] && [ "$(cat "$(cur)/.stage_direct_cpso")" != "$k1" ]'; fi
echo "t_cs_pipelines：$n 项，失败 $fail"
[ $fail = 0 ]
