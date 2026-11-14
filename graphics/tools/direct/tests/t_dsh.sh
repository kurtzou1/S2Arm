#!/bin/bash
# S2A.Dsh（直连兜底现编，graphics/tools/direct/dsh）单测：考卷 = 直连离线链对动森（01006F8002326000）的全部产物，期望值就是离线链出的文件，不跑被测实现得来。
#   ① 命令行 spirv-cross 后端抽 300 键（几何全取、配对片元不在样本里的预置离线 .metal）：.metal 逐字节、.json 按语义（去 chain_metal / vin / fetch）全一致
#   ② 同一后端走导出入口 s2a_dsh_compile 的本体抽 40 键：全一致
#   ③ 内置 SPIRV-Cross 后端（libdsx nxgal_dmsh_xc）抽 500 键：bindings 与入口名全一致；Metal 校验器 newLibraryWithSource 建库、按名取入口全过
#   ④ 反证：答案表清空后，表里的键（期望数 = 表行数里在映射表中的）全部判不一致（判据不会绿着失效）
#   ⑤ 导出入口失败路径 4 例：返回非 0、stderr 一行【红】
#   ⑤b 缺答案表 shader_facts.tsv 按空表现编：40 键全部编出（11-13 D-QW2Q）
#   ⑥ 逐函数对照（t_dsh_fn.py）：冻结金样 dsh_fn_golden.jsonl（删除前的离线链原函数一次算出，无游戏数据）vs C# 移植，补考卷没走到的分支
#   ⑧ 宽屏外推尾段（t_push.py）：vs_push 插的那段在 GPU 上逐例跑，期望按规格手算，带反证
#   ⑫ 片元早期深度照实传（t_early_z.py）：控制段 +0x718 位 0 → [[early_fragment_tests]]，期望脚本自己读包里的控制段字节，带反证
#   ⑩ 宽屏 16:9 采样换算（t_uvx.py）：fs_uvx 的改写与插进去的 s2a_uv 在 GPU 上逐例跑，期望按回放层取值手算，带反证
#   ⑨ 缓存命中路径的可读瓦片变体（10-26）：带整数输出入口（main0_u）又有 _bf 的片元键，空缓存新编一遍、拿它的缓存再出一遍（走缓存命中），两遍都出 _bf 且逐字节相同
#      （旧代码缓存命中时把带 main0_u 的整份 _b.metal 交给变体生成，变体编不过、悄悄没有 _bf：暗黑3 3f4319a0c8392329）
# 考卷（10-25 起）：门禁自己出，生产出库碰不到。输入 = 冻结的动森包目录 + 表（DSH_INPUTS，缺省 ~/.s2arm/run/s2arm/gate_data/dsh/01006F8002326000，只读，
#   bash t_dsh.sh freeze <直连出库 work 目录：出库时设 S2A_DIRECT_KEEP=1，留在 cache/direct/<程序号>/keep/work> 才会写；inputs.sha 核内容，对不上 = 红）；答案 = 被测这棵树的离线链
#   （C# 整份出库 dsh_batch build，11-01 出库链挪进 C#；部分出库随迁移删除）在小夹具上整份出库：配置档副本的映射表只留本次要比的键（曲面阶段行全留，域模式按全部域着色器算），
#   只出 Mac、按 Mac 版出包形态发布（--no-ios --publish mac，顺带出 ps_inputs.tsv 给 ⑦），--export-mac 导出逐键文件当考卷；
#   放 DSH_EXAM_CACHE（缺省 ~/.s2arm/run/s2arm/cache/gate_dsh）/<输入指纹>-<链版本>-<翻译指纹 + 出库进程源码指纹>-<键集>/，同一翻译器复用，内容寻址缓存 cas/ 跨版本共用（冷出 753 键约 80 秒）。
#   原先考卷是生产缓存 cache/direct/<程序号>：b-<链版本> 是陆续增量出的、work/ 每次出库整体覆盖，两者对不上，10-25 00:25 一次出库后门禁 68/300 红（同一提交现出考卷 300/300）。
# 全量 9794 键对拍不在门禁里：DSH_EXAM=<直连出库缓存目录>/keep bash t_dsh.sh full（读那份出库自己的答案与输入；出库时设 S2A_DIRECT_KEEP=1，10-31 起缓存不再常留逐键产物）。
set -u; R=$(cd "$(dirname "$0")/../../../.." && pwd); H=$R/graphics/tools/direct/tests
# X = 正在出的考卷临时目录：门禁外层超时杀掉本脚本时一并删（10-30 df9957b7c 全套：.mk.* 半成品 255 MB 留在共享缓存，下一次照样从头冷出）
X=; T=$(mktemp -d "${TMPDIR:-/tmp}/t_dsh.XXXXXX"); trap 'rm -rf "$T" ${X:+"$X"}' EXIT; bad=0; res=()
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=1; fi; res+=("$3"); }
TID=01006F8002326000; IN=${DSH_INPUTS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_data/dsh/$TID}
insha() { (cd "$1" && find . -type f ! -name inputs.sha | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16); }
if [ "${1:-}" = freeze ]; then   # freeze <直连出库 work 目录>：冻结门禁输入（只在换考卷游戏 / 抽取格式变了时人工跑一次）
  W=${2:?freeze 要给直连出库的 work 目录（S2A_DIRECT_KEEP=1 出库后的 cache/direct/<程序号>/keep/work）}; [ ! -e "$IN" ] || { echo "$IN 已在（换新先挪走旧的）"; exit 1; }
  mkdir -p "$IN/profile" && cp -R "$W/merged/pkg" "$IN/pkg" && cp "$W/merged/shader_map.tsv" "$IN/" && cp -R "$W/profile/$TID" "$IN/profile/" && insha "$IN" > "$IN/inputs.sha" && chmod -R a-w "$IN" && echo "冻结 ${IN}（$(cat "$IN/inputs.sha")）"; exit $?
fi
if [ -n "${DSH_EXAM:-}" ]; then E=$DSH_EXAM   # 指定一份出库缓存（全量对拍那份出库自己的答案）
  CHAIN=$(sed -n 's/.*DMSH_CHAIN "\([0-9a-f]*\)".*/\1/p' "$R/graphics/nvn/gfx/nvn/dmsh_chain.h")
  REF=$E/mac/b-$CHAIN; PKG=$E/work/merged/pkg; MAP=$E/work/merged/shader_map.tsv; TAB=$E/work/profile/$TID
else PKG=$IN/pkg; MAP=$IN/shader_map.tsv; TAB=$IN/profile/$TID
  [ -f "$IN/inputs.sha" ] || { echo "S2A.Dsh 对拍：没有门禁输入 ${IN}（bash $0 freeze <直连出库 work 目录>）→ 红"; exit 1; }
  [ "$(insha "$IN")" = "$(cat "$IN/inputs.sha")" ] || { echo "S2A.Dsh 对拍：门禁输入 $IN 被改过（内容指纹对不上 inputs.sha）→ 红"; exit 1; }
fi
for p in "$PKG" "$MAP" "$TAB/shader_facts.tsv" "$TAB/shader_pairs.tsv"; do
  [ -e "$p" ] || { echo "S2A.Dsh 对拍：考卷输入缺 ${p}（动森包记录 / 表）→ 红"; exit 1; }
done
command -v spirv-cross > /dev/null || { echo "S2A.Dsh 对拍：没有命令行 spirv-cross（Homebrew）→ 红"; exit 1; }

# ---- 编：S2A.Dsh + 对拍工具、libdsx.dylib、Metal 校验器 ----
DSH_J=${S2A_CPU_GATE:-6}
EXAM_J=${DSH_EXAM_J:-$DSH_J}
if [ -n "${S2A_CPU_GATE:-}" ] && [ "$EXAM_J" -gt "$DSH_J" ]; then EXAM_J=$DSH_J; fi
"$DN" build "$H/dsh_cmp/dsh_cmp.csproj" -c Release -m:"$DSH_J" -nodeReuse:false -v q > "$T/build.log" 2>&1 || { echo "S2A.Dsh 对拍：dotnet build 失败：$(grep -m1 ' error ' "$T/build.log" | cut -c1-200) → 红"; exit 1; }
export DSH_CMP_DLL=$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll   # ⑧⑩⑪ 经 dshfn.py 调 C# 改写函数：用刚编好的这份，不再各自 dotnet build
make -s -C "$R/graphics/dsx" -j"$DSH_J" "$R/build/dsx/libdsx.dylib" > "$T/make.log" 2>&1 || { echo "S2A.Dsh 对拍：libdsx.dylib 编不过：$(grep -m1 error "$T/make.log" | cut -c1-200) → 红"; exit 1; }
# shellcheck disable=SC1091
S2A_TC_QUIET=1 source "$R/tools/toolchain.sh" || { echo "S2A.Dsh 对拍：Xcode 不能用（见上）→ 红"; exit 1; }   # 按用户机器解析（10-25：toolchain.env 里那行不再是缺省）
xcrun clang -O1 -fobjc-arc -o "$T/dsh_mtlcheck" "$H/dsh_mtlcheck.m" -framework Metal -framework Foundation > "$T/mtl_build.log" 2>&1 || { echo "S2A.Dsh 对拍：Metal 校验器编不过 → 红"; exit 1; }
# ---- 考卷：被测树的离线链在小夹具上整份出库（①②③ 的抽样 + 配对片元、④ 答案表里的键；⑥⑦ 从出成的库里取）----
# exam <键表> <临时目录> <考卷目录> <缓存根> [额外参数…]：配置档副本 <临时目录>/prof/<程序号>，映射表只留键表里的键（原顺序；曲面 hs / ds 行全留），dmsh_chain.py --build-env 给链号 / 摘要，
#   dsh_batch build 整份出库（输出根 <临时目录>/out、发布根 <临时目录>/pub）；Mac 逐键文件导到 <考卷目录>/mac/b-<链号>
DB=(); while IFS= read -r l; do DB+=("$l"); done < <(cd "$R/translator" && python3 -c 'import dsh_batch; print("\n".join(dsh_batch.get()[0]))')
[ ${#DB[@]} -ge 2 ] || { echo "S2A.Dsh 对拍：dsh_batch 编不出来 → 红"; exit 1; }
SPVC=$(cd "$R/translator" && python3 -c 'import spvc_inproc; print(spvc_inproc.lib_path())') && [ -f "$SPVC" ] || { echo "S2A.Dsh 对拍：取不到 libspvc_cli → 红"; exit 1; }
exam() {
  local K=$1 D=$2 M=$3 C=$4; shift 4; mkdir -p "$D/prof/$TID" || return 1
  cp "$TAB"/*.tsv "$D/prof/$TID/" && chmod u+w "$D/prof/$TID"/*.tsv || return 1
  awk -F'\t' 'NR == FNR { k[$1] = 1; next } ($4 in k) || $1 ~ /^(hs|ds)/' "$K" "$TAB/shader_map.tsv" > "$D/prof/$TID/shader_map.tsv" || return 1
  local env; env=$(DM_GAMES_DIR=$D/prof DM_GAMES_FIRST=1 DM_GAME=$TID python3 "$R/translator/dmsh_chain.py" --build-env "$D/rows.tsv") || { echo "$env"; return 1; }
  local ch gm inp; IFS=$'\t' read -r ch gm inp <<< "$env"
  timeout "${TO:-900}" "${DB[@]}" build --pkg "$PKG" --profile "$D/prof/$TID" --game "$gm" --chain "$ch" --inputs "$inp" --profile-rows "$D/rows.tsv" --out "$D/out" --cas "$C" \
    --dsx "$R/build/dsx/libdsx.dylib" --spvc "$SPVC" --bf --export-mac "$M/mac/b-$ch" --lock "$R/translator/dmsh_chain.lock" "$@"
}
awk -F'\t' 'NR == FNR { if ($0 !~ /^#/ && NF > 1) k[$1] = 1; next } ($4 in k) && !s[$4]++ { print $4 }' "$TAB/shader_facts.tsv" "$MAP" > "$T/fk.txt"; nf=$(wc -l < "$T/fk.txt" | tr -d ' ')
if [ -z "${DSH_EXAM:-}" ]; then
  LS=("$DN" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" --pkg "$PKG" --map "$MAP" --tables "$TAB" --out "$T/ls" --print-keys)
  { "${LS[@]}" --keys sample:300 --seed-pairs; "${LS[@]}" --keys sample:40; "${LS[@]}" --keys sample:500 --seed-pairs; cat "$T/fk.txt"; } | LC_ALL=C sort -u > "$T/exk.txt"
  # 考卷按 库版本 V + 翻译指纹 xlate_fp 分目录：10-30 起 V 只随 ABI 变，翻译器改了 V 不变，只按 V 分会拿旧翻译器出的考卷对拍
  read -r CHAIN XFP < <(cd "$R/translator" && python3 -c 'import dmsh_chain; print(dmsh_chain.version(), dmsh_chain.xlate_fp())') && [ -n "${XFP:-}" ] || { echo "S2A.Dsh 对拍：算不出离线链版本 / 翻译指纹 → 红"; exit 1; }
  BFP=$(cat "$R"/graphics/tools/direct/dsh/batch/*.cs "$R/graphics/tools/direct/dsh/batch/dsh_batch.csproj" | shasum | cut -c1-8)   # 出库进程（编排、编批库、发布）不在翻译指纹里：改了它考卷要重出
  EC=${DSH_EXAM_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/gate_dsh}; E=$EC/$(cat "$IN/inputs.sha")-$CHAIN-$XFP$BFP-$(shasum < "$T/exk.txt" | cut -c1-8); REF=$E/mac/b-$CHAIN
  if [ ! -f "$E/done" ]; then
    mkdir -p "$EC"; X=$(mktemp -d "$EC/.mk.XXXXXX")
    exam "$T/exk.txt" "$T/exam" "$X" "$EC/cas" --iosout "$T/exam/pub" --no-ios --publish mac -j "$EXAM_J" > "$X/build.log" 2>&1 \
      || { echo "S2A.Dsh 对拍：离线链出考卷失败（$(tail -1 "$X/build.log" | cut -c1-160)；$X/build.log）→ 红"; exit 1; }
    [ -d "$X/mac/b-$CHAIN" ] && cp "$T/exam/pub/ps_inputs.tsv" "$X/ps_inputs.tsv" || { echo "S2A.Dsh 对拍：离线链没出 b-$CHAIN / ps_inputs.tsv → 红"; exit 1; }   # 考卷只留 Mac 逐键文件与 ps_inputs.tsv
    touch "$X/done"; mv "$X" "$E" 2> /dev/null || rm -rf "$X"; X=   # 同时有两份门禁出同一份：先到的留下
    ls -dt "$EC"/*-*-*/ 2> /dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done   # 只留最近 3 份
  fi
fi
[ -d "$REF" ] || { echo "S2A.Dsh 对拍：考卷缺 ${REF} → 红"; exit 1; }
CMP=("$DN" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" --ref "$REF" --pkg "$PKG" --map "$MAP" --dsx "$R/build/dsx/libdsx.dylib" -j "$DSH_J")
NX=(--backend nxgal --dsx "$R/build/dsx/libdsx.dylib")
line() { grep -m1 '^后端' "$1" | sed 's/；.*//'; }
frac() { grep -m1 '^后端' "$1" | sed -E 's/.*比了 ([0-9]+) 个键，一致 ([0-9]+)，.*/\2\/\1/'; }

if [ "${1:-}" = full ]; then
  [ -n "${DSH_EXAM:-}" ] || { echo "全量对拍要 DSH_EXAM=<直连出库缓存目录>（门禁考卷只出抽样的键）"; exit 1; }
  "${CMP[@]}" --tables "$TAB" --out "$T/full" --keys all --report "$T/full.tsv" > "$T/full.log" 2>&1; rc=$?
  cat "$T/full.log" | grep -v '^  …'; exit $rc
fi

"${CMP[@]}" --tables "$TAB" --out "$T/o1" --keys sample:300 --seed-pairs > "$T/1.log" 2>&1
ck "① 命令行后端 300 键全一致（$(line "$T/1.log")）" 'grep -q "比了 300 个键，一致 300，" "$T/1.log"' "①命令行$(frac "$T/1.log")"
"${CMP[@]}" --tables "$TAB" --out "$T/o2" --keys sample:40 --seed-pairs --capi > "$T/2.log" 2>&1
ck "② 导出入口 40 键全一致（$(line "$T/2.log")）" 'grep -q "比了 40 个键，一致 40，" "$T/2.log"' "②导出入口$(frac "$T/2.log")"
"${CMP[@]}" "${NX[@]}" --tables "$TAB" --out "$T/o3" --keys sample:500 --seed-pairs --abi-only --mtl-list "$T/o3.lst" > "$T/3.log" 2>&1
ck "③ 内置 SPIRV-Cross 500 键 bindings 与入口名全一致（$(line "$T/3.log")）" 'grep -q "比了 500 个键，一致 500，" "$T/3.log"' "③内置SPIRV-Cross$(frac "$T/3.log")"
"$T/dsh_mtlcheck" "$T/o3.lst" "$DSH_J" > "$T/3m.log" 2>&1; m3=$?; nl=$(wc -l < "$T/o3.lst" | tr -d ' ')
ck "③ Metal 建库全过（$(head -1 "$T/3m.log")；清单 $nl 份）" '[ $m3 = 0 ] && grep -q "建库 $nl/$nl" "$T/3m.log"' "Metal$(head -1 "$T/3m.log" | sed 's/.*）：//; s/、/·/')"
# ④ 反证：答案表只留表头，表里的键都该变（notes 多「不在答案表」、threadgroup_size 变 null）
mkdir -p "$T/tab0"; cp "$TAB/shader_pairs.tsv" "$TAB/shader_map.tsv" "$TAB/shader_map.tsv.conflicts.tsv" "$T/tab0/"; grep '^#' "$TAB/shader_facts.tsv" > "$T/tab0/shader_facts.tsv"
"${CMP[@]}" "${NX[@]}" --tables "$T/tab0" --out "$T/o4" --keys "file:$T/fk.txt" > "$T/4.log" 2>&1
ck "④ 反证：答案表清空，表里 $nf 键全判不一致（$(line "$T/4.log")）" '[ "$nf" -gt 0 ] && grep -q "比了 $nf 个键，一致 0，不一致 $nf" "$T/4.log"' "④反证${nf}/${nf}"
"$DN" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" --neg --tables "$TAB" --out "$T/o5" > "$T/5.log" 2>&1; r5=$?
ck "⑤ $(tail -1 "$T/5.log")" '[ $r5 = 0 ]' "⑤失败路径$(tail -1 "$T/5.log" | grep -o '[0-9]*/[0-9]*')"
# ⑤b 没有答案表照样现编（11-13 D-QW2Q：玩家导入不带 shaders/ 的 game.img，缺 shader_facts.tsv 原先每键「no answer table」、整局黑屏）：
#   表目录只给映射表与空配对表（对拍工具自己要读配对表），导出入口 40 键全部编出、不报缺表
mkdir -p "$T/tabx"; cp "$TAB"/shader_map.tsv* "$T/tabx/"; echo '# empty' > "$T/tabx/shader_pairs.tsv"
"$DN" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" --pkg "$PKG" --map "$MAP" --dsx "$R/build/dsx/libdsx.dylib" -j "$DSH_J" --tables "$T/tabx" --out "$T/o5b" --keys sample:40 --capi > "$T/5b.log" 2>&1; r5b=$?
ck "⑤b 缺答案表按空表现编：$(grep -o '比了 [0-9]* 个键[^；]*' "$T/5b.log" | head -1)" '[ $r5b = 0 ] && grep -q "比了 40 个键，一致 40，" "$T/5b.log" && ! grep -q "no answer table" "$T/5b.log"' "⑤b缺表现编$(grep -o '一致 [0-9]*' "$T/5b.log" | head -1 | grep -o '[0-9]*')/40"
python3 "$H/t_dsh_fn.py" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" "$R/build/dsx/libdsx.dylib" > "$T/6.log" 2>&1; r6=$?
grep '✗' "$T/6.log" | head -5
ck "⑥ $(tail -1 "$T/6.log")" '[ $r6 = 0 ]' "⑥逐函数$(tail -1 "$T/6.log" | sed -E 's/.* ([0-9]+) 例，一致 ([0-9]+)，.*/\2\/\1/')"
# ⑦ 设备口径的 vs_pad（10-24 直连线 Mac 验碰到：顶点现编、配对片元在包里只有库）：不预置片元 MSL，只给 ps_inputs.tsv（出包同一脚本从离线库抽）
#   → 离线链补过输出位置的顶点着色器全一致；反证：表也不给 → 这批全不一致
python3 -c "import glob,json,os,sys
ks=[os.path.basename(j)[:-7] for j in sorted(glob.glob(sys.argv[1]+'/*_b.json')) if (lambda d: d.get('stage')=='vs' and d.get('vs_pad'))(json.load(open(j)))]
open(sys.argv[2],'w').write(''.join(k+chr(10) for k in ks[::max(1,len(ks)//40)][:40]))" "$REF" "$T/pk.txt"; np=$(wc -l < "$T/pk.txt" | tr -d ' ')
mkdir -p "$T/tab7"; cp "$TAB"/shader_*.tsv* "$T/tab7/"
cp "$E/ps_inputs.tsv" "$T/tab7/" 2> /dev/null   # 考卷整份出库发布时顺带出的（同一份 Mac 产物算，出包同一段 C# LibPack.PsInputsWrite）；没有它 ⑦ 正例不过 = 红
"${CMP[@]}" --tables "$T/tab7" --out "$T/o7" --keys "file:$T/pk.txt" > "$T/7.log" 2>&1
"${CMP[@]}" --tables "$TAB" --out "$T/o7n" --keys "file:$T/pk.txt" > "$T/7n.log" 2>&1
ck "⑦ 设备口径 vs_pad：只给 ps_inputs.tsv，补过输出的 ${np} 个顶点键全一致（$(line "$T/7.log")）；反证不给表全不一致（$(line "$T/7n.log")）" '[ "$np" -gt 0 ] && grep -q "比了 ${np} 个键，一致 ${np}，" "$T/7.log" && grep -q "比了 ${np} 个键，一致 0，不一致 ${np}" "$T/7n.log"' "⑦vs_pad${np}/${np}"
# ⑧ 宽屏外推尾段（S2A.Dsh VsPush）：插进顶点函数的那段原文在 GPU 上逐例跑，期望按规格手算；反证不带尾段的核外推例对不上（t_push.py）
xcrun clang -O1 -fobjc-arc -o "$T/t_push_run" "$H/t_push_run.m" -framework Metal -framework Foundation > "$T/8b.log" 2>&1 && python3 "$H/t_push.py" "$T/t_push_run" > "$T/8.log" 2>&1; r8=$?
ck "⑧ $(tail -1 "$T/8.log")" '[ $r8 = 0 ]' "⑧外推尾段$(tail -1 "$T/8.log" | grep -o '[0-9]* 项，失败 [0-9]*')"
# ⑩ 宽屏 16:9 采样换算（S2A.Dsh FsUvx）：同一执行器跑 s2a_uv，期望按 uvx_fill 的取值手算；反证不换算的核对不上（t_uvx.py）
python3 "$H/t_uvx.py" "$T/t_push_run" > "$T/10.log" 2>&1; r10=$?
ck "⑩ $(tail -1 "$T/10.log")" '[ $r10 = 0 ]' "⑩采样换算$(tail -1 "$T/10.log" | grep -o '[0-9]* 项，失败 [0-9]*')"
# ⑫ 片元早期深度照实传（控制段 +0x718 位 0 → EarlyZForce → [[early_fragment_tests]]）：期望由脚本自己读考卷包的控制段字节得来，位 1 / 位 0 各 6 支；反证旧实现写死 false 时位 1 全不符（t_early_z.py）
python3 "$H/t_early_z.py" "$H/dsh_cmp/bin/Release/net10.0/dsh_cmp.dll" "$R/build/dsx/libdsx.dylib" "$IN" > "$T/12.log" 2>&1; r12=$?
ck "⑫ $(tail -1 "$T/12.log")" '[ $r12 = 0 ]' "⑫早期深度$(tail -1 "$T/12.log" | grep -o '位 1 [0-9]* 支、位 0 [0-9]* 支')"
# ⑨ 期望 = 新编路径（空缓存）出的 _bf（_bf 缺省不出，这里 --bf）；被测 = 同一批键拿那份缓存再出（缓存命中路径）
python3 -c "import glob,json,os,sys
ks=[os.path.basename(j)[:16] for j in sorted(glob.glob(sys.argv[1]+'/*_b.json')) if (lambda d: d.get('stage')=='ps' and d.get('entry_u'))(json.load(open(j))) and os.path.exists(j[:-7]+'_bf.metallib')]
open(sys.argv[2],'w').write(' '.join(ks[::max(1,len(ks)//4)][:4]))" "$REF" "$T/uk.txt"; nu=$(wc -w < "$T/uk.txt" | tr -d ' ')
tr ' ' '\n' < "$T/uk.txt" > "$T/uk.lst"
for x in x1 x2; do TO=300 exam "$T/uk.lst" "$T/$x" "$T/$x" "$T/x1/cas" -j "${S2A_CPU_GATE:-4}" > "$T/9$x.log" 2>&1; done
b9=$(python3 -c "import filecmp,glob,os,sys
ks=open(sys.argv[1]).read().split(); a=glob.glob(sys.argv[2]+'/mac/b-*'); b=glob.glob(sys.argv[3]+'/mac/b-*')
ok=sum(1 for k in ks if a and b and all(os.path.exists(os.path.join(d[0],k+'_bf.metallib')) for d in (a,b)) and filecmp.cmp(os.path.join(a[0],k+'_bf.metallib'),os.path.join(b[0],k+'_bf.metallib'),shallow=False))
print(ok)" "$T/uk.txt" "$T/x1" "$T/x2")
ck "⑨ 缓存命中路径的可读瓦片变体：带 main0_u 的 ${nu} 个片元键，新编与缓存命中两遍都出 _bf 且逐字节相同 ${b9}/${nu}（$(grep -m1 'shader cache' "$T/9x2.log")）" '[ "$nu" -gt 0 ] && [ "$b9" = "$nu" ] && grep -q "shader cache: hit $nu, rebuilt 0" "$T/9x2.log"' "⑨缓存命中变体${b9}/${nu}"
python3 "$H/t_color_round_fetch.py" "$R/build/dsx/libdsx.dylib" > "$T/11.log" 2>&1; r11=$?
ck "⑪ half 出口与可读附件变体：$(tail -1 "$T/11.log")" '[ $r11 = 0 ]' "⑪half与fetch"
[ $bad = 0 ] || for f in "$T"/[1-8].log; do grep -m3 '例 \|✗' "$f"; done
echo "S2A.Dsh 对拍：${res[*]}｜$([ $bad = 0 ] && echo 全过 || echo 有失败)"; exit $bad
