#!/bin/bash
# 开发描述文件自动申请：pack/ensure_profile.sh <包名> <团队号> <基础权限> [设备 UDID]
# 用一个最小 SwiftUI 工程（同包名、同权限、自动签名；模板在 pack/prov/）跑一次 xcodebuild -allowProvisioningUpdates，让 Xcode 在账号上注册包名并下发开发描述文件
# （10-20 新款出包签名「没有 <团队>.<包名> 的开发描述文件」：巫师3 / 八方2 / 怪猎 / 丝之歌各手工申请过一次）。只在签名报退出码 3 时由 pack/ipa.sh 调用。
set -u; BID=${1:?包名}; TEAM=${2:?团队号}; ENT=${3:?基础权限}; UDID=${4:-}
# 第 4 个参数给设备硬件 UDID（启动器「装到 iPhone」：pack/jobs/install.py）：目标指这台真机并允许登记设备，描述文件才含它（免费个人团队必须这样，10-26 测试设备2 实测）
DEST='generic/platform=iOS'; REG=(); [ -n "$UDID" ] && { DEST="${S2A_PROFILE_DEST:-platform=iOS,id=$UDID}"; REG=(-allowProvisioningDeviceRegistration -destination-timeout 120); }   # S2A_PROFILE_DEST：Apple Vision Pro 写 id=<UDID>（install.py，按 iPad 兼容装、理论支持未真机验证）   # 等目的设备 2 分钟（缺省 30 秒）：锁屏的手机有时间解锁
# 工程是 pack/prov/ 里的现成模板（10-26 起；原来每次现跑 xcodegen 生成，用户机没有 Homebrew / xcodegen，新款第一次出包签名必挂）：
#   模板 = 同一份 xcodegen 规格（name Prov、iOS 17.0、application、UILaunchScreen、自动签名、CODE_SIGN_ENTITLEMENTS app.entitlements）生成的工程，包名 / 团队号留占位 S2ABID / S2ATEAM，这里替换
# S2A_PROFILE_NEED_UDIDS（我方测试设备，pack/ipa_tail.py 给）：本包名的开发描述文件缺其中任一台 → 先移到 <产物根>/.stale_profiles/（不删），
#   不移的话 Xcode 认旧的还有效、不重申（11-07 实测：io.s2arm-exp.d2r 旧 46 台，直接跑 7 秒没换；移走后重申得 61 台含 Duo）。重申按账号现有登记设备出，不用插手机
if [ -n "${S2A_PROFILE_NEED_UDIDS:-}" ]; then
  SD=${S2A_ROOTS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots}/.stale_profiles
  IFS=: read -r -a PDS <<< "${S2A_PROFILE_DIRS:-$HOME/Library/MobileDevice/Provisioning Profiles:$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
  for pd in "${PDS[@]}"; do for f in "$pd"/*.mobileprovision; do [ -f "$f" ] || continue
    x=$(security cms -D -i "$f" 2> /dev/null) || continue
    grep -qF "<string>${TEAM}.${BID}</string>" <<< "$x" || continue
    for u in $S2A_PROFILE_NEED_UDIDS; do grep -qF "<string>$u</string>" <<< "$x" || { if mkdir -p "$SD" && mv "$f" "$SD/"; then echo "移走缺测试设备 $u 的旧描述文件 ${f##*/} → $SD"; else echo "【黄】移不走缺测试设备 $u 的旧描述文件 ${f}：Xcode 会认旧的不重申"; fi; break; }; done
  done; done
fi
H=$(cd "$(dirname "$0")" && pwd); D=$(mktemp -d); trap 'rm -rf "$D"' EXIT; cp -R "$H/prov/" "$D/" && cp "$ENT" "$D/app.entitlements" || { echo "【红】拷不了描述文件申请工程模板（$H/prov）"; exit 1; }
/usr/bin/sed -i '' -e "s/\"S2ABID\"/\"${BID}\"/g" -e "s/\"S2ATEAM\"/\"${TEAM}\"/g" "$D/Prov.xcodeproj/project.pbxproj" || { echo "【红】填不了描述文件申请工程的包名 / 团队号"; exit 1; }
(cd "$D" && timeout 600 xcodebuild -project Prov.xcodeproj -scheme Prov -configuration Debug -destination "$DEST" -derivedDataPath dd -allowProvisioningUpdates ${REG[@]+"${REG[@]}"} build > build.log 2>&1) \
  || { KL=${S2A_ROOTS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots}/.failed/${BID}_ensure_profile.log; mkdir -p "$(dirname "$KL")"; if ! cp "$D/build.log" "$KL" 2> /dev/null; then KL="（没留住：拷不进 ${KL}）"; fi   # 失败留全文（临时目录退出即删，10-30 凌晨原因一栏是空的、现场也没了）
       # 11-08：第一次签名弹钥匙串授权框没人点，xcodebuild 等到 timeout 打 BUILD INTERRUPTED，末尾的 error 行是无关的 DVTDevice 杂音
       grep -aq 'BUILD INTERRUPTED' "$D/build.log" && { echo "【红】等钥匙串授权超时：在这台 Mac 屏幕上的钥匙串弹窗里点「始终允许」（需要的话输入 Mac 登录密码），再点一次「装到 iPhone」"; exit 1; }
       # #897：Xcode 先打真正的原因（第一条 error:，如「Personal development teams … do not support the … capability」），后面跟泛泛的「No profiles … were found」；原先取最后一条，原因丢了
       echo "【红】申请 ${BID} 的开发描述文件失败（$(grep -a 'error:' "$D/build.log" | head -1 | cut -c1-240 | grep . || grep -a -i 'error' "$D/build.log" | grep -v '^ *$' | tail -1 | cut -c1-200 | grep . || echo "xcodebuild 没打错误行，末行：$(tail -1 "$D/build.log" | cut -c1-160)")；全文 ${KL}）"
       grep -a -o 'error:The device needs to be unlocked[^}]*\|error:[^}]*locked[^}]*' "$D/build.log" | head -1 | cut -c1-200
       # 诊断#a32ff2（11-14 两台 Mac）：「Unable to find a destination matching the provided destination specifier」后面 xcodebuild 逐台列
       #   「{ platform:iOS, id:…, error:<为什么用不了> }」，原先只留第一行、原因丢了；这里把第一条带 error 的目的设备原因单列一行
       R=; grep -a -q 'Unable to find a destination matching' "$D/build.log" \
         && R=$(grep -a -o '{ *platform:iOS[^}]*error:[^}]*}' "$D/build.log" | head -1 | sed 's/.*error://; s/ *}$//' | cut -c1-200)
       [ -n "$R" ] && echo "【红】这台 iPhone 现在用不了（Xcode 原话：${R}）"
       # 11-05：Xcode 升级后 iOS 平台组件不跟着装，xcodebuild 报「iOS 26.5 is not installed. Please download and install the platform」——
       #   新包名一律申请不到描述文件（老包名有现成的不受影响），原文埋在长行里看不出修法，这里直说
       grep -a -q 'is not installed\. Please download and install the platform' "$D/build.log" \
         && echo "【红】本机 Xcode 没装 iOS 平台组件（Xcode 升级后不会跟着装），新包名申请不到开发描述文件；修法：xcodebuild -downloadPlatform iOS（苹果官方源，装在系统盘）"
       exit 1; }   # 目的设备为什么不可用（10-26 测试设备2 锁屏，原先只报「等不到目的设备」）
echo "已申请 ${BID} 的开发描述文件（$(grep -a 'Provisioning Profile:' "$D/build.log" | head -1 | sed 's/^ *//' | cut -c1-100)）"
