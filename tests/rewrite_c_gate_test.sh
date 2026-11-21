#!/bin/bash
# C 改写器（出包唯一路径）的两项金样挂进门禁：合成语料 × 苹果 / 安卓 × 自旋全部产物（rewrite_c_test.py），FAR 补丁容量重选（rewrite_front_synth_test.py，#290）。
#   10-31 删 Python 改写器前是 C / Python 对拍，之后对仓库里的金样（tests/rewrite_golden.py）。
#   两个 .py 没有 .sh 壳时门禁不跑（10-26 #420 翻 C 为缺省时补）；C 命令行按出包同一入口取（pack/rewriter.py c-path），不是另编一份。
#   另两项要宿主 C 接口测试程序 s2a-rewrite-api-test（出包不编它）：C 接口隔离与坏输入（rewrite_c_api_test.py）、SDK 代码形态契约（rewrite_sdk_c_test.py）。
#   它们按同目录找测试程序，所以在 build/rewriter-api-test 开 S2A_REWRITER_API_TEST 同源同依赖另编一份命令行 + 测试程序（10-29 接线扫描查出门禁一直没跑）
# 门禁覆盖：runtime/rewriter/* pack/rewriter.py tests/rewrite_golden.py tests/fixtures/rewrite_golden/*
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（lz4：rewrite_c_test 造 lz4 压缩输入）
C=$("$PY" "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1); [ -x "$C" ] || { echo "🔴 取不到出包 C 改写器（pack/rewriter.py c-path）"; exit 1; }
rc=0
REW=$C "$PY" "$H/tests/rewrite_c_test.py" || { echo "🔴 rewrite_c_test 没过（上面一行写明是产物差、退出码差还是超时）"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_data_in_text_test.py" || { echo "🔴 rewrite_data_in_text_test：代码段内嵌数据判定不符"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_scale_test.py" || { echo "🔴 rewrite_scale_test：一个函数里大量 br x18 / 大量函数时改写超时或计数不符（#251）"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_reachdefs_scale_test.py" || { echo "🔴 rewrite_reachdefs_scale_test：控制流回溯仍随函数长度平方变慢或跳转表识别数不符"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_eh_absptr_test.py" || { echo "🔴 rewrite_eh_absptr_test：.eh_frame 绝对指针编码（absptr）读不了或函数范围不符（#286）"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_front_synth_test.py" || { echo "🔴 rewrite_front_synth_test：C 的 FAR 容量重选与金样不符"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_below_sp_test.py" || { echo "🔴 rewrite_below_sp_test：恢复 sp 后还用 sp 以下数据的函数里，x18 补丁岛仍往 sp 以下写（一款第一方动作游戏 / #515）"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_eh_hdr_test.py" || { echo "🔴 rewrite_eh_hdr_test：.eh_frame_hdr 没有二分表 / 整个缺失时函数边界取不到或改写中止"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_as36_test.py" || { echo "🔴 rewrite_as36_test：36 位老 SDK 写死的可随机区 / 栈区没认出、认错或 TRAP 表头不符（#1503）"; rc=1; }
REW=$C "$PY" "$H/tests/rewrite_sainit_test.py" || { echo "🔴 rewrite_sainit_test：分配器初始化闸（StandardAllocator 入口压小）的补丁岛编码或门表行不符"; rc=1; }
DEPS=$("$PY" "$H/pack/rewriter.py" deps-path) || { echo "🔴 取不到 C 改写器固定依赖（pack/rewriter.py deps-path）"; exit 1; }
AB="$H/build/rewriter-api-test"
# 固定构建目录的缓存记着上次配置时的源码路径：同一棵树先后跑过不同目录布局的分支（源码搬了目录）时，CMake 拒绝配置
#   「The source … does not match the source … used to generate cache」（11-09 列车门禁红一次）。源码路径不符就整目录重建（tests/cmake_fresh_dir_test.sh）
fresh_cmake_dir() { [ ! -f "$2/CMakeCache.txt" ] || grep -qxF "CMAKE_HOME_DIRECTORY:INTERNAL=$1" "$2/CMakeCache.txt" || rm -rf "$2"; }
fresh_cmake_dir "$H/runtime/rewriter" "$AB"
{ cmake -S "$H/runtime/rewriter" -B "$AB" -DS2A_REWRITER_DEPS="$DEPS" -DCMAKE_BUILD_TYPE=Release -DS2A_REWRITER_API_TEST=ON \
  && cmake --build "$AB" --config Release --target s2a-rewrite s2a-rewrite-api-test --parallel 2; } > "$AB.log" 2>&1 \
  || { echo "🔴 编 C 接口测试程序失败（全文 $AB.log）"; tail -5 "$AB.log"; exit 1; }
REW=$AB/s2a-rewrite "$PY" "$H/tests/rewrite_c_api_test.py" || { echo "🔴 rewrite_c_api_test：C 接口隔离 / 坏输入处理不符"; rc=1; }
REW=$AB/s2a-rewrite "$PY" "$H/tests/rewrite_sdk_c_test.py" || { echo "🔴 rewrite_sdk_c_test：SDK 代码形态 / 导出返回契约不符"; rc=1; }
[ $rc = 0 ] && echo "✅ C 改写器合成语料金样 + FAR 重选金样 + C 接口 + SDK 形态契约全过（C $(basename "$(dirname "$C")")）"
exit $rc
