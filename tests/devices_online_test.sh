#!/bin/bash
# 门禁覆盖：tools/devices.sh
# 设备在线判定（_s2a_dc_seen）：devicectl 列表里这台的状态是 available / available (paired) / connected 才算在线；unavailable、shutdown 不算（11-13：子串匹配把 unavailable 当在线）：bash tests/devices_online_test.sh
set -u; R=$(cd "$(dirname "$0")/.." && pwd); bad=0
export S2A_MACHINE_NO_LOCAL=1 S2A_DEVICES_NO_LOCAL=1
. "$R/tools/devices.sh"
L='Name   Hostname   Identifier                                    State                Model     Reality
甲              00000000-0000000000000011 (UDID)              available (paired)   iPhone    physical
乙              00000000-0000000000000012 (UDID)              unavailable          iPhone    physical
丙              00000000-0000000000000013 (UDID)              connected            iPhone    physical
丁              00000000-0000000000000014 (UDID)              shutdown             iPhone    simulated
戊              00000000-0000000000000015 (UDID)              available            iPhone    physical'
for c in "11 0 available (paired)" "12 1 unavailable" "13 0 connected" "14 1 shutdown" "15 0 available" "16 1 不在列表"; do
  set -- $c; id=00000000-00000000000000$1; want=$2; shift 2
  _s2a_dc_seen "$L" "$id"; got=$?
  if [ "$got" = "$want" ]; then echo "通 ${*}：在线判定 $([ "$want" = 0 ] && echo 在线 || echo 不在线)"; else echo "✗ ${*}：期望 $([ "$want" = 0 ] && echo 在线 || echo 不在线)，真结果相反"; bad=$((bad + 1)); fi
done
[ "$bad" = 0 ] && echo "设备在线判定单测全过" || { echo "设备在线判定单测 $bad 项不通"; exit 1; }
