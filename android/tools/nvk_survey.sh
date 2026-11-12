#!/usr/bin/env bash
# 新图形层设备普查：在接着的安卓设备上直连起一局，收齐回报要的 7 项，写成一个目录 + 一页 report.md。
#   bash android/tools/nvk_survey.sh <程序号> [秒数=60] [输出目录=./nvk-survey-<程序号>-<时间>]
# 前提：
#   · 设备上装的是新层的包（构建时带 S2ARM_ANDROID_VK_BACKEND=nvk，见 docs/安卓新图形层_联合开发.md）；
#   · 这款游戏已经在应用里导入过；
#   · adb 在 PATH 上，或设了 ANDROID_HOME / ANDROID_SDK_ROOT；接了多台设备时设 ANDROID_SERIAL。
# 只读数：不改设备上的游戏与存档；收完把调试属性复位、把游戏进程停掉。
# 收的 7 项（docs/安卓新图形层_联合开发.md「回报什么」）：
#   1 机型 / 芯片 / 系统版本 / 刷新率   2 程序号   3 未接清单   4 其它红行   5 最后一行呈现读数   6 截图   7 进程是否还在（没了附崩溃日志）
# 采集失败不中断（#737）：进程起局即崩、设备中途掉线、screencap 输出不合法，都照常写出 report.md 与
# logcat.txt / crash.txt，缺哪一项写在末尾「提示」里——起局即崩的机器正是普查最想要的样本。
set -euo pipefail
T=${1:?用法：nvk_survey.sh <程序号> [秒数=60] [输出目录]}
S=${2:-60}
case $T in [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;; *) echo "【红】程序号要 16 位十六进制：$T" >&2; exit 2;; esac
case $S in ''|*[!0-9]*) echo "【红】秒数要是整数：$S" >&2; exit 2;; esac
O=${3:-./nvk-survey-$T-$(date +%Y%m%d-%H%M%S)}
P=org.s2arm.android

ADB=$(command -v adb 2> /dev/null || true)
if [ -z "$ADB" ]; then
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$d" ] && [ -x "$d/platform-tools/adb" ]; then ADB=$d/platform-tools/adb; break; fi
  done
fi
[ -n "$ADB" ] || { echo "【红】找不到 adb（PATH、ANDROID_HOME、ANDROID_SDK_ROOT 都没有）" >&2; exit 2; }
a() { "$ADB" "$@" < /dev/null; }

# 从可能带前缀（双屏机的 screencap 会先往 stdout 打一行 [Warning] Multiple displays were found…）的字节流里
# 取出 PNG：在头 4 KB 里找到第一个 PNG 魔术字节，从那里截到文件尾；截完文件头仍不是 PNG 就算失败、不留半截文件。
png_extract() {
  local src=$1 dst=$2 off
  off=$(head -c 4096 "$src" | LC_ALL=C od -An -v -tu1 | awk '
    { for (i = 1; i <= NF; i++) b[++n] = $i }
    END {
      for (i = 1; i + 7 <= n; i++)
        if (b[i] == 137 && b[i+1] == 80 && b[i+2] == 78 && b[i+3] == 71 &&
            b[i+4] == 13 && b[i+5] == 10 && b[i+6] == 26 && b[i+7] == 10) { print i; exit 0 }
      exit 1
    }') || return 1
  tail -c +"$off" "$src" > "$dst" || return 1
  [ "$(head -c 8 "$dst" | LC_ALL=C od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] || { rm -f "$dst"; return 1; }
}

# pipefail 下 adb 返回非零会让整条管道非零，下面的采集都自己兜住：失败记在「提示」里，不中断。
n=$(a devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ' || true)
n=${n:-0}
if [ "$n" = 0 ]; then echo "【红】没有接着的设备（adb devices 里没有 device 状态的）" >&2; exit 2; fi
if [ "$n" != 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then echo "【红】接了 ${n} 台设备：设 ANDROID_SERIAL 指定一台" >&2; exit 2; fi
a shell pm path "$P" > /dev/null 2>&1 || { echo "【红】设备上没装 ${P}" >&2; exit 2; }

mkdir -p "$O"
prop() { a shell getprop "$1" | tr -d '\r'; }
restore() { a shell "am force-stop $P; setprop debug.s2a.debug_env 0" > /dev/null 2>&1 || true; }
trap restore EXIT

notes=""
note() { notes="${notes}- $1"$'\n'; }

start_ok=1
a shell "setprop debug.s2a.debug_env 1; am force-stop $P; logcat -c; logcat -b crash -c; input keyevent WAKEUP" || start_ok=0
a shell am start -W -n "$P/$P.MainActivity" --es s2arm.title_id "$T" --ez s2arm.experimental_revision true --es s2arm.graphics_mode direct > /dev/null || start_ok=0
[ "$start_ok" = 1 ] || note "起局命令失败（adb 报错或设备掉线），下面的读数可能不完整。"

t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$S" ]; do
  sleep 3
  if [ $((SECONDS - t0)) -gt 6 ] && [ -z "$(a shell pidof "$P:game" 2> /dev/null | tr -d '\r' || true)" ]; then break; fi   # 进程没了立刻收
done
waited=$((SECONDS - t0))
# 进程不在时 adb shell pidof 返回非零，pipefail 会把这条赋值也判成失败、set -e 直接在写报告前退出，
# 而「起局即崩」正是普查最想要的样本（#737），所以这里容错，进程没了照常写报告。
alive=$(a shell pidof "$P:game" 2> /dev/null | tr -d '\r' || true)
logcat_ok=1
a logcat -d -s S2Arm > "$O/logcat.txt" || logcat_ok=0
[ "$logcat_ok" = 1 ] || note "logcat.txt 抓取失败（设备可能已断开），报告里日志几节会是空的。"
LC_ALL=C grep -a -v 'prev|' "$O/logcat.txt" > "$O/this-run.txt" || true   # 带 prev| 的是应用转述的上一局日志，不算这一局的
crash_ok=1
a logcat -d -b crash > "$O/crash.txt" || crash_ok=0
[ "$crash_ok" = 1 ] || note "crash.txt 抓取失败（设备可能已断开），崩溃一节会是空的。"

# 截图先写临时文件、校验通过才落地：双屏机的 screencap 会先往 stdout 打一行
# [Warning] Multiple displays were found…，直接重定向得到的不是合法 PNG（#737）。
shot_state="截图不可用"
shot_tmp="$O/.screen.png.tmp"
shot_rc=0
"$ADB" exec-out screencap -p < /dev/null > "$shot_tmp" 2> /dev/null || shot_rc=$?
if png_extract "$shot_tmp" "$O/screen.png"; then
  shot_state="screen.png"
elif [ "$shot_rc" != 0 ]; then
  note "截图不可用：screencap 执行失败（设备可能已断开），没留 screen.png。"
else
  note "截图不可用：screencap 的输出里截不出合法 PNG，没留 screen.png。"
fi
rm -f "$shot_tmp"

g() { LC_ALL=C grep -a "$@" || true; }
hz=$(a shell dumpsys display 2> /dev/null | g -m1 -o -E 'fps=[0-9.]+' | head -1 || true)
session=$(g -E 'nvk session: backend open|graphics selection' "$O/this-run.txt" | sed 's/^.*S2Arm *: //' | tail -2)
unimpl=$(g '未接：' "$O/this-run.txt" | sed 's/.*未接：//; s/（首次.*//')
red=$(g '【红】' "$O/this-run.txt" | g -v '未接：' | sed 's/^.*S2Arm *: //' | cut -c1-200 | sort | uniq -c | sort -rn)
present=$(g 'nvk present: 第' "$O/this-run.txt" | sed 's/^.*nvk present: //' | tail -1)
crash=$(g -E 'signal |Abort message' "$O/crash.txt" | head -3 | cut -c1-200)

[ -n "$alive" ] || note "游戏进程没在跑（起局即崩或已经退出）：未接清单为空只代表还没走到，不代表都接了。"

{
  echo "# 新图形层设备普查"
  echo
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| 机型 | $(prop ro.product.manufacturer) $(prop ro.product.model) |"
  echo "| 芯片 | $(prop ro.soc.manufacturer) $(prop ro.soc.model)（平台 $(prop ro.board.platform)） |"
  echo "| 系统 | Android $(prop ro.build.version.release)（API $(prop ro.build.version.sdk)） |"
  echo "| 刷新率 | ${hz:-读不到} |"
  echo "| 程序号 | $T |"
  echo "| 仓库提交 | $(git -C "$(dirname "$0")" rev-parse --short HEAD 2> /dev/null || echo 不在仓库里跑) |"
  echo "| 起局后等了 | ${waited} 秒（上限 ${S}） |"
  if [ -n "$alive" ]; then echo "| 游戏进程 | 还在 |"; else echo "| 游戏进程 | 没了 |"; fi
  echo
  echo "## 选路与会话"
  echo '```'
  echo "${session:-（日志里没有会话行：多半没走到新层，核对包是不是带 nvk 编的）}"
  echo '```'
  echo "## 未接清单（每种一行，按首次出现的先后）"
  echo '```'
  echo "${unimpl:-（0 种）}"
  echo '```'
  echo "## 其它红行（去重计数）"
  echo '```'
  echo "${red:-（0 行）}"
  echo '```'
  echo "## 最后一行呈现读数"
  echo '```'
  echo "${present:-（没有：还没呈现满 600 帧，或没走到呈现）}"
  echo '```'
  echo "## 崩溃"
  echo '```'
  echo "${crash:-（无）}"
  echo '```'
  if [ -n "$notes" ]; then
    echo
    echo "## 提示"
    printf '%s' "$notes"
  fi
  echo
  echo "截图：${shot_state}；完整日志：logcat.txt；崩溃日志：crash.txt。回报时把这一页贴进 Issue，可用的文件作附件。"
} > "$O/report.md"
cat "$O/report.md"
echo
rm -f "$O/this-run.txt"
echo "已写到 ${O}/"
