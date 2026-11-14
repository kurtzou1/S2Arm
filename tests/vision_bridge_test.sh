#!/bin/bash
# 真机驾驶员桥单测（tools/vision_bridge.sh，假 devicectl tests/fake_devicectl.py + 假驾驶员，秒级）：bash tests/vision_bridge_test.sh
# 期望按信箱约定手写（autoplay.c vision_run_remote 注释）：
#   ① 没有会话号时，机上残留的 v01.req（旧会话）不答  ② 本会话 v01：拉走截图、把「试过没用的键」交驾驶员、推回 v01.json 与 v01.done（= 会话号）
#   ③ v02 升级（escalate=1、touchw=1280）→ 驾驶员收到 S2A_VISION_ESCALATE=1、S2A_VISION_TOUCH_W=1280  ④ 换会话 → 从 v01 重数、答新会话  ⑤ stop 文件出现 → 退出
# 门禁覆盖：tools/vision_bridge.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/vbridge.XXXXXX"); trap 'touch $T/l/stop; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export FAKE_DEV=$T/dev S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py" BRIDGE_POLL=0.1
V=$T/dev/D1/apps/com.x/Documents/vision; mkdir -p $V $T/l
cat > $T/vis.sh <<'S'
echo "png=$(basename $1) tried=${S2A_VISION_TRIED:-} esc=${S2A_VISION_ESCALATE:-0} tw=${S2A_VISION_TOUCH_W:-}" >> "$(dirname $0)/calls.log"; printf '{"keys": ["X"], "playable": false, "why": "假"}\n' > "$2"
S
waitf() { for _ in $(seq 1 100); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }
printf 'session=old\ntried=\nescalate=0\n' > $V/v01.req; echo png > $V/v01.png   # 上一局残留：没有 session 文件
S2A_VISION_SH=$T/vis.sh BRIDGE_PARENT=$$ bash $H/tools/vision_bridge.sh D1 com.x $T/l & BP=$!
sleep 1.5
ck "① 没有会话号：残留 v01.req 不答（没有 v01.done、驾驶员没被调）" '[ ! -e $V/v01.done ] && [ ! -s $T/calls.log ]'
rm -f $V/v01.*; echo s1 > $V/session
echo png1 > $V/v01.png; printf 'session=s1\ntried=A,B\nescalate=0\n' > $V/v01.req
waitf $V/v01.done
ck "② 本会话 v01：v01.done = s1、v01.json 推回、驾驶员收到 tried=A,B（实为 $(head -1 $T/calls.log 2> /dev/null)）" \
  '[ "$(cat $V/v01.done 2> /dev/null)" = s1 ] && grep -q "\"X\"" $V/v01.json && [ "$(head -1 $T/calls.log)" = "png=v01.png tried=A,B esc=0 tw=" ]'
echo png2 > $V/v02.png; printf 'session=s1\ntried=\nescalate=1\ntouchw=1280\n' > $V/v02.req
waitf $V/v02.done
ck "③ v02 升级 + 触点画布宽：驾驶员收到 S2A_VISION_ESCALATE=1、S2A_VISION_TOUCH_W=1280（实为 $(sed -n 2p $T/calls.log 2> /dev/null)）" '[ "$(sed -n 2p $T/calls.log)" = "png=v02.png tried= esc=1 tw=1280" ]'
rm -f $V/v0*; echo s2 > $V/session; echo png3 > $V/v01.png; printf 'session=s2\ntried=\nescalate=0\n' > $V/v01.req
waitf $V/v01.done
ck "④ 换会话 s2：从 v01 重数、v01.done = s2" '[ "$(cat $V/v01.done 2> /dev/null)" = s2 ] && [ "$(sed -n 3p $T/calls.log)" = "png=v01.png tried= esc=0 tw=" ]'
touch $T/l/stop; for _ in $(seq 1 50); do kill -0 $BP 2> /dev/null || break; sleep 0.1; done
ck "⑤ stop 文件出现 → 桥退出" '! kill -0 $BP 2> /dev/null && grep -q "桥停（收到 stop）" $T/l/bridge.log'
# ⑥ 推回失败（11-02 测试设备1：推回失败后下一轮重拉图、重问驾驶员，一问耗两遍）：手算期望——第 1 次 copy to 失败，下一轮只重推、驾驶员只被调 1 次，v01.done = s6
V6=$T/dev/D6/apps/com.x/Documents/vision; mkdir -p $V6 $T/l6; : > $T/calls6.log; sed "s|calls.log|calls6.log|" $T/vis.sh > $T/vis6.sh
echo s6 > $V6/session; echo png6 > $V6/v01.png; printf 'session=s6\ntried=\nescalate=0\n' > $V6/v01.req
FAKE_FAIL_TO=1 S2A_VISION_SH=$T/vis6.sh BRIDGE_PARENT=$$ bash $H/tools/vision_bridge.sh D6 com.x $T/l6 & BP6=$!
waitf $V6/v01.done; touch $T/l6/stop; for _ in $(seq 1 50); do kill -0 $BP6 2> /dev/null || break; sleep 0.1; done
ck "⑥ 推回失败一次：只重推不重问（驾驶员被调 $(grep -c . $T/calls6.log) 次、v01.done = $(cat $V6/v01.done 2> /dev/null)）" '[ "$(grep -c . $T/calls6.log)" = 1 ] && [ "$(cat $V6/v01.done 2> /dev/null)" = s6 ] && grep -q "推回失败" $T/l6/bridge.log'
# ⑦ 多款容器包：自动玩家信箱在 Documents/games/<号>/vision（S2A_VISION_DIR，tools/dev_run.sh 按启动上下文传）——桥在那里答、不去 Documents/vision
V7=$T/dev/D7/apps/com.x/Documents/games/0400486024DEC000/vision; mkdir -p $V7 $T/l7
echo s7 > $V7/session; echo png7 > $V7/v01.png; printf 'session=s7\ntried=\nescalate=0\n' > $V7/v01.req
S2A_VISION_DIR=Documents/games/0400486024DEC000/vision S2A_VISION_SH=$T/vis.sh BRIDGE_PARENT=$$ bash $H/tools/vision_bridge.sh D7 com.x $T/l7 & BP7=$!
waitf $V7/v01.done
ck "⑦ 多款容器信箱目录：v01.done = s7、答案推回同一目录" '[ "$(cat $V7/v01.done 2> /dev/null)" = s7 ] && [ -s $V7/v01.json ]'
touch $T/l7/stop; wait $BP7 2> /dev/null
[ $bad = 0 ] && echo "vision_bridge 单测全过" || { echo "vision_bridge 单测有不通"; exit 1; }
