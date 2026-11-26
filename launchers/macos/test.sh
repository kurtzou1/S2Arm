#!/bin/bash
# Mac-only frontend checks; no game files, device access or network installation.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R"
source "$R/tools/toolchain.sh"   # 门禁用统一工具链（tools/toolchain.env）；S2A_DEVELOPER_DIR 可覆盖
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$R/build/macos/swift-cache"
mkdir -p build/macos/tests
# 两套 Python 单测与下面的 Swift 编译 / XCTest 互不依赖（不读 build/macos）：放后台同时跑，输出进日志，末尾按原顺序打印、任一不通整步不通
trap 'kill $(jobs -p) 2> /dev/null || :' EXIT   # 中途失败退出时不留后台单测
# 测试进程卡住有上限（11-26：门禁这一步挂了 879 秒，输出都在下面的日志文件里、门禁日志里没有一行用例名或现场，只能等无进展看门狗 300 秒来停）：
#   日志 S2A_UI_STALL_S 秒（缺省 180，短于看门狗）没长 = 卡住 → 打现场（日志尾、最后开始的用例、各测试进程 sample 栈）→ 杀整组 → 退 124 判红。
#   按「日志没长、进程树也没吃 CPU」判，不按总时长：负载高时测试慢但一直在出用例行、编译不出行也在吃 CPU，都不会误杀。
#   11-26 03:26 又挂一次（6bed06c6736b4078）：卡在没包进来的「swift test … list」（编完 Build complete 之后列用例时不动），所以列用例、两套 Python 单测也都经它跑
tree_cpu() {   # tree_cpu <pid>：这个进程连同全部子孙累计 CPU 秒数（ps time 列 [[dd-]hh:]mm:ss.cc）
  ps -A -o pid=,ppid=,time= | awk -v root="$1" '{ p[$1] = $2; t = $3; d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] } n = split(t, b, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + b[i]; c[$1] = s + d * 86400 }
    END { tot = 0; for (k in c) { x = k; while (x != "" && x != 0 && x != root && (x in p)) x = p[x]; if (x == root) tot += c[k] } printf "%d", tot }'
}
capped() {   # capped <日志> <命令…>：前台跑，输出进日志
  local log=$1; shift; "$@" > "$log" 2>&1 & local pid=$! last=-1 lastc=-1 same=0 n cpu
  while kill -0 "$pid" 2> /dev/null; do
    sleep 5; n=$(wc -c < "$log" 2> /dev/null || echo 0); cpu=$(tree_cpu "$pid")
    if [ "$n" = "$last" ] && [ "$cpu" = "$lastc" ]; then same=$((same + 5)); else same=0; last=$n; lastc=$cpu; fi
    if [ "$same" -ge "${S2A_UI_STALL_S:-180}" ]; then
      echo "【红】测试卡住：$log ${same} 秒没新输出、进程树没吃 CPU（${*}）"
      echo "  最后开始的用例：$(grep -a "Test Case '.*' started" "$log" | tail -1)"; echo "  日志尾："; tail -15 "$log" | sed 's/^/    | /'
      local kids; kids=$(pgrep -P "$pid"; for k in $(pgrep -P "$pid"); do pgrep -P "$k"; done)
      for k in $pid $kids; do echo "  进程 ${k}：$(ps -o command= -p "$k" 2> /dev/null | cut -c1-160)"; sample "$k" 2 -file "$log.sample.$k" > /dev/null 2>&1 && grep -a -m12 -E "^ +[0-9]+ " "$log.sample.$k" | sed 's/^/    /'; done
      kill -TERM $kids "$pid" 2> /dev/null; sleep 2; kill -KILL $kids "$pid" 2> /dev/null; wait "$pid" 2> /dev/null; return 124
    fi
  done
  wait "$pid"
}
capped build/macos/tests/py-tests.log python3 -B -m unittest discover -s launchers/macos/Tests -p 'test_*.py' -v & py_tests=$!
capped build/macos/tests/py-gui-jobs.log python3 -B -m unittest discover -s launchers/macos/gui_jobs/tests -v & py_gui=$!
python3 launchers/macos/sparkle_vendor.py > /dev/null   # Sparkle 二进制包不随仓库，按校验值备到 frontend/Vendor/
swift_args=(--disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos --scratch-path build/macos/spm)
capped build/macos/tests/swift-discovery.raw swift test "${swift_args[@]}" list || exit $?
grep -aE '^[A-Za-z0-9_]+\.[^/[:space:]]+/[^[:space:]]+$' build/macos/tests/swift-discovery.raw > build/macos/tests/swift-discovery.log || :   # 列表行（capped 把编译输出也收进同一份日志，按原先的列用例行格式挑出来）
# 三个 XCTest 模块（S2ArmLauncherTests / S2ArmAppleTests / S2ArmAppleAdapterTests）各起一个进程同时跑（11-14 门禁提速：原先一个 swift test 串着跑，
#   约 29 + 25 + 0.6 秒，整步取决于最慢那个模块）。按模块切、不在模块内再切：S2ArmAppleTests 里有用例改写 xctest 进程共用的
#   UserDefaults「appLanguage」（跨进程可见），同一模块的用例仍在同一进程里按原顺序跑，与原先完全一样。
#   上面 list 已编好，这里 --skip-build；SwiftPM 默认对 scratch 目录加锁、三个进程会互等，只读跑测试用 --ignore-lock。
#   各模块输出按模块顺序拼成同一份 swift-execution.log，check_xctest.py 照旧核「发现的每个用例恰好跑完一次」——漏切、多切都会红
swift_rc=0; mods=(); while IFS= read -r m; do mods+=("$m"); done < <(sed -nE 's#^([A-Za-z0-9_]+)\.[^/[:space:]]+/[^[:space:]]+$#\1#p' build/macos/tests/swift-discovery.log | LC_ALL=C sort -u)
pids=(); for m in "${mods[@]}"; do
  capped "build/macos/tests/swift-execution.$m.log" swift test "${swift_args[@]}" --skip-build --ignore-lock --filter "^${m}\\." & pids+=($!); done
for i in "${!pids[@]}"; do wait "${pids[$i]}" || swift_rc=$?; done
for m in "${mods[@]}"; do cat "build/macos/tests/swift-execution.$m.log"; done > build/macos/tests/swift-execution.log
py_rc=0; wait "$py_tests" || py_rc=$?; cat build/macos/tests/py-tests.log
wait "$py_gui" || py_rc=$?; cat build/macos/tests/py-gui-jobs.log
[ "$py_rc" = 0 ] || exit "$py_rc"
cat build/macos/tests/swift-execution.log
python3 launchers/macos/check_xctest.py build/macos/tests/swift-discovery.log build/macos/tests/swift-execution.log
[ "$swift_rc" = 0 ] || exit "$swift_rc"
# SwiftPM does not run a dependency package's tests with the parent package.
# Keep frontend layout, controller and language regressions in the standard Mac test entry point.
frontend_args=(--disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos/frontend --scratch-path build/macos/frontend-ui)
capped build/macos/tests/frontend-discovery.raw swift test "${frontend_args[@]}" list || exit $?
grep -aE '^[A-Za-z0-9_]+\.[^/[:space:]]+/[^[:space:]]+$' build/macos/tests/frontend-discovery.raw > build/macos/tests/frontend-discovery.log || :
frontend_rc=0
capped build/macos/tests/frontend-execution.log swift test "${frontend_args[@]}" || frontend_rc=$?
cat build/macos/tests/frontend-execution.log
python3 launchers/macos/check_xctest.py build/macos/tests/frontend-discovery.log build/macos/tests/frontend-execution.log
[ "$frontend_rc" = 0 ] || exit "$frontend_rc"
# 原生输入（input_test.m）与系统键盘桥接（textinput_test.m）的 C / ObjC 单测挪到 tests/macos_native_input_test.sh（合入前层、按依赖文件路由；
#   11-10：#417 Joy-Con 体感改走 HID 后 input_test 漏链 joycon_imu.m，这里只在合入后层跑，守望才发现）
