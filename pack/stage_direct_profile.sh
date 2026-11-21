#!/bin/bash
# Raw preparation: <extracted-root> <profile-root> [--version vN ...].
# Versioned stage: <款> [--require-consumer], uses roots.sh transaction/CAS.
# No build or runtime protocol. --require-consumer validates the build profile only.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
if [ "$#" -ge 2 ] && [ "$2" != --require-consumer ]; then
  ROOT=$1; OUT=$2; shift 2
  exec "$PY" "$H/direct_profile_stage.py" "$ROOT" --out "$OUT" "$@"
fi
G=${1:?款}; shift
if [ "$#" -gt 0 ]; then
  [ "$#" = 1 ] && [ "$1" = --require-consumer ] || { echo "用法：$0 <款> [--require-consumer]" >&2; exit 2; }
fi
source "$H/roots.sh"
source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
CUR=$(root_cur "$G")
[ -n "$CUR" ] && [ -d "$CUR/exefs" ] && { [ -d "$CUR/romfs" ] || [ -f "$CUR/romfs.std" ]; } || { echo "【红】${G} 缺现行 exefs/romfs"; exit 1; }   # RomFS 是目录或镜像 romfs.std 都行（graphics/nvn/tools/romfs_list.py image_of）
# Vulkan 款（graphics/nvn/tools/gfx_api.py 判，出包分流唯一判法）：直连走 Vulkan 层，着色器是 SPIR-V，用不到 NVN 每款配置档（shader_groups 等），不准备、不校验
VPY=${S2A_PYTHON:-${S2A_PY:-$(bash "$H/../tools/machine.sh" get S2A_PY 2> /dev/null)}}; VPY=${VPY:-python3}
API=$("$VPY" "$H/../graphics/nvn/tools/gfx_api.py" "$CUR/exefs") || { echo "【红】${G} 判图形接口失败（graphics/nvn/tools/gfx_api.py）：${API#*	}"; exit 1; }
[ "${API%%	*}" = vulkan ] && { echo "🟢 ${G} 是 Vulkan 款：不用 NVN 直连配置档"; exit 0; }
[ "${API%%	*}" = gl ] && { echo "🟢 ${G} 是 OpenGL 款：直连走 GL 层、着色器是 GLSL 源码，不用 NVN 直连配置档"; exit 0; }
META=$("$PY" "$H/direct_profile_stage.py" "$CUR" --key) || exit $?   # 退 3 = 本款用了直连还没实现的结构（内容缺口），原样交给 refresh 打黄；其余非 0 报红
K=$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1])["key"])' "$META")
SOURCE=$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1])["source"])' "$META")
KB=$K; K=$(stage_deps_key "$CUR" direct_profile "$KB" "$SELF") || exit 1
if [ "$SOURCE" = generated ]; then
  if root_stage_done "$CUR" direct_profile "$K" && [ -f "$CUR/direct_profile.json" ]; then
    echo "🟡 ${G} 临时配置候选 ${K} 已准备（未实跑）"
  else
    TAG=$(root_tag "$G" "dp-${KB}"); W=$(root_begin "$G" "$TAG") || exit 1
    trap 'root_abort "$G" "$TAG"' EXIT
    "$PY" "$H/direct_profile_stage.py" "$W" --out "$W/direct-profile/$KB" > "$W/direct_profile.json" || exit $?
    "$PY" - "$W/direct_profile.json" "$W" <<'PY'
import json,sys
from pathlib import Path
p,root=map(Path,sys.argv[1:])
d=json.loads(p.read_text())
# Relative to the immutable artifact root, never retain the .tmp directory.
d["profile"]=str(Path(d["profile"]).resolve().relative_to(root.resolve()))   # both sides resolved: macOS /var is /private/var
d["DM_GAMES_DIR"]=str(Path(d["profile"]).parent)
p.write_text(json.dumps(d,ensure_ascii=False,sort_keys=True)+"\n")
PY
    "$PY" "$H/direct_profile_stage.py" "$W" --selected > /dev/null || exit $?
    stage_deps_save "$W" direct_profile "$KB" "$SELF" > "$W/.stage_direct_profile" || exit 1   # 目录名与阶段键都用基础键（KB）；清单只管判跳过
    ROOT_REPLAY='direct-profile direct_profile.json .stage_direct_profile .stage_direct_profile.deps' root_commit "$G" "$TAG" || exit 1
    trap - EXIT
    echo "🟡 ${G} 临时配置候选 ${KB} 已进入产物根（未实跑）"
  fi
else
  echo "🟢 ${G} 配置选择：${SOURCE}（未改变配置）"
fi
# The direct line approved direct_lib.py's DM_GAMES_DIR consumer in PR220.
# This checks build input only; runtime loading remains the direct line's work.
CUR=$(root_cur "$G")
"$PY" "$H/direct_profile_stage.py" "$CUR" --selected > /dev/null || exit $?
