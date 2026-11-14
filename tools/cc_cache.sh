#!/bin/bash
# C / ObjC / C++ 编译缓存（ccache）开关：source 本文件后调 s2a_ccache_on <仓库根>（tools/gate.sh 开头调，门禁本机那份与 gate-host 那份都走）。
#   为什么（10-30 列车线实测）：门禁里的编译时间多半是同一份源重复编——graphics/metal 的 test-deps、帧率上限 / 上屏驻留单测、iOS 全量编译各自整份重编渲染器
#   （SPIRV-Cross 等，任一源改动就 rm -f *.o 全编；干净复验 git clean 后从零编），按时间戳的 make 增量管不到。按内容缓存后同一份输入只编一次。
#   键 = 预处理前的源与全部头文件内容 + 命令行（含 -isysroot、目标、优化级）+ 真编译器文件；路径按仓库根改成相对、调试信息里的路径映射成「.」（tools/ccshim/shim），
#   所以不同工作树、本机 / gate-host 各自的树能互相命中，而且命中拿到的 .o 与本树自己编的逐字节相同。
#   不缓存的：链接、-E、-fsyntax-only、读标准输入（tools/ccshim/shim 原样交给系统 xcrun）。没装 ccache（brew install ccache）或 S2A_CCACHE=0 → 什么都不变
#   缓存目录 ${S2A_RUN_ROOT}/s2arm/cache/ccache（与 nxaot 同级，gate-host 上在远端家目录下），上限 S2A_CCACHE_MAX（缺省 15G），满了 ccache 自己按最久没用的淘汰
#   命中统计：每次编译一行写进 S2A_CCACHE_LOG（缺省不写）；s2a_ccache_sum <日志> 汇总成「命中 a / 共 b」
s2a_ccache_on() {
  local root=$1 b
  [ "${S2A_CCACHE:-1}" = 0 ] && return 0
  [ "$(uname -s)" = Darwin ] || return 0   # 入口按 xcrun 解真编译器，只在 macOS 成立；Linux / WSL 的门禁不经这层
  b=$(command -v ccache 2> /dev/null || true); [ -n "$b" ] || { [ -x /opt/homebrew/bin/ccache ] && b=/opt/homebrew/bin/ccache; }
  [ -n "$b" ] && [ -x "$root/tools/ccshim/shim" ] || return 0
  export S2A_CCACHE_BIN=$b CCACHE_DIR=${S2A_CCACHE_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/ccache} CCACHE_BASEDIR=$root \
    CCACHE_MAXSIZE=${S2A_CCACHE_MAX:-15G}
  [ -n "${S2A_CCACHE_LOG:-}" ] && export CCACHE_STATSLOG=$S2A_CCACHE_LOG
  # 入口名（cc / c++ / clang / clang++ / xcrun）现建在被忽略的 build/ 下，指向 tools/ccshim/shim（10-30 出包线：仓库里提交软链，
  #   启动器打引擎时 bundle_engine 拒收软链，build_app 打不出 App）
  local d=$root/build/ccshim n; mkdir -p "$d" || return 0
  # 已指对就不重建、要改也先建临时链接再 mv -fh 原子覆盖（11-14：同一棵树门禁并行几步都 source 本文件，ln -sfn 先删后建，
  #   那一瞬别的步正经 build/ccshim/clang 编译会「command not found」；同类坑见 remote.sh 共享链接）
  for n in cc c++ clang clang++ xcrun; do
    [ "$(readlink "$d/$n" 2> /dev/null)" = "$root/tools/ccshim/shim" ] && continue
    ln -sfn "$root/tools/ccshim/shim" "$d/.$n.tmp.$$" && { mv -fh "$d/.$n.tmp.$$" "$d/$n" 2> /dev/null || mv -fT "$d/.$n.tmp.$$" "$d/$n"; }; done   # -h：macOS / BSD；-T：GNU
  case ":$PATH:" in *":$d:"*) ;; *) export PATH="$d:$PATH" ;; esac
}
# s2a_ccache_sum <stats_log>…：「命中 a / 共 b」（只数真正进了缓存判断的编译；链接等直通的不算）
s2a_ccache_sum() {
  cat "$@" 2> /dev/null | awk '/^(direct|preprocessed)_cache_hit$/{h++} /^cache_miss$/{m++} END{printf "命中 %d / 共 %d\n", h, h + m}'
}
