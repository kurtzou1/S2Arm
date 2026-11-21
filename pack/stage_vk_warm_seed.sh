#!/bin/bash
# 出包·安卓首局预热种子阶段：pack/stage_vk_warm_seed.sh <款>（只在 S2A_PACK_PLAT=android 的刷新里跑，pack/refresh.sh）
# 出 shaders/direct/warm-vk/<闭包摘要>-<profile 摘要>/{programs-v1-<闭包>.bin, pipes-v1-352.bin}：安卓真机跑局落下的预热清单，
#   宿主首局（本机还没有清单）读它在后台预建程序与管线（android/native/nvn/nvn_vk_{prog,pipe}_warm.h「随包种子」）。
#   来源 = <运行根>/s2arm/vk_warm/<程序号>/（或 S2A_VK_WARM_SOURCES），由 android/tools/vk_warm_seed.py 校验、配对、按程序身份滤管线后写出。
# 苹果的种子表（pack/stage_direct_seed.sh，跑局知识 seen.tsv）换不出安卓清单：安卓的程序身份含设备 profile 与现场事实，见 vk_warm_seed.py 头注释。
# 键 = 本脚本 + vk_warm_seed.py 的内容 + 产出目录逐文件内容（产出只由来源内容定）；与现行 .stage_vk_warm_seed 相同就跳过。
# 种子是锦上添花：工具失败只打一行【黄】、现行不动、退 0；没有来源时产出为空，现行里的 warm-vk 随之删掉（包里不带种子）。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$H/$(basename "$0")   # 实际读入进键（各阶段同一套，pack/stage_keyfiles.sh；tests/stage_deps_test.py ⑤）
T=$(mktemp -d "${TMPDIR:-/tmp}/s2a_vkwarm.XXXXXX") || { echo "【红】$G 建不了首局预热种子的临时目录"; exit 1; }
trap 'rm -rf "$T"' EXIT
"$PY" "$R/android/tools/vk_warm_seed.py" "$T/out" "$CUR" > "$T/log" 2>&1 \
  || { echo "【黄】$G 安卓首局预热种子这次没收（android/tools/vk_warm_seed.py：$(tail -1 "$T/log" | cut -c1-200)）；包照常出，现行不动，下次刷新重试"; exit 0; }
K=$( { shasum -a 256 < "$H/stage_vk_warm_seed.sh"; shasum -a 256 < "$R/android/tools/vk_warm_seed.py"
       (cd "$T/out" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; shasum -a 256 < "$f"; done); } | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" vk_warm_seed "$KB" "$SELF" "$R/android/tools/vk_warm_seed.py") || exit 1
root_stage_done "$CUR" vk_warm_seed "$K" && { echo "🟢 $G 现行已是安卓首局预热种子 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "vw-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
rm -rf "$W/shaders/direct/warm-vk"
if [ -n "$(ls -A "$T/out" 2> /dev/null)" ]; then
  mkdir -p "$W/shaders/direct" && cp -R "$T/out" "$W/shaders/direct/warm-vk" || { echo "【红】$G 首局预热种子拷不进工作根"; root_abort "$G" "$TAG"; exit 1; }
fi
K=$(stage_deps_save "$W" vk_warm_seed "$KB" "$SELF" "$R/android/tools/vk_warm_seed.py") || { root_abort "$G" "$TAG"; exit 1; }
echo "$K" > "$W/.stage_vk_warm_seed" || { root_abort "$G" "$TAG"; exit 1; }
ROOT_REPLAY='shaders/direct/warm-vk .stage_vk_warm_seed .stage_vk_warm_seed.deps' root_commit "$G" "$TAG" || exit 1
echo "🟢 $G $(tail -1 "$T/log")（现行 → $(basename "$(root_cur "$G")")）"
