#!/usr/bin/env bash
# 门禁路由：android/
# 门禁层：合入后
# 门禁本机：* android/test.sh 要 CMake 3.18+ / NDK 29.0.14206865 / JDK 17 / 固定 venv（Capstone 5.0.7、LZ4 4.4.5）；门禁机没有 CMake
# 安卓无设备 CPU 测的门禁钩子：整套 android/test.sh（Java 单测 / 原生宿主单测与变异对照 / Python 契约 / 可移植改写准备回归）。
# 11-11 旧安卓三钩子删除后（017d7695b）android/ 是无钩子路径（tools/gate_route.py NOHOOK），test.sh 没有任何门禁入口在跑；
# 维护者当时定「新 android/gate.sh（门禁路由：android/）接上时删掉 NOHOOK」，本钩子即这一步。
# 不在这里的（各有入口，不重复）：
#   · 新图形层 NDK 交叉链接：android/native/gfx_plat/gate.sh；
#   · 安卓 APK 单库链接核对：tests/android_apk_link_test.sh；Linux runtime CTest：android/linux_ctest.sh（要 aarch64 Linux / colima）；
#   · nvn_gpu_* Vulkan 后端契约用例：tests/android_vk_test.sh。
# 门禁预算：--budget → 1800 秒（11-20 本机整套 1464 秒，基线 c11c831ed；改 android/ 任一文件都会跑这一整套）
[ "${1:-}" = --budget ] && { echo 1800; exit 0; }
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # 仓库根
# test.sh 的 Java 段用 PATH 上的 javac：先选定 JDK 17（与 JNI 检查同一个 Home），新版本 JDK 排在前面也不能顶掉它
JAVAC=$(bash android/tools/jdk17.sh || true)
[ -n "$JAVAC" ] || { echo "🔴 安卓门禁找不到 JDK 17 的 javac（可用 S2A_JAVAC=<javac 路径> 指定）" >&2; exit 1; }
JAVA_HOME=$("$JAVAC" -J-XshowSettings:properties -version 2>&1 | sed -n 's/^[[:space:]]*java.home = //p')
[ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/javac" ] || { echo "🔴 选中的 javac（${JAVAC}）没有返回完整 JDK Home" >&2; exit 1; }
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
# 子项隔离（android/tools/gate_step.sh）：整套里每个子项失败都记下它自己的红行，结尾成段给 tools/gate.sh 的红步摘要
#   （11-23：原先 exec 直接跑整套、没 s2a_gate_init，隔离从没生效，通过的子项按设计打的负对照红行进了摘要，误导两轮定位）
source android/tools/gate_step.sh
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
bash android/test.sh
