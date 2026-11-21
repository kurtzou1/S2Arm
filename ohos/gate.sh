#!/bin/bash
# 门禁路由：ohos/ runtime/rewriter/ tests/rewrite_target_test.sh
# 门禁钩子（tools/gate.sh 自动跑）：鸿蒙线不要鸿蒙 SDK / 模拟器 / 设备就能跑的单测。
#   要鸿蒙 SDK、只能 Windows 宿主跑、或依赖未公开工具的（run_guest_classifier.py、test_module_enhancement_headers.py、test_nro_container.py）在各自文件头写「门禁手动」与单跑命令。
# 改写器两支要 unicorn / capstone：用 S2A_PY（tools/gate.sh 指到 ~/.s2arm/venv 的固定解释器）；托管两支要 .NET 10（门禁给的 DOTNET）。
# 退出码 0 = 绿；最后一行是汇总（期望 → 真结果）。
set -u
cd "$(dirname "$0")/.." || exit 2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-dotnet}
pass=0; fail=0; failed=
ck() {   # ck <退出码> <名>：失败时打日志末尾
    if [ "$1" = 0 ]; then pass=$((pass + 1)); echo "通 $2"
    else fail=$((fail + 1)); failed="$failed $2"; echo "不通 $2（退出 $1）"; tail -20 "$T/$2.log" | sed 's/^/  | /'; fi
}
"${S2A_PY:-python3}" -B ohos/tests/test_signed_generator.py > "$T/signed_generator.log" 2>&1; ck $? signed_generator
"${S2A_PY:-python3}" -B ohos/tests/test_rewrite_ohos.py . "$T/rewrite_ohos" > "$T/rewrite_ohos.log" 2>&1; ck $? rewrite_ohos
"${S2A_PY:-python3}" -B ohos/tests/test_rewrite_sp_add.py --out "$T/rewrite_sp_add" > "$T/rewrite_sp_add.log" 2>&1; ck $? rewrite_sp_add
"${S2A_PY:-python3}" -B ohos/tests/keyboard/run.py --dotnet "$DN" --output "$T/keyboard" > "$T/keyboard.log" 2>&1; ck $? keyboard
"${S2A_PY:-python3}" -B ohos/tests/audio-session/run.py --dotnet "$DN" --build-root "$T/audio_session" > "$T/audio_session.log" 2>&1; ck $? audio_session
echo "鸿蒙单测：期望 5/5 通过 → 真结果 $pass/$((pass + fail)) 通过${failed:+（不通：${failed}）}"
[ $fail = 0 ]
