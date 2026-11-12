#!/bin/bash
# 出包·抽取阶段（10-25 维护者「抽着色器只做一次」）：pack/stage_extract.sh <款>
# 把 Switch 着色器从游戏文件里抽出来，放新版本产物根 extract/（graphics/tools/direct/extract.sh：Unreal 存档 ue_pak + 直连抽取 shader_split + S2Arm nxsh_extract，含追加内容）。
#   直连库阶段（direct_lib.sh ①②）只读它，不再每次出库从头抽两遍（动森 J=4 时 127 + 44 秒；直连库键含整棵 graphics/nvn，翻译链 / 出库工具一改就整段重出，游戏没变也照抽）。
# 缓存键 = 游戏输入（romfs / aoc 路径+长度+首尾64KiB抽样、exefs/main 全内容）+ 抽取代码（pack/stage_inputs/extract.tsv「入」的文件：两个抽取器与依赖闭包，新依赖由 tests/stage_keys_test.sh 扫出、要在表里归类）
#   + Python 与解包库版本 + 所选配置档的内容键（shader_split 读配置档的 shader_groups / shader_note / modules 与 shader_facts_manual.tsv）；与现行 .stage_extract 相同就跳过。
# 排在会改 romfs / main 的阶段（改写、宽屏界面布局）之后、直连库阶段之前（pack/refresh.sh 双轨段）。Vulkan / OpenGL 款没有 NVN 着色器可抽，直接过。
# 并行：J = 调用方给的 J / S2A_CPU_BAKE（tools/cores.sh）/ 本机核数，两个抽取器都按 J 开进程池。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（声明表管调用到的代码，实际读入管真读了哪些文件和表）
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -d "$CUR/romfs" ] && [ -f "$CUR/exefs/main" ] || { echo "【红】$G 现行产物根没有 romfs/ 或 exefs/main"; exit 1; }
bash "$H/stage_direct_profile.sh" "$G" --require-consumer || exit $?   # 配置档同直连库阶段（零配置推导 / 手写档），抽取按同一份档
CUR=$(root_cur "$G")
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
VPY=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; VPY=${VPY:-python3}
KR=
# 只复用本轮已验证的不可变根版本；未知根、工具版本变化或损坏memo一律回到同一helper核算。
if [ -n "${S2A_RESOURCE_KEY_ONCE_FILE:-}" ] && [ -f "$S2A_RESOURCE_KEY_ONCE_FILE" ]; then
  read -r RK_V RK_ROOT RK_KEY RK_SUM RK_HELPER RK_EXTRA < "$S2A_RESOURCE_KEY_ONCE_FILE" || :
  RK_ID=$(stat -c '%d:%i' "$CUR" 2>/dev/null || stat -f '%d:%i' "$CUR" 2>/dev/null) || RK_ID=
  RK_MEMO="$(dirname "$CUR")/.resource-input-cache/${RK_ID/:/-}.json"
  if [ "${RK_V:-}" = s2a-resource-once-v2 ] && [ "${RK_ROOT:-}" = "$RK_ID" ] && [ -z "${RK_EXTRA:-}" ] && [ -f "$RK_MEMO" ]; then
    case ${RK_KEY:-} in ''|*[!0-9a-f]*) ;; *)
      [ ${#RK_KEY} = 16 ] && [ "$(shasum -a 256 < "$RK_MEMO" | cut -d' ' -f1)" = "${RK_SUM:-}" ] && [ "$(shasum -a 256 < "$H/resource_input_key.py" | cut -d' ' -f1)" = "${RK_HELPER:-}" ] && KR=$RK_KEY;;
    esac
  fi
fi
[ -n "$KR" ] || KR=$("$PY" "$H/resource_input_key.py" "$CUR") || { echo "【红】$G 算游戏输入键失败"; exit 1; }
API=$("$VPY" "$R/graphics/nvn/tools/gfx_api.py" "$CUR/exefs") || { echo "【红】$G 判图形接口失败（graphics/nvn/tools/gfx_api.py）：${API#*	}"; exit 1; }
case ${API%%	*} in vulkan|gl) echo "🟢 $G ${API%%	*} 款没有 NVN 着色器可抽，跳过"; exit 0;; esac
PROFILE=$("$PY" "$H/direct_profile_stage.py" "$CUR" --selected) || exit 1
PDIR=$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1])["profile"])' "$PROFILE")
PK=$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1])["profile_key"])' "$PROFILE")
source "$H/srcs.sh"; TID=$(prog_id "$CUR"); [ -n "$TID" ] || { echo "【红】$G 取不到程序号"; exit 1; }
# 抽取代码键（10-26 维护者收窄）：只算 pack/stage_inputs/extract.tsv「入」的文件（两个抽取器与它们的依赖闭包）；原先手列 KF 含整棵 graphics/tools/shbake（C# 烘焙器也进键）
source "$H/stage_keyfiles.sh"; KT=$(stage_files_key extract "$R") || exit 1
KV=$("$VPY" -c 'import sys, lz4, numpy; print(sys.version.split()[0], lz4.__version__, numpy.__version__)' 2>&1)
# 图形接口只按判出的类别进键（gfx_api.py 本身在 extract.tsv 归「外」）：类别变了才重抽
# 试跑开关 S2A_DIRECT_RUNTIME_ONLY=1（普查第②层：不抽不预编，全部着色器运行时首遇现编，9.9 万支的款几分钟起局）：开了才进键，不开时键与原先逐字节相同
RTO=; [ "${S2A_DIRECT_RUNTIME_ONLY:-0}" = 1 ] && RTO='
runtime-only'
K=$(printf '%s\n%s\n%s\n%s\n%s%s\n' "$KR" "$KT" "$KV" "$PK" "${API%%	*}" "$RTO" | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" extract "$KB" "$SELF") || exit 1
root_stage_done "$CUR" extract "$K" && { echo "🟢 $G 现行已是抽取 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "ex-${K:0:8}"); W=$(root_begin "$G" "$TAG") || { root_abort "$G" "$TAG"; exit 1; }
t0=$SECONDS
J=${J:-${S2A_CPU_BAKE:-${S2A_JOBS:-$(getconf _NPROCESSORS_ONLN)}}}; [ "$J" -ge 1 ] 2> /dev/null || { echo "【红】$G 并行度读不出（J / S2A_JOBS / getconf 核数）"; root_abort "$G" "$TAG"; exit 1; }; export J
# 宿主工具模式要的 Mac 宿主（10-28 维护者：RomFS 有 .pak / .pkz 且抽取器要用 Oodle 解码器时；10-29 运行时 GLSLC 款要游戏自带的 glslcCompile 离线编，glslc_offline.py --need 判），
#   增量编一遍；只有 Oodle 时不带 C# 省约 60 秒（宿主工具模式跳过 S2A_Init），GLSLC 要带
GN=$("$VPY" "$R/translator/glslc_offline.py" --need "$W" 2> /dev/null)
# RomFS 里有没有 Unreal 包：经 graphics/nvn/tools/romfs_list.py（仓库里唯一的 RomFS 遍历；同 find -iname … -print -quit）
source "$H/decoder_need.sh"   # 要不要游戏自带解码器（RomFS 容器判据，只此一处）
if decoder_need "$R" "$W/romfs" || [ "$GN" = yes ]; then
  # 发版 App 自带已编好的宿主（pack/jobs/core.py 设 S2A_BUNDLED_HOST）：不再现编（issue #8 根因：Runtime-only dotnet 编不出）
  if [ -n "${S2A_BUNDLED_HOST:-}" ] && [ -f "$S2A_BUNDLED_HOST" ]; then
    echo "[s2a] 使用发版 App 内置 Mac 宿主：$S2A_BUNDLED_HOST"
  else
    # GLSLC 工具模式与 LZ5 解码器（勇者斗恶龙 XI S）要 C# 服务层（SDK 初始化连系统服务，runtime/src/host_main.c）；只有 OodleLZ 时不带 C#
    #   （11-01：原先只按 GLSLC 判，勇者斗恶龙 XI S 普查里 LZ5 起不来；translator/oodle_needs_sdk.py 按 main 符号表判，同宿主）
    HCS=1
    if [ "$GN" != yes ]; then
      LZ=$("$VPY" "$R/translator/oodle_needs_sdk.py" "$W/exefs") || { echo "【红】$G 判解码器要不要 C# 失败（oodle_needs_sdk.py 读不了 $W/exefs/main）"; root_abort "$G" "$TAG"; exit 1; }
      [ "$LZ" = yes ] || HCS=0
    fi
    # 引擎 / 整机缓存在带空格的目录（启动器：~/Library/Application Support）时 make 按空格拆路径（11-01 勇者斗恶龙 XI S：子 make graphics/metal 的 ROOT 带空格，
    #   No rule to make target `Support/S2Arm/engines/…/tools/toolchain.env'）：-C、ROOT 与 C# / vpx / opus 缓存一律换无空格别名（同 pack/ipa.sh）
    ( source "$R/tools/nospace.sh"; RN=$(s2a_nospace "$R") || { echo "建不了引擎目录的无空格别名（${R}）"; exit 1; }
      for v in S2A_CS_CACHE S2A_VPX_CACHE S2A_OPUS_CACHE; do [ -n "${!v:-}" ] || continue; mkdir -p "${!v}" && a=$(s2a_nospace "${!v}") && export "$v=$a" || { echo "建不了 $v 的无空格别名"; exit 1; }; done
      S2A_CS=$HCS bash "$R/tools/host_build.sh" --tree "$RN" ROOT="$RN" ) > "$W/host_build.log" 2>&1 || { echo "【红】$G 编译 Mac 宿主失败（$(tail -2 "$W/host_build.log" | tr '\n' ' ' | cut -c1-200)）"; root_abort "$G" "$TAG"; exit 1; }
  fi
fi
if [ -n "$RTO" ]; then   # 试跑：不调抽取器，按抽取缺口走（extract.sh 退 3 同一条路：下面写 direct_gap.txt，直连库阶段出运行时现编空库）
  echo "直连库失败：试跑 S2A_DIRECT_RUNTIME_ONLY=1，不抽不预编，运行时首遇现编" > "$W/extract.log"; xrc=3
else
DM_GAMES_DIR="$(dirname "$PDIR")${DM_GAMES_DIR:+:$DM_GAMES_DIR}" DM_GAMES_FIRST=1 DM_GAME=$TID bash "$R/graphics/tools/direct/extract.sh" "$W" "$W/extract" > "$W/extract.log" 2>&1; xrc=$?
fi
# 退 3 = 只有直连用的那两份抽不出（extract.sh 头注释：Unreal 存档读不开、认不出着色器容器、运行时现编的 GLSL 没抓到输出、拆分出错……）：
#   11-05 维护者定「直连库编不出也照出包、运行时由宿主现翻兜底」——不再作废本阶段，把原因写进 extract/direct_gap.txt 照常提交、退 0，
#   直连库阶段（stage_direct.sh）见到它出一个合法的空库（离线 0 支），运行时每支着色器在 ProgramSetShaders 首遇现编（nvn_mtl.m s2a_dsh_compile）。
#   原先这里退 3、refresh 报「直连单轨停在 抽取阶段」整款出不了包（c1104_r2 直连缺口 11 款）。其余非 0 照旧是出包内部出错
if [ $xrc = 3 ]; then
  gap=$(grep -a '直连库失败：' "$W/extract.log" 2> /dev/null | tail -1 | sed 's/^.*\(直连库失败：\)/\1/' | cut -c1-260)
  mkdir -p "$S2A_ROOTS/.failed" && cp "$W/extract.log" "$S2A_ROOTS/.failed/${G}_extract.log"
  mkdir -p "$W/extract" && printf '%s\n' "${gap:-直连库失败：extract.sh 退 3 没写原因}" > "$W/extract/direct_gap.txt" || { root_abort "$G" "$TAG"; exit 1; }
  echo "【黄】$G 抽取缺口：${gap:-extract.sh 退 3}；本款离线直连库为空，运行时首遇现编（照常出包）"; xrc=0
fi
# 失败时连同各步日志（extract/ 下的 s2x.log 等）一起留进 .failed/<款>_extract.d/（10-30 巫师3 / Bloodstained：只留了总日志，s2x.log 随临时根删掉，看不到哪几条解不开）
if [ $xrc != 0 ]; then mkdir -p "$S2A_ROOTS/.failed" && cp "$W/extract.log" "$S2A_ROOTS/.failed/${G}_extract.log"
  rm -rf "$S2A_ROOTS/.failed/${G}_extract.d"
  if [ -d "$W/extract" ] && ! rsync -a --prune-empty-dirs --include='*/' --include='*.log' --exclude='*' "$W/extract/" "$S2A_ROOTS/.failed/${G}_extract.d/" 2> /dev/null; then echo "【黄】$G 抽取各步日志没留全（$S2A_ROOTS/.failed/${G}_extract.d）"; fi
  root_abort "$G" "$TAG"
  [ $xrc = 3 ] && { echo "【红】$G $(grep -a '直连库失败：' "$S2A_ROOTS/.failed/${G}_extract.log" 2> /dev/null | tail -1 | sed 's/^.*\(直连库失败：\)/\1/' | cut -c1-260)"; exit 3; }
  echo "【红】$G 抽取失败（$(grep '抽取\]' "$S2A_ROOTS/.failed/${G}_extract.log" | tail -1 | sed "s#$W/extract/#$S2A_ROOTS/.failed/${G}_extract.d/#g" | cut -c1-240)）"; exit 1; fi   # 路径换成留下来的那份（临时根随 root_abort 删了，10-30 塞尔达照红行找日志以为丢了）
# 降级汇总（v0.3.1）：离线 0 支（direct_gap.txt）、S2Arm 抽取没跑成 / 跳过读不了的部分（extract/s2x/degrade.tsv）→ 产物根 degrade.extract.tsv
#   （格式同 degrade.rewrite.tsv：阶段 / 类别 / 处数 / 玩家提示 / 说明；出包作业收尾读它上屏、诊断包收它）；没有降级就删掉旧表
{ rows=$(cat "$W/extract/s2x/degrade.tsv" "$W/extract/split/degrade.tsv" 2> /dev/null)
  [ -s "$W/extract/direct_gap.txt" ] && rows="${rows:+$rows
}extract	offline_zero	1	这款的着色器没能提前编好，第一次进新场景会卡一下，遇到请反馈	$(head -1 "$W/extract/direct_gap.txt")"
  if [ -n "$rows" ]; then n=$(printf '%s\n' "$rows" | grep -c .)
    [ -s "$W/extract/direct_gap.txt" ] || rows="extract	partial	${n}	这款有部分着色器没能提前编好，第一次进新场景可能会卡一下，遇到请反馈	逐类见下
$rows"
    printf '# 阶段\t类别\t处数\t玩家提示\t说明\n%s\n' "$rows" > "$W/degrade.extract.tsv" || { root_abort "$G" "$TAG"; exit 1; }
  else rm -f "$W/degrade.extract.tsv"; fi; }
K=$(stage_deps_save "$W" extract "$KB" "$SELF") || { root_abort "$G" "$TAG"; exit 1; }; echo "$K" > "$W/.stage_extract"
# 与改写 / 能力表 / RomFS 索引并行（refresh.sh 快路，11-06）：本阶段只写这些，提交时现行被别的阶段改过就重放到新现行
ROOT_REPLAY='extract extract.log host_build.log degrade.extract.tsv .stage_extract .stage_extract.deps' root_commit "$G" "$TAG" || exit 1
echo "$(grep '抽取\]' "$(root_cur "$G")/extract.log" | tail -1 | sed 's/^\[抽取\] //')；$(du -sh "$(root_cur "$G")/extract" | cut -f1)，阶段 $((SECONDS - t0)) 秒，现行 → $(basename "$(root_cur "$G")")"
