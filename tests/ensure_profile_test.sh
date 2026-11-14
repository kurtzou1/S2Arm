#!/bin/bash
# 申请开发描述文件的红因单测（pack/ensure_profile.sh，假 xcodebuild，约 1 秒）：bash tests/ensure_profile_test.sh
#   ① 假 xcodebuild 打 Xcode 26 缺 iOS 平台组件的原文（「iOS 26.5 is not installed. Please download and install the platform from Xcode」）并退 65
#      → 退 1、有一行「【红】本机 Xcode 没装 iOS 平台组件 … xcodebuild -downloadPlatform iOS」（11-05 七龙珠Z 新包名签不了）
#   ② 别的编译错误（假 xcodebuild 打 error: Signing requires a development team）→ 退 1、不出平台组件那行（只认真缺平台）
#   ⑥ #897 免费个人团队：Xcode 先打真正原因「error: … Personal development teams … do not support the Extended Virtual Addressing capability.」、
#      再打泛泛的「error: No profiles for … were found」→ 退 1、红行带第一条（Personal development teams），不是最后那条
#   ③ S2A_PROFILE_NEED_UDIDS=「U1 U2」、描述文件目录里本包名一份只含 U1、一份含 U1 U2、别的包名一份只含 U1（假 security cms 原样吐文件）
#      → 只有「本包名缺 U2」那份移进 <产物根>/.stale_profiles/，另两份原地不动；假 xcodebuild 成功 → 退 0（11-07 Duo 登记前申请的描述文件装不上 Duo）
#   ④ 没给 S2A_PROFILE_NEED_UDIDS → 一份都不移
#   ⑤ dev_sign.py：S2A_PROFILE_NEED_UDIDS 里有描述文件没有的设备 → 退 3、点名缺的那台；都有 → 不报缺设备（往下走到挑签名身份，假 security 没身份 → 报钥匙串，退 3）；
#      ipa_tail.test_udids：名单只有全 0 占位 → 空（玩家机不核）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
mkdir -p "$T/bin"; printf '{}\n' > "$T/ent.plist"
fake() { printf '#!/bin/bash\necho "%s"\nexit 65\n' "$1" > "$T/bin/xcodebuild"; chmod +x "$T/bin/xcodebuild"; }
run() { PATH="$T/bin:$PATH" S2A_ROOTS="$T/roots" bash "$H/pack/ensure_profile.sh" com.example.t1 TEAM123 "$T/ent.plist" 2>&1; }
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
fake '		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device, error:iOS 26.5 is not installed. Please download and install the platform from Xcode > Settings > Components. }'
o=$(run); r=$?
ck "① 缺 iOS 平台组件 → 退 ${r}（期望 1）、给出修法行" '[ $r = 1 ] && grep -q "【红】本机 Xcode 没装 iOS 平台组件.*xcodebuild -downloadPlatform iOS" <<< "$o"'
fake 'error: Signing for "Prov" requires a development team.'
o=$(run); r=$?
ck "② 别的签名错误 → 退 ${r}（期望 1）、不出平台组件行" '[ $r = 1 ] && ! grep -q "没装 iOS 平台组件" <<< "$o"'
printf '#!/bin/bash\necho "error: Cannot create a iOS App Development provisioning profile for \"com.example.t1\". Personal development teams, including \"T\", do not support the Extended Virtual Addressing capability."\necho "error: No profiles for '"'"'com.example.t1'"'"' were found: Xcode couldn'"'"'t find any iOS App Development provisioning profiles matching '"'"'com.example.t1'"'"'."\nexit 65\n' > "$T/bin/xcodebuild"; chmod +x "$T/bin/xcodebuild"
o=$(run); r=$?
ck "⑥ 免费团队不支持的权限 → 退 ${r}（期望 1）、红行带第一条原因" '[ $r = 1 ] && grep -q "【红】申请 com.example.t1 的开发描述文件失败（error: Cannot create.*Personal development teams" <<< "$o"'
# ⑦ 诊断#a32ff2：真机目的地用不了，xcodebuild 先打「Unable to find a destination …」、再逐台列带 error 的设备 → 退 1、单列一行这台为什么用不了（期望手写：开发者模式没开）；
#   没有带 error 的设备条目 → 不出这行
printf '#!/bin/bash\necho "xcodebuild: error: Unable to find a destination matching the provided destination specifier:"\necho "		{ platform:iOS, id:U1 }"\necho "	Ineligible destinations for the \\"Prov\\" scheme:"\necho "		{ platform:iOS, arch:arm64, id:U1, name:iPhone, error:Developer Mode disabled To use iPhone for development, enable Developer Mode in Settings. }"\nexit 70\n' > "$T/bin/xcodebuild"; chmod +x "$T/bin/xcodebuild"
o=$(run); r=$?
ck "⑦ 目的设备用不了 → 退 ${r}（期望 1）、单列原因「Developer Mode disabled」" '[ $r = 1 ] && grep -q "【红】这台 iPhone 现在用不了（Xcode 原话：Developer Mode disabled To use iPhone for development, enable Developer Mode in Settings.）" <<< "$o"'
fake 'xcodebuild: error: Unable to find a destination matching the provided destination specifier:'
o=$(run); r=$?
ck "⑦b 没有带 error 的设备条目 → 退 ${r}（期望 1）、不出这行" '[ $r = 1 ] && ! grep -q "这台 iPhone 现在用不了" <<< "$o"'
P=$T/prof; mkdir -p "$P"; pl() { printf '<plist><dict><key>application-identifier</key><string>%s</string><key>ProvisionedDevices</key><array>%s</array></dict></plist>\n' "$1" "$2"; }
pl TEAM123.com.example.t1 '<string>U1</string>' > "$P/old.mobileprovision"; pl TEAM123.com.example.t1 '<string>U1</string><string>U2</string>' > "$P/new.mobileprovision"
pl TEAM123.com.example.other '<string>U1</string>' > "$P/other.mobileprovision"
printf '#!/bin/bash\n[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"\nexit 1\n' > "$T/bin/security"; chmod +x "$T/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/xcodebuild"; chmod +x "$T/bin/xcodebuild"
o=$(S2A_PROFILE_DIRS="$P" run); r=$?
ck "④ 没给测试设备名单 → 一份不移（rc=${r}）" '[ $r = 0 ] && [ -f "$P/old.mobileprovision" ] && [ ! -d "$T/roots/.stale_profiles" ]'
o=$(S2A_PROFILE_DIRS="$P" S2A_PROFILE_NEED_UDIDS='U1 U2' run); r=$?
ck "③ 只移本包名缺 U2 的那份、另两份不动（rc=${r}）" '[ $r = 0 ] && [ -f "$T/roots/.stale_profiles/old.mobileprovision" ] && [ ! -e "$P/old.mobileprovision" ] && [ -f "$P/new.mobileprovision" ] && [ -f "$P/other.mobileprovision" ] && grep -q "移走缺测试设备 U2 的旧描述文件 old.mobileprovision" <<< "$o"'
# ⑤ dev_sign：假 security 吐的是真 plist（dev_sign 用 plistlib 解）
mkdir -p "$T/home/Library/MobileDevice/Provisioning Profiles" "$T/app"
python3 -c 'import plistlib,sys,datetime;plistlib.dump({"Entitlements":{"application-identifier":"TEAM123.com.example.t1","get-task-allow":True},"ProvisionedDevices":["U1"],"ExpirationDate":datetime.datetime(2030,1,1)},open(sys.argv[1],"wb"))' "$T/home/Library/MobileDevice/Provisioning Profiles/a.mobileprovision"
ds() { HOME="$T/home" PATH="$T/bin:$PATH" python3 "$H/pack/dev_sign.py" "$T/app" com.example.t1 TEAM123 "$T/ent.plist" 2>&1; }
o=$(S2A_PROFILE_NEED_UDIDS='U1 U2' ds); r=$?; o2=$(S2A_PROFILE_NEED_UDIDS='U1' ds); r2=$?
u=$(S2A_MACHINE_NO_LOCAL=1 S2A_DEVICES_NO_LOCAL=1 python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import ipa_tail;print(repr(ipa_tail.test_udids()))' "$H/pack")
ck "⑤ dev_sign 缺 U2 → 退 ${r}、点名 U2；都有 → 不报缺设备（${r2}）；占位名单 → 测试设备空（${u}）" '[ $r = 3 ] && grep -q "不含测试设备 U2" <<< "$o" && ! grep -q "不含测试设备" <<< "$o2" && [ "$u" = "'"''"'" ]'
# ⑥ 申请时的目标：给了设备号 → platform=iOS,id=<UDID>；Apple Vision Pro（install.py 传 S2A_PROFILE_DEST=id=<UDID>，按 iPad 兼容装、理论支持未真机验证）
#   → 原样用 id=<UDID>，让 Xcode 自己认平台；两种都带 -allowProvisioningDeviceRegistration 登记这台设备
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$ARGS_OUT"\nexit 0\n' > "$T/bin/xcodebuild"; chmod +x "$T/bin/xcodebuild"
rv() { ARGS_OUT="$T/args" PATH="$T/bin:$PATH" S2A_ROOTS="$T/roots" S2A_PROFILE_DIRS="$P" bash "$H/pack/ensure_profile.sh" com.example.t1 TEAM123 "$T/ent.plist" U9 > /dev/null 2>&1; }
rv; a1=$(tr '\n' ' ' < "$T/args"); S2A_PROFILE_DEST=id=U9 rv; a2=$(tr '\n' ' ' < "$T/args")
ck "⑥ 目标：iPhone「${a1}」含 platform=iOS,id=U9；Vision Pro「${a2}」含 -destination id=U9；都登记设备" \
  'grep -q -- "-destination platform=iOS,id=U9" <<< "$a1" && grep -q -- "-destination id=U9 " <<< "$a2" && grep -q -- "-allowProvisioningDeviceRegistration" <<< "$a2"'
[ $bad = 0 ] && echo "✅ 申请描述文件红因全通" || { echo "🔴 申请描述文件红因有不通项"; exit 1; }
