#!/bin/bash
# 真机自动玩家的 Mac 侧驾驶员桥（11-01 维护者派：iOS 上没有视觉脚本也没有密钥，真机局到不了 MARK）：
#   bash tools/vision_bridge.sh <设备> <包名> <本地目录>
# 真机上的自动玩家（tests/autoplay/autoplay.c，起局带 S2A_VISION_REMOTE=1）把每一问写成 Documents/vision/vNN.png + vNN.req（会话号、试过没用的键、是否升级），
#   本脚本经 devicectl 拉走，跑与 Mac 局同一个驾驶员 tests/autoplay/vision.sh（S2A_VISION_SH 可换），把 vNN.json 推回、最后推 vNN.done（内容 = 会话号）。
#   按键仍由真机上的自动玩家自己按；本脚本只答题。密钥只在 Mac 上（vision.sh 读），不进手机。
# 会话：先拉 Documents/vision/session（自动玩家开局清掉上局残留后写）；换了会话从 v01 重数。只答本会话的请求，上局残留的 req 不答。
# 结束：<本地目录>/stop 出现、或 BRIDGE_PARENT（缺省本脚本父进程）没了就退出。每一问记一行到 <本地目录>/bridge.log。
# 单测：tests/vision_bridge_test.sh（假 devicectl S2A_DEVICECTL、假驾驶员）
set -u
DEV=${1:?设备} B=${2:?包名} L=${3:?本地目录}; mkdir -p "$L"
H=$(cd "$(dirname "$0")/.." && pwd)
DC=${S2A_DEVICECTL:-xcrun devicectl}
VSH=${S2A_VISION_SH:-$H/tests/autoplay/vision.sh}
POLL=${BRIDGE_POLL:-1}
VD=${S2A_VISION_DIR:-Documents/vision}   # 设备上的信箱目录 = 自动玩家的 <文档根>/vision：单款 App 是 Documents/vision，多款容器包是 Documents/games/<号>/vision（tools/dev_run.sh 按启动上下文传；空串 = 缺省）
PARENT=${BRIDGE_PARENT:-$PPID}
log() { echo "[$(date +%T)] $*" >> "$L/bridge.log"; }
# devicectl 一律带它自带的 --timeout（同 tools/dev_run.sh dcp：外层 timeout 只兜 devicectl 自己卡死）
dcp() { local T=$1; shift; timeout $((T + ${S2A_DC_MARGIN:-30})) $DC "$@" --timeout "$T" > /dev/null 2>&1; }
pull() { rm -f "$2"; dcp 20 device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$B" --source "$VD/$1" --destination "$2" && [ -s "$2" ]; }
push() { dcp 20 device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$B" --source "$1" --destination "$VD/$2"; }
log "桥起：设备 $DEV 包 $B 驾驶员 $VSH"
S= n=1
while [ ! -e "$L/stop" ] && kill -0 "$PARENT" 2> /dev/null; do
  if pull session "$L/session.cur"; then
    s=$(head -1 "$L/session.cur" | tr -d '\r\n')
    [ "$s" != "$S" ] && { S=$s; n=1; log "会话 $S"; }
  fi
  if [ -n "$S" ]; then
    f=$(printf 'v%02d' $n)
    if pull $f.req "$L/$f.req" && [ "$(sed -n 's/^session=//p' "$L/$f.req")" = "$S" ]; then
      t0=$SECONDS
      # 这一问上一轮已经答过、只是推回失败（11-02 测试设备1 智慧的再现：推回失败后下一轮重新拉图、重问驾驶员，一问耗两遍）：只重推，不重问
      if [ -s "$L/$f.json" ] && [ "$(cat "$L/$f.done" 2> /dev/null)" = "$S" ]; then rc=重推
      elif pull $f.png "$L/$f.png"; then
        S2A_VISION_TRIED="$(sed -n 's/^tried=//p' "$L/$f.req")" S2A_VISION_ESCALATE="$(sed -n 's/^escalate=1$/1/p' "$L/$f.req")" S2A_VISION_TOUCH_W="$(sed -n 's/^touchw=//p' "$L/$f.req")" bash "$VSH" "$L/$f.png" "$L/$f.json"; rc=$?
      else rc=-1; echo '{"keys": [], "playable": false, "why": "桥没拉到截图"}' > "$L/$f.json"; fi
      [ -s "$L/$f.json" ] || echo '{"keys": [], "playable": false, "why": "驾驶员没写答案"}' > "$L/$f.json"
      echo "$S" > "$L/$f.done"
      if push "$L/$f.json" $f.json && push "$L/$f.done" $f.done; then log "$f 答（驾驶员退出 ${rc}，$((SECONDS - t0)) 秒）：$(head -c 200 "$L/$f.json" | tr -d '\n')"; n=$((n + 1))
      else log "$f 推回失败，下一轮重推"; fi
      continue
    fi
  fi
  sleep "$POLL"
done
log "桥停（$([ -e "$L/stop" ] && echo 收到 stop || echo 父进程没了)）"
