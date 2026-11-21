#!/usr/bin/env bash
# 门禁覆盖：android/tests/devprofiles/* tools/devprofile_lint.py android/tools/device_profile.py android/native/direct/dev_facts.c
# 接线：android/test.sh 调本脚本
# 设备档案（s2a-device-profile-v1，#1749 M0）的白名单校验与导出工具：
#   正例：入库的每份档案过 lint；反例：类型错 / 缺键 / 摘要不符 / 格式名不在表里 / probes 段乱塞，各自红在对应原因上；
#   隐私负对照：往档案里塞白名单外的键（序列号、build fingerprint、安装路径这类）→ 必须红「白名单外的键」；
#   导出工具：诊断包取法、debug 包 run-as 取法（adb 用替身）各取一份，产物与原档案逐字节相同；坏档案不写。
# 期望全部来自档案文件本身与反例的构造，不跑被测实现求期望。宿主 python3 即可，约 2 秒。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
PY=${PY:-python3}
lint="$repo/tools/devprofile_lint.py"
mkdir -p "$repo/build/devprofile-lint"
out=$(mktemp -d "$repo/build/devprofile-lint/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT

shopt -s nullglob
profiles=("$repo"/android/tests/devprofiles/*.json)
[ ${#profiles[@]} -ge 3 ] || { echo "【红】android/tests/devprofiles 下档案不足 3 份（${#profiles[@]}）"; exit 1; }
"$PY" "$lint" "${profiles[@]}"
echo "PASS: 正例 ${#profiles[@]} 份入库档案过白名单与摘要校验"

base="$repo/android/tests/devprofiles/mali-g710-r32p1.json"
export REPO="$repo"
n=0
bad() {   # $1 名字 $2 改法（Python：p 是档案对象）$3 是否重算摘要（1 / 0）$4 红因里必须有的字 [$5 底档，缺省 mali 那份]
  "$PY" - "${5:-$base}" "$out/bad.json" "$2" "$3" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ['REPO'], 'tools'))
import devprofile_lint as l
src, dst, code, redigest = sys.argv[1:]
p = json.load(open(src))
exec(code)
if redigest == '1': p['factsDigest'] = l.digest(p)
open(dst, 'w').write(json.dumps(p, ensure_ascii=False))
PY
  if "$PY" "$lint" "$out/bad.json" > "$out/bad.log" 2>&1; then echo "【红】反例漏抓：$1 —— lint 照样绿"; cat "$out/bad.log"; exit 1; fi
  grep -q -- "$4" "$out/bad.log" || { echo "【红】反例红错了地方：$1 —— 红因里没有「$4」"; cat "$out/bad.log"; exit 1; }
  echo "PASS: 反例 $1 → 红（$(grep -m1 -- "$4" "$out/bad.log" | sed 's/^【红】[^ ]* //')）"
  n=$((n + 1))
}
# 隐私负对照：白名单外的键，摘要照算（证明拦它的是白名单，不是摘要）
bad '顶层塞序列号' "p['serial'] = 'R5CT1234567'" 1 '\$\.serial：白名单外的键'
bad '身份段塞 ro.serialno' "p['identity']['ro.serialno'] = 'R5CT1234567'" 1 'identity.ro.serialno：白名单外的键'
bad '机型段塞完整 build fingerprint' "p['model']['fingerprint'] = 'vendor/device:14/UP1A/1:user/release-keys'" 1 'model.fingerprint：白名单外的键'
bad '系统段塞安装路径' "p['system']['installPath'] = '/data/app/~~x==/org.s2arm.android-y==/base.apk'" 1 'system.installPath：白名单外的键'
bad '限值里塞账号' "p['vulkan']['properties']['limits']['account'] = 'someone'" 1 'limits.account：白名单外的键'
bad 'probes 段塞任意键' "p['probes'] = {'imei': '490154203237518'}" 1 'probes.imei：白名单外的键'
# 其余反例
bad '改了限值不重算摘要' "p['vulkan']['properties']['limits']['maxImageDimension2D'] += 1" 0 'factsDigest：与内容不符'
bad '特性取值不是 0/1' "p['vulkan']['features']['depthClamp'] = 2" 1 'features.depthClamp：取值 2'
bad '缺必填键' "del p['identity']['deviceName']" 1 'identity.deviceName：缺必填键'
bad '格式名不在事实表里' "p['vulkan']['formats']['VK_FORMAT_R64_SFLOAT'] = [0, 0, 0]" 1 'formats.VK_FORMAT_R64_SFLOAT：白名单外的键'
bad '厂商号不是 hex 串' "p['identity']['vendorId'] = 5045" 1 'identity.vendorId：应为字符串'
bad '扩展三态之外的值' "p['vulkan']['extensions']['VK_KHR_swapchain'] = 2" 1 'extensions.VK_KHR_swapchain：取值 2'
# 元数据 provenance / completeness / sources（不进摘要：改它们不用重算 factsDigest）
minimal="$repo/android/tests/devprofiles/minimal-1.1.json"
bad 'assembled 缺非保守字段的出处' "del p['sources']['vulkan.properties.maxPerSetDescriptors']" 0 'maxPerSetDescriptors：值 1024 不是「不支持」' "$minimal"
bad 'assembled 整段没有 sources' "del p['sources']" 0 'assembled 档案必须带 sources' "$minimal"
bad 'assembled 出处指向不存在的字段' "p['sources']['vulkan.properties.noSuchLimit'] = 'x'" 0 '出处指向档案里没有的字段' "$minimal"
bad 'probed 带 sources' "p['sources'] = {'vulkan.formats': 'gpuinfo 报告 1'}" 0 'probed 档案不许带 sources'
bad 'provenance 非法值' "p['provenance'] = 'guessed'" 0 'provenance：格式不对'
bad 'completeness 非法值' "p['completeness'] = 'mostly'" 0 'completeness：格式不对'
bad '缺 provenance' "del p['provenance']" 0 'provenance：缺必填键'
"$PY" - "$minimal" "$out/meta.json" <<'PY'
import json, sys; p = json.load(open(sys.argv[1])); p.update(provenance='probed', completeness='complete'); p.pop('sources'); open(sys.argv[2], 'w').write(json.dumps(p))
PY
"$PY" "$lint" "$out/meta.json" > /dev/null || { echo "【红】改元数据（provenance / completeness / 去 sources）不该动 factsDigest，lint 却红了"; exit 1; }
echo "PASS: 元数据不进摘要：改 provenance / completeness、去掉 sources 后不重算 factsDigest 照样过"
echo "PASS: 反例 $n 种全部按预期变红（其中隐私负对照 6 种、元数据 7 种）"

# 导出工具：诊断包取法
name=$(basename "$base" .json)
gen=0123456789abcdef
# 诊断包的样子：manifest.json + logs/host.log + devprofile/<名>.json（DiagnosticBundleWriter）
"$PY" -c "import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('manifest.json', '{}'); z.writestr('logs/host.log', 'x'); z.write(sys.argv[2], 'devprofile/$gen.json')" "$out/bundle.zip" "$base"
"$PY" "$repo/android/tools/device_profile.py" --bundle "$out/bundle.zip" --out "$out/got" --name "$name"
cmp -s "$out/got/$name.json" "$base" || { echo "【红】导出工具（诊断包）取出的档案和原文件不一致"; diff "$out/got/$name.json" "$base" | head; exit 1; }
echo "PASS: 导出工具（诊断包取法）：取出的档案与原文件逐字节相同"
# debug 包取法：adb 替身只认 run-as 的 ls -t / cat 两条命令（多放一份旧代和一个别的文件，必须取最新那一代）
mkdir -p "$out/phone/files/devprofile"
cp "$base" "$out/phone/files/devprofile/$gen.json"
echo '{}' > "$out/phone/files/devprofile/fedcba9876543210.json"
echo x > "$out/phone/files/devprofile/notes.txt"
cat > "$out/adb" <<EOF
#!/usr/bin/env bash
[ "\$1" = -s ] && shift 2
case "\$*" in
  "shell run-as org.s2arm.android ls -t files/devprofile") printf '%s\n' notes.txt $gen.json fedcba9876543210.json ;;
  "exec-out run-as org.s2arm.android cat files/devprofile/"*) cat "$out/phone/\${@: -1}" ;;
  *) echo "adb 替身：不认识的命令 \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$out/adb"
ADB="$out/adb" "$PY" "$repo/android/tools/device_profile.py" --serial FAKE --out "$out/got-debug" --name "$name"
cmp -s "$out/got-debug/$name.json" "$base" || { echo "【红】导出工具（run-as）取出的档案和原文件不一致"; exit 1; }
echo "PASS: 导出工具（debug 包 run-as 取法，adb 替身）：取最新一代、与原文件逐字节相同"
# 坏档案不写：手机上那份被塞了白名单外的键
"$PY" -c "import json,sys; p=json.load(open(sys.argv[1])); p['serial']='R5CT1234567'; open(sys.argv[2],'w').write(json.dumps(p))" "$base" "$out/phone/files/devprofile/$gen.json"
if ADB="$out/adb" "$PY" "$repo/android/tools/device_profile.py" --out "$out/got-bad" > "$out/bad-export.log" 2>&1; then
  echo "【红】导出工具把没过白名单的档案写出来了"; cat "$out/bad-export.log"; exit 1
fi
[ ! -e "$out/got-bad" ] || [ -z "$(ls -A "$out/got-bad")" ] || { echo "【红】导出工具红了却留下了文件"; exit 1; }
grep -q '白名单外的键' "$out/bad-export.log" || { echo "【红】导出工具红因不对"; cat "$out/bad-export.log"; exit 1; }
echo "PASS: 导出工具（负对照）：手机上的档案塞了白名单外的键 → 拒绝、不写文件"
