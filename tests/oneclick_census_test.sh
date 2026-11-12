#!/bin/bash
# 一键出包·普查与出包目标单测（pack/oneclick/oneclick.sh 的 --from-extract / --target；播种 / 刷新 / 出包换成桩，约 10 秒）：bash tests/oneclick_census_test.sh
# 期望（按规则手写）：
#   ① --from-extract <解包目录> --target mac：不要 prod.keys（给一个不存在的路径）也走得通；刷新收到 Mac 口径（S2A_PACK_PLAT=macos）、不起宽屏出表
#      （S2A_WIDEN_PKG=0、S2A_WIDEN_AUTO_RUN=0）；不调出包（ipa.sh）；logs/mac_root.txt = 现行产物根；目录里没有直连版本元数据 → 按 unpack.tsv
#      合成（content_version = update 2228224、title_id 大写）
#   ② 只给 --from-extract：照常调出包一次、刷新不是 Mac 口径、起宽屏出表（S2A_WIDEN_PKG=1）
#   ③ main.npdm 的 META 标志不是 64 位 → 报红「32 位」、退出非 0
#   ③b 位数工具（假 nx_unpack）失败 / 输出空 / unknown → 报红「读不出 …/main.npdm 的程序位数」、退出非 0、不刷新（审计 P2-29：原先当 64 位往下）；
#      aarch32 → 报红「32 位」；aarch64 → 照常走通
#   ④ 解包目录缺 unpack.tsv → 报红、退出非 0
#   ⑤ 目录里已有直连版本元数据 → 不覆盖
#   ⑥ --target ios 与不给 --target 一样：调出包一次、刷新不是 Mac 口径
#   ⑦ --target android / ohos：报红「开发中」、退出 3，一个阶段都不跑（不刷新、不出包、不建输出目录）
#   ⑨ --lite（普查精简档，11-07 随通用模式拆掉）：已不是参数 → 报「不认得的参数 --lite」、非零退出、一个阶段都不跑
#   ⑩b 解包目录只换了 romfs 里的文件 / 只多了追加内容 → 要重播种（审计 #1534 P1-54）
#   ⑧ 不认得的目标（--target windows）→ 报红、退出 2，一个阶段都不跑；旧的 --mac 不再认（报「不认得的参数」、退出非 0）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/repo; mkdir -p $R/pack/oneclick $R/tools $R/x/exefs
cp "$H/pack/oneclick/oneclick.sh" "$H/pack/oneclick/cachehits.py" "$H/pack/oneclick/titles.tsv" "$H/pack/oneclick/ipa_mode.py" "$H/pack/oneclick/deliver_pack.py" $R/pack/oneclick/
cp "$H/pack/direct_profile_input.py" $R/pack/   # 一键出包写直连版本旁注调它（算法只一份，解包阶段也调它）
mkdir -p "$R/pack/jobs" "$R/compat/tree"; cp "$H"/pack/jobs/*.py "$R/pack/jobs/"; cp "$H/compat/tree/global.json" "$R/compat/tree/"   # 一键出包判 .NET SDK 调 pack/jobs/ipa.py dotnet_sdk()（版本按 global.json，全仓一处判法）
cp "$H/pack/roots.sh" "$H/pack/srcs.sh" "$H/pack/build_id.sh" $R/pack/
mkdir -p $R/graphics/nvn/tools; cp "$H/graphics/nvn/tools/romfs_list.py" $R/graphics/nvn/tools/   # 播种键盘点 romfs/ 与 aoc/（审计 #1534 P1-54）
for f in cores.sh progress.sh machine.sh; do cp "$H/tools/$f" $R/tools/; done
cat > $R/pack/seed_root.sh <<'EOF'
#!/bin/bash
echo $(( $(cat "$(dirname "$S2A_ROOTS")/../seed.n" 2> /dev/null || echo 0) + 1 )) > "$(dirname "$S2A_ROOTS")/../seed.n"   # 播种次数（⑩）：S2A_ROOTS = $T/<输出>/roots
r=$S2A_ROOTS/$1@$2; mkdir -p "$r" && cp -R "$3/exefs" "$r/" && cp "$3"/*.tsv "$3"/*.json "$r/" 2> /dev/null; ln -sfn "$1@$2" "$S2A_ROOTS/$1@现行"; echo "🟢 播种桩 $r"
EOF
cat > $R/pack/refresh.sh <<EOF
#!/bin/bash
[ -z "\${FAKE_AOC_MISS:-}" ] || printf '追加内容缺\t%s\t假原因\n' "\$FAKE_AOC_MISS" > "\$S2A_ROOTS/\$1@现行/aoc.log"   # 追加内容阶段记下没解出的包（审计 P2-30）
echo "PLAT=\${S2A_PACK_PLAT:-无} WPKG=\${S2A_WIDEN_PKG:-无} WAUTO=\${S2A_WIDEN_AUTO_RUN:-无}" >> $T/refresh.log; echo "LITE=\${S2A_PACK_LITE:-无}" >> $T/lite.log; echo "🟢 刷新桩"
EOF
cat > $R/pack/ipa.sh <<EOF
#!/bin/bash
echo ipa >> $T/ipa.log; c=\$(cd -P "\$S2A_ROOTS/\$1@现行" && pwd); mkdir -p "\$c/pkg/pack"; python3 -c "import os,plistlib,sys,zipfile; m=os.environ.get('FAKE_GM','direct'); z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('Payload/S2Arm.app/Info.plist', plistlib.dumps(dict(S2AGraphicsMode=m, S2AGraphicsModeReason=os.environ.get('FAKE_GR','')) if m else {})); z.close()" "\$c/pkg/\$1.ipa"; echo '{}' > "\$c/pkg/pack/manifest.json"; : > "\$c/pkg/pack/index.tsv"; echo "🟢 出包桩"
EOF
chmod +x $R/pack/*.sh
{ head -c 64 /dev/zero; printf 'BUILDIDBUILDID01'; head -c 32 /dev/zero; } > $R/x/exefs/main
# 0x80 字节 META 头、第 0x0C 字节是标志（真实 npdm 至少这么长；nx_unpack --npdm-isa 不足 0x80 字节判 unknown）
mknpdm() { python3 -c "import sys; b = bytearray(0x80); b[:4] = b'META'; b[0x0c] = int(sys.argv[2]); open(sys.argv[1], 'wb').write(bytes(b))" "$1" "$2"; }
mknpdm $R/x/exefs/main.npdm 1
printf 'title_id\t0100abcd00001000\nname\tCensus Fixture\ndisplay_version\t1.2.3\nupdate\t2228224\naoc\t1000,1001\n' > $R/x/unpack.tsv
mkdir -p "$T/fonts"; export S2A_FONTS="$T/fonts"
# 32 位判定走真 nx_unpack --npdm-isa（全仓唯一判法，同 pack/srcs.sh 按本树源码哈希取 / 现编）；--from-extract 不调它解包
NXU=$(unset S2A_NX_UNPACK; source "$H/pack/srcs.sh" > /dev/null 2>&1; echo "$SRC_N"); [ -x "$NXU" ] || { echo "不通 nx_unpack 没编出来（dotnet build -c Release pack/nx_unpack）"; exit 1; }
export S2A_NX_UNPACK=$NXU S2A_MACHINE_NO_LOCAL=1 S2A_BEAT_S=3600
OC() { bash $R/pack/oneclick/oneclick.sh "$@" --keys $T/没有.keys 2>&1; }
o1=$(OC --from-extract $R/x --target mac --out $T/o1); r1=$?
ck "① --from-extract --target mac：rc=${r1}、刷新「$(cat $T/refresh.log 2> /dev/null)」、出包桩 $(grep -c . $T/ipa.log 2> /dev/null || echo 0) 次、Mac 产物根 $(cat $T/o1/logs/mac_root.txt 2> /dev/null)" \
  '[ $r1 = 0 ] && [ "$(cat $T/refresh.log)" = "PLAT=macos WPKG=0 WAUTO=0" ] && [ ! -e $T/ipa.log ] && [ "$(cat $T/o1/logs/mac_root.txt)" = "$(cd -P $T/o1/roots/t0100abcd00001000@现行 && pwd)" ] && [[ "$o1" == *"完成（Mac 产物根）"* ]]'
dp=$(python3 -c "import json; d = json.load(open('$R/x/direct-profile-input.json')); print(d['title_id'], d['content_version'])" 2> /dev/null)
ck "① 版本元数据按 unpack.tsv 合成：${dp}" '[ "$dp" = "0100ABCD00001000 2228224" ]'
rm -f $T/refresh.log
o2=$(OC --from-extract $R/x --out $T/o2); r2=$?
ck "② 只给 --from-extract：rc=${r2}、出包桩 $(grep -c . $T/ipa.log 2> /dev/null || echo 0) 次、刷新「$(cat $T/refresh.log 2> /dev/null)」" '[ $r2 = 0 ] && [ "$(grep -c . $T/ipa.log)" = 1 ] && [ "$(cat $T/refresh.log)" = "PLAT=无 WPKG=1 WAUTO=无" ]'
mknpdm $R/x/exefs/main.npdm 0; o3=$(OC --from-extract $R/x --target mac --out $T/o3); r3=$?; mknpdm $R/x/exefs/main.npdm 1
ck "③ 32 位程序 → rc=${r3}、报红" '[ $r3 != 0 ] && [[ "$o3" == *"32 位"* ]]'
cat > $T/fakenxu <<'EOF'
#!/bin/bash
[ "$1" = --npdm-isa ] || exit 97
case $FAKE_ISA in fail) echo "🔴 读不了 $2：假失败" >&2; exit 3;; empty) exit 0;; *) echo "$FAKE_ISA";; esac
EOF
chmod +x $T/fakenxu
for m in fail:读不出 empty:读不出 unknown:读不出 aarch32:"32 位" aarch64:ok; do want=${m#*:}; m=${m%%:*}; rm -f $T/refresh.log
  o=$(FAKE_ISA=$m S2A_NX_UNPACK=$T/fakenxu OC --from-extract $R/x --target mac --out $T/o3$m); r=$?
  if [ "$want" = ok ]; then ck "③b 假位数工具 ${m} → rc=${r}、照常刷新" '[ $r = 0 ] && [ -e $T/refresh.log ]'
  elif [ "$want" = 读不出 ]; then ck "③b 假位数工具 ${m} → rc=${r}、报红点名 main.npdm、没刷新" '[ $r != 0 ] && [[ "$o" == *"🔴 读不出 "*"/x/exefs/main.npdm 的程序位数"* ]] && [ ! -e $T/refresh.log ]'
  else ck "③b 假位数工具 ${m} → rc=${r}、报红 32 位、没刷新" '[ $r != 0 ] && [[ "$o" == *"32 位"* ]] && [ ! -e $T/refresh.log ]'; fi
done
mkdir -p $T/y/exefs; cp $R/x/exefs/* $T/y/exefs/; o4=$(OC --from-extract $T/y --target mac --out $T/o4); r4=$?
ck "④ 缺 unpack.tsv → rc=${r4}、报红" '[ $r4 != 0 ] && [[ "$o4" == *"要有 exefs/main 与 unpack.tsv"* ]]'
echo '{"format": 1, "title_id": "KEEP"}' > $R/x/direct-profile-input.json; OC --from-extract $R/x --target mac --out $T/o5 > /dev/null
ck "⑤ 已有版本元数据不覆盖（$(cat $R/x/direct-profile-input.json)）" 'grep -q KEEP $R/x/direct-profile-input.json'
rm -f $R/x/direct-profile-input.json
# ⑤b 旧解包目录没有旁注、也没有更新（11-03 塞尔达御天之剑HD 手测单的形状）：content_version 取本体 CNMT 版本（base），
#    不是 0、也不是显示版本。期望手算：unpack.tsv 的 base 4096 → 4096；换一个只有 update、没有 base 的目录 → 取 update 2228224
mkdir -p $T/z/exefs; cp $R/x/exefs/* $T/z/exefs/; cp $R/x/unpack.tsv $T/z/unpack.tsv
printf 'title_id\t0100abcd00001000\nname\tBase Only\ndisplay_version\t7.7.7\nupdate\t\nbase\t4096\n' > $T/z/unpack.tsv
OC --from-extract $T/z --target mac --out $T/o5b > /dev/null; r5b=$?
dp5b=$(python3 -c "import json; d = json.load(open('$T/z/direct-profile-input.json')); print(d['title_id'], d['content_version'], d['display'])" 2> /dev/null)
ck "⑤b 旧目录无旁注 + 无更新 → 按本体版本补旁注（rc=${r5b}，实得「${dp5b}」，期望「0100ABCD00001000 4096 7.7.7」）" '[ $r5b = 0 ] && [ "$dp5b" = "0100ABCD00001000 4096 7.7.7" ]'
printf 'title_id\t0100abcd00001000\nname\tWith Update\ndisplay_version\t1.2.3\nupdate\t2228224\nbase\t4096\n' > $T/z/unpack.tsv; rm -f $T/z/direct-profile-input.json
OC --from-extract $T/z --target mac --out $T/o5c > /dev/null
dp5c=$(python3 -c "import json; print(json.load(open('$T/z/direct-profile-input.json'))['content_version'])" 2> /dev/null)
ck "⑤c 有更新 → 取更新版本（实得 ${dp5c}，期望 2228224；不是本体 4096）" '[ "$dp5c" = 2228224 ]'
rm -f $T/z/direct-profile-input.json
printf 'title_id\t0100abcd00001000\nname\tAncient\ndisplay_version\t1.0\n' > $T/z/unpack.tsv
o5d=$(OC --from-extract $T/z --target mac --out $T/o5d); r5d=$?
ck "⑤d 解包产物没有 update / base（旧工具）→ 报红点名，不写 0 顶替（rc=${r5d}）" '[ $r5d != 0 ] && [ ! -e $T/z/direct-profile-input.json ] && [[ "$o5d" == *"没有更新也没有本体内容版本"* ]]'
rm -f $T/z/unpack.tsv; cp $R/x/unpack.tsv $T/z/unpack.tsv
rm -f $T/refresh.log $T/ipa.log; o6=$(OC --from-extract $R/x --target ios --out $T/o6); r6=$?
ck "⑥ --target ios：rc=${r6}、出包桩 $(grep -c . $T/ipa.log 2> /dev/null || echo 0) 次、刷新「$(cat $T/refresh.log 2> /dev/null)」" '[ $r6 = 0 ] && [ "$(grep -c . $T/ipa.log)" = 1 ] && [ "$(cat $T/refresh.log)" = "PLAT=无 WPKG=1 WAUTO=无" ]'
# ⑥b result 的画面模式取交付 IPA 里的 Info.plist（11-01 #1104：原先读产物根中间目录 build/ios/…/Info.plist，那份不在就报 unknown，通用 / 直连两单作业记录都是 unknown）：
#   桩 IPA 写 generic + 理由 → result graphics_mode=generic、graphics_reason 原样；写 direct → direct；IPA 里没有 S2AGraphicsMode → 报红、result ok=false（不猜 unknown）
lastev() { python3 -c 'import json,sys; a=[json.loads(x) for x in open(sys.argv[1])]; r=a[-1]; print(r.get("ok"), r.get("graphics_mode"), r.get("graphics_reason"), sep="|")' "$1" 2> /dev/null; }
OC --from-extract $R/x --target ios --out $T/o6d --events $T/d.events > /dev/null; e6d=$(lastev $T/d.events)
ck "⑥b IPA 写 direct → result「${e6d}」（只有直连，不再带画面模式理由）" '[ "$e6d" = "True|direct|None" ]'
o6n=$(FAKE_GM= OC --from-extract $R/x --target ios --out $T/o6n --events $T/n.events); r6n=$?; e6n=$(lastev $T/n.events)
ck "⑥b IPA 没有 S2AGraphicsMode → rc=${r6n}、result「${e6n:0:20}」、报读不出画面模式" '[ $r6n != 0 ] && [[ "$e6n" == False* ]] && [[ "$o6n" == *"读不出画面模式"* ]]'
# ⑥c 追加内容有一份没解出（产物根 aoc.log「追加内容缺」行）：完成行带黄字「追加内容 <文件名> 未能解出，包内不含」，result 的 aoc_missing 点名；没缺时 aoc_missing 为空表
o6m=$(FAKE_AOC_MISS=dlc2.nsp OC --from-extract $R/x --target ios --out $T/o6m --events $T/m.events); r6m=$?
e6m=$(python3 -c 'import json,sys; print(" ".join(json.loads(open(sys.argv[1]).read().splitlines()[-1])["aoc_missing"]))' $T/m.events 2> /dev/null)
ck "⑥c 有缺：rc=${r6m}、完成行带黄字、result aoc_missing=${e6m}" '[ $r6m = 0 ] && [[ "$(grep "🟢 完成：" <<< "$o6m")" == *"🟡 追加内容 dlc2.nsp 未能解出，包内不含"* ]] && [ "$e6m" = dlc2.nsp ]'
o6k=$(OC --from-extract $R/x --target ios --out $T/o6k --events $T/k.events); e6k=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["aoc_missing"])' $T/k.events 2> /dev/null)
ck "⑥c 没缺：完成行没有黄字、aoc_missing=${e6k}" '[[ "$o6k" != *"未能解出"* ]] && [ "$e6k" = "[]" ]'
rm -f $T/refresh.log $T/ipa.log
for tg in ohos; do o7=$(OC --from-extract $R/x --target $tg --out $T/o7$tg); r7=$?
  ck "⑦ --target ${tg}：rc=${r7}（3）、报红开发中、没刷新没出包、没建输出目录" '[ $r7 = 3 ] && [[ "$o7" == *"🔴 目标 ${tg}：开发中"* ]] && [ ! -e $T/refresh.log ] && [ ! -e $T/ipa.log ] && [ ! -e $T/o7$tg ]'; done
mkdir -p $R/pack/targets/android
cat > $R/pack/targets/android/package.py <<'PYFIX'
import json, os, pathlib, sys
out = pathlib.Path(sys.argv[sys.argv.index('--out') + 1]) / 'android-delivery'
out.mkdir()
(out / 'game.apk').write_bytes(b'apk')
(out / 'resources').mkdir()
(out / 'resources/manifest.json').write_text('{}')
(out / 'artifact.json').write_text('{}')
print(json.dumps(dict(apk=str(out / 'game.apk'), resources=str(out / 'resources'), artifact=str(out / 'artifact.json'))))
PYFIX
rm -f $T/refresh.log $T/ipa.log
o7a=$(OC --from-extract $R/x --target android --out $T/o7a --events $T/android.events); r7a=$?
ev7a=$(python3 -c 'import json,sys; a=[json.loads(x) for x in open(sys.argv[1])]; print(a[-1].get("ok") and a[-1].get("apk", "").endswith("game.apk"))' "$T/android.events" 2>/dev/null)
ck "⑦ Android 使用共享刷新并交付 APK、资源及账本（rc=${r7a}）" '[ $r7a = 0 ] && [ "$(cat $T/refresh.log)" = "PLAT=android WPKG=0 WAUTO=0" ] && [ ! -e $T/ipa.log ] && [ -f $T/o7a/android-delivery/game.apk ] && [ -f $T/o7a/android-delivery/resources/manifest.json ] && [ -f $T/o7a/android-delivery/artifact.json ] && [ "$ev7a" = True ]'
mkdir -p "$R/android/tools"
cat > $R/android/tools/deploy_game.py <<'PYFIX'
import os, pathlib, sys
pathlib.Path(os.environ['S2A_FAKE_INSTALL_MARKER']).write_text(' '.join(sys.argv[1:]))
sys.exit(1 if os.environ.get('S2A_FAKE_INSTALL_FAIL') else 0)
PYFIX
export S2A_FAKE_INSTALL_MARKER=$T/install.marker
rm -f $T/refresh.log $T/ipa.log
ok_install=$(OC --from-extract $R/x --target android --out $T/install-ok --install-serial fixture); ri=$?
ck "⑦ 安卓可选安装调用统一部署入口且不自动启动（rc=${ri}）" '[ $ri = 0 ] && grep -q -- "--serial fixture" $T/install.marker && grep -q -- "--resources " $T/install.marker && grep -q -- "--no-start" $T/install.marker'
rm -f $T/install.marker
failed_install=$(S2A_FAKE_INSTALL_FAIL=1 OC --from-extract $R/x --target android --out $T/install-fail --install-serial fixture); rif=$?
ck "⑦ 安卓安装失败报非零（rc=${rif}）" '[ $rif != 0 ] && [ -f $T/install.marker ] && [[ "$failed_install" == *"设备安装或导入失败"* ]]'
rm -f $T/refresh.log $T/ipa.log
o8=$(OC --from-extract $R/x --target windows --out $T/o8); r8=$?; o8b=$(OC --from-extract $R/x --mac --out $T/o8b); r8b=$?
ck "⑧ --target windows：rc=${r8}（2）、报红；--mac：rc=${r8b}、报不认得；都没刷新" '[ $r8 = 2 ] && [[ "$o8" == *"不认得的目标「windows」"* ]] && [ $r8b != 0 ] && [[ "$o8b" == *"不认得的参数 --mac"* ]] && [ ! -e $T/refresh.log ] && [ ! -e $T/o8 ]'
rm -f $T/refresh.log $T/ipa.log; o9=$(OC --from-extract $R/x --target mac --lite --out $T/o9); r9=$?
ck "⑨ --lite 已拆：rc=${r9}、报不认得、没刷新没出包" '[ $r9 != 0 ] && [[ "$o9" == *"不认得的参数 --lite"* ]] && [ ! -e $T/refresh.log ] && [ ! -e $T/ipa.log ]'
# ⑩ 同一输出目录再出一次：解包目录只改了 ctl/control.nacp（解包工具重合成）→ 要重播种（.seeded 键变、播种桩再调一次）；什么都没改 → 不重播种
mkdir -p $R/x/ctl; printf 'nacp-v1' > $R/x/ctl/control.nacp; rm -f $T/seed.n
OC --from-extract $R/x --target mac --out $T/o10 > /dev/null; k1=$(cat $T/o10/.seeded); OC --from-extract $R/x --target mac --out $T/o10 > /dev/null; k2=$(cat $T/o10/.seeded)
printf 'nacp-v2' > $R/x/ctl/control.nacp; OC --from-extract $R/x --target mac --out $T/o10 > /dev/null; k3=$(cat $T/o10/.seeded); rm -rf $R/x/ctl
ck "⑩ 只改 ctl/control.nacp 要重播种：播种桩 $(cat $T/seed.n 2> /dev/null || echo 0) 次（期望 2）、键 ${k1} → 不变 ${k2} → 改 ${k3}" '[ "$(cat $T/seed.n)" = 2 ] && [ "$k1" = "$k2" ] && [ "$k2" != "$k3" ]'
# ⑩b 审计 #1534 P1-54：解包目录只换了 romfs 里一个文件（同名同大小、内容与修改时间变）/ 只多了一份追加内容 → 要重播种；再出一次不变 → 不重播种
mkdir -p $R/x/romfs; printf 'AAAA' > $R/x/romfs/a.bin; touch -t 202601010000 $R/x/romfs/a.bin; rm -f $T/seed.n
OC --from-extract $R/x --target mac --out $T/o10b > /dev/null; k1=$(cat $T/o10b/.seeded)
printf 'BBBB' > $R/x/romfs/a.bin; OC --from-extract $R/x --target mac --out $T/o10b > /dev/null; k2=$(cat $T/o10b/.seeded)
OC --from-extract $R/x --target mac --out $T/o10b > /dev/null; k3=$(cat $T/o10b/.seeded)
mkdir -p $R/x/aoc/0; printf 'dlc' > $R/x/aoc/0/d.bin; OC --from-extract $R/x --target mac --out $T/o10b > /dev/null; k4=$(cat $T/o10b/.seeded); rm -rf $R/x/romfs $R/x/aoc
ck "⑩b 只换 romfs 文件 / 只多追加内容要重播种：播种桩 $(cat $T/seed.n 2> /dev/null || echo 0) 次（期望 3）、键 ${k1} → 换 romfs ${k2} → 不变 ${k3} → 加 aoc ${k4}" '[ "$(cat $T/seed.n)" = 3 ] && [ "$k1" != "$k2" ] && [ "$k2" = "$k3" ] && [ "$k3" != "$k4" ]'
[ $bad = 0 ] && echo "oneclick_census 单测全过" || { echo "oneclick_census 单测有不通"; exit 1; }
