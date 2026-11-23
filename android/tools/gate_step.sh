#!/usr/bin/env bash
# Gate-only child isolation: preserve the failing child's first red, not red
# negative controls printed by earlier successful children.
s2a_gate_init() {
    S2A_GATE_SUMMARY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/s2a-android-gate-summary.XXXXXXXX")
    S2A_GATE_SUMMARY_FILE="$S2A_GATE_SUMMARY_DIR/failure"
    export S2A_GATE_SUMMARY_DIR S2A_GATE_SUMMARY_FILE
}

# 说明行（s2a_gate_note）也占摘要位（gate.sh 里「🔴 找不到 JDK」之类说明后紧跟 exit 1，它就是红因），但只是「暂占」：
#   之后有子项返回非零，以那一步的诊断为准（11-07：gate-host 上安卓钩子返回 75，摘要却是更早一条「W2 … 未运行（仅 Linux）」说明，
#   真正返回 75 那一步的诊断被盖掉，门禁和维护者都看不到原因）。子项红之后的说明不覆盖子项红
s2a_gate_note() {
    printf '%s\n' "$1" >&2
    if [ -n "${S2A_GATE_SUMMARY_FILE:-}" ] && [ ! -s "$S2A_GATE_SUMMARY_FILE" ]; then
        printf '%s\n' "$1" > "$S2A_GATE_SUMMARY_FILE"
        : > "$S2A_GATE_SUMMARY_FILE.note"
    fi
}

s2a_gate_step() {
    # Direct test.sh users retain its original stdout/stderr and exit semantics.
    if [ -z "${S2A_GATE_SUMMARY_FILE:-}" ]; then "$@"; return $?; fi
    local log rc first last cmd
    local -a status
    log=$(mktemp "$S2A_GATE_SUMMARY_DIR/step.XXXXXXXX")
    rc=0
    "$@" 2>&1 | tee "$log" || {
        status=("${PIPESTATUS[@]}")
        rc=${status[0]}
        [ "$rc" -ne 0 ] || rc=${status[1]}
    }
    if [ "$rc" -ne 0 ]; then
        # 失败子项自己的红行（反证段【负对照开始】…【负对照结束】不算）：结尾成段给 tools/gate.sh 的红步摘要（11-23：摘要原先 grep 整份日志，
        #   通过的子项按设计打的负对照红行——provider 缺导出场景、save_atomic 变异、caps_shape 策略反证——把真红 demand 计时挤成了第 5 条）
        cmd="$*"; cmd=${cmd//"$PWD"\//}   # 仓库根前缀去掉：沙箱路径每次不同，带着它守望签名就不稳
        { printf '✗ 子项 %s（rc=%s）\n' "$cmd" "$rc" | cut -c1-200
          awk '/【负对照开始】/ { n = 1; next } /【负对照结束】/ { n = 0; next } !n' "$log" |
            grep -a -E '^(不通|✗|FAIL: |FAIL|ERROR: |RED)|AssertionError|【红】|🔴|: error:' | head -8 | cut -c1-200 || true; } >> "$S2A_GATE_SUMMARY_DIR/failed"   # 没有红行（set -e / pipefail 下 grep 退 1）不能中断收尾
    fi
    if [ "$rc" -ne 0 ] && { [ ! -s "$S2A_GATE_SUMMARY_FILE" ] || [ -e "$S2A_GATE_SUMMARY_FILE.note" ]; }; then
        rm -f "$S2A_GATE_SUMMARY_FILE.note"
        first=$(awk '/【负对照开始】/ { n = 1; next } /【负对照结束】/ { n = 0; next } !n' "$log" | grep -m1 -E '【红】|🔴' || true)
        if [ -z "$first" ]; then
            last=$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)
            first="【红】安卓门禁子项失败（rc=${rc}，${1##*/}）：${last:-无诊断输出}"
        fi
        printf '%s\n' "$first" > "$S2A_GATE_SUMMARY_FILE"
    fi
    rm -f "$log"
    return "$rc"
}

s2a_gate_finish() {
    local rc=$1
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        if [ -s "$S2A_GATE_SUMMARY_DIR/failed" ]; then   # tools/gate.sh red_view 只取这一段做红步摘要
            { echo '【失败子项摘要开始】'; cat "$S2A_GATE_SUMMARY_DIR/failed"; echo '【失败子项摘要结束】'; } >&2
        fi
        if [ -s "$S2A_GATE_SUMMARY_FILE" ]; then
            cat "$S2A_GATE_SUMMARY_FILE" >&2
        else
            printf '【红】安卓门禁失败（rc=%s；子项没有诊断输出）\n' "$rc" >&2
        fi
    fi
    rm -rf "$S2A_GATE_SUMMARY_DIR"
    exit "$rc"
}
