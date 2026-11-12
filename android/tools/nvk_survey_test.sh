#!/usr/bin/env bash
# android/tools/nvk_survey.sh 的宿主单测（假 adb，不需要设备、不需要游戏，约 2 秒）：bash android/tools/nvk_survey_test.sh
# 覆盖 #737 两处：
#   ① 游戏进程起局即崩（adb shell pidof 非零）时，脚本仍以 0 退出并写出 report.md / logcat.txt / crash.txt，
#      报告写「游戏进程 | 没了」、崩溃节有内容；设备中途掉线（logcat / crash / screencap 全失败）同样出报告，
#      缺项进「提示」；adb devices 自己失败时按原来的红字退出 2，不是被 pipefail 打断的半截退出。
#   ② screencap 输出带一行 [Warning] Multiple displays were found… 前缀时截回与输入逐字节相同的 PNG；
#      纯文本输入时不留下 screen.png、临时文件也不留，报告写「截图不可用」。
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }

# 假 adb：按 $FAKE 目录里的夹具决定本局设备表现；缺哪个夹具就按「设备上拿不到这一项」返回非零。
mkdir -p "$T/bin" "$T/home" "$T/work"
cat > "$T/bin/adb" <<'ADB'
#!/usr/bin/env bash
m=$FAKE
case $1 in
  devices) [ -e "$m/devices_fail" ] && exit 1; printf 'List of devices attached\nABCD1234\tdevice\n'; exit 0;;
  exec-out) [ -e "$m/screencap.bin" ] || exit 1; cat "$m/screencap.bin"; exit 0;;
  logcat) case $2$3 in
            -d-s) [ -e "$m/logcat.txt" ] || exit 1; cat "$m/logcat.txt";;
            -d-b) [ -e "$m/crash.txt" ] || exit 1; cat "$m/crash.txt";;
            *) exit 1;;
          esac; exit 0;;
  shell) case $2 in
           pidof) [ -e "$m/alive" ] || exit 1; echo 4242;;
           pm) echo 'package:/data/app/~~fake/base.apk';;
           getprop) echo fake;;
           dumpsys) echo 'DisplayDeviceInfo{fps=120.0}';;
           am) [ -e "$m/start_fail" ] && exit 1; echo 'Status: ok';;
           *) exit 0;;
         esac; exit 0;;
  *) exit 0;;
esac
ADB
chmod +x "$T/bin/adb"

# 合法 PNG 夹具：1×1 RGB，纯合成、不含任何游戏数据（同 tests/vision_env_test.sh 的做法）。
python3 - "$T/one.png" <<'PY'
import struct, sys, zlib
def ch(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
raw = b'\0' + b'\0\0\0'
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
PY

WARN='[Warning] Multiple displays were found. please use -d <display-id>'
run() {   # run <夹具目录> <秒数> <输出目录名> → 回显脚本退出码
  ( export FAKE="$T/$1" PATH="$T/bin:$PATH" HOME="$T/home"
    cd "$T/work" && bash "$here/nvk_survey.sh" 0100DCA0064A6000 "$2" "$T/$3" > "$T/$3.log" 2>&1 )
  echo $?
}

# ① 起局即崩：pidof 非零，日志与崩溃都在，截图带双屏警告前缀
mkdir -p "$T/crash"
cat > "$T/crash/logcat.txt" <<'LOG'
11-12 18:00:00.000  1000  1000 I S2Arm   : nvk session: backend open
11-12 18:00:00.100  1000  1000 I S2Arm   : 未接：nvnCommandBufferSetPatch
11-12 18:00:00.200  1000  1000 E S2Arm   : 【红】NVN device 0: 合成红行
LOG
printf '11-12 18:00:00.300  1000  1000 F DEBUG   : signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0\n' > "$T/crash/crash.txt"
{ printf '%s\n' "$WARN"; cat "$T/one.png"; } > "$T/crash/screencap.bin"
rc=$(run crash 0 out-crash)
echo "  起局即崩：退出码 ${rc}，目录 $(cd "$T/out-crash" 2> /dev/null && ls -1 | tr '\n' ' ')"
ck "① 起局即崩（pidof 非零）：退出码 0（实 ${rc}）" '[ "$rc" = 0 ]'
ck "① 起局即崩：report.md / logcat.txt / crash.txt 都在" '[ -s "$T/out-crash/report.md" ] && [ -f "$T/out-crash/logcat.txt" ] && [ -f "$T/out-crash/crash.txt" ]'
ck "① 起局即崩：报告写「游戏进程 | 没了」" 'grep -qx "| 游戏进程 | 没了 |" "$T/out-crash/report.md"'
ck "① 起局即崩：崩溃节有内容" 'grep -q "signal 11 (SIGSEGV)" "$T/out-crash/report.md"'
ck "① 起局即崩：未接清单照常摘出来（1 行）" 'grep -qx "nvnCommandBufferSetPatch" "$T/out-crash/report.md"'
echo "  报告关键行：$(sed -n "/游戏进程/p;/^截图：/p" "$T/out-crash/report.md" | tr '\n' ' ')"

# ② 双屏警告前缀的截图：截回逐字节相同的 PNG，临时文件不留
echo "  screen.png 文件头：$(od -An -tx1 -N8 "$T/out-crash/screen.png" 2> /dev/null | tr -d "\n")"
ck "② 带前缀截图：screen.png 落地" '[ -f "$T/out-crash/screen.png" ]'
ck "② 带前缀截图：与输入 PNG 逐字节相同" 'cmp -s "$T/one.png" "$T/out-crash/screen.png"'
ck "② 带前缀截图：报告写「截图：screen.png」" 'grep -q "^截图：screen.png；" "$T/out-crash/report.md"'
ck "② 带前缀截图：临时文件不留" '[ ! -e "$T/out-crash/.screen.png.tmp" ]'

# ② 纯文本截图：不留 screen.png，报告写「截图不可用」
mkdir -p "$T/textshot"
printf 'not a png at all\n' > "$T/textshot/screencap.bin"
rc=$(run textshot 0 out-text)
echo "  纯文本截图：退出码 ${rc}，目录 $(cd "$T/out-text" 2> /dev/null && ls -1 | tr '\n' ' ')"
ck "② 纯文本截图：退出码仍是 0（实 ${rc}）" '[ "$rc" = 0 ]'
ck "② 纯文本截图：不留 screen.png" '[ ! -e "$T/out-text/screen.png" ] && [ ! -e "$T/out-text/.screen.png.tmp" ]'
ck "② 纯文本截图：报告写「截图：截图不可用」" 'grep -q "^截图：截图不可用；" "$T/out-text/report.md"'
ck "② 纯文本截图：提示里说明原因" 'grep -q "截不出合法 PNG" "$T/out-text/report.md"'

# ① 设备中途掉线：logcat / crash / screencap 全失败，仍出三个文件、缺项进「提示」
mkdir -p "$T/offline"
rc=$(run offline 0 out-offline)
echo "  设备掉线：退出码 ${rc}，目录 $(cd "$T/out-offline" 2> /dev/null && ls -1 | tr '\n' ' ')"
ck "① 设备掉线：退出码 0（实 ${rc}）" '[ "$rc" = 0 ]'
ck "① 设备掉线：三个文件都在（空文件也算）" '[ -s "$T/out-offline/report.md" ] && [ -f "$T/out-offline/logcat.txt" ] && [ -f "$T/out-offline/crash.txt" ]'
ck "① 设备掉线：提示点名 logcat / crash / 截图" 'grep -q "logcat.txt 抓取失败" "$T/out-offline/report.md" && grep -q "crash.txt 抓取失败" "$T/out-offline/report.md" && grep -q "screencap 执行失败" "$T/out-offline/report.md"'
ck "① 设备掉线：不留 screen.png" '[ ! -e "$T/out-offline/screen.png" ]'

# ① adb devices 自己失败：按原来的红字退出 2，不是 pipefail 打断
mkdir -p "$T/nodev"; : > "$T/nodev/devices_fail"
rc=$(run nodev 0 out-nodev)
echo "  adb devices 失败：退出码 ${rc}，输出 $(tr '\n' ' ' < "$T/out-nodev.log")"
ck "① adb devices 失败：退出码 2（实 ${rc}）" '[ "$rc" = 2 ]'
ck "① adb devices 失败：给出红字提示" 'grep -q "没有接着的设备" "$T/out-nodev.log"'

[ $bad = 0 ] && echo "nvk_survey 单测全过" || { echo "nvk_survey 单测有不通"; exit 1; }
