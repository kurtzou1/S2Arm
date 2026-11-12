# S2Arm 测试设备名单与选机（source 本文件后 s2a_device <1|2|3|any|iphone|duo|UDID|CoreDevice 标识>）。
# 11-06 维护者：「测试设备1和2和 Duo 都能用，做成负载均衡的吧。各线也可以指定要在 iPhone 17 Pro Max（2台配置一模一样）还是 Duo 上做」：
#   名单每行第 7 列是机型类（iphone = 测试设备1 / 2 两台 17 Pro Max，duo = Duo；没写按名字认，见 _s2a_cls）；s2a_device 收到 any / iphone / duo 时由 s2a_device_pick 在该类里挑最闲的那台
#   （负载 = 锁有人持 + 排队号数 + 刚选中还没取锁的占位；同负载先挑已装这款容器的那台，再挑机号小的），选中后导出 DEVNUM=<机号>，调用方把 DEV 改成它。
# 设备只认两台测试设备（贡献者自己的设备：S2A_DEVICE_OWN=1，见 s2a_device 末段）；日常手机永远拒绝。真机硬件标识不进仓库：
#   复制 tools/machine.local.example 为 tools/machine.local，填 S2A_DEVICES_LOCAL / S2A_DAILY_PHONE_LOCAL。
#   单测设 S2A_DEVICES_NO_LOCAL=1，强制用下面的占位标识。占位取全 0 的 UDID 形状（不用中文代号：dev_run.sh 按 [0-9A-Fa-f-] 取 devicectl 报的
#   硬件 UDID，中文代号取不到，单测就测不到白名单真路径）；没有 machine.local 时选中的也是占位，devicectl 找不到设备、当场红。
# 选中后导出：SW_DEVICE（CoreDevice 标识，devicectl 用）、SW_IOS_UDID（硬件 UDID，ideviceinfo 用）、DEVNAME、
#   SW_DEVLOCK_DIR / SW_DEVLOCK_QUEUE / SW_DEVBATTERY_LOCKS / DEVBATTERY_DIR（该机的锁与电量闸目录）。
# 锁目录沿用旧库 / 研究员正在用的那两把（10-19 核过 维护方工具），新旧工具同时上机也互斥：
#   测试设备1 在本机：~/sw-work/run/ios/device.lock；测试设备2 在 gate-host：~/.s2arm/run/devq2/device2.lock。
# 选机前核 devicectl 看得到（11-12 维护者：测试设备2 只走局域网（devicectl：connected / localNetwork），idevice_id -l 看不到它，原先「必须在本机 USB 上」让它永远挑不中）：
#   USB 或局域网都算，devicectl list devices 里这台是 available / connected 即可；电量闸读不到电量时只记一行、照跑（tools/devbattery.sh）。S2A_DEVICE_NO_USB_CHECK=1 跳过（单测用）；
#   S2A_DEVICECTL_LIST=<命令> 换掉 devicectl 列表（单测用）
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/machine.sh"
_S2A_DEV_CODE_PHONE=00000000-0000000000000000
_S2A_DEV_CODE_LIST="1|测试设备1|00000000-0000000000000001|00000000-0000-0000-0000-000000000001|$HOME/sw-work/run/ios/device.lock|$HOME/sw-work/run/ios|iphone
2|测试设备2|00000000-0000000000000002|00000000-0000-0000-0000-000000000002|${S2A_RUN_ROOT:-$HOME/.s2arm/run}/devq2/device2.lock|${S2A_RUN_ROOT:-$HOME/.s2arm/run}/devq2/battery|iphone
3|Duo|00000000-0000000000000003|00000000-0000-0000-0000-000000000003|$HOME/.s2arm/devices/00000000-0000000000000003/device.lock|$HOME/.s2arm/devices/00000000-0000000000000003/battery|duo"
if [ "${S2A_DEVICES_NO_LOCAL:-0}" = 1 ]; then
  S2A_DAILY_PHONE=$_S2A_DEV_CODE_PHONE; S2A_DEVICES=$_S2A_DEV_CODE_LIST
else
  : "${S2A_DAILY_PHONE:=$_S2A_DEV_CODE_PHONE}"
  if [ -z "${S2A_DEVICES:-}" ]; then S2A_DEVICES=$_S2A_DEV_CODE_LIST; fi
  [ -n "${S2A_DAILY_PHONE_LOCAL:-}" ] && S2A_DAILY_PHONE=$S2A_DAILY_PHONE_LOCAL
  [ -n "${S2A_DEVICES_LOCAL:-}" ] && S2A_DEVICES=$S2A_DEVICES_LOCAL
fi
unset _S2A_DEV_CODE_PHONE _S2A_DEV_CODE_LIST
# 机型类：名单第 7 列；没写（tools/machine.local 沿用 6 列，旧版本脚本只读 6 列、加列会把它粘进电量目录）按名字认：名字含 Duo = duo，其余 = iphone
_s2a_cls() { [ -n "$2" ] && { echo "$2"; return; }; case $1 in *Duo*|*duo*) echo duo;; *) echo iphone;; esac; }
# 名单里的机号：s2a_device_ids <any|iphone|duo|机号|名字>（any = 全部；iphone / duo = 该机型类；机号 / 名字 = 它自己）
s2a_device_ids() {
  local spec=${1:-any} n name udid cd lock bdir cls
  while IFS='|' read -r n name udid cd lock bdir cls; do [ -n "$n" ] || continue
    case $spec in any) echo "$n";; iphone|duo) [ "$(_s2a_cls "$name" "$cls")" = "$spec" ] && echo "$n";; *) { [ "$spec" = "$n" ] || [ "$spec" = "$name" ]; } && echo "$n";; esac
  done <<< "$S2A_DEVICES"; }
s2a_device_class() { local n name udid cd lock bdir cls; while IFS='|' read -r n name udid cd lock bdir cls; do [ "$1" = "$n" ] && { _s2a_cls "$name" "$cls"; return 0; }; done <<< "$S2A_DEVICES"; return 1; }
s2a_device_field() {   # s2a_device_field <机号> <udid|lock|name>
  local n name udid cd lock bdir cls; while IFS='|' read -r n name udid cd lock bdir cls; do [ "$1" = "$n" ] || continue
    [ -n "${S2A_TEST_ROOT:-}" ] && lock=$S2A_TEST_ROOT/$(basename "$lock")
    case $2 in udid) echo "$udid";; lock) echo "$lock";; name) echo "$name";; esac; return 0; done <<< "$S2A_DEVICES"; return 1; }
# 负载：s2a_device_load <机号> → 整数 = 锁有活人持（锁目录 pid 活着）+ 活排队号数 + 活占位数（s2a_device_pick 选中、还没取锁的调用方；同 pid 已排号 / 持锁的不重复算）
s2a_device_load() {
  local L q c p ts d n=0 seen=; L=$(s2a_device_field "$1" lock) || { echo 99; return; }; q=${L%.lock}.queue; c=${L%.lock}.claim
  p=$(cat "$L/pid" 2> /dev/null); [ -n "$p" ] && kill -0 "$p" 2> /dev/null && { n=$((n + 1)); seen=" $p "; }
  for d in "$q"/*; do [ -d "$d" ] || continue; p=${d##*_}; kill -0 "$p" 2> /dev/null || continue; n=$((n + 1)); seen="$seen $p "; done
  for d in "$c"/*; do [ -e "$d" ] || continue; p=${d##*/}; ts=${p#*_}; p=${p%%_*}   # 占位名 = <pid>_<建时纪元秒>
    { kill -0 "$p" 2> /dev/null && [ $(( $(date +%s) - ${ts:-0} )) -lt "${S2A_DEVICE_CLAIM_S:-600}" ]; } || { rm -rf "$d"; continue; }
    case $seen in *" $p "*) ;; *) n=$((n + 1));; esac; done
  echo "$n"; }
# 选机：s2a_device_pick <any|iphone|duo> [包名] → 打出机号。候选 = 该类里在本机 USB 上的（单测 S2A_DEVICE_NO_USB_CHECK=1 不核）、调度没暂停的（sched/pause/<机号>）；
#   按（负载，没装这款容器，机号）取最小；同包名的容器记录 = 调度的现装登记 <调度目录>/installed/<机号>_<包名>（记忆 place-game-on-device-with-container-1102）。
#   选中即在 <锁>.claim/ 记一个占位（调用方 pid），取锁排号时 维护方工具 清掉；两家同时选不会挤到同一台（选机整段在 ~/.s2arm/devpick 互斥里）
_s2a_dc_list() {   # devicectl 看得到的设备列表（一行一台，原文）；本机没 timeout 时直接跑
  if [ -n "${S2A_DEVICECTL_LIST:-}" ]; then bash -c "$S2A_DEVICECTL_LIST" 2> /dev/null; return; fi
  local tb; tb=$(command -v timeout || command -v gtimeout)
  ${tb:+$tb 30} xcrun devicectl list devices 2> /dev/null; }
_s2a_dc_seen() { printf '%s\n' "$1" | grep -F -- "$2" | grep -qE 'available|connected'; }   # <列表> <UDID>
s2a_device_pick() {
  local spec=${1:-any} b=${2:-} sd=${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched} n best= bk= k ld u p mx=${S2A_DEVICE_PICK_LOCK:-$HOME/.s2arm/devpick} i L
  [ -n "${S2A_TEST_ROOT:-}" ] && mx=$S2A_TEST_ROOT/devpick
  mkdir -p "${mx%/*}"; for i in $(seq 100); do mkdir "$mx" 2> /dev/null && break; p=$(cat "$mx/pid" 2> /dev/null); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$mx"; sleep 0.1; done; echo $$ > "$mx/pid" 2> /dev/null
  local dcl=; [ "${S2A_DEVICE_NO_USB_CHECK:-0}" != 1 ] && dcl=$(_s2a_dc_list)
  for n in $(s2a_device_ids "$spec"); do
    [ -f "$sd/pause/$n" ] && continue
    if [ "${S2A_DEVICE_NO_USB_CHECK:-0}" != 1 ]; then u=$(s2a_device_field "$n" udid); _s2a_dc_seen "$dcl" "$u" || continue; fi
    ld=$(s2a_device_load "$n"); k=$(printf '%04d%d%02d' "$ld" "$([ -n "$b" ] && [ -f "$sd/installed/${n}_$b" ] && echo 0 || echo 1)" "$n")
    { [ -z "$bk" ] || [ "$k" \< "$bk" ]; } && { bk=$k; best=$n; }
  done
  if [ -n "$best" ]; then L=$(s2a_device_field "$best" lock); mkdir -p "${L%.lock}.claim"; : > "${L%.lock}.claim/$$_$(date +%s)"; fi
  rm -rf "$mx"; [ -n "$best" ] || { echo "【红】没有可用的 ${spec} 测试设备（都不在 devicectl 列表里（USB / 局域网都没连上）或调度暂停中）" >&2; return 1; }
  echo "$best"; }
s2a_device() {
  local want=${1:?s2a_device <1|2|3|any|iphone|duo|UDID|CoreDevice 标识>} line n name udid cd lock bdir cls
  case $want in any|iphone|duo) want=$(s2a_device_pick "$want" "${2:-${BUNDLE:-}}") || return 1;; esac
  if [ "$want" = "$S2A_DAILY_PHONE" ]; then echo "【红】$want 是日常手机，不碰" >&2; return 1; fi
  while IFS='|' read -r n name udid cd lock bdir cls; do
    [ "$want" = "$n" ] || [ "$want" = "$name" ] || [ "$want" = "$udid" ] || [ "$want" = "$cd" ] || continue
    if [ "${S2A_DEVICE_NO_USB_CHECK:-0}" != 1 ]; then
      _s2a_dc_seen "$(_s2a_dc_list)" "$udid" || { echo "【红】${name}（${udid}）devicectl 看不到（USB 和局域网都没连上），换一台或先把它连上" >&2; return 1; }
    fi
    [ -n "${S2A_TEST_ROOT:-}" ] && { lock=$S2A_TEST_ROOT/$(basename "$lock"); bdir=$S2A_TEST_ROOT/battery; }   # 单测：锁与电量目录落临时目录，不碰真锁
    mkdir -p "${lock%/*}" 2> /dev/null
    export SW_DEVICE=$cd SW_IOS_UDID=$udid DEVNAME=$name DEVNUM=$n DEVCLASS=$(_s2a_cls "$name" "$cls") SW_DEVLOCK_DIR=$lock SW_DEVLOCK_QUEUE=${lock%.lock}.queue SW_DEVBATTERY_LOCKS=$lock DEVBATTERY_DIR=$bdir
    return 0
  done <<< "$S2A_DEVICES"
  # 贡献者自己的设备（10-29 维护者 出差：开发者自查自修，用自己的 iPhone 起局、拉回读数）：显式 S2A_DEVICE_OWN=1 才开，不读我方设备表、不经调度器——
  #   名单外的 <want> 按硬件 UDID / CoreDevice 标识 / 设备名，在本机 devicectl 列出的已配对实体 iOS 设备里找，恰好一台才用（同名多台要求改用 UDID）；
  #   日常手机照样拒。锁与电量目录放 S2A_OWN_DEV_ROOT（缺省 ~/.s2arm/devices）/<UDID>/；选中的这台补进 S2A_DEVICES，执行器的白名单核对照常过
  if [ "${S2A_DEVICE_OWN:-0}" = 1 ]; then
    local js r; js=$(mktemp); ${S2A_DEVICECTL:-xcrun devicectl} list devices --json-output "$js" > /dev/null 2>&1
    r=$(python3 - "$js" "$want" <<'PY'
import json, sys
js, want = sys.argv[1:]
try: ds = json.load(open(js))['result']['devices']
except Exception: ds = []
hit = []
for x in ds:
    hp, dp, cp = x.get('hardwareProperties', {}), x.get('deviceProperties', {}), x.get('connectionProperties', {})
    if hp.get('reality') != 'physical' or hp.get('platform') != 'iOS' or cp.get('pairingState') != 'paired': continue
    if want in (hp.get('udid'), x.get('identifier'), dp.get('name')): hit.append('|'.join((dp.get('name', ''), hp.get('udid', ''), x.get('identifier', ''))))
print(hit[0] if len(hit) == 1 else '#%d' % len(hit))
PY
)
    rm -f "$js"
    case $r in
      '#0') echo "【红】S2A_DEVICE_OWN=1：本机已配对的实体 iOS 设备里没有 ${want}（按 UDID / CoreDevice 标识 / 设备名找，xcrun devicectl list devices 看）" >&2; return 1;;
      '#'*) echo "【红】S2A_DEVICE_OWN=1：$want 对上 ${r#\#} 台设备，改用 UDID 指定" >&2; return 1;;
    esac
    IFS='|' read -r name udid cd <<< "$r"
    if [ "$udid" = "$S2A_DAILY_PHONE" ] || [ "$cd" = "$S2A_DAILY_PHONE" ]; then echo "【红】${want}（${udid}）是日常手机，不碰" >&2; return 1; fi
    command -v idevice_id > /dev/null && ! idevice_id -l 2>/dev/null | grep -qx "$udid" && echo "【黄】${name}（${udid}）不在本机 USB 上：局照跑，功耗读数（pw*.plist）要 USB 连接才有" >&2
    command -v idevice_id > /dev/null || echo "【黄】本机缺 libimobiledevice（brew install libimobiledevice）：局照跑，功耗读数（pw*.plist）和电量闸读不到" >&2
    lock=${S2A_OWN_DEV_ROOT:-$HOME/.s2arm/devices}/$udid/device.lock; bdir=${lock%/*}/battery
    [ -n "${S2A_TEST_ROOT:-}" ] && { lock=$S2A_TEST_ROOT/own_$udid.lock; bdir=$S2A_TEST_ROOT/battery; }
    mkdir -p "${lock%/*}" "$bdir"
    S2A_DEVICES="$S2A_DEVICES"$'\n'"own|$name|$udid|$cd|$lock|$bdir"
    export S2A_DEVICES SW_DEVICE=$cd SW_IOS_UDID=$udid DEVNAME=$name SW_DEVLOCK_DIR=$lock SW_DEVLOCK_QUEUE=${lock%.lock}.queue SW_DEVBATTERY_LOCKS=$lock DEVBATTERY_DIR=$bdir
    return 0
  fi
  echo "【红】设备 $want 不在测试设备名单（只认测试设备1 / 测试设备2 / Duo，或 any / iphone / duo；贡献者用自己的设备设 S2A_DEVICE_OWN=1），不碰" >&2; return 1
}
# 白名单核对（执行器在任何 devicectl 动作前调）：$1 是 CoreDevice 标识或硬件 UDID
s2a_device_allowed() {
  [ -n "${1:-}" ] && [ "$1" != "$S2A_DAILY_PHONE" ] && printf '%s\n' "$S2A_DEVICES" | awk -F'|' -v d="$1" '$3==d||$4==d{f=1} END{exit !f}'
}
