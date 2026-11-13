#!/bin/bash
# 门禁覆盖：tools/devices.sh
# 同一台测试设备只有一把锁（11-13：一条线没读到设备表，走自有设备路径对测试设备1 另起了一把锁，和按名单取锁的线同时往同一台手机装包）：bash tests/devices_own_lock_test.sh
#   期望（按规则手写）：
#   ① 按名单选中测试设备（机号 1）→ 锁 = 名单那把（单测落 $S2A_TEST_ROOT/device.lock），并在 <自有设备根>/<UDID>/registered.tsv 登记它
#   ② 另一个环境没读到设备表（名单只有占位）、S2A_DEVICE_OWN=1 指同一个 UDID → 锁仍是 ① 那把，不是 own_<UDID>.lock
#   ③ 没登记过的自有设备 → 照旧 own_<UDID>.lock（不受影响）
set -u; R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
UD=00000000-00000000000000A1; OU=00000000-00000000000000B2; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "✗ $1"; bad=$((bad + 1)); fi; }
common() { export S2A_TEST_ROOT=$T S2A_DEVICE_NO_USB_CHECK=1 S2A_MACHINE_NO_LOCAL=1 S2A_DAILY_PHONE=00000000-0000000000000000; }
r1=$( common; export S2A_DEVICES="1|测试设备1|$UD|CD-1|$T/real/device.lock|$T/real/battery|iphone"
      . "$R/tools/devices.sh" && s2a_device 1 > /dev/null 2>&1 && echo "$SW_DEVLOCK_DIR" )
ck "① 名单选中：锁 = $T/device.lock（真结果 ${r1}）" '[ "$r1" = "$T/device.lock" ]'
ck "① 登记文件里是这把锁" '[ "$(cut -f1 "$T/own_devices/$UD/registered.tsv" 2> /dev/null)" = "$T/device.lock" ]'
mkdir -p "$T/fd"; LIST="[{\"name\":\"测试设备1\",\"udid\":\"$UD\",\"identifier\":\"CD-1\"},{\"name\":\"贡献者手机\",\"udid\":\"$OU\",\"identifier\":\"CD-9\"}]"
own() { ( common; unset S2A_DEVICES; export S2A_DEVICES_NO_LOCAL=1 S2A_DEVICE_OWN=1 S2A_DEVICECTL="python3 $R/tests/fake_devicectl.py" FAKE_DEV=$T/fd FAKE_DEVLIST=$LIST
          . "$R/tools/devices.sh" && s2a_device "$1" > /dev/null 2>&1 && echo "$SW_DEVLOCK_DIR" ); }
r2=$(own "$UD"); ck "② 没读到设备表、自有设备路径指同一 UDID：锁仍是 $T/device.lock（真结果 ${r2}）" '[ "$r2" = "$T/device.lock" ]'
r3=$(own "$OU"); ck "③ 没登记的自有设备：锁 = $T/own_$OU.lock（真结果 ${r3}）" '[ "$r3" = "$T/own_$OU.lock" ]'
[ "$bad" = 0 ] && echo "设备锁同机同锁单测全过" || { echo "设备锁同机同锁单测 $bad 项不通"; exit 1; }
