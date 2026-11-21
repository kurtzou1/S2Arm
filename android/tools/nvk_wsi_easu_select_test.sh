#!/bin/sh
# 独立宿主回归：只编译选择/合成函数，不链接驱动，不执行旧套件。
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SOURCE=${1:-"$ROOT"}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/nvk-wsi-select.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
python3 "$HERE/nvk_wsi_easu_select_extract.py" "$SOURCE" "$BUILD"
CC=${CC:-cc}
for mode in candidate omit_preflight; do
 "$CC" -std=c11 -Wall -Wextra -Werror \
  -I"$BUILD/$mode" -I"$SOURCE/graphics/nvn/third_party/vulkan-headers/include" \
  "$ROOT/android/tests/nvn_wsi_easu_select_test.c" -o "$BUILD/$mode/test"
 set +e
 "$BUILD/$mode/test" > "$BUILD/$mode/log" 2>&1
 code=$?
 set -e
 cat "$BUILD/$mode/log"
 echo "$mode EXIT=$code"
 if [ "$mode" = candidate ]; then
  [ "$code" -eq 0 ] || exit 1
 else
  [ "$code" -eq 1 ] || exit 1
  grep -q 'FAIL same:.*logs==' "$BUILD/$mode/log" || exit 1
 fi
done
