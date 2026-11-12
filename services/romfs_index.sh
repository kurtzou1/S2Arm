#!/bin/bash
# 出包时生成 RomFS 预建索引：bash services/romfs_index.sh <游戏数据根>（含 romfs/），写 <根>/romfs.s2aidx。
# 起局（Application.Register）见到它就不再枚举 romfs/ 现建镜像（01006F8002326000 Mac 暖 450 ms → 见单测读数）。romfs/ 内容一变就要重出。
# 构建失败 = 红，不许拿上一次留下的旧 romfs_index.dll 顶上（T141 #937：旧写法 `dotnet build … | grep … | sort -u || true` 把失败吞成 rc=0，
#   接着 exec 旧 DLL 写旧逻辑的索引；上层 stage_romfsidx.sh 只看退出码与产物非空，看不出「没换成新的」）。
# 区分两件事：增量构建「没有变化」= build rc=0（照常跑已有 DLL）；「构建失败」= rc≠0（非 0 退出、不跑任何 DLL）。
set -euo pipefail
# 超时（#591）：把仓库 tools/bin 放到 PATH 最前（perl 版 timeout，同 tools/toolchain.sh）。PATH 上是外部文件，下面的 exec timeout 照用。
_s2a_d=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || _s2a_d=; while [ -n "$_s2a_d" ] && [ ! -f "$_s2a_d/tools/_timeout.sh" ] && [ "$_s2a_d" != / ]; do _s2a_d=${_s2a_d%/*}; done; { [ -n "$_s2a_d" ] && [ -f "$_s2a_d/tools/_timeout.sh" ] && . "$_s2a_d/tools/_timeout.sh"; } || :
# 物理路径（pwd -P）：工作树在符号链接下（macOS /tmp → /private/tmp）时，MSBuild 内部解析成实体路径，
# 与逻辑 /tmp 入口混用会让 ProjectReference 拿不到 ref 输出（CS0006 连环缺 dll）。
HERE=$(cd "$(dirname "$0")" && pwd -P)
DN=${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}
# 可选 --list <RomFS 清单>：出包期由 graphics/nvn/tools/romfs_list.py sizes 写的「字节数\t相对路径」，索引器不再自己枚举目录、逐个打开取长度
[ $# -eq 1 ] || { [ $# -eq 3 ] && [ "$2" = --list ]; } || { [ $# -ge 5 ] && [ $# -le 6 ] && [ "$1" = --std ]; } \
  || { echo "用法：romfs_index.sh <游戏数据根> [--list <RomFS 清单>] | --std <RomFS 目录> <清单或 -> <输出文件> <偏移> [--consume]（IMG v1 的 RomFS 段，pack/img.py）" >&2; exit 2; }
if [ -n "${S2A_PREBUILT_TOOLS:-}" ]; then
  exec timeout 600 "$DN" "$S2A_PREBUILT_TOOLS/romfs/romfs_index.dll" "$@"
fi
DLL="$HERE/romfs_index/bin/Release/net10.0/romfs_index.dll"
BUILD_ARGS=(-c Release -nologo -v q)
if [ "$(uname -s)" = Linux ]; then
  BUILD_ARGS+=(-m:1)
  if [ -n "${S2A_ROMFS_ARTIFACTS:-}" ]; then
    BUILD_ARGS+=(--artifacts-path "$S2A_ROMFS_ARTIFACTS")
    DLL="$S2A_ROMFS_ARTIFACTS/bin/romfs_index/release/romfs_index.dll"
  fi
fi
LOG=${TMPDIR:-/tmp}/romfs_index_build.$$.log   # 不用 mktemp -t：macOS 与 GNU 的 -t 语义不同
trap 'rm -f "$LOG"' EXIT
ERRPAT=" error |rror\(s\)"   # 与旧写法同一个挑错规则，只改「失败怎么报」不改造哪些行
RC=0
timeout 300 "$DN" build "$HERE/romfs_index" "${BUILD_ARGS[@]}" > "$LOG" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "【红】services/romfs_index.sh：构建失败（退出 ${RC}），没有更新 romfs_index.dll——不运行旧 DLL" >&2
  if grep -qE "$ERRPAT" "$LOG"; then grep -E "$ERRPAT" "$LOG" | sort -u >&2; else tail -n 5 "$LOG" >&2; fi
  exit "$RC"
fi
if [ ! -s "$DLL" ]; then
  echo "【红】services/romfs_index.sh：构建报告成功但没有产物 ${DLL}——不能拿旧 DLL 顶上（没换成新的）" >&2
  exit 1
fi
rm -f "$LOG"; trap - EXIT
exec timeout 600 "$DN" "$DLL" "$@"
