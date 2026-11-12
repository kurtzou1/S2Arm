# S2Arm 测试设备电量闸。底本：小菠萝主干 sw/ios/tools/devbattery.sh（~/xbl/wt/sw/main 793f440ac），S2Arm 起归本仓维护。UDID 由 tools/devices.sh 的 s2a_device 设；没设返回 2（维护方工具 当场退出）
# 测试设备电量闸（测试 iPhone 01:46 没电关机、断到 09:26——插在 Mac 上供电跟不上，屏幕常亮 10 小时电量一路掉到 1%）。
# 用法：source 本文件后 devbattery_gate || exit 1（真机局取设备锁之前调）。读法：ideviceinfo 电池域（USB 不通再走网络 -n）。
#   电量 < 30%：落暂停标记 $SW_ROOT/run/ios/device_low_battery、记【红】、记进 $SW_ROOT/run/ios/device_alert.txt，拒绝开跑（返回 1），之后所有真机局都拒绝；
#   有暂停标记时电量 ≥ 60% 才撤标记放行（充电中途 30%–60% 一律拒绝，免得刚过线又跑没电）；
#   接着外接电源（ExternalConnected 为真，充满停充也算）：只按当场读数，≥ 20% 即放行（有暂停标记顺手撤掉），< 20% 拒绝——维护者 10-20 定「插着电就直接测，不用等 60%」，
#     （10-18 原口径要求同时在充）；拔电时仍按上面两条（< 30% 暂停、回到 60% 放行）。
#   插着电却没在充、且电量低于 90% 才记【红】提醒（供电跟不上），但不拦——系统在高电量下会自己停充（全天停在 99–100%、「充电=0」，旧判据「低于 100%」整下午误报）；读不到电量记【红】并拒绝（多半设备已离线）。
# 放行时把「电量 N%（充电 / 未充电，电源 有 / 无）」写进 DEVBATTERY_LINE，调用方记进表头 / 日志；每次读数追加到 $SW_ROOT/run/ios/battery.log。
# 测试开关：DEVBATTERY_FAKE="<电量> <充电 0/1> <电源 0/1>" 不读设备，直接用这组数（单测 devbattery_test.sh 用）。
DEVBATTERY_LOW=${DEVBATTERY_LOW:-30}; DEVBATTERY_RESUME=${DEVBATTERY_RESUME:-60}; DEVBATTERY_CHARGING_MIN=${DEVBATTERY_CHARGING_MIN:-20}
DEVBATTERY_DIR=${DEVBATTERY_DIR:-${SW_ROOT:-$HOME/sw-work}/run/ios}
devbattery_read() {   # 输出「电量 充电 电源 充满」四个数（0/1），读不到返回 1，没配 UDID 返回 2，本机缺工具返回 3，USB 不通且交局内判返回 6
  if [ -n "${DEVBATTERY_FAKE:-}" ]; then echo "$DEVBATTERY_FAKE"; return 0; fi
  local u=${SW_IOS_UDID:-} out
  [ -n "$u" ] || return 2   # 没选测试设备（s2a_device 没调）   # 没配 UDID（与「读不到」分开报）
  # 本机缺工具与「设备没应答」分开报（返回 3）：timeout 来自 coreutils，macOS 不自带；缺它时下面两条命令根本起不来，原先一律报成「设备多半离线」并让调用方白等到上限
  local tb; tb=$(command -v timeout || command -v gtimeout) || return 3
  command -v ideviceinfo > /dev/null || return 3
  out=$("$tb" 20 ideviceinfo -u "$u" -q com.apple.mobile.battery 2>/dev/null) || out=$("$tb" 20 ideviceinfo -n -u "$u" -q com.apple.mobile.battery 2>/dev/null) || {
    # 拔电测试（10-19）：设备走网络连接，ideviceinfo 两条都不通。退到 App 自己记的电量：执行器局中把宿主日志「[电] 电量 N%，状态」写进 app_battery_<UDID>.txt（「电量 状态」），
    # 不超过 SW_DEVBATTERY_APP_MAX_AGE_S（缺省 1800）秒就按它判；没有新鲜读数时，调用方声明会在局内判电量（SW_DEVBATTERY_INRUN=1，执行器开局 ≥ 60%、局中 < 30% 停局）返回 6，否则照旧算读不到
    local cf=$DEVBATTERY_DIR/app_battery_$u.txt p s
    if [ -s "$cf" ] && [ $(( $(date +%s) - $(stat -f %m "$cf") )) -le "${SW_DEVBATTERY_APP_MAX_AGE_S:-1800}" ] && read -r p s < "$cf" && [ "${p:--1}" -ge 0 ] 2>/dev/null; then
      echo "$p $([ "$s" = 充电中 ] && echo 1 || echo 0) $([ "$s" = 充电中 ] || [ "$s" = 已充满 ] && echo 1 || echo 0) $([ "$s" = 已充满 ] && echo 1 || echo 0)"; return 0; fi
    [ "${SW_DEVBATTERY_INRUN:-0}" = 1 ] && return 6; return 1; }
  awk '/^BatteryCurrentCapacity:/{p=$2} /^BatteryIsCharging:/{c=($2=="true")} /^ExternalConnected:/{e=($2=="true")} /^FullyCharged:/{f=($2=="true")} END{ if (p=="") exit 1; print p, c+0, e+0, f+0 }' <<<"$out"
}
devbattery_gate() {
  mkdir -p "$DEVBATTERY_DIR"; local flag=$DEVBATTERY_DIR/device_low_battery log=$DEVBATTERY_DIR/battery.log r p c e f now; now=$(date '+%m-%d %H:%M:%S')
  r=$(devbattery_read); local rc=$?
  if [ $rc = 2 ]; then
    echo "$now 没配 UDID" >> "$log"; DEVBATTERY_LINE="电量 没配 UDID"
    echo "【红】没选测试设备（SW_IOS_UDID 为空，先 s2a_device 1|2），读不了电量，这局不跑" >&2; return 2; fi
  if [ $rc = 3 ]; then
    echo "$now 本机缺工具" >> "$log"; DEVBATTERY_LINE="电量 读不了：本机缺 timeout 或 ideviceinfo"
    echo "【红】本机缺读电量要用的命令：timeout（brew install coreutils）$(command -v timeout gtimeout > /dev/null && echo 有 || echo 没有)，ideviceinfo（brew install libimobiledevice）$(command -v ideviceinfo > /dev/null && echo 有 || echo 没有)。与设备无关，装好再跑" >&2; return 3; fi
  if [ $rc = 6 ]; then
    echo "$now USB 读不到、无新鲜 App 读数，交局内判" >> "$log"; DEVBATTERY_LINE="电量 USB 读不到（网络连接），交执行器局内判：开局 ≥ ${DEVBATTERY_RESUME}%、局中 < ${DEVBATTERY_LOW}% 停局"
    [ -f "$flag" ] && { echo "【红】测试设备电量暂停中（标记 ${flag}：$(head -1 "$flag")），没有新读数确认回到 ${DEVBATTERY_RESUME}%，这局不跑" >&2; return 1; }
    return 0; fi
  if [ $rc != 0 ]; then
    # 11-12 维护者：读不到电量只记一行、照跑，不拦（测试设备2 只走局域网，ideviceinfo 两条都不通，原先一直拒跑、设备闲着）。
    #   设备真离线由后面的 devicectl 装机 / 起局自己报；读得到的低电量照旧拦
    echo "$now 读不到（照跑）" >> "$log"; DEVBATTERY_LINE="电量 读不到（照跑）"
    echo "【黄】测试设备电量读不到（ideviceinfo USB / 网络都不通，局域网连接的设备常见），照跑" >&2; return 0; fi
  read -r p c e f <<<"$r"; f=${f:-0}
  DEVBATTERY_LINE="电量 ${p}%（$([ "$c" = 1 ] && echo 充电 || echo 未充电)，电源 $([ "$e" = 1 ] && echo 有 || echo 无)）"
  echo "$now $p% 充电=$c 电源=$e 充满=$f" >> "$log"
  [ "$e" = 1 ] && [ "$c" = 0 ] && [ "$f" = 0 ] && [ "$p" -lt "${DEVBATTERY_NOCHARGE:-90}" ] && echo "【红】测试设备插着电源却没在充（${p}%）：供电跟不上，局照跑，请换充电头 / 线" >&2
  if [ "$e" = 1 ]; then   # 接着电源：只看当场读数，不看暂停标记（维护者 10-20）
    if [ "$p" -ge "$DEVBATTERY_CHARGING_MIN" ]; then [ -f "$flag" ] && { rm -f "$flag"; echo "测试设备接着电源、电量 ${p}%（≥ ${DEVBATTERY_CHARGING_MIN}%）：撤掉暂停标记，真机局放行" >&2; }; return 0; fi
    echo "【红】测试设备接着电源但电量 ${p}% 低于 ${DEVBATTERY_CHARGING_MIN}%：这局不跑" >&2; return 1
  fi
  if [ -f "$flag" ]; then
    if [ "$p" -ge "$DEVBATTERY_RESUME" ]; then rm -f "$flag"; echo "测试设备电量回到 ${p}%（≥ ${DEVBATTERY_RESUME}%），撤掉暂停标记，真机局放行" >&2
    else echo "【红】测试设备电量暂停中：现 ${p}%，充到 ${DEVBATTERY_RESUME}% 才放行（标记 ${flag}：$(head -1 "$flag")）" >&2; return 1; fi
  elif [ "$p" -lt "$DEVBATTERY_LOW" ]; then
    echo "$now 电量 ${p}% 充电=$c 电源=$e" > "$flag"
    echo "【红】测试设备电量 ${p}% 低于 ${DEVBATTERY_LOW}%：暂停全部真机局，充到 ${DEVBATTERY_RESUME}% 再放行（标记 ${flag}）" >&2
    devbattery_notify "测试设备电量 ${p}%，真机局已暂停，充到 ${DEVBATTERY_RESUME}% 放行"; return 1
  fi
  return 0
}
devbattery_notify() {   # 记进 battery.log 与 device_alert.txt（巡检读这个文件；不用系统通知：osascript 首次会弹权限框）
  echo "$(date '+%m-%d %H:%M:%S') 通知：$1" | tee -a "$DEVBATTERY_DIR/battery.log" >> "$DEVBATTERY_DIR/device_alert.txt"
}
