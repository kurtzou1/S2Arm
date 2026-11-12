#!/bin/bash
# 推资源包（#206）：把 <资源包目录> 增量推到已装好的 App，只传机上没有 / 内容变了的文件。
#
# 推包逻辑只在 tools/push_pack.py 一份（11-06 维护者拍板：Mac / Windows 玩家流程同一后端，原先这里的 bash 与 Windows 的 pack/orch/push_win.py
#   各写一遍，残留批覆盖、.pushed 记账两边各踩一次坑）。本文件只剩两个入口：
#   ① tools/dev_run.sh 部署段 . 本文件后调 push_pack：算待推（push_pack.py plan）→ 回调 dev_run 按推送量放大看门、机上空间不够先腾 → 推（push_pack.py send）
#   ② 独立跑（手动装机）：tools/push_pack.sh <设备 UDID|名字> <bundle id> <资源包目录> [--full] [--apply] = python3 tools/push_pack.py run …
#   --full：不信机上账，整包重推（等同 dev_run.sh 的 S2A_PUSH_FULL=1）。口径（残留批 / 抽查实况 / .pushed / 1 GB 一批 / 流式写）见 push_pack.py 文件头
set -u
PUSH_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/push_pack.py"   # 同目录：调度把 tools/ 整份单独拷到 gate-host 跑

# —— dev_run.sh 调用（调用方提供 t / fin，可选 UD = 手机 UDID）——
#   给了 PUSH_ON_PLAN=<函数名> 时，算出待推量后回调它（$1 批数 $2 文件数 $3 字节数）：dev_run 在那里按推送量放大看门段与设备锁
#   给了 PUSH_ON_LOWSPACE=<函数名> 时，机上可写不够 push_pack.py need 算的量先回调它（$1 = 要的 MB），回来重读可写，够了照推、仍不够报红（11-06：dev_run 挂腾空间）
push_py() {   # push_py <plan|free|send> <设备> <bundle id> <资源包目录> <scratch 目录> [参数…]：日志行逐行交 t，机读结果在 <scratch>/push.state
  local op=$1 D=$2 B=$3 PACK=$4 O=$5 l; shift 5
  rm -f "$O/push.state"
  python3 -B "$PUSH_PY" "$op" "$D" "$B" "$PACK" --work "$O" ${UD:+--udid "$UD"} "$@" > "$O/push_py.out" 2>&1; local rc=$?
  while IFS= read -r l; do t "$l"; done < "$O/push_py.out"
  return $rc
}
push_state() { sed -n "s/^$1 //p" "$2/push.state" 2>/dev/null; }
push_free_b() { python3 -B "$PUSH_PY" free "$1" "$2" "$3" --work "$4" ${UD:+--udid "$UD"} 2>/dev/null | grep -E '^[0-9]+$'; }
push_pack() {   # push_pack <设备> <bundle id> <资源包目录> <scratch 目录> [1 = 整包重推]
  local D=$1 B=$2 PACK=$3 O=$4 FULL=${5:-0} fb nd
  PUSH_K=0 PUSH_NBATCH=0 PUSH_NTODO=0 PUSH_NBYTES=0
  push_py plan "$D" "$B" "$PACK" "$O" $([ "$FULL" = 1 ] && echo --full) || fin push "$(push_state FAIL "$O" || true)"
  set -- $(push_state PLAN "$O")
  [ $# = 3 ] || fin push "算待推清单失败"
  # 推之前核剩余空间：要的 = 待推量 + 最大一批 + 每文件 4 KB + 余量（push_pack.py need）；读不到只记一行、照推
  if [ "$3" -gt 0 ]; then fb=$(push_free_b "$D" "$B" "$PACK" "$O"); nd=$(python3 -B "$PUSH_PY" need "$D" "$B" "$PACK" --work "$O" 2> /dev/null | grep -E '^[0-9]+$'); nd=${nd:-$(( $3 * 2 + ${S2A_PUSH_SPARE_GB:-1} * 1073741824 ))}
    if [ -z "$fb" ]; then t "🟡 读不到手机剩余空间（ideviceinfo），不核、照推"
    elif [ "$fb" -lt "$nd" ] && [ -n "${PUSH_ON_LOWSPACE:-}" ] && "$PUSH_ON_LOWSPACE" $((nd >> 20)) && fb=$(push_free_b "$D" "$B" "$PACK" "$O") && [ -n "$fb" ] && [ "$fb" -ge "$nd" ]; then
      t "腾空间后可写 $((fb >> 30)) GB ≥ 要 $((nd >> 30)) GB，照推"   # 11-06 维护者：空间不够先卸 24 小时以上的我方 App（调用方 PUSH_ON_LOWSPACE <要的 MB>，dev_run 挂 tools/dev_prune.sh）
    elif [ "$fb" -lt "$nd" ]; then t "【红】手机剩余空间不足：可写 $((fb >> 30)) GB < 要 $((nd >> 30)) GB（待推 $(( $3 >> 30 )) GB + 解开时最大一批 + 余量）；先卸掉机上不用的包（tools/dev_uninstall.sh）"; fin push "测试设备空间不足"; fi
  fi
  # 调用方的看门预算按推送量放大（dev_run 的 push_budget：已用 + 300 秒 + 推送 15 MB/s + 机上解包 50 MB/s）
  [ -z "${PUSH_ON_PLAN:-}" ] || "$PUSH_ON_PLAN" "$1" "$2" "$3"
  push_py send "$D" "$B" "$PACK" "$O" || fin push "$(push_state FAIL "$O" || true)"
  PUSH_K=$(push_state SENT "$O") PUSH_NBATCH=$1 PUSH_NTODO=$2 PUSH_NBYTES=$3
}

# —— 独立运行：同一份 push.py 一条龙 ——
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in --help|-h|"") sed -n '2,10p' "$0"; exit 0;; esac
  D= B= PACK= FULL= APPLY=
  for a in "$@"; do case $a in
    --full) FULL=--full;;
    --apply) APPLY=--apply;;   # 推完起一次 App 只解包并等解完
    *) if [ -z "$D" ]; then D=$a; elif [ -z "$B" ]; then B=$a; elif [ -z "$PACK" ]; then PACK=$a; else echo "认不得参数 $a" >&2; exit 2; fi;;
  esac; done
  [ -n "$D" ] && [ -n "$B" ] && [ -n "$PACK" ] || { sed -n '2,10p' "$0" >&2; exit 2; }
  exec python3 -B "$PUSH_PY" run "$D" "$B" "$PACK" $FULL $APPLY
fi
