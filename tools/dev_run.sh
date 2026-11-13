#!/bin/bash
# S2Arm 真机执行器：tools/dev_run.sh <作业目录>   （在连着那台测试设备的 Mac 上跑：测试设备1 本机、测试设备2 gate-host）
# 底本：旧库 tools/dev_newarch_run.sh @20887cc。只认资源包 v2；App 侧标记 / 环境 / Documents 布局见 tests/真机契约.md。
#
# 作业目录：job.env + *.ipa + pack/（资源包 v2：manifest.json index.tsv 与按包内路径放的文件）+ 可选 save/（device/ account/）system_time pso.metallib
# job.env 键：
#   DEV=1|2|3|iphone|duo|any  测试设备（tools/devices.sh 名单：1 / 2 = 两台 17 Pro Max，3 = Duo；iphone / duo / any = 该类里挑最闲的那台；名单外 / 日常手机一律拒绝）；贡献者自己的 iPhone：DEV=<UDID 或设备名，带空格加引号：DEV='我的 iPhone'> 且环境 S2A_DEVICE_OWN=1（不经调度器，产物同测试设备局）
#   BUNDLE=<包名>       必须等于 ipa 的 CFBundleIdentifier
#   ACT_S=60 MARK 后采多少秒收局；ARRIVE_S=<秒> 多久没 MARK 判红（缺省 = 测试段剩余）。不给 App 传帧率（10-21 维护者：游戏按自己请求的交换间隔跑，判据从 host.log「帧节拍」行取）
#   UNINSTALL=0|1      1 = 先卸载（冷容器）；COLD=1 起局带 S2A_COLD_START=1（首局）
#   ENVJSON='"K":"V",…' 额外起局环境（有就是诊断局，记分板不写，调用方负责）
#   GAME / COST_LINE / COST_WHY 款名、线名、为什么跑（调度填，进成本账本 维护方工具）
#   PULL="<Documents 下相对路径> …" 额外拉回；PUSH="<作业内路径>:<Documents 下路径> …" 额外推送
#   FS_STOP=1          host.log 一出「【红】出图未满屏」当场停局
#   CAP_S=300|600      测试段上限（调度按款填：010074F013262000 600，其余 300；别的值按 300）
#   SMOKE=1            登记冒烟：部署后起 App 看 30 秒进程在不在就收（RESULT=smoke-ok / smoke），不跑局
# 两段看门（硬上限，不留开关）：部署段（取锁 → 装包 → 推送）≤ DCAP=900 秒；测试段（起局 → 收局拉回）≤ CAP=300 秒（job.env CAP_S，只有 010074F013262000 由调度填 600）。到点杀局、放锁、判红。
# 出错即停：起局 30 秒 host.log 仍空；60 秒没有「S2A 就绪」；60 秒没出帧；出帧后 10 秒不前进；电量开局 < 60% 或局中 < 30%（未充电）。
# 结果：<作业目录>/out_<时刻>/（run.log timing.tsv host.log frames.tsv gate.txt …），最后一行 RESULT=done|red|suspect|skip|lock|install|push|deployed|smoke-ok|smoke out=… reason=…
#   suspect = 局中测试设备前台失焦（系统弹框挡着 App）：不给绿也不记红，记分格按局无效（tools/score_cells.py infra）
#   skip = 前置条件没满足、没真跑（电量闸、设备不可用）：不是游戏 / 包的红，调度不打分、不进记分板、不计补位次数（10-23 两台拔电，电量闸停的局被记成能玩红、误判掉 M2）
set -u
J=$(cd "${1:?作业目录}" && pwd -P); TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# 工作盘准入（11-06 维护者：真机局拉回截图 / 录像 / 日志落作业目录，排同一本账；单测给 S2A_DISK_HELD=1 跳过）
. "$TOOLS/disk_admit_gate.sh"; disk_admit_gate 真机局 "$(basename "$J")" "$J" "$0" "$@"
. "$J/job.env"
O=$J/out_$(date +%m%d%H%M%S); mkdir -p "$O"
t() { echo "[$(date +%T)] $*" | tee -a "$O/run.log"; }
# 统一账本（11-04 能耗线）：进了测试段的局（done / red / suspect）收局时把帧率 / GPU 时间 / 整机功率 / 热状态 / 内存足迹记一行进 维护方工具 的账本，
#   不论红绿、满不满屏（五问格会把读数压成「—」）；写不成只记黄、不改结论
#   账本 ${S2A_DEVICE_LEDGER:-${S2A_RUN_ROOT:-~/.s2arm/run}维护方工具/ledger.tsv}；同成本账本约定，单测（S2A_TEST_ROOT 设了）没显式给 S2A_DEVICE_LEDGER 就不记
ledger() { case $1 in done|red|suspect) ;; *) return 0;; esac; [ -n "${T_PUSH:-}" ] || return 0; local s
  [ -n "${S2A_TEST_ROOT:-}" ] && [ -z "${S2A_DEVICE_LEDGER:-}" ] && return 0
  [ -n "${S2A_PRIVATE_TOOLS:-}" ] || return 0   # 统一账本是维护方设施
  s=$(timeout 60 python3 "$S2A_PRIVATE_TOOLS/device_ledger.py" "$O" --ledger="${S2A_DEVICE_LEDGER:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/device_ledger/ledger.tsv}" --result="$1" --why="${2:-}" --dev="${DEVNAME:-${D:-}}" 2>> "$O/ledger.err") && t "$s" || t "【黄】统一账本没写成（见 $O/ledger.err）"; }
fin() { disarm; ledger "$1" "${2:-}"; cost_log iphone "${GAME:-${BUNDLE:-?}}" $(( $(date +%s) - ${T_REQ:-$(date +%s)} )) "$1${2:+ $2}" "$O"; echo "RESULT=$1 out=$O${2:+ reason=$2}"; exit "${3:-1}"; }   # 每局记成本账本（线 / 为什么来自 job.env 的 COST_LINE / COST_WHY）
DC=${S2A_DEVICECTL:-xcrun devicectl}   # 单测注入假 devicectl
# devicectl 一律用它自带的 --timeout：到点由 CoreDeviceService 撤掉这次操作。外层 timeout 只在 devicectl 自己卡死时兜底（多给 S2A_DC_MARGIN 秒）。
#   10-20 实证：从外面杀正在传文件的 devicectl（撞 300 秒硬上限杀进程树），下一局通道挂死 10/28（正常收局后 1/54），挂上后不自愈、要重启手机。超时统一返回 124
dcp() { local T=$1 s0=$SECONDS r; shift; timeout $((T + ${S2A_DC_MARGIN:-30})) $DC "$@" --timeout "$T"; r=$?; [ $r != 0 ] && [ $((SECONDS - s0)) -ge "$T" ] && r=124; return $r; }

source "$TOOLS/devices.sh"
cost_log() { :; }; [ -z "${S2A_PRIVATE_TOOLS:-}" ] || source "$S2A_PRIVATE_TOOLS/cost_log.sh"
source "$TOOLS/gpu_hang.sh"   # GPU 卡死签名（局中判红即停；各线真机脚本复用同一份）
source "$TOOLS/devwatch.sh"   # 硬上限看门狗 arm / disarm（到点 TERM，宽限后仍在就按管道强杀，11-04）
s2a_device "${DEV:?job.env 缺 DEV}" 2> >(tee -a "$O/run.log" >&2) || fin skip "设备 $DEV 不可用（见 run.log）"
case $DEV in any|iphone|duo) t "选机：DEV=${DEV} → 测试设备 ${DEVNUM}（${DEVNAME}，负载均衡）"; DEV=$DEVNUM;; esac   # 后面的现装登记 / 记录名按具体机号
D=$SW_DEVICE; UD=$SW_IOS_UDID; B=${BUNDLE:?job.env 缺 BUNDLE}; BD=$DEVBATTERY_DIR; mkdir -p "$BD"
# 设备通道挂起：devicectl 拷完不退出（10-20 测试设备2：18 字节 app.id 写完挂 14.5 分钟；拉 host.log 挂满 206 秒）。拷贝幂等 → 超时按大小定、超时重试一次
cpto() {   # 超时 = S2A_CP_T0（缺省 60）秒 + 每 10 MB 1 秒（实测推送约 33 MB/s，留 3 倍余量）
  local c0=$SECONDS r i T=$(( ${S2A_CP_T0:-60} + $(du -sk "$1" 2>/dev/null | cut -f1) / 10240 ))
  for i in 1 2; do
    dcp "$T" device copy to --device "$D" --domain-type appDataContainer --domain-identifier "$B" --source "$1" --destination "$2" >> "$O/cp.log" 2>&1; r=$?
    [ $r = 124 ] || break; echo "[$(date +%T)] 挂：推 $2 超 ${T} 秒（第 $i 次）" >> "$O/slow_devicectl.log"
  done
  [ $((SECONDS - c0)) -ge 20 ] && echo "[$(date +%T)] 慢：推 $2 用了 $((SECONDS - c0)) 秒（rc=${r}）" >> "$O/slow_devicectl.log"
  return $r
}
# 推完在机上逐文件核（10-26 运维线：八方2 推存档 cpto 返回成功、devicectl 没报错，机上却少了 4 MB 的 account/MJSaveData1，游戏读档那一刻退回标题）：
#   本地的「相对路径 大小」与机上 device info files --json-output 列出的文件逐条比（目录：递归比全部文件；单个文件：列它所在目录、按名字比），缺 / 大小不同就重推一次，
#   再不一致返回 1（调用方 fin push 报红）。不一致明细写 $O/vpush.diff
vpush() {   # vpush <本地文件或目录> <机上路径>
  local src=$1 dst=$2 sub i; [ -d "$src" ] && sub=$dst || sub=$(dirname "$dst")
  for i in 1 2; do
    cpto "$src" "$dst" || return 1
    dcp 60 device info files --device "$D" --domain-type appDataContainer --domain-identifier "$B" --subdirectory "$sub" --json-output "$O/vpush.json" > /dev/null 2>&1 \
      && python3 - "$src" "$dst" "$O/vpush.json" > "$O/vpush.diff" <<'PY' && return 0
import json, os, sys
src, dst, js = sys.argv[1:]
got = {f['relativePath']: f['metadata']['size'] for f in json.load(open(js))['result']['files'] if not f.get('resources', {}).get('isDirectory')}
if os.path.isdir(src):
    want = {os.path.relpath(os.path.join(d, n), src): os.path.getsize(os.path.join(d, n)) for d, _, fs in os.walk(src) for n in fs}
else:
    want = {os.path.basename(dst): os.path.getsize(src)}; got = {k: v for k, v in got.items() if k == os.path.basename(dst)}
bad = [f'{k}：本地 {v} 字节，机上{"没有" if k not in got else " " + str(got[k]) + " 字节"}' for k, v in sorted(want.items()) if got.get(k) != v]
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
    t "推 $dst 后机上核对不符（第 $i 次）：$(head -3 "$O/vpush.diff" 2> /dev/null | tr '\n' '；')"
  done; return 1
}
cpfrom() {   # 慢调用记日志（10-19 测试设备1：起局后首次拉文件等隧道 2 分 41 秒，根因未定）；调用方没给 CPF_T 时超时 120 秒、挂了重试一次
  local c0=$SECONDS r i n=2; [ -n "${CPF_T:-}" ] && n=1
  for i in $(seq 1 $n); do
    dcp "${CPF_T:-120}" device copy from --device "$D" --domain-type appDataContainer --domain-identifier "$B" --source "$1" --destination "$2" >> "$O/cpf.log" 2>&1; r=$?
    [ $r = 124 ] || break
  done
  [ $((SECONDS - c0)) -ge 20 ] && echo "[$(date +%T)] 慢：拉 $1 用了 $((SECONDS - c0)) 秒（rc=${r}）" >> "$O/slow_devicectl.log"
  return $r
}
scr() {   # 整屏截图 → $O/screen/<名>.png（10-21 维护者：看最终上屏效果 / 挂死时屏上有没有弹窗）；失败只记一行，不影响局结论
  # 截亮着的那块屏（11-07 性能线 A：Duo 两块屏，primary 是背光关着的 LCD，不带 --display-unique-id 截的就是它 = 全黑）：每次截前列一次屏，取 active 的 uniqueId；
  #   列不出 / 单屏机（primary 就是 active）照旧不带参数
  local u; mkdir -p "$O/screen"; u=$(dcp 20 device info displays --device "$D" --json-output "$O/screen/displays.json" > /dev/null 2>&1 && python3 -c 'import json, sys
print(next((d["uniqueId"] for d in json.load(open(sys.argv[1]))["result"]["displays"] if d.get("active")), ""))' "$O/screen/displays.json" 2> /dev/null)
  dcp 30 device capture screenshot --device "$D" ${u:+--display-unique-id "$u"} --destination "$O/screen/$1.png" >> "$O/screen.log" 2>&1 && [ -s "$O/screen/$1.png" ] || { rm -f "$O/screen/$1.png"; t "截屏 $1 失败（见 screen.log）"; return 0; }
}
probe_from() {   # 开局第一次拉文件当通道探针：超时重试一次，还超时判红——不白等 600 秒
  # 不重启 CoreDeviceService（10-20 全天重启 26 次只救回 5 次，且两台手机共用这个服务：一台的执行器重启它，打断了另一台正在推的包，留下截短残包）；
  # 也不再按机上有 SoftwareUpdateUIService 判「更新提示挡住」并停机（10-20 22:1x 反例：开着它拉文件照样 1 秒返回）
  local r; CPF_T=${S2A_PROBE_T:-60} cpfrom "$1" "$2"; r=$?; [ $r = 124 ] || return $r
  t "【黄】开局拉 $1 超 ${S2A_PROBE_T:-60} 秒（设备通道挂住），重试一次"
  CPF_T=${S2A_PROBE_T:-60} cpfrom "$1" "$2"; r=$?
  # 10-21 定因：手机端文件服务卡住，几分钟到十几分钟自己恢复（调度冷却后再派）；截一张屏看屏上有没有弹窗（截屏走别的服务，文件服务挂着也能截）
  [ $r = 124 ] && { scr hang; fin red "设备通道挂死：开局拉 $1 两次各超 ${S2A_PROBE_T:-60} 秒（手机端文件服务卡住，通常几分钟到十几分钟自己恢复$([ -s "$O/screen/hang.png" ] && echo "；屏幕截图见 screen/hang.png")）"; }
  return $r
}
vk_spv_keep() {   # vk_spv_keep <拉回的 vk/ 目录> <程序号大写>：Vulkan 首遇现编存下的游戏 SPIR-V（<键>.spv）并进 pso_seed/<程序号>/vk_spv/（已有同名不覆盖），下次出包翻进离线库（11-05）
  local n=0 f d=${S2A_PSO_SEED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/pso_seed}/$2/vk_spv
  for f in "$1"/*.spv; do [ -s "$f" ] || continue; mkdir -p "$d"; [ -e "$d/${f##*/}" ] || { cp "$f" "$d/${f##*/}.tmp" && mv "$d/${f##*/}.tmp" "$d/${f##*/}" && n=$((n + 1)); }; done
  [ "$n" = 0 ] || t "Vulkan 现编 SPIR-V：新收 ${n} 支 → pso_seed/$2/vk_spv/"
}
pso_keep() {   # pso_keep <拉回的 pso_user.tsv> <标签>：非空就按时间戳存一份进 pso_seed/<程序号>/（出库时 graphics/tools/direct/pso_seed.py 跨文件按行去重合并）；空 / 没有只记一行、不判红
  local u; u=$(echo "$TIDL" | tr 'a-f' 'A-F')
  if [ -s "$1" ]; then local d=${S2A_PSO_SEED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/pso_seed}/$u f; f=$(basename "$J")_${O##*_}_$2.tsv; mkdir -p "$d"
    cp "$1" "$d/$f.tmp" && mv "$d/$f.tmp" "$d/$f"; t "管线种子来源（$2）：拉回 pso_user.tsv $(grep -c . "$1") 行 → pso_seed/$u/$f"
  else rm -f "$1"; t "管线种子来源（$2）：机上没有 wire/$u/pso_user.tsv（没装过 / 通用模式局 / 没建过管线）"; fi
}
deadlog() {   # App 起来就退出时先把机上 host.log 拉回（10-23 010074F013262000 冒烟 5 秒退出、什么证据都没留）：限 30 秒拉一次，打出最能说明问题的一行（【红】/ CRASH 优先，否则末行）
  CPF_T=30 cpfrom Documents/host.log "$O/host.log" && [ -s "$O/host.log" ] || { echo "host.log 没拉回"; return 0; }
  local l; l=$(LC_ALL=C /usr/bin/grep -aE '【红】|CRASH' "$O/host.log" | tail -1); [ -n "$l" ] || l=$(LC_ALL=C /usr/bin/grep -av '^[[:space:]]*$' "$O/host.log" | tail -1)
  echo "host.log 末要：$(cut -c1-160 <<< "$l")"
}
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d[int(k)] if isinstance(d,list) else d[k]
print(d)" "$1" "$2" 2>/dev/null; }

export SW_DEVBATTERY_INRUN=1   # 拔电走网络时电量闸交局内判
devlock_acquire() { :; }; devlock_release() { :; }; devlock_extend() { :; }; [ -z "${S2A_PRIVATE_TOOLS:-}" ] || source "$S2A_PRIVATE_TOOLS/devlock.sh"   # 设备锁是维护方多线共用设施：贡献者单人单机不上锁
DCAP=900; CAP=${CAP_S:-300}; case $CAP in 300|600) ;; *) CAP=300;; esac; T_REQ=$(date +%s)   # CAP_S 调度按款填（只有 010074F013262000 600，见 维护方工具），别的值一律按 300
devlock_acquire "真机局 $(basename "$J")（${DEVNAME}，部署 ≤ ${DCAP} 秒 + 测试 ≤ ${CAP} 秒）" $((DCAP + CAP)) || { t "等不到设备锁"; fin lock "等不到设备锁"; }
trap devlock_release EXIT
T_LOCK=$(date +%s); PH=部署; CAPN=$DCAP; W0=$T_LOCK
oncap() {
  trap - TERM; disarm
  local why="${PH}段超 ${CAPN} 秒硬上限"; [ $(( $(date +%s) - W0 )) -lt "$CAPN" ] && why="被外部停局"
  t "【红】${why}（取锁后 $(( $(date +%s) - T_LOCK )) 秒），杀局、放锁，不拉回"
  [ -n "${PID:-}" ] && dcp 15 device process terminate --device "$D" --pid "$PID" > /dev/null 2>&1
  fin red "$why"
}
trap oncap TERM; arm $DCAP

# —— 部署段 ——
IPA=$(ls "$J"/*.ipa 2>/dev/null | head -1); [ -n "$IPA" ] || fin install "作业里没有 ipa"
IB=$(unzip -p "$IPA" 'Payload/*.app/Info.plist' 2>/dev/null | plutil -extract CFBundleIdentifier raw - 2>/dev/null)
[ "$IB" = "$B" ] || { t "【红】包名不符：ipa 是 ${IB:-读不出}，job.env BUNDLE=${B}（起的会是机上别的 App）"; fin red bundle; }
# 白名单二次核：devicectl 报的硬件 UDID 必须等于选中的测试设备（输出格式变了取不到 → 停，不静默跳过）
HW=$(dcp 60 device info details --device "$D" 2>/dev/null | sed -En 's/.*[Uu][Dd][Ii][Dd]: *([0-9A-Fa-f-]+).*/\1/p' | head -1)
[ "$HW" = "$UD" ] || { t "【红】devicectl 报的硬件 UDID「${HW:-取不到}」≠ 选中的 $DEVNAME ${UD}，停"; fin red whitelist; }
# 清残留（只部署时不清：人可能正在玩，10-20 维护者 试玩中被结束过一局）：起局前结束**本局要装的这个包名**的残留进程（旧库残留会拖死文件服务，10-20 测试设备1）。
#   别的包名一律不碰，哪怕是本项目测试身份（io.s2arm.* / io.s2arm-exp.*）：11-04 21:09 能耗线巫师3 基线局按「全部本项目身份」清，维护者 正在测试设备1 手测，
#   结束了机上 20 个 S2Arm 进程（out_1104210838 stale.txt）；11-02 怪猎局结束过 维护者 复测中的一款第一方动作冒险游戏、10-26 结束过银河 2。维护者 11-04 定只清本局包名。
#   取舍：10-29 真机线改清全部，是因为双人成行挂在后台、每开一款弹「查找本地网络」框（7 局判可疑）——后台别款弹框只让局判可疑（不给绿也不记红），
#   结束人正在玩的 App 不可挽回，前者让给后者。
#   按包名查各自安装路径（info apps 的 url，认 /Bundle/Application/<UUID>/ 一段：url 带 /private、进程表可能不带）
appdirs_of() {   # appdirs_of <包名…>：这些包在机上的安装路径段（/Bundle/Application/<UUID>/，一行一个）；取不到打空
  local T; T=$(mktemp); dcp 40 device info apps --device "$D" --json-output "$T" > /dev/null 2>&1
  python3 -c 'import json, sys, urllib.parse
k = "/Bundle/Application/"
for a in json.load(open(sys.argv[1]))["result"]["apps"]:
    u = urllib.parse.unquote(urllib.parse.urlparse(a.get("url") or "").path)
    b = a.get("bundleIdentifier") or ""
    if b in sys.argv[2:] and k in u: print(k + u.split(k, 1)[1].split("/", 1)[0] + "/")' "$T" "$@" 2> /dev/null; rm -f "$T"; }
procs_in() { [ -n "$1" ] || return 0; dcp 40 device info processes --device "$D" 2>/dev/null | grep -F "$1" | awk '{print $1}' | grep -E '^[0-9]+$' || true; }   # procs_in <安装路径段>：在跑的进程号
# 停进程并核实（11-07 维护者：ab_pre3d2 收局 done 后在测试设备2 上又活了约 20 分钟，金刚局随后同机起，整机卡死）：terminate → 2 秒后复查 → 还在发 SIGKILL → 再复查；
#   打出最后仍在的进程号（空 = 都没了）
kill_verify() { local d=$1 p L; L=$(procs_in "$d"); [ -n "$L" ] || return 0
  for p in $L; do dcp 15 device process terminate --device "$D" --pid "$p" > /dev/null 2>&1; done; sleep "${S2A_KILL_VERIFY_S:-2}"; L=$(procs_in "$d"); [ -n "$L" ] || return 0
  for p in $L; do dcp 15 device process signal --device "$D" --pid "$p" --signal SIGKILL > /dev/null 2>&1; done; sleep "${S2A_KILL_VERIFY_S:-2}"; procs_in "$d"; }
# 自动化起局登记 $BD/autolaunch/<UDID>/<包名>（「时刻 局目录」）：起局写、收局核实进程确实没了才删。下一局起局前，同机登记里别款包的进程一律停掉并记名——
#   只停执行器自己起过、收局没核实干净的包；人自己从主屏打开的包没有登记，照旧不碰（11-04 定案：按「全部本项目身份」清曾结束 维护者 手测中的 20 个进程）
ALR=$BD/autolaunch/$UD; mkdir -p "$ALR"
APPDIRS=$(appdirs_of "$B")
stale() { [ "${DEPLOY_ONLY:-0}" = 1 ] || [ -z "$APPDIRS" ] || dcp 40 device info processes --device "$D" 2>/dev/null | grep -F "$APPDIRS" | { [ -n "${O:-}" ] && { echo "== $(date +%T)"; } >> "$O/stale.txt"; tee -a "${O:-/dev/null}/stale.txt" 2> /dev/null || cat; } | awk '{print $1}' | grep -E '^[0-9]+$' || true; }
STALE=$(stale)
n=0; for p in $STALE; do dcp 15 device process terminate --device "$D" --pid "$p" > /dev/null 2>&1 && n=$((n + 1)); done; [ $n -gt 0 ] && t "清残留：结束本局包 $B 的残留进程 $n 个（进程路径记在 stale.txt；别的包名不碰）"
# terminate 回成功也可能没结束（10-20 测试设备2：切后台验证留下的 3 个 S2Arm 两轮 terminate 后仍在，SIGKILL 才走）：复查，还在的发 SIGKILL
if [ -n "$STALE" ]; then sleep 2; K=$(stale); for p in $K; do dcp 15 device process signal --device "$D" --pid "$p" --signal SIGKILL > /dev/null 2>&1; done; [ -n "$K" ] && t "清残留：terminate 后仍在的 $(echo $K | wc -w | tr -d ' ') 个发 SIGKILL"; fi
# 清自动化遗留（见 ALR）：只部署时不清（同上，人可能正在玩）
if [ "${DEPLOY_ONLY:-0}" != 1 ]; then
  for f in "$ALR"/*; do [ -f "$f" ] || continue; ob=${f##*/}; [ "$ob" = "$B" ] && continue
    od=$(appdirs_of "$ob"); [ -n "$od" ] || { rm -f "$f"; continue; }   # 机上已没装这款：登记作废
    L0=$(procs_in "$od"); [ -n "$L0" ] || { rm -f "$f"; continue; }
    LEFT=$(kill_verify "$od")
    [ -n "$LEFT" ] && { t "【红】清自动化遗留：$ob 的进程 $(echo $LEFT) 停不掉（上局 $(cut -d' ' -f2- "$f") 收局没核实干净），不起局"; fin red "同机残留进程停不掉：$ob pid $(echo $LEFT)"; }
    t "清自动化遗留：结束 $ob 的进程 $(echo $L0)（上局 $(cut -d' ' -f2- "$f") 收局没核实干净）"; echo "$(date '+%m-%d %T') 起局前结束自动化遗留 $ob pid $(echo $L0)" >> "$ALR.log"; rm -f "$f"
  done
fi
# 抢救非测试局日志（10-23 维护者：维护者 实机局走到自动路线到不了的地方——同局 5 次着色器首遇现编、记分板抓不到；下面卸载 / 推空文件会冲掉机上 host.log）：
#   本机每局收局记下拉回的 host.log 内容哈希（$BD/hostlog_head_<UDID>_<包名>）；起局前机上 host.log 哈希与它不同 = 两局测试之间有人自己玩过，
#   （11-02 改：原先比第一行，可每次开机第一行都是同一行「窗口已占 …」，维护者 手玩智慧的再现 v3 那局没认出来，被体验线紧接着起的对照局覆盖；只部署也照样抢救——收推送会起一次 App、轮转 host.log）
#   连同往局日志 logs/host-*.log 存到 S2A_OWNPLAY_DIR（缺省 ~/.s2arm/run/s2arm/ownplay）/<款>_<时刻>_机<号>/，tools/firstuse_scan.py 扫首遇现编，> 0 记进记分板读数并写着色器线收件箱。只读，不判格
ownplay() {
  local hm="$BD/hostlog_head_${UD}_$B" jp=${S2A_OWNPLAY_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ownplay} h d sc n pk sd
  # 这是开局第一次拉文件：用 probe_from 当通道探针（挂住重试一次、还挂判红），不白等 60 秒再到后面 app.id 那里挂第二次
  probe_from Documents/host.log "$O/prev_host.log" && [ -s "$O/prev_host.log" ] || { rm -f "$O/prev_host.log"; return 0; }
  h=$(shasum -a 256 < "$O/prev_host.log" | cut -c1-16)
  [ -f "$hm" ] || { echo "$h" > "$hm"; rm -f "$O/prev_host.log"; return 0; }   # 第一次没有记录：认它是上一局测试的（宁漏不误报），只记下
  [ "$h" = "$(cat "$hm")" ] && { rm -f "$O/prev_host.log"; return 0; }
  d=$jp/${GAME:-$B}_$(date +%m%d%H%M%S)_机${DEV:-?}; mkdir -p "$d" && mv "$O/prev_host.log" "$d/host.log"
  # frames.tsv：手玩局在 Documents/env.txt 带了 S2A_FRAMES_TSV 时也写它（11-02 画质性能线要 维护者 手玩的局内帧率）；和上一局测试收局时记下的哈希不同才算这局的，一并存
  CPF_T=60 cpfrom Documents/frames.tsv "$d/frames.tsv" > /dev/null 2>&1 && [ -s "$d/frames.tsv" ] && [ "$(shasum -a 256 < "$d/frames.tsv" | cut -c1-16)" != "$(cat "$BD/frames_sha_${UD}_$B" 2> /dev/null)" ] || rm -f "$d/frames.tsv"
  # App 起局把上一局 host.log 改名进 Documents/logs/host-<起局时刻>.log（11-06 每局一份、留 10 份）：两局测试之间玩了几次时，前几次在这里；
  #   整个目录拉回，内容哈希等于上一局测试收局那份的删掉（扫描时其余一并算）
  CPF_T=60 cpfrom Documents/logs "$d/logs" > /dev/null 2>&1 || rm -rf "$d/logs"
  for h in "$d"/logs/host-*.log; do [ -s "$h" ] && [ "$(shasum -a 256 < "$h" | cut -c1-16)" != "$(cat "$hm")" ] || rm -f "$h"; done
  rmdir "$d/logs" 2> /dev/null
  sd=${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}; pk=$(bash -c ". '$sd/installed/${DEV:-x}_$B' 2>/dev/null; echo \${COMMIT:-?}")
  sc=$(python3 "$TOOLS/firstuse_scan.py" "$d" 2>/dev/null); n=${sc%%	*}; echo "包 ${pk}；${sc#*	}" > "$d/firstuse.txt"
  t "两局测试之间机上有人自己玩过（host.log 不是上一局测试收局时那份）：日志$([ -s "$d/frames.tsv" ] && echo " + frames.tsv")存 ${d}；首遇现编 ${n:-?}（${sc#*	}）"
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  printf '%s\t%s\t%s\t\t\t\t\t\t\t维护者 实机局首遇现编 %s 次（包 %s）：%s；日志 %s\t\t\t\t\n' "$(date '+%m-%d %H:%M')" "${GAME:-$B}" "$pk" "$n" "$pk" "${sc#*	}" "$d" >> "${S2A_BOARD:-run/记分板.tsv}"
  mkdir -p "$sd/inbox"; echo "$(date '+%m-%d %H:%M:%S') 🔴 维护者 实机局首遇现编 ${n} 次：${GAME:-$B} 测试设备${DEV:-?} 包 ${pk}（${sc#*	}；日志 ${d}）" >> "$sd/inbox/画面着色器.log"
}
ownplay
# 管线种子来源·装前（维护者 11-02：怪猎 维护者 手玩首遇现编的 5 条管线没回流——局末拉回只在测试局走，只部署 / 人玩的局从没拉过，卸载重装再把 App 容器连表清掉）：
#   动机上 App（卸载 / 覆盖装）之前，先把上一次在这台机上跑过（人玩或测试局）记下的 pso_user.tsv 拉回；拉不到只记一行
# 程序号（小写）：通用模式包取 shaders/shcache/<程序号>/ 那一层；直连包没有那一层，取 shaders/direct/game.tsv 的 program_id。
#   11-05 能耗线：只认 shcache 时直连款（Windows 出包机包全是）装前 / 局末的 pso_user.tsv 与 direct_rt/ 从不拉回，Switch Sports 两局机上新记 112 行、种子来源一行没进
# 本包程序号（小写）：包里 Ryujinx 缓存目录名 → 直连 NVN 的 game.tsv → exefs/main.npdm（同出包 pack/srcs.sh prog_id 的 npdm 取法）。
#   11-06 银河 2：Vulkan 包两样前者都没有，取空 → 收局整段不拉直连现编产物（Documents/wire/<程序号>/shaders/），vk_spv 从没回流过、日志也没一行
tidl() { local t; t=$(ls "$J/pack/shaders/shcache" 2> /dev/null | head -1)
  [ -n "$t" ] || t=$(awk -F'\t' '$1 == "program_id" { print tolower($2); exit }' "$J/pack/shaders/direct/game.tsv" 2> /dev/null)
  [ -n "$t" ] || t=$(python3 -c "import sys;sys.path.insert(0,sys.argv[1]);import addr_need;print(addr_need.npdm_program(sys.argv[2]).lower())" "$TOOLS" "$J/pack/exefs/main.npdm" 2> /dev/null)
  echo "$t"; }
TIDL=$(tidl)
[ -n "$TIDL" ] && { CPF_T=30 cpfrom "Documents/wire/$(echo "$TIDL" | tr 'a-f' 'A-F')/pso_user.tsv" "$O/pso_user_pre.tsv" 2> /dev/null; pso_keep "$O/pso_user_pre.tsv" 装前; }
[ "${UNINSTALL:-0}" = 1 ] && { dcp 120 device uninstall app --device "$D" "$B" > "$O/uninst.log" 2>&1; t "卸载"; }
appurl() {
  dcp 60 device info apps --device "$D" --bundle-id "$B" --json-output "$O/apps.json" > /dev/null 2>&1
  python3 -c "import json,sys;a=json.load(open(sys.argv[1]))['result']['apps'];print(a[0]['url'] if a else '')" "$O/apps.json" 2>/dev/null
}
# 登记冒烟借机不留包（11-06 维护者：冒烟单 DEV=any，把刚按 维护者 令卸掉的款又装回测试设备）：部署前机上确认没有这个身份 → 冒烟收尾卸掉，测试设备保持冒烟前的样子。
#   查不清（通道失败、读不出列表）按「装着」处理、不卸：宁可留一个包，不误卸机上原有的
SMOKE_RM=; [ "${SMOKE:-0}" = 1 ] && dcp 60 device info apps --device "$D" --bundle-id "$B" --json-output "$O/apps0.json" > /dev/null 2>&1 \
  && [ "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['result']['apps']))" "$O/apps0.json" 2> /dev/null)" = 0 ] && SMOKE_RM=1
smoke_fin() {   # smoke_fin <fin 的参数…>：部署前没装的先卸再收
  [ -n "$SMOKE_RM" ] && { dcp 120 device uninstall app --device "$D" "$B" > "$O/uninst.log" 2>&1 && t "冒烟：部署前机上没有 ${B}，已卸载（测试设备保持冒烟前的样子）" || t "【黄】冒烟：部署前机上没有 ${B}，收尾卸载失败（$O/uninst.log）"; }
  fin "$@"; }
# 机上空间不够时腾空间（11-06 维护者：「如果安装遇到了空间问题，就删掉超过 24 小时的咱们的包」）：tools/dev_prune.sh 在本局持着的设备锁里，
#   按最后装 / 用的时间从旧到新卸 24 小时以上的我方 App（跳过 io.s2arm.01007EF00011E000 等永不卸的、读不出时间的），卸前备份存档，腾到可用 ≥ 需要就停；记 $O/prune.log
devfree() { if [ -n "${S2A_DEV_FREE_CMD:-}" ]; then bash -c "$S2A_DEV_FREE_CMD"; else ideviceinfo -u "$UD" -q com.apple.disk_usage -k AmountDataAvailable 2> /dev/null | awk '{printf "%d", $1 / 1048576}'; fi; }
space_need() {   # space_need <需要 MB> <为什么>：可用不够就腾；腾完仍不够只记黄（照常往下走，由装包 / 推包自己报红）
  local f; f=$(devfree); [ -n "$f" ] && [ "$f" -lt "$1" ] || return 0
  t "机上可用 ${f} MB < ${2}需要 ${1} MB：卸 24 小时以上的我方 App 腾空间"
  [ -n "${S2A_PRIVATE_TOOLS:-}" ] || { t "【黄】自有设备不自动卸 App：手动清理后重跑"; return 0; }
  S2A_PRUNE_KEEP="${S2A_PRUNE_KEEP-2:io.s2arm.botw} ${DEVNUM:-$DEV}:$B" bash "$S2A_PRIVATE_TOOLS/dev_prune.sh" "${DEVNUM:-$DEV}" --need-mb "$1" >> "$O/prune.log" 2>&1; t "$(tail -1 "$O/prune.log")"   # 本局正在部署的包永不卸
  grep '^卸 ' "$O/prune.log" | sed 's/（.*//' | while read -r x; do t "  $x"; done; }
IS=$(shasum -a 256 "$IPA" | cut -c1-16)
if [ "${UNINSTALL:-0}" != 1 ] && probe_from Documents/app.id "$O/r.app.id" && [ -s "$O/r.app.id" ] && [ "$(cat "$O/r.app.id")" = "$IS $(appurl)" ]; then
  t "装包：机上已是同一包（${IS}），不重装"
else
  dcp 600 device install app --device "$D" "$IPA" > "$O/install.log" 2>&1 || {
    if grep -qiE 'space|storage|disk.*full|insufficient' "$O/install.log"; then   # 空间类错误：腾一次再装一次
      t "装包失败（空间不足：$(tail -1 "$O/install.log" | cut -c1-120)）"; space_need $(( $(du -k "$IPA" | cut -f1) * 3 / 1024 + 1024 )) "装包"
      dcp 600 device install app --device "$D" "$IPA" > "$O/install.log" 2>&1; fi; } || { t "装包失败：$(tail -2 "$O/install.log" | tr '\n' ' ' | cut -c1-200)"; fin install "装包失败"; }
  echo "$IS $(appurl)" > "$O/app.id"; cpto "$O/app.id" Documents/app.id; t "装包 $(basename "$IPA")（${IS}）"
fi
T_INST=$(date +%s)

# 资源包 v2：推包段在 tools/push_pack.sh（与本脚本共用同一份，手动装机也走它）——按 sha256 比出要推的文件（机上 index.applied.tsv + .pushed）、
#   把上次没解完的残留批用空包盖掉、推前抽查机上实况、一批 <=1 GB 打 pax tar 推进 .incoming/（每推完一批追加进 .pushed）、最后推索引与清单
push_budget() {   # push_pack 算出待推量后的回调 <批数> <文件数> <字节数>：部署段上限随推送量放大
# 部署段上限随推送量放大：已用 + 300 秒 + 推送（按 15 MB/秒，USB 2 实测约 34 MB/秒）+ 机上解包（按 50 MB/秒）；不小于 900 秒
#   （10-20 巫师3 首推 32.7 GB 在 USB 2 上必然超 900 秒、被看门狗杀在推送中途，留下截短残包，后面 4 局全报 -4）
  DCAP2=$(( $(date +%s) - T_LOCK + 300 + $3 / 15728640 + $3 / 52428800 )); if [ "$DCAP2" -gt "$DCAP" ]; then
    DCAP=$DCAP2; CAPN=$DCAP; disarm; arm $(( DCAP - ($(date +%s) - T_LOCK) )); devlock_extend $((DCAP + CAP))   # 锁上限跟着放大（原先只放大本段看门，取锁时的 1200 秒到点照杀）
    t "部署段上限按推送量放大到 ${DCAP} 秒（待推 $(( $3 >> 20 )) MB），设备锁上限放到 $((DCAP + CAP)) 秒"; fi
}
. "$TOOLS/push_pack.sh"   # 推包主体（push_pack）与手动装机入口同源，只此一份
PUSH_ON_PLAN=push_budget; push_lowspace() { space_need "$1" "推资源包"; }; PUSH_ON_LOWSPACE=push_lowspace   # 机上可写不够先腾空间（push_pack 回调）
push_pack "$D" "$B" "$J/pack" "$O" "$([ "${S2A_PUSH_FULL:-0}" = 1 ] && echo 1 || echo 0)" || fin push "推资源包失败"
gone() {   # gone <pid>：0 = 机上进程表里确实没有它；拉不到进程表（通道问题）/ 空表 / 没给 pid 都按「不知道」返回 1，调用方照旧等
  [ -n "${1:-}" ] && dcp 40 device info processes --device "$D" > "$O/ps.txt" 2>/dev/null && [ -s "$O/ps.txt" ] && ! awk -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$O/ps.txt"
}
# 收推送放部署段：机上 .applied ≠ 本包 index_sha256 就起一次 App（S2A_PACK_APPLY_ONLY=1）解包后退出；完成 = unpack.log 本次新增了完成行「解开 N 个包 … .applied = 本包清单」
#   （11-02 测试设备2 暗黑2：新包与机上旧包索引相同，.applied 推之前就对得上；原判「.applied 对上 + 本次有新增行」在解到第 5/8 批、刚写第一行进度时就成立，
#    数批数判「收推送包数不符」红掉，后面推存档那步没走到——机上是新存档、进不了离线模式。进度行不算完成）
applied_line() { tail -n +$((u0 + 1)) "$O/r.unpack.log" 2>/dev/null | grep -q "解开 [0-9]* 个包 .*\.applied = ${WANT}"; }
WANT=$(jget "$J/pack/manifest.json" index_sha256); cpfrom "Documents/资源包/.applied" "$O/r.applied"
if [ "$(cat "$O/r.applied" 2>/dev/null)" != "$WANT" ] || [ "$PUSH_K" -gt 0 ]; then   # 推了包就一定收（账没变、只是补推丢了的文件时 .applied 本来就对得上）
  ta=$(date +%s); cpfrom Documents/unpack.log "$O/r.unpack.log"; u0=$(wc -l < "$O/r.unpack.log" 2>/dev/null || echo 0); u0=${u0// /}
  dcp 90 device process launch --device "$D" --terminate-existing --environment-variables '{"S2A_PACK_APPLY_ONLY":"1"}' --json-output "$O/apply_launch.json" "$B" > "$O/apply_launch.log" 2>&1 || { t "起包收推送失败：$(tail -1 "$O/apply_launch.log" | cut -c1-160)"; fin push "起包收推送失败"; }
  AW=$(( DCAP - ($(date +%s) - T_LOCK) - 60 )); AP=$(jget "$O/apply_launch.json" result.process.processIdentifier)
  until cpfrom "Documents/资源包/.applied" "$O/r.applied" && [ "$(cat "$O/r.applied")" = "$WANT" ] && cpfrom Documents/unpack.log "$O/r.unpack.log" && applied_line; do
    if [ $(( $(date +%s) - ta )) -gt $AW ]; then   # 超时当场留现场：机上 .incoming 还剩几个推送包（剩得多 = App 没在解 / 中途没了）
      left=$(dcp 60 device info files --device "$D" --domain-type appDataContainer --domain-identifier "$B" --subdirectory "Documents/资源包/.incoming" --no-recurse 2>/dev/null | grep -c '\.tar ')
      t "机上收推送超 ${AW} 秒（部署段剩余预算）：.incoming 还剩 ${left:-?} / ${PUSH_NBATCH:-?} 个推送包，unpack.log 本次新增 $(( $(wc -l < "$O/r.unpack.log" 2>/dev/null || echo "$u0") - u0 )) 行"; fin push "收推送超时"
    fi
    # 收推送的 App 进程没了还没对上 = 没走到解包 / 解到一半没了（10-22 链 SDK 27 的包启动即崩，原先白等到部署预算用完）：当场报红收局。
    # 进程没了它写的都已落盘，再拉一次 .applied / unpack.log 判，不会误判刚解完退出的
    if gone "$AP"; then
      cpfrom "Documents/资源包/.applied" "$O/r.applied" && [ "$(cat "$O/r.applied")" = "$WANT" ] && cpfrom Documents/unpack.log "$O/r.unpack.log" && applied_line && break
      t "App 没走到解包：收推送的 App（pid ${AP}）起来 $(( $(date +%s) - ta )) 秒后进程已退出，.applied 没对上本包、unpack.log 本次新增 $(( $(wc -l < "$O/r.unpack.log" 2>/dev/null || echo "$u0") - u0 )) 行"; DL=$(deadlog); t "$DL"; fin push "App 没走到解包；$DL"
    fi
    cpfrom Documents/unpack.log "$O/r.unpack.log"; tail -n +$((u0 + 1)) "$O/r.unpack.log" 2>/dev/null | grep -q '返回 -' && { t "机上收推送失败：$(tail -1 "$O/r.unpack.log" | cut -c1-200)"; fin push "收推送失败"; }
    sleep "${S2A_POLL_APPLY_S:-5}"
  done
  # 解开的包数 = 本次推的批数（10-25 测试设备2：推 4 批、App 记「解开 0 个包」照写 .applied，执行器只看 .applied 当成功）
  nu=$(tail -n +$((u0 + 1)) "$O/r.unpack.log" 2>/dev/null | grep -o '解开 [0-9]* 个包' | tail -1 | grep -o '[0-9]*')
  [ "${nu:-0}" -ge "$PUSH_K" ] || { t "【红】资源包：推了 ${PUSH_K} 批，机上只解开 ${nu:-?} 个包（$(tail -1 "$O/r.unpack.log" | cut -c1-120)）"; fin push "收推送包数不符"; }
  t "资源包：机上解开推送包、写 .applied（$(( $(date +%s) - ta )) 秒）"
  # 收推送的 App 写完 .applied 还要收尾（冲刷日志、优雅退出），进程还在：等它真退出再盖空 / 起局，到点没退就结束它，结束不了报红。
  #   11-05 能耗线 Switch Sports 冷装局：原先不等，它与真局同时活着、比真局晚轮换 host.log，把真局日志挤成 host.prev.log，拉回的 host.log 只剩它自己的 760 字节
  w=0; until gone "$AP" || [ "$w" -ge "${S2A_APPLY_EXIT_S:-20}" ]; do sleep 1; w=$((w + 1)); done
  if gone "$AP"; then t "收推送的 App（pid ${AP}）已退出（等了 ${w} 秒）"
  else dcp 30 device process terminate --device "$D" --pid "$AP" > /dev/null 2>&1; sleep 1
    gone "$AP" || { t "【红】收推送的 App（pid ${AP}）${w} 秒没退出、结束也没结束掉：不起局（两个进程会同时写 host.log）"; fin push "收推送进程不退"; }
    t "收推送的 App（pid ${AP}）${w} 秒没自己退出，已结束"
  fi
fi

SV=; if [ -d "$J/save" ]; then   # 存档（服务接入线 S2A_SAVE_DIR）：save/ 下按类型分 device/ account/；以目录为源推到新子目录（新目录推送快），起局时服务层清空再整棵拷入
  SV=sv_$(date +%H%M%S); vpush "$J/save" "Documents/$SV" || { t "推存档失败"; fin push "推存档失败（机上核对：$(head -2 "$O/vpush.diff" 2> /dev/null | tr '\n' '；')）"; }
  t "存档 $(ls "$J/save" | tr '\n' ' ')→ Documents/$SV"
fi
if [ -s "$J/pso.metallib" ]; then   # 管线归档按 sha 比，同一份不重推
  ps=$(shasum -a 256 "$J/pso.metallib" | cut -c1-16); cpfrom Documents/pso.metallib.sha "$O/r.pso.sha"
  if [ "$(cat "$O/r.pso.sha" 2>/dev/null)" = "$ps" ]; then t "管线归档：机上已是同一份（${ps}）"
  else echo "$ps" > "$O/pso.sha"; cpto "$J/pso.metallib" Documents/pso.metallib && cpto "$O/pso.sha" Documents/pso.metallib.sha || { t "推管线归档失败"; fin push "推管线归档失败"; }; t "管线归档：推（${ps}）"; fi
fi
for pp in ${PUSH:-}; do vpush "$J/${pp%%:*}" "Documents/${pp#*:}" || { t "推 ${pp%%:*} 失败"; fin push "推 ${pp%%:*} 失败"; }; done
# 只部署（DEPLOY_ONLY=1）：装包、推资源包 / 存档 / 管线归档后收工、不起局——人要亲手玩时不抢手机前台（10-20 维护者 试玩测试设备1）
# 只部署收推送时起过一次 App、写了新的 host.log：记下它的哈希（同收局），不然下一局起局前 ownplay 会把这份当「有人玩过」误存
[ "${DEPLOY_ONLY:-0}" = 1 ] && { CPF_T=60 cpfrom Documents/host.log "$O/host.log" && [ -s "$O/host.log" ] && shasum -a 256 < "$O/host.log" | cut -c1-16 > "$BD/hostlog_head_${UD}_$B"
  t "只部署：装包与推送完成，不起局"; fin deployed "" 0; }
# 登记冒烟（SMOKE=1，维护方工具 pkg 新包登记前；10-22 维护者：链 SDK 27 没接 UIScene 的九款包登记后全部启动即崩）：部署后起 App（不带自动玩家等环境），
#   S2A_SMOKE_S（缺省 30）秒内进程一直在 = 能起，结束 App、RESULT=smoke-ok；中途没了 = RESULT=smoke（包的问题）；起包命令本身失败按通道问题 RESULT=red
if [ "${SMOKE:-0}" = 1 ]; then
  # 先清机上旧 host.log（收推送那次起的 App 也写它）：冒烟退出时拉回的才一定是这次起包的
  : > "$O/hl0"; cpto "$O/hl0" Documents/host.log || t "冒烟：清机上旧 host.log 失败（退出时拉回的可能是旧的）"
  # 不带 --environment-variables：真 devicectl 拒收空对象 '{}'（「Unable to decode environment variables」，10-22 线上第一单冒烟三次起包失败）
  dcp 90 device process launch --device "$D" --terminate-existing --json-output "$O/launch.json" "$B" > "$O/launch.log" 2>&1 || { t "冒烟：起包失败：$(grep -m1 -i 'error' "$O/launch.log" | cut -c1-160)"; smoke_fin red "冒烟起包失败"; }
  PID=$(jget "$O/launch.json" result.process.processIdentifier); [ -n "$PID" ] || { t "冒烟：起包没回 pid"; smoke_fin red "冒烟起包没回 pid"; }
  ts=$(date +%s); SM=${S2A_SMOKE_S:-30}; t "冒烟：起 App（pid ${PID}），看 $SM 秒"
  while :; do
    gone "$PID" && { te=$(( $(date +%s) - ts )); t "冒烟：App（pid ${PID}）起来 ${te} 秒后进程已退出"; PID=; DL=$(deadlog); t "$DL"; smoke_fin smoke "App 起来 ${te} 秒退出；$DL"; }
    [ $(( $(date +%s) - ts )) -ge "$SM" ] && break; sleep "${S2A_POLL_S:-5}"
  done
  dcp 15 device process terminate --device "$D" --pid "$PID" > /dev/null 2>&1; t "冒烟：App 起来 $SM 秒进程一直在，已结束"; smoke_fin smoke-ok "" 0
fi
# 起局前把要拉回的文件盖空（空 = 本局没写；拉回过上一局的文件当本局读）：摆一个空文件目录一次推（逐个推每次 5–6 秒）
aps() {   # 机上 Documents/ 根下自动玩家自存的截图 ap_*.png（MARK / 中段 / 收局 / 卡住）；文件列表 macOS 27 的 devicectl 打在 stderr（10-20 gate-host 上 2>/dev/null 列出 0 个）
  dcp 60 device info files --device "$D" --domain-type appDataContainer --domain-identifier "$B" --subdirectory Documents --no-recurse 2>&1 | awk '{print $1}' | grep '^ap_.*\.png$'
}
rm -rf "$O/blank"; mkdir -p "$O/blank"
# PULL 里像目录的（结尾 / 或最后一段没有扩展名）不写空文件：写成空文件推上去会盖住机上同名目录，App 建目录失败整局不出帧（10-23 两局巫师3；维护方工具 submit 已拒，这里兜底）
for f in ${PULL:-}; do case ${f##*/} in *.*) ;; *) t "【黄】PULL 里 $f 像目录（没有扩展名）：起局前不盖空文件，收局也拉不回（只拉文件）";; esac; done
for f in host.log frames.tsv cold_start.txt ap_summary.json threads.txt $(for p in ${PULL:-}; do case ${p##*/} in (*.*) echo "$p";; esac; done) $(aps); do mkdir -p "$O/blank/$(dirname "$f")"; : > "$O/blank/$f"; done   # 上局截图也盖空（空 = 本局没截）
# 逐个文件推：以目录为源推到 Documents 根时 devicectl 要扫目标目录，资源包解开后（13.8 万文件）一次要 49 秒；单个文件 0–1 秒（10-19 测试设备1 实测）
s_=$SECONDS; (cd "$O/blank" && find . -type f | sed 's#^\./##') | while read -r f; do cpto "$O/blank/$f" "Documents/$f" || exit 1; done || { t "盖空待拉回文件失败"; fin push "盖空失败"; }
t "盖空待拉回文件 $(find "$O/blank" -type f | wc -l | tr -d ' ') 个（含列截图），$((SECONDS - s_)) 秒"
pw() { command -v idevicediagnostics > /dev/null && timeout 20 idevicediagnostics -u "$UD" ioregentry AppleSmartBattery > "$O/$1" 2>/dev/null; }
s_=$SECONDS; pw pw0.plist
t "功率基线 $((SECONDS - s_)) 秒"; t "电池：$(timeout 20 ideviceinfo -u "$UD" -q com.apple.mobile.battery 2>/dev/null | awk '/^BatteryCurrentCapacity:/{p=$2} /^BatteryIsCharging:/{c=$2} /^ExternalConnected:/{e=$2} END{printf "电量 %s%%，充电 %s，外接电源 %s", p, c, e}')"

# —— 测试段 ——
T_PUSH=$(date +%s); disarm; PH=测试; CAPN=$CAP; W0=$T_PUSH; arm $CAP
ACT_S=${ACT_S:-60}; SEC=$(( CAP - 15 ))   # 留 15 秒收局拉回
# 真机驾驶员（11-01 维护者：iOS 上没有视觉脚本也没有密钥，真机自动玩家到不了 MARK）：App 带 S2A_VISION_REMOTE=1 把每一问写进 Documents/vision/ 信箱，
#   Mac 侧 tools/vision_bridge.sh 经 devicectl 拉走、跑同一个 vision.sh、把答案推回。S2A_VISION_BRIDGE=auto（缺省）= Mac 上驾驶员可用才开：脚本在，且
#   缺省后端（本机 claude CLI 直连，11-12 起；中转站已停用）PATH 上有 claude、或显式 S2A_VISION_BACKEND=or / jev 时有 OpenRouter 钥匙；1 / 0 强制。
#   驾驶员不可用（没 CLI / 没登录 / 没钥匙）由 vision.sh 退出 3、答案带 unavailable，经桥推回手机，自动玩家红停
VSH=${S2A_VISION_SH:-$TOOLS/../tests/autoplay/vision.sh}; VBR=${S2A_VISION_BRIDGE:-auto}
[ "$VBR" = auto ] && { VBR=0; [ -r "$VSH" ] && { [ -n "${S2A_VISION_SH:-}" ] || case ${S2A_VISION_BACKEND:-cli} in (cli) command -v claude > /dev/null;; (*) [ -r "$HOME/.s2arm/.secrets/openrouter.key" ];; esac; } && VBR=1; }
[ "$VBR" = 0 ] && [ "${S2A_VISION_BRIDGE:-auto}" = auto ] && echo "【红】真机驾驶员不开：Mac 上看屏驾驶员不可用（缺省走本机 claude CLI：PATH 上没有 claude；或 S2A_VISION_BACKEND=${S2A_VISION_BACKEND:-cli} 缺 OpenRouter 钥匙），自动玩家到不了 MARK" >&2
ENV=$(python3 - "${ENVJSON:-}" <<PY
import json, sys
e = {"S2A_FRAMES_TSV": "frames.tsv", "S2A_AUTOPLAY": "1"}   # iPhone 上自动玩家缺省关（人手动打开 App 不带环境变量），执行器起局显式开
# 屏幕亮度缺省固定 0.5（10-30 iOS 功耗测量口径修法 3）：整机瓦数含屏幕，亮度不固定时跨日对比混进屏幕功耗；与小菠萝「亮度 0.5」同口径。
#   要用机上当前亮度的局显式 --env=S2A_BRIGHTNESS=-1（App 端 < 0 = 不动）
e["S2A_BRIGHTNESS"] = "0.5"
if "$SV": e["S2A_SAVE_DIR"] = "$SV"
for f, k in (("system_time", "S2A_SYSTEM_TIME"), ("language", "S2A_SYSTEM_LANGUAGE"), ("region", "S2A_REGION"), ("timezone", "S2A_TIMEZONE")):   # 测试资产里的开机时间 / 语言 / 地区 / 时区
    try: v = open("$J/" + f).read().strip()
    except OSError: v = ""
    if v: e[k] = v
if "${COLD:-0}" == "1": e["S2A_COLD_START"] = "1"
if "$VBR" == "1": e["S2A_VISION_REMOTE"] = "1"
# 自动玩家局内段 = 本局 MARK 后采集秒数 + 30：局内段先完自动玩家就收局，执行器看到出图停判红（10-20 M1 两次：动作环 60 / 采 285；动作环 = 采集 180 同时到点，下一轮轮询先看到「10 秒没新帧」）
# 性能测量口径（11-07 维护者：离完工越来越近，测试手段要撤，读数要按玩家实际）：开发设施（停住现场 / 地址余量 / MemDiag / 音频周期账，见 s2a_dev_on）
#   缺省按发布口径关——等同 S2ADevFacilities=0 的玩家包；要它们的诊断局在 ENVJSON 里显式 "S2A_DEV_FACILITIES":"1"。重探针一律只在诊断局显式开，账本据此标「诊断局」
e["S2A_DEV_FACILITIES"] = "0"
e["S2A_AP_LOOP_S"] = str(int("$ACT_S") + 30)   # 一律传（10-20 缺省 60 时没传，动作环也是 60，又同时到点被判出图停）
if sys.argv[1]: e.update(json.loads("{" + sys.argv[1] + "}"))
print(json.dumps(e, ensure_ascii=False))
PY
) || { t "ENVJSON 不是合法 JSON 片段：${ENVJSON:-}"; fin red "ENVJSON 非法"; }
# 局中日志走控制台流（S2A_CONSOLE：auto 缺省 = App 二进制里有 S2A_LOG_CONSOLE 就开；1 / 0 强制）：devicectl … launch --console 陪 App 跑完整局，
#   原生层日志行（runtime/src/logcon.c）实时到 $O/live/con.raw，局中不再拉 host.log / frames.tsv。10-21 测试出包线实测：手机端文件服务挂死（拉 18 字节 20 秒超时）时
#   控制台流 100 秒照样收到 454 行（心跳 / 能耗 / 自动玩家）；0100152000022000 / 一款第一方动作冒险游戏局中第一次拉 frames.tsv 就挂的触发点随之消失。收局 SIGTERM 这条命令，devicectl 转给 App 优雅退出。
#   控制台里没有 C# 侧的行（[gal] 帧节拍 / GPU 慢等，走 fd 2 只进 host.log），收局拉回的 host.log 为准；拉不回就用控制台流顶上并记「待拉」。
CONS=${S2A_CONSOLE:-auto}
if [ "$CONS" = auto ]; then CONS=0; unzip -p "$IPA" 'Payload/*.app/S2Arm' 2> /dev/null | LC_ALL=C /usr/bin/grep -aq S2A_LOG_CONSOLE && CONS=1; fi
# 局的环境显式给 S2A_LOG_CONSOLE=0（--env=S2A_LOG_CONSOLE=0）→ 不开控制台流（10-26 原生层线：巫师3 分配二分要关掉日志镜像这一半，执行器原先一律强制 =1）
[ "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("S2A_LOG_CONSOLE",""))' "$ENV")" = 0 ] && CONS=0
mkdir -p "$O/live"
echo "$(date '+%m-%d %T') $O" > "$ALR/$B"   # 自动化起局登记（见 ALR）：收局核实进程没了才删
if [ "$CONS" = 1 ]; then
  ENV=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1]);e["S2A_LOG_CONSOLE"]="1";print(json.dumps(e,ensure_ascii=False))' "$ENV")
  # 不带 --timeout：这条命令要陪 App 跑完整局，由收局 / 看门狗结束
  $DC device process launch --console --device "$D" --terminate-existing --environment-variables "$ENV" --json-output "$O/launch.json" "$B" > "$O/live/con.raw" 2> "$O/launch.log" &
  CPID=$!
else
  dcp 90 device process launch --device "$D" --terminate-existing --environment-variables "$ENV" --json-output "$O/launch.json" "$B" > "$O/launch.log" 2>&1 || t "起包失败：$(tail -1 "$O/launch.log" | cut -c1-160)"
fi
BR=; if [ "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("S2A_VISION_REMOTE",""))' "$ENV")" = 1 ]; then
  mkdir -p "$O/vision"; BRIDGE_PARENT=$$ S2A_VISION_SH="$VSH" S2A_DEVICECTL="$DC" bash "$TOOLS/vision_bridge.sh" "$D" "$B" "$O/vision" & BR=$!
  t "驾驶员桥起（pid ${BR}）：Mac 侧答真机自动玩家每一问（驾驶员 ${VSH}；记 vision/bridge.log）"; fi
PID=$(jget "$O/launch.json" result.process.processIdentifier); t "起局 $([ "$CONS" = 1 ] && echo "（控制台流，pid 收局后才知道）" || echo "pid=${PID:-无}")，环境 $ENV"
# 同局交替开关（帧率能耗线 10-24，runtime/src/alt.c）：作业 --env 带 S2A_ALT=<秒> 时，每段里采两次整机功耗——段起点后 ALT_G1 秒（pwalt_<k>a.plist）、
#   段终点前 ALT_G2 秒（pwalt_<k>b.plist），只用这两次之间的读数：设备从自己的 MARK 起算段、执行器晚一个轮询周期 + 拉日志才看到 MARK，
#   护边要盖住这段滞后，不让段边界附近的功耗算进相邻段（测试出包线 10-24 审出）。每次采样记 pwalt.tsv：段号 a/b 目标秒 实际秒（相对执行器看到 MARK），
#   迟到超过一个轮询周期 + 1 秒的不采、记「迟到」（alt_report.py 那段功耗算未测）。电池累计量约每秒刷新一次（10-24 量：60 次 / 63 秒）
ALT_S=$(printf '%s' "${ENVJSON:-}" | sed -n 's/.*"S2A_ALT":"\([0-9]*\)".*/\1/p'); ALT_K=0; ALT_PH=a
T0=$(date +%s); RED=; WHY=; n0=-1; tch=$T0; MK=; W_EL=; POLL=${S2A_POLL_S:-$([ "$CONS" = 1 ] && echo 2 || echo 10)}; STALL_S=${S2A_STALL_S:-10}; mkdir -p "$O/live"
if [ -n "$ALT_S" ]; then   # 同局交替：护边 = 1 秒 / 轮询周期（向上取整）+ 2 秒；段长至少 S2A_ALT_MIN_S（缺省 10）秒且长于两边护边，否则判红（零长段读数是垃圾）
  ALT_PC=${POLL%.*}; [ "$ALT_PC" != "$POLL" ] && ALT_PC=$(( ${ALT_PC:-0} + 1 )); ALT_G1=1; ALT_G2=$(( ALT_PC + 2 ))
  if [ "$ALT_S" -lt "${S2A_ALT_MIN_S:-10}" ] || [ "$ALT_S" -le $(( ALT_G1 + ALT_G2 + 1 )) ]; then t "【红】S2A_ALT=$ALT_S 秒太短（至少 ${S2A_ALT_MIN_S:-10} 秒、且长于两边护边 $(( ALT_G1 + ALT_G2 + 1 )) 秒）"; fin red "S2A_ALT 太短"; fi
fi
SEC=$(( CAP - (T0 - T_PUSH) - ${S2A_PULL_RESERVE_S:-45} ))   # 起局后可用秒数：硬上限从测试段开始（装包 / 起局已花 T0−T_PUSH）算，留 S2A_PULL_RESERVE_S（缺省 45）秒结束 App + 拉回（10-20 M1：按起局算 285 秒，硬上限先到、局被杀、日志全丢）
# 局中不拉 frames.tsv（S2A_LIVE_FRAMES=0，执行器环境或作业 --env 给）：帧号取 host.log 的 10 秒心跳「[心跳] 帧 N」，frames.tsv 收局结束 App 后再拉。
#   10-21 测试出包线：0100152000022000 / 一款第一方动作冒险游戏局里起局后第一次拉 frames.tsv 就挂、之后全部拉文件超时、手机端文件服务挂十几分钟；01006F8002326000同拉法正常——对照验证这个触发点
LIVEF=${S2A_LIVE_FRAMES:-1}; case "${ENVJSON:-}" in *'"S2A_LIVE_FRAMES":"0"'*) LIVEF=0;; esac
[ "$CONS" = 1 ] && LIVEF=0
# 控制台流 → live/host.log：去掉 pty 的 \r 与 devicectl 自己的提示行
con2log() { tr -d '\r' < "$O/live/con.raw" | LC_ALL=C /usr/bin/grep -avE '^(Launched application with|Waiting for the application to terminate|The app terminated with)' > "$O/live/host.log"; }
texit() { local c d; c=$(jget "$O/launch.json" result.terminationResult.exitCode); d=$(jget "$O/launch.json" result.terminationResult.wasCoreDumpCreated); echo "退出码 ${c:-取不到}$([ "$d" = True ] && echo "，有崩溃转储")"; }
STL=$STALL_S; [ "$LIVEF" = 0 ] && [ "$STL" -lt "${S2A_HB_STALL_MIN:-30}" ] && STL=${S2A_HB_STALL_MIN:-30}   # 心跳 10 秒一行：停顿判据不能短于两三个心跳
hlsize() {   # 机上 Documents/host.log 的字节数（列目录不拉文件）；列不出返回 1
  dcp 20 device info files --device "$D" --domain-type appDataContainer --domain-identifier "$B" --subdirectory Documents --no-recurse --json-output "$O/live/ls.json" > /dev/null 2>&1 || return 1
  python3 -c 'import json, sys
fs = json.load(open(sys.argv[1]))["result"]["files"]
print(next((f["metadata"]["size"] for f in fs if f.get("relativePath") == "host.log"), 0))' "$O/live/ls.json" 2> /dev/null; }
livepull() { [ "$CONS" = 1 ] && { con2log; return 0; }; CPF_T=$LT cpfrom Documents/host.log "$O/live/host.log" || return 1; [ "$LIVEF" = 0 ] && return 0; CPF_T=$LT cpfrom Documents/frames.tsv "$O/live/f.tsv"; }
# 已出到第几帧（10-27 R13 坑 2）：拉回的 live 副本会滞后——判红「出图停在第 4747 帧已 30 秒」时设备心跳已打到 6547、
#   机上 frames.tsv 到 6687（16.7 ms/帧），MARK（6490）早过了。所以帧号取「frames.tsv 行数」与「host.log 心跳帧号」里大的那个，
#   而不是 live 副本的静态快照。
# 进程内重启（11-04 Windows 出包线外置局：切 60 帧代按「立刻重启」）后帧号从 1 重数、frames.tsv 重写成只剩新的一段：一个帧号比到底会把
#   开窗时的 4134 与重启后的 1144 比、判「窗口内没出新帧」。按段累计：同一份 host.log 里心跳帧号变小 = 计数器归零（日志按时间顺序写，
#   live 副本滞后只会让快照旧、不会让顺序倒退），把前一段最后的心跳帧号记进底数；返回 底数 + 当前段帧号，单调不回退。不靠宿主的重启提示行（Mac 路径不打）
frame_now() {
  local f=0 b h c
  [ "$LIVEF" = 0 ] || { c=$(wc -l < "$O/live/f.tsv" 2> /dev/null); f=$(( ${c:-1} - 1 )); [ "$f" -lt 0 ] && f=0; }
  read -r b h <<< "$(LC_ALL=C /usr/bin/grep -a '\[心跳\] 帧 [0-9]' "$O/live/host.log" 2> /dev/null | sed 's/.*\[心跳\] 帧 \([0-9]*\).*/\1/' \
    | awk '{ if ($1 + 0 < c) b += c; c = $1 + 0 } END { print b + 0, c + 0 }')"
  case ${b:-} in ''|*[!0-9]*) b=0;; esac; case ${h:-} in ''|*[!0-9]*) h=0;; esac
  [ "$h" -gt "$f" ] && f=$h
  echo $(( b + f ))   # 重启过（b > 0）时 frames.tsv 已是新的一段（每轮先拉 host.log 后拉 frames.tsv）
}
# 新鲜读数（11-06 性能线 A：Duo 上两局拉回的 live 副本 30 秒没更新，判红前重读也没拿到新内容，把一直在出帧的局判成「出图停」SIGTERM 收掉）：
#   宿主心跳由主线程 10 秒定时器触发（ios/app.m），和出帧线程无关——真停帧时心跳照打、帧号不变。
#   新鲜读数 = 拉回的 host.log 里来了新的心跳行（不是「host.log 变长」：两局现场判停时 MARK 等别的行照常到了，偏偏心跳迟到——
#   Duo 热状态 2 下心跳块先做整窗驻留扫描，两行心跳隔了 30 秒以上；控制台流模式帧号只来自心跳）。记 HG_T；
#   判「出图停」要求停帧之后来过新心跳（HG_T > tch），否则只记「拉取不新鲜」不判
HB0=0; HG_T=0
freshmark() { local h; h=$(LC_ALL=C /usr/bin/grep -ac '\[心跳\] 帧 [0-9]' "$O/live/host.log" 2> /dev/null); [ "${h:-0}" -gt "$HB0" ] && { HB0=$h; HG_T=$(date +%s); }; return 0; }
# 判红前重读一次（同上）：重拉 frames.tsv + host.log 再取最新帧；帧号涨了就按新帧续命，不拿滞后快照判死。
#   拉取超时按测试段剩余秒数截短（维护方 A3 第 6 条）：剩余 ≤ 0 不重读（返回 1），免得一次重读把局拖过 CAP 硬上限、日志全丢。
#   S2A_FRAME_RECHECK=0 关掉（只排障 / 对照验证时用）
reframe() {
  local rem t
  rem=$(( SEC - ($(date +%s) - T0) ))
  [ "$rem" -gt 0 ] || return 1
  t=${S2A_LIVE_PULL_T:-30}
  [ "$rem" -lt "$t" ] && t=$rem
  if CPF_T=$t livepull > /dev/null 2>&1; then freshmark; else PFN=$(( ${PFN:-0} + 1 )); t "  判红前重读：拉文件失败（本局第 ${PFN} 次），按旧副本取帧"; fi
  n=$(frame_now); [ "$n" != "$n0" ] && { n0=$n; tch=$(date +%s); }; stl=$(( $(date +%s) - tch ))
  return 0
}
# 加载帧单个命令缓冲 GPU 执行好几秒（10-21 原生层线：怪猎第 712 帧 7.2 秒，宿主连打「【红】GPU 慢：等栅栏 … 继续等」，第 8 秒出了下一帧）不算停帧：
#   host.log 末尾 2 KB 有「GPU 慢」且没有「GPU 卡死」时延后判停，累计最多 S2A_GPU_SLOW_GRACE（缺省 30）秒；渲染器 20 秒判卡死会自己打红退出
GS0=; slowgpu() { tail -c 2048 "$O/live/host.log" 2> /dev/null | LC_ALL=C /usr/bin/grep -aq 'GPU 慢' || return 1
  tail -c 2048 "$O/live/host.log" | LC_ALL=C /usr/bin/grep -aq 'GPU 卡死' && return 1
  GS0=${GS0:-$(date +%s)}; [ $(( $(date +%s) - GS0 )) -lt "${S2A_GPU_SLOW_GRACE:-30}" ] || return 1; tch=$(date +%s); return 0; }
hasl() { LC_ALL=C /usr/bin/grep -aq "$1" "$O/live/host.log" 2>/dev/null; }
while :; do
  sleep "$POLL"
  c0=$SECONDS; left=$(( SEC - ($(date +%s) - T0) ))
  # 先看截止：拉文件失败的轮次也要到点收局（10-20 M1：通道变慢、连续「拉文件失败」走 continue 跳过了截止判断，撞 300 秒硬上限、日志全丢）
  if [ $left -le 0 ]; then el=$(( $(date +%s) - T0 ))
    if [ -n "$W_EL" ] && [ $(( el - W_EL )) -ge 60 ]; then t "收局：窗口截到测试段上限，采了 $(( el - W_EL )) 秒（要 ${ACT_S}；起局后 $el 秒）"; break; fi
    RED=1; WHY="窗口没采满：到测试段上限（起局后 $SEC 秒）"; t "【红】$WHY"; break; fi
  # 轮询拉文件超时 S2A_LIVE_PULL_T（缺省 30 秒，正常 2 秒内）：通道挂一次只丢一轮，不把窗口拖到截止（10-20 测试设备2：拉 host.log 挂 171 秒，窗口拖到起局后 285 秒、判超 300 秒，功率窗口混进空闲段）
  LT=${S2A_LIVE_PULL_T:-30}; [ $left -lt "$LT" ] && LT=$left
  # 日志暴涨即停（11-07 性能线 A：测试设备1 kD1_diag 挂死后 5 分钟 host.log 涨到 120 MB，整份拉超时 →「本轮不判」→ 永不判，GPU 卡死即停跟着失效）：
  #   不开控制台流时，拉之前先列机上 Documents 取 host.log 大小（一次 devicectl 列目录，几 KB），超过 S2A_LIVE_LOG_MAX_KB（缺省 65536 = 64 MB）不拉、当轮红收局、不截屏。
  #   正常整局 host.log 远小于此；列目录失败只跳过本项检查，照旧拉
  if [ "$CONS" != 1 ] && HLS=$(hlsize) && [ "$HLS" -gt $(( ${S2A_LIVE_LOG_MAX_KB:-65536} * 1024 )) ]; then
    RED=1; GPUHANG=1; WHY="日志暴涨即停：机上 host.log $(( HLS / 1024 )) KB，超过 ${S2A_LIVE_LOG_MAX_KB:-65536} KB（多为 GPU 挂死后刷屏；整份拉会超时、局中判定失效），不拉"
    t "【红】出错即停：${WHY}（起局后 $(( $(date +%s) - T0 )) 秒）"; break; fi
  livepull || {
    el=$(( $(date +%s) - T0 )); PFN=$(( ${PFN:-0} + 1 )); t "拉文件失败（起局后 ${el} 秒，本局第 ${PFN} 次），本轮不判"
    [ -n "$W_EL" ] && [ $el -ge $(( W_EL + ACT_S )) ] && { t "收局：窗口到点（${ACT_S} 秒；本轮拉文件失败，帧数以收局后拉回为准；起局后 $el 秒）"; break; }
    continue; }
  freshmark
  [ -z "${FIRSTPULL:-}" ] && { FIRSTPULL=$((SECONDS - c0)); [ "$FIRSTPULL" -gt 60 ] && t "【黄】起局后首次拉文件 $FIRSTPULL 秒"; }
  el=$(( $(date +%s) - T0 ))   # 拉完再算（拉文件可能卡很久）
  # 心跳第一次报「前台失焦」（系统弹框挡着 App）：当场截整屏 screen/unfocus.png，收局按框里文字分类（tools/sysdialog.sh）
  [ -z "${UFSHOT:-}" ] && LC_ALL=C /usr/bin/grep -a '\[心跳\] ' "$O/live/host.log" 2> /dev/null | LC_ALL=C /usr/bin/grep -aq '前台失焦' \
    && { UFSHOT=1; scr unfocus; t "心跳报前台失焦（起局后 ${el} 秒）：整屏截图 screen/unfocus.png"; }
  hs=$(wc -c < "$O/live/host.log" 2>/dev/null || echo 0)
  n=$(frame_now)   # 帧号取 frames.tsv 行数与 host.log 心跳帧号里大的那个（见 frame_now）
  [ $n != $n0 ] && { n0=$n; tch=$(date +%s); }
  # 停顿秒数每轮只取一次：两个判停分支各调 date 会跨秒（10-23 门禁偶发红：「再等」分支算出 1 秒跳过、下一分支算出 2 秒判红，slowgpu 没被问到）
  stl=$(( $(date +%s) - tch ))
  [ "${hs// /}" -gt 0 ] && SEEN=1; [ $n -gt 0 ] && { FSEEN=1; T_FF=${T_FF:-$(date +%s)}; }
  BL=$(LC_ALL=C /usr/bin/grep -a '\[电\] 电量 [0-9]' "$O/live/host.log" 2>/dev/null | tail -1 | sed 's/.*\[电\] 电量 \([0-9]*\)%，\(.*\)$/\1 \2/')
  [ -n "$BL" ] && echo "$BL" > "$BD/app_battery_$UD.txt"
  CEND=; [ "$CONS" = 1 ] && ! kill -0 "$CPID" 2> /dev/null && { con2log; CEND=1; }
  # GPU 卡死即停（11-07 维护者：测试设备2 hang 之后局还跑了几分钟，整机卡死要人重启）：一见签名就收局、跳过收局前截屏、立刻结束 App
  if GHL=$(s2a_gpu_hang "$O/live/host.log"); then RED=1; GPUHANG=1; WHY="GPU 卡死即停：${GHL}"
  elif [ "${FS_STOP:-0}" = 1 ] && hasl '【红】出图未满屏'; then RED=1; WHY="首帧满屏红即停：$(LC_ALL=C /usr/bin/grep -a '【红】出图未满屏' "$O/live/host.log" | head -1 | sed 's/.*【红】//' | cut -c1-120)"
  elif [ -n "$CEND" ]; then RED=1; WHY="App 提前退出（控制台流结束，$(texit)）"
  elif [ -z "${SEEN:-}" ] && [ $el -ge 30 ]; then RED=1; WHY="起局 ${el} 秒 host.log 仍为空"
  elif [ $el -ge 60 ] && ! hasl 'S2A 就绪'; then RED=1; WHY="起局 ${el} 秒没有「S2A 就绪」"
  elif [ -n "$BL" ] && read -r bp bs <<< "$BL" && [ "$bs" != 充电中 ] && [ "$bs" != 已充满 ] && { { [ -z "${BS0:-}" ] && BS0=$bp && [ "$bp" -lt 60 ]; } || [ "$bp" -lt 30 ]; }; then
    RED=1; SKIP=1   # 电量闸是测试环境的前置条件，不是游戏的红：收成 skip（未跑）
    if [ "$bp" -lt 30 ]; then WHY="电量 $bp% 低于 30%（未充电），停局并暂停真机局"; echo "$(date '+%m-%d %H:%M:%S') 电量 ${bp}%（App 读数，执行器局中）" > "$BD/device_low_battery"
    else WHY="开局电量 $bp% 低于 60%（未充电），本局不跑"; fi
  elif [ -z "${FSEEN:-}" ] && [ $el -ge 60 ]; then RED=1; WHY="起局 ${el} 秒还没出帧"
  elif [ $n -gt 0 ] && [ "$stl" -ge "$STL" ] && slowgpu; then t "出图停在第 $n 帧，但宿主最近报「GPU 慢…继续等」：再等（渲染器自己 20 秒判卡死）"
  elif [ $n -gt 0 ] && [ "$stl" -ge "$STL" ]; then
    # 判红前先重读一次最新帧（10-27 R13 坑 2）：live 副本滞后约 30 秒，静快照会把仍在出图的局判成「出图停在」。
    #   重读后帧号涨了 = 设备还在出图，按新帧续命；没涨、也不是「GPU 慢」才判红
    n_before=$n; [ "${S2A_FRAME_RECHECK:-1}" = 0 ] || reframe || t "  测试段已到截止：不再重读最新帧，直接按现有帧判停"
    [ "$n" -gt "$n_before" ] && t "出图停在第 $n_before 帧已 $stl 秒：判红前重读，设备已到第 $n 帧（live 副本滞后），继续等"
    if [ $n -gt 0 ] && [ "$stl" -ge "$STL" ] && ! slowgpu; then
      hgs=$(( $(date +%s) - HG_T ))
      if [ "$HG_T" -gt "$tch" ]; then RED=1; WHY="出图停在第 $n 帧已 $stl 秒"   # 停帧之后来过新心跳、帧号没涨 = 真停帧
      # 停帧之后没来过新心跳：心跳迟到（Duo 实见）、拉取不新鲜，或整个进程连主线程都停了，分不清——不判；满 3 倍判据仍没新心跳才判红，原因写明
      elif [ "$hgs" -ge $(( STL * 3 )) ]; then RED=1; WHY="出图停在第 $n 帧已 $stl 秒（拉回的 host.log 也 $hgs 秒没有新心跳：心跳停或拉取一直不更新）"
      else NFS=$(( ${NFS:-0} + 1 )); t "出图停在第 $n 帧已 $stl 秒，但拉回的 host.log 自那以后没有新心跳（$hgs 秒，拉取不新鲜 / 心跳迟到）：不判停，等新鲜读数（本局第 ${NFS} 次）"; fi
    fi
  fi
  [ -n "$RED" ] && { t "【红】出错即停：${WHY}（起局后 $el 秒）"; break; }
  if [ -z "$MK" ]; then
    MK=$(sed -n 's/.*S2A 标记 MARK：帧 \([0-9]*\).*/\1/p' "$O/live/host.log" 2>/dev/null | head -1)
    [ -n "$MK" ] && { T_MK=$(date +%s); W_EL=$el; W_N=$n; pw pwh.plist; [ -n "$ALT_S" ] && : > "$O/pwalt.tsv"; scr mark; t "窗口起点：起局后 $el 秒、第 $n 帧（MARK 帧 ${MK}），采 $ACT_S 秒"; }
  fi
  if [ -n "$W_EL" ] && [ -n "$ALT_S" ]; then   # 同局交替：段内两次采样（见上）；一次轮询跨过的采样点逐个补，迟到太多的不采
    d=$(( $(date +%s) - T_MK ))
    while :; do
      if [ "$ALT_PH" = a ]; then tg=$(( ALT_K * ALT_S + ALT_G1 )); else tg=$(( (ALT_K + 1) * ALT_S - ALT_G2 )); fi
      [ "$d" -ge "$tg" ] || break
      if [ $(( d - tg )) -le $(( ALT_PC + 1 )) ]; then pw "pwalt_${ALT_K}${ALT_PH}.plist"; echo "$ALT_K $ALT_PH $tg $(( $(date +%s) - T_MK ))" >> "$O/pwalt.tsv"
      else echo "$ALT_K $ALT_PH $tg 迟到 $d" >> "$O/pwalt.tsv"; fi
      if [ "$ALT_PH" = a ]; then ALT_PH=b; else ALT_PH=a; ALT_K=$(( ALT_K + 1 )); fi
    done
  fi
  if [ -n "$W_EL" ] && [ $el -ge $(( W_EL + ACT_S )) ]; then
    if [ $n -le "$W_N" ] && [ "${S2A_FRAME_RECHECK:-1}" != 0 ]; then   # 同上：判红前重读最新帧
      n_before=$n; reframe || t "  测试段已到截止：不再重读最新帧，直接按现有帧判停"
      [ "$n" -gt "$n_before" ] && t "窗口内没出新帧（停在第 $n_before 帧）：判红前重读，设备已到第 $n 帧，继续等"
    fi
    [ $n -gt "$W_N" ] || { RED=1; WHY="窗口 $(( el - W_EL )) 秒内没出新帧（停在第 $n 帧）"; t "【红】$WHY"; break; }
    t "收局：窗口 $(( el - W_EL )) 秒、$(( n - W_N )) 帧（起局后 $el 秒）"; break
  fi
  [ -z "$MK" ] && [ $el -ge "${ARRIVE_S:-$SEC}" ] && { RED=1; WHY="起局 ${el} 秒没到达代表场景（没有 MARK）"; t "【红】$WHY"; break; }
  if [ $el -ge $SEC ]; then   # 到测试段上限：已 MARK 且窗口 ≥ 60 秒按正常收局（窗口截短），否则判红
    if [ -n "$W_EL" ] && [ $(( el - W_EL )) -ge 60 ]; then t "收局：窗口截到测试段上限，采了 $(( el - W_EL )) 秒（要 ${ACT_S}）、$(( n - W_N )) 帧（起局后 $el 秒）"; break; fi
    RED=1; WHY="窗口没采满：到测试段上限（起局后 $SEC 秒）"; t "【红】$WHY"; break; fi
done
T_END=$(date +%s)
rem() { echo $(( W0 + CAP - ${S2A_END_MARGIN_S:-10} - $(date +%s) )); }   # 测试段还剩几秒（给看门狗留 S2A_END_MARGIN_S 秒余量）
ptry() {   # ptry <源> <目标> [最少秒数]：剩余预算够就拉一次（限时 = min(120, 剩余)），不够就跳过并记一行
  local r; r=$(rem); [ "$r" -ge "${3:-5}" ] || { t "拉回 $1 跳过：测试段只剩 ${r} 秒"; return 1; }
  [ -n "${PHUNG:-}" ] && { echo "$1" >> "$O/pending_pull.txt"; return 1; }
  [ "$r" -gt "${S2A_END_PULL_T:-120}" ] && r=${S2A_END_PULL_T:-120}; CPF_T=$r cpfrom "$1" "$2"; local c=$?
  [ $c = 124 ] && [ "$CONS" = 1 ] && { PHUNG=1; echo "$1" >> "$O/pending_pull.txt"; t "【黄】收局拉 $1 超 ${r} 秒（文件服务挂住）：余下拉回跳过、记待拉（pending_pull.txt）"; }
  return $c
}
[ -z "${GPUHANG:-}" ] && [ "$(rem)" -ge "${S2A_SHOT_MIN_S:-45}" ] && scr end   # GPU 卡死 / 日志暴涨不截（截屏最多 30 秒，先结束 App）；收局前（App 还在屏上）截一张；测试段剩不到 45 秒就不截（截屏最多 30 秒，先保拉回）
if [ "$CONS" = 1 ]; then
  kill -TERM "$CPID" 2> /dev/null; i=0; while kill -0 "$CPID" 2> /dev/null && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
  kill -0 "$CPID" 2> /dev/null && { kill -KILL "$CPID" 2> /dev/null; t "【黄】控制台流 15 秒没收住，强杀（App 可能还在，下局开局清残留）"; }
  con2log; PID=$(jget "$O/launch.json" result.process.processIdentifier); t "收局：控制台流 $(wc -l < "$O/live/host.log" | tr -d ' ') 行，App pid=${PID:-无}、$(texit)"
else [ -n "${PID:-}" ] && dcp 15 device process terminate --device "$D" --pid "$PID" > /dev/null 2>&1; fi
# 收局核实（11-07 维护者：ab_pre3d2 收局 done 后进程又活了约 20 分钟）：按本包安装路径列进程，还在就补 terminate / SIGKILL，停不掉判红；核实干净才撤登记
if [ -z "$APPDIRS" ]; then t "【黄】收局核实跳过：取不到 $B 的安装路径（登记留着，下一局起局前再清）"
else sleep "${S2A_KILL_VERIFY_S:-2}"; KL0=$(procs_in "$APPDIRS")   # 先给正常退出留 2 秒，免得把退出中的进程当残留
  if [ -z "$KL0" ]; then rm -f "$ALR/$B"
  else KL=$(kill_verify "$APPDIRS")
    if [ -n "$KL" ]; then RED=1; WHY="${WHY:+${WHY}；}收局后 App 进程停不掉（pid $(echo $KL)）"; t "【红】收局后 App 进程 $(echo $KL) terminate + SIGKILL 都没停掉"
    else t "收局核实：App 进程 $(echo $KL0) 收局后还在，已补停（terminate / SIGKILL 后核实没了）"; rm -f "$ALR/$B"; fi
  fi
fi
[ "$(rem)" -ge 25 ] && pw pw1.plist
for f in host.log frames.tsv unpack.log cold_start.txt ${PULL:-}; do ptry "Documents/$f" "$O/$(basename "$f")" || t "拉回 $f 失败"; done
for f in ap_summary.json threads.txt; do ptry "Documents/$f" "$O/$f" 10 2> /dev/null; [ -s "$O/$f" ] || rm -f "$O/$f"; done
# 记下本局 host.log / frames.tsv 的内容哈希（下局起局前用来认「中间有没有人自己玩过」，见 ownplay）；本局不是冷局但扫出首遇现编也报着色器线（冷局归首局格判）
[ -s "$O/host.log" ] && shasum -a 256 < "$O/host.log" | cut -c1-16 > "$BD/hostlog_head_${UD}_$B"
[ -s "$O/frames.tsv" ] && shasum -a 256 < "$O/frames.tsv" | cut -c1-16 > "$BD/frames_sha_${UD}_$B"
if [ "${COLD:-0}" != 1 ] && [ -s "$O/host.log" ]; then FU=$(python3 "$TOOLS/firstuse_scan.py" "$O" 2>/dev/null); [ "${FU%%	*}" -gt 0 ] 2>/dev/null && { t "非冷局首遇现编 ${FU%%	*}（${FU#*	}）"; mkdir -p "${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}/inbox"; echo "$(date '+%m-%d %H:%M:%S') 🟡 非冷局首遇现编 ${FU%%	*} 次：${GAME:-$B}（${FU#*	}；局 ${O}）" >> "${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}/inbox/画面着色器.log"; }; fi   # 自动玩家轨迹 / 小结（走路线的局没有）、全线程现场（崩溃 / GPU 卡死前原生层写）；空 = 本局没写
# 本局新遇到的着色器（画面·着色器线 C①，10-21 维护者定：遇到包里没有的代码自动收回、并入下一版包）：起局时 graphics/loop/ShaderPack.cs 把包内 Ryujinx 缓存种进
#   Documents/S2A/ryujinx/games/<程序号>/cache/shader/，运行中 Ryujinx 往后追加包里没有的程序；收局（成功 / 红局都拉）拉回 shcache_rt/，收集与重烘归着色器线。
#   程序号取包里 shaders/shcache/<程序号>/ 那一层；拉不到只记一行、不判红
TIDL=$(tidl)
if [ ! -d "$J/pack/shaders/shcache/$TIDL" ] || [ -z "$TIDL" ]; then t "着色器缓存拉回跳过：包里没有 shaders/shcache/<程序号>/"
elif [ "$(rem)" -ge 20 ]; then mkdir -p "$O/shcache_rt"
  for f in guest.toc guest.data shared.toc shared.data; do ptry "Documents/S2A/ryujinx/games/$TIDL/cache/shader/$f" "$O/shcache_rt/$f" 10 2> /dev/null; [ -s "$O/shcache_rt/$f" ] || rm -f "$O/shcache_rt/$f"; done
  nr=$(ls "$O/shcache_rt" | wc -l | tr -d ' '); [ "$nr" = 4 ] && t "着色器缓存：拉回 shcache_rt/ 4 个文件 $(du -sk "$O/shcache_rt" | cut -f1) KB（程序号 ${TIDL}）" || t "着色器缓存拉回不全：${nr}/4 个文件（程序号 ${TIDL}，不判红）"
  # 同时把这局装的包的缓存克隆进 pkg_shcache/（APFS 克隆不占盘）：收集器核「包干不干净」原先只认作业里 PKG 指的包快照，快照按 gc 规则只留最近几版，
  #   收集器晚到时已删 → 整局「不收」（10-23 丝之歌 8 局 7 局如此）；局目录自带包缓存后核查不再依赖快照存活
  [ "$nr" = 4 ] && [ -f "$J/pack/shaders/shcache/$TIDL/shared.toc" ] && { rm -rf "$O/pkg_shcache"; cp -cR "$J/pack/shaders/shcache/$TIDL/." "$O/pkg_shcache" 2> /dev/null || t "包缓存克隆进 pkg_shcache/ 失败（收集器回退到包快照）"; }
else t "着色器缓存拉回跳过：测试段只剩 $(rem) 秒"; fi
# 直连兜底现编产物（现编回收 R1，docs/研究/现编回收方案.md）：Documents/wire/<程序号大写>/shaders/ 整个目录拉回 direct_rt/，出包时 graphics/tools/direct/rt_collect.py 出线索表、本机重出；
#   拉不到 / 没有这个目录（通用模式局、没现编过）只记一行、不判红
if [ -n "$TIDL" ] && [ "$(rem)" -ge 20 ]; then TIDU=$(echo "$TIDL" | tr 'a-f' 'A-F')
  ptry "Documents/wire/$TIDU/shaders" "$O/direct_rt" 10 2> /dev/null
  vk_spv_keep "$O/direct_rt/vk" "$TIDU"
  nd=$(ls "$O/direct_rt" 2> /dev/null | wc -l | tr -d ' '); [ "${nd:-0}" -gt 0 ] && t "直连兜底现编：拉回 direct_rt/ ${nd} 个文件" || { rm -rf "$O/direct_rt"; t "直连兜底现编：设备上没有 wire/$TIDU/shaders/（没现编过或通用模式局）"; }
else t "【黄】直连兜底现编拉回跳过：$([ -z "$TIDL" ] && echo '取不到本包程序号' || echo "测试段只剩 $(rem) 秒")（现编产物 / vk_spv 本局不回流）"; fi
# 管线种子表来源（画面·着色器线 10-25）：本局机上见过的管线表 Documents/wire/<程序号大写>/pso_user.tsv 拉回 pso_seed/<程序号>/（pso_keep），
#   只有 game.tsv 的款出库时 graphics/tools/direct/pso_seed.py 合并进随包 pso_manifest.tsv（别的版本 / 结构的行出库时滤掉）；拉不到只记一行、不判红
if [ -n "$TIDL" ] && [ "$(rem)" -ge 15 ]; then
  ptry "Documents/wire/$(echo "$TIDL" | tr 'a-f' 'A-F')/pso_user.tsv" "$O/pso_user_dev.tsv" 10 2> /dev/null; pso_keep "$O/pso_user_dev.tsv" 局末
fi
na=0; [ "$(rem)" -ge 30 ] && for p in $(aps); do mkdir -p "$O/shots_ap"; ptry "Documents/$p" "$O/shots_ap/$p" 10 2> /dev/null; if [ -s "$O/shots_ap/$p" ]; then na=$((na + 1)); else rm -f "$O/shots_ap/$p"; fi; done   # 自动玩家截图（上局的已盖空，空 = 本局没截）
[ $na -gt 0 ] && t "自动玩家截图：拉回 $na 张（shots_ap/）"
# 控制台模式 host.log 没拉回：用控制台流顶上（只有原生层行，C# 侧的帧节拍 / GPU 慢等不在里面）
if [ "$CONS" = 1 ] && [ ! -s "$O/host.log" ] && [ -s "$O/live/host.log" ]; then cp "$O/live/host.log" "$O/host.log"; t "【黄】host.log 没拉回：用控制台流顶上（$(wc -l < "$O/host.log" | tr -d ' ') 行；C# 侧行缺）"; fi
[ -n "$BR" ] && { touch "$O/vision/stop"; for _ in $(seq 1 50); do kill -0 "$BR" 2> /dev/null || break; sleep 0.5; done; kill "$BR" 2> /dev/null
  t "驾驶员桥停：答了 $(grep -c ' 答（' "$O/vision/bridge.log" 2> /dev/null || echo 0) 问"; }
disarm; trap - TERM; T_PULL=$(date +%s); devlock_release; trap - EXIT
d_() { [ -n "$1" ] && [ -n "$2" ] && echo $(( $2 - $1 )) || echo -; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(d_ $T_REQ $T_LOCK)" "$(d_ $T_LOCK $T_INST)" "$(d_ $T_INST $T_PUSH)" "$(d_ $T_PUSH "${T_FF:-}")" "$(d_ "${T_FF:-}" "${T_MK:-}")" "$(d_ "${T_MK:-}" $T_END)" "$(d_ $T_END $T_PULL)" "$(d_ $T_LOCK $T_PULL)" > "$O/timing.tsv"
t "用时（秒）：取锁等待 / 装包 / 推送 / 起局到首帧 / 首帧到 MARK / MARK 到收局 / 拉回 / 合计 = $(tr '\t' ' ' < "$O/timing.tsv")"

# 收局判定：崩溃 / 报红数 / 满屏 / 每帧分配闸门
cr=$(LC_ALL=C /usr/bin/grep -ac 'CRASH' "$O/host.log" 2>/dev/null); cr=${cr:-0}
RED_EMPTY='【红】未实现服务：[[:space:]]*$'   # 服务层退出时必打的汇总行，列表为空 = 0 个未实现服务，不计红（同 tools/redline.py；10-20 维护者裁定）
nred=$(LC_ALL=C /usr/bin/grep -a '【红】' "$O/host.log" 2>/dev/null | grep -v '出图未满屏' | LC_ALL=C /usr/bin/grep -avc -E "$RED_EMPTY"); nred=${nred:-0}
# 按「名/号」归并（行尾的「（…第 N 次）x0=…」各行不同，整行去重会把同一个号数成很多种）
LC_ALL=C /usr/bin/grep -a '【红】未实现' "$O/host.log" 2>/dev/null | LC_ALL=C /usr/bin/grep -av -E "$RED_EMPTY" | sed 's/.*【红】未实现：//; s/[（ ].*//' | sort | uniq -c | sort -rn > "$O/unimpl.txt"
python3 "$TOOLS/frame_gate.py" "$O" > "$O/gate.txt"; GATE=$(cat "$O/gate.txt")
t "拉回 host.log $(wc -c < "$O/host.log" 2>/dev/null | tr -d ' ') 字节；CRASH ${cr}；宿主报红 $nred 行（未实现 $(wc -l < "$O/unimpl.txt" | tr -d ' ') 种）；分配闸门 ${GATE/	/：}"
GM=$(grep -a -m1 -E '图形模式：(直连|通用)' "$O/host.log" 2> /dev/null | sed 's/^.*图形模式：//' | cut -c1-160); echo "${GM:-未知}" > "$O/gfx_mode.txt"
t "本局图形模式：${GM:-未知（host.log 没有「图形模式」行）}"   # 记分板按它分直连 / 通用格（tools/score_cells.py gfx_mode）
# 五问帧率格（11-02 维护者：真机局按 frames.tsv 墙钟出，与记分板 / quality_check 同口径 tools/score_cells.py fps_window；
#   不引用 host.log「帧节拍：交换间隔」——那是游戏请求的节拍不是实测：回归 E2 一款第一方动作冒险游戏照抄成「60 帧」，实测 19.99 帧/秒、慢帧 99.92%）。--diag=1 只打印不写记分板
FR=$(python3 "$TOOLS/score_cells.py" "$O" --game="${GAME:-?}" --diag=1 2> "$O/score.notes" | awk -F'\t' '{print $6 "\t" $10}')
t "五问帧率格：${FR%%	*}（${FR#*	}）"
[ "$cr" -gt 0 ] && [ -z "$RED" ] && { RED=1; WHY=崩溃; }
case "$GATE" in 红*) [ -z "$RED" ] && { RED=1; WHY="分配闸门红：${GATE#*	}"; };; esac
uf=$(LC_ALL=C /usr/bin/grep -a '【红】出图未满屏' "$O/host.log" 2>/dev/null | head -1 | sed 's/.*【红】//' | cut -c1-160)
[ -n "$uf" ] && t "【红】${uf}（只进画面格，不停局）"
# 判据缺席不当通过（10-26 维护者：直连上屏 nvn_mtl.m 不打「[画] 满屏判据 已开」/「【红】出图未满屏」，没红行不等于满屏）：直连局一条满屏判据行都没有 → 记未验（画面格由 score_cells.fs_unverified 判未测）
if LC_ALL=C /usr/bin/grep -aq '图形模式：直连' "$O/host.log" 2>/dev/null && ! LC_ALL=C /usr/bin/grep -aq '\[画\] 满屏判据 已开' "$O/host.log" 2>/dev/null; then t "满屏：未验（直连无判据：host.log 没有「[画] 满屏判据 已开」，没红行不算满屏）"; fi
[ -n "${SKIP:-}" ] && fin skip "$WHY"   # 前置条件没满足（电量闸）：未跑，不带宿主红行、不改写成「没到 MARK」
# 自动玩家自己收的局（200 秒没进可玩 → 优雅退出）：出图停住 / 没出帧是它停的，不是游戏卡死，按「没到 MARK」报（10-21 原生层线：01007EF00011E000 卡 DLC 介绍页被报成「出图停在第 5723 帧」）
if [ -n "$RED" ] && [ -z "$MK" ] && LC_ALL=C /usr/bin/grep -aq '自动玩家结束：优雅退出' "$O/host.log" 2>/dev/null; then WHY="没到 MARK：自动玩家没进可玩、已结束并优雅退出（执行器原判：${WHY}）"; t "【红】$WHY"; fi
# 屏上有系统浮层（心跳「前台失焦」：UIApplication 失焦但仍在前台，如更新提示 / 控制中心）：写进结论，红不一定是游戏的（10-21 测试设备2 00:20 起浮层挡着 App）
nuf=$(LC_ALL=C /usr/bin/grep -a '\[心跳\] ' "$O/host.log" 2>/dev/null | LC_ALL=C /usr/bin/grep -ac '前台失焦'); nuf=${nuf:-0}
#   来源不止一种（10-25 国行机「无线数据」联网提示框：10-26 取证推翻「答一次不允许就不再弹」：包名禁网时 App 进程里听写框架一查网络就再弹，要选「仅限无线局域网」；10-26 测试设备2「软件更新 iOS 27.0.1 可以安装」框被当成无线数据报，
#   提示 维护者 点错）：按局中首次失焦时的整屏截图里的文字分类（tools/sysdialog.sh：无线数据 / 软件更新 / 其他系统框 / 未识别），照实写类别和该点的按钮
if [ "$nuf" -gt 0 ]; then
  IFS=$'\t' read -r UFC UFA UFT <<< "$(bash "$TOOLS/sysdialog.sh" "$O/screen/unfocus.png")"; printf '%s\t%s\t%s\n' "$UFC" "$UFA" "$UFT" > "$O/sysdialog.tsv"
  FOC="测试设备屏上有系统弹框（心跳 $nuf 次「前台失焦」；类别：${UFC}；请在测试设备 $D 上${UFA}$([ "$UFC" = 无线数据 ] && echo "，包名 $B")${UFT:+；屏上文字：$UFT}）"; t "【黄】$FOC"
fi
# 未写先采样（渲染器缺省常开，gal_tex.m gal_uw_*；10-23 帧率能耗线：八方2 地面黑块等「贴图新建后没写过就被采样」，哪局自然出现现场就在哪局）：
# 有就并进结论（红 / 绿都带），只是提示，不改红绿
nuw=$(LC_ALL=C /usr/bin/grep -ac '【未写先采样】' "$O/host.log" 2>/dev/null); nuw=${nuw:-0}
if [ "$nuw" -gt 0 ]; then
  uw1=$(LC_ALL=C /usr/bin/grep -a '【未写先采样】' "$O/host.log" | head -1 | sed 's/.*【未写先采样】//' | cut -c1-120)
  UWL="未写先采样 ${nuw} 张（首张${uw1}）"; t "【黄】${UWL}"; FOC="${FOC:+${FOC}；}${UWL}"
fi
# 有前台失焦的局一律记可疑（10-26 维护者）：弹框挡着时的红 / 绿都说明不了游戏，不给绿也不记红；执行器原判写在后面备查
[ "$nuf" -gt 0 ] && fin suspect "可疑：系统弹框致前台失焦；${FOC}$([ -n "$RED" ] && echo "；执行器原判红：$WHY")" 1
if [ -n "$RED" ]; then   # 结论带上宿主最后一条红行（执行器只看得到「出图停住」，真正原因如 GPU 卡死在宿主日志里，曾被读漏）
  hr=$(LC_ALL=C /usr/bin/grep -a '【红】' "$O/host.log" 2>/dev/null | grep -v '出图未满屏' | LC_ALL=C /usr/bin/grep -av -E "$RED_EMPTY" | tail -1 | sed 's/.*【红】//' | cut -c1-120)
  [ -n "$hr" ] && WHY="${WHY}；宿主最后红行：$hr"
  fin red "$WHY${FOC:+；$FOC}"
fi
fin done "${FOC:-}" 0
