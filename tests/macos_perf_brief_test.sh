#!/bin/bash
# Mac 帧率浮层（#2207）单测：macos/perf_brief.m 离屏行为（macos/tests/t_perf_brief.m）+ front_mac.m 菜单接线。
# 门禁只看：macos/perf_brief.h macos/perf_brief.m macos/tests/t_perf_brief.m macos/front_mac.m tests/macos_perf_brief_test.sh
# 门禁覆盖：macos/perf_brief.h macos/perf_brief.m macos/tests/t_perf_brief.m tests/macos_perf_brief_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo "跳过：Mac 专用（环境未就绪）"; exit 75; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
clang -fobjc-arc -O1 -Wall -Werror "$H/macos/tests/t_perf_brief.m" "$H/macos/perf_brief.m" -framework AppKit -o "$T/t" || { echo "🔴 t_perf_brief 编不过"; exit 1; }
"$T/t" ${1:+"$1"} || exit 1
# 菜单接线（front_mac.m）：「显示」菜单两项、⌃⌘P、开局按偏好接着显示
F="$H/macos/front_mac.m"; fails=0
for want in '@"显示帧率"' '@"帧率旁显示内存占用"' 'action:@selector(togglePerfItem:) keyEquivalent:@"p"' '[delegate perfApply];' 'forKey:@"S2APerfHUD"' 'forKey:@"S2APerfHUDMem"'; do
  grep -qF -- "$want" "$F" && echo "✓ front_mac.m 含 $want" || { echo "✗ front_mac.m 缺 $want"; fails=$((fails + 1)); }
done
grep -q 'macos/perf_brief.m' "$H/launchers/macos/build.mk" && echo "✓ launchers/macos/build.mk 编进 perf_brief.m" || { echo "✗ build.mk 没编进 perf_brief.m"; fails=$((fails + 1)); }
[ $fails = 0 ] && echo "✓ macos_perf_brief：全过" || { echo "✗ macos_perf_brief：接线不通 $fails"; exit 1; }
