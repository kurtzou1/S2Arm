#!/bin/bash
export S2A_CAPS_OWN=1   # 本测的是我方 60 帧 / 满屏旧口径（11-13 起发布缺省只用社区补丁，见 tests/caps_patch_only_test.py）
# 包内能力清单生成单测（pack/gen_caps.sh → tools/caps_policy.py，临时产物根 + 合成登记表仓库，约 1 秒）：bash tests/gen_caps_test.sh
#   全能力出包口径（维护者 10-29 07:0x「默认开、强信号才关」）：
#   ① 发布：有宽屏表 + 帧率表、没有强信号 → fps60 1、原因「默认开：来源 …」；widen 0「发布缺省关」（维护者 11-02 19:0x：满屏默认关，真机验过 / 有补丁才开）；带 widen_verified.tsv → widen 1
#   ② 发布：强信号表本款本构建 widen「宽屏画面坏」→ widen 0、原因带信号；fps60 照开
#   ③ 发布：名单_60帧 本款本构建 逻辑速度=红 → fps60 0「强信号：逻辑速度红」
#   ④ 发布：没有帧率来源 → fps60 0「强信号：静态无来源」，宽屏有第三层通用满屏照开；社区补丁 / 通用宽屏改写算来源（cpatch.tsv fps: / widescreen:、<模块>.widen.tsv 非空）
#   ⑤ 发布：能力覆盖表 L1 = L2 = 不需要（游戏原生 60 帧）算帧率来源
#   ⑥ --all-caps：不看强信号，有来源即开   ⑦ 强信号表里有口径外的信号 → 退出非 0（不认的不当强信号，也不悄悄忽略）
#   ⑧ 两种模式 direct / gyro / haptics 都是 1；别款的强信号不串到本款   ⑨ caps_policy.py hash：能力内容哈希只随该能力的来源内容变   ⑩ 也随实现它的宿主代码变
#   ⑪ 产物根各平台同一份（改写阶段出 s2a_caps.tsv / s2a_caps.all.tsv，ipa.sh 只取用）   ⑫ Mac 宿主装载前读、日志带原因（widen / fps60 / fps60_display 各一处）   ⑬ 安卓资源包带清单、装载前读
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
v() { awk -F'\t' -v k="$2" '$1 == k {print $2}' "$1"; }   # 某能力的值
why() { awk -F'\t' -v k="$2" '$1 == k {sub(/^# /, "", $3); print $3}' "$1"; }
PID=0100152000022000; BID=158c0c7399aabd7bf83795c2ef3484c7
C=$T/root; mkdir -p $C/exefs; printf 'title_id\t%s\n' "$PID" > $C/unpack.tsv
python3 - "$C/exefs/main" "$BID" <<'PY'
import sys; b = bytearray(0x100); b[0:4] = b'NSO0'; b[0x40:0x50] = bytes.fromhex(sys.argv[2]); open(sys.argv[1], 'wb').write(b)
PY
G=$T/repo; mkdir -p $G/docs
# 强信号行按「程序号 构建号 能力 信号 依据 日期」写，内容哈希列按登记时该能力的实现哈希自动补（10-29 起必填；caps_policy.py signal-hash <仓库>）
# 登记表按款拆目录（10-30，tools/reglist.py）：夹具先写单文件、再拆成 docs/<表名>/<程序号>.tsv（拆前删旧目录，同一表重写是整表替换）
split_reg() { for t in 名单_能力强信号 名单_60帧 名单_60帧能力覆盖; do [ -f $G/docs/$t.tsv ] && rm -rf $G/docs/$t; done; python3 $H/tools/reglist.py migrate $G > /dev/null; }
reg() { local hs; hs=$(python3 $H/tools/caps_policy.py signal-hash $G)
  { printf '# 强信号\n程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n'; printf '%s' "${1:-}" | awk -F'\t' -v OFS='\t' -v hs="$hs" 'BEGIN { n = split(hs, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); h[kv[1]] = kv[2] } }
    NF { $3 = $3 OFS h[$3]; print }'; } > $G/docs/名单_能力强信号.tsv; split_reg; }
fps() { printf '# 60 帧\n程序号\t构建号\t款\t日期\t帧率\t整机W\t满屏\t包\t依据局\t能力来源\t备注\t逻辑速度\t逻辑速度局\n%s' "${1:-}" > $G/docs/名单_60帧.tsv; split_reg; }
cov() { printf '# 覆盖\n程序号\t构建号\t款\tL1交换间隔\tL1依据\tL2引擎限帧\tL2依据\tL3时间步\tL3依据\t未达标原因\n%s' "${1:-}" > $G/docs/名单_60帧能力覆盖.tsv; split_reg; }
run() { S2A_CAPS_REPO=$G bash $H/pack/gen_caps.sh mk8d $C $T/$1.tsv ${2:-} > $T/$1.log 2>&1; echo $?; }
reg; fps; cov; touch $C/widen_enable.handheld.tsv $C/fps.tsv
r=$(run o1); ck "① 发布：有来源、无强信号 → fps60 1 默认开、widen 0 发布缺省关（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o1.tsv fps60)" = 1 ] && [ "$(v $T/o1.tsv widen)" = 0 ] && case "$(why $T/o1.tsv widen)" in 发布缺省关*) true;; *) false;; esac && [ "$(why $T/o1.tsv fps60)" = "默认开：来源 fps.tsv" ]'
touch $C/widen_verified.tsv
r=$(run o1v); ck "① 发布：带 widen_verified.tsv（真机验过）→ widen 1 默认开（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o1v.tsv widen)" = 1 ] && [ "$(why $T/o1v.tsv widen)" = "默认开：来源 第三层通用满屏、widen_enable.handheld.tsv、widen_verified.tsv" ]'
rm -f $C/widen_verified.tsv
reg "$PID	$BID	widen	宽屏画面坏	shots/tires.png 两侧残留	2026-10-29
0100000000000999	$BID	fps60	崩溃归因	别款	2026-10-29
"
r=$(run o2); ck "② 发布：widen 强信号 → widen 0 带信号、fps60 照开（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o2.tsv widen)" = 0 ] && [ "$(why $T/o2.tsv widen)" = "强信号：宽屏画面坏（shots/tires.png 两侧残留）" ] && [ "$(v $T/o2.tsv fps60)" = 1 ]'
ck "⑧ 别款的强信号（fps60 崩溃归因）不串到本款" '[ "$(v $T/o2.tsv fps60)" = 1 ]'
reg; fps "$PID	${BID:0:16}	mk8d	2026-10-29	60/60	4/4	100/100	abc	局	规则	-	红	局_off / 局_on
"
r=$(run o3); ck "③ 发布：名单_60帧 逻辑速度=红（16 字节构建号前缀）→ fps60 0（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o3.tsv fps60)" = 0 ] && case "$(why $T/o3.tsv fps60)" in 强信号：逻辑速度红*) true;; *) false;; esac'
fps; rm -f $C/widen_enable.handheld.tsv $C/fps.tsv
r=$(run o4); ck "④ 发布：没有逐款表 → fps60 1「引擎通用：放开出图间隔（全引擎…）」+ fps60_display 1；宽屏发布缺省关（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o4.tsv fps60)" = 1 ] && [ "$(v $T/o4.tsv fps60_display)" = 1 ] && case "$(why $T/o4.tsv fps60)" in 默认开：来源\ 引擎通用：放开出图间隔*) true;; *) false;; esac && [ "$(v $T/o4.tsv widen)" = 0 ] && case "$(why $T/o4.tsv widen)" in 发布缺省关*) true;; *) false;; esac'
printf '编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\nfps:aa\tmain\t0\tfps\t60\tnone\tx\t\t0\nwidescreen:bb\tmain\t1\tultrawide\tw\tnone\tx\t\t1\n' > $C/cpatch.tsv
r=$(run o4b --all-caps); ck "④ 社区帧率 / 宽屏补丁算来源（--all-caps 看来源）（rc=${r}）" '[ "$(v $T/o4b.tsv fps60)" = 1 ] && [ "$(v $T/o4b.tsv widen)" = 1 ] && [ "$(why $T/o4b.tsv widen)" = "默认开：来源 第三层通用满屏、社区宽屏补丁" ]'
rm -f $C/cpatch.tsv; printf '# 宽屏点\nmain\t0x10\tf32\n' > $C/main.widen.tsv; : > $C/sdk.widen.tsv
r=$(run o4c --all-caps); ck "④ <模块>.widen.tsv 非空 = 通用宽屏改写来源；空文件不算（--all-caps 看来源）（rc=${r}）" '[ "$(why $T/o4c.tsv widen)" = "默认开：来源 第三层通用满屏、通用宽屏改写" ]'
rm -f $C/main.widen.tsv $C/sdk.widen.tsv
cov "$PID	$BID	mk8d	不需要	x	不需要	x	未知	x	—
"
r=$(run o5); ck "⑤ 能力覆盖 L1 = L2 = 不需要 → fps60 1「默认开：来源 游戏原生 60 帧」（rc=${r}）" '[ "$(v $T/o5.tsv fps60)" = 1 ] && [ "$(why $T/o5.tsv fps60)" = "默认开：来源 游戏原生 60 帧" ]'
cov; touch $C/widen_enable.handheld.tsv; reg "$PID	$BID	widen	宽屏画面坏	x	2026-10-29
"
r=$(run o6 --all-caps); ck "⑥ --all-caps：不看强信号，有来源即开（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o6.tsv widen)" = 1 ]'
reg "$PID	$BID	widen	判不出	x	2026-10-29
"
r=$(run o7); ck "⑦ 口径外信号「判不出」→ 退出非 0（rc=${r}）" '[ $r != 0 ]'
ck "⑧ 两种模式 direct / gyro / haptics 都是 1" 'for f in $T/o1.tsv $T/o6.tsv; do for k in direct gyro haptics; do [ "$(v $f $k)" = 1 ] || exit 1; done; done'
# ⑨ 能力内容哈希（验证账的键）：同内容同哈希；只改帧率表 → fps60 变、widen 不变；cpatch 里 widescreen: 行变 → widen 变
P=$H/tools/caps_policy.py; hv() { python3 $P hash $C | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k {print $2}'; }
printf 'a\n' > $C/fps.tsv; w1=$(hv widen); f1=$(hv fps60); w1b=$(hv widen)
printf 'b\n' > $C/fps.tsv; w2=$(hv widen); f2=$(hv fps60)
printf '编号\t模块\n' > $C/cpatch.tsv; printf 'widescreen:cc\tmain\n' >> $C/cpatch.tsv; w3=$(hv widen)
ck "⑨ 哈希：同内容同哈希、只改帧率表 fps60 变 widen 不变、宽屏补丁行变 widen 变" '[ "$w1" = "$w1b" ] && [ ${#w1} = 16 ] && [ "$f1" != "$f2" ] && [ "$w1" = "$w2" ] && [ "$w3" != "$w2" ]'
# ⑩ 内容哈希算进宿主实现（维护者 10-29）：改宿主帧率实现 runtime/src/fps.c → 只有 fps60 变；改直连出图层 nvn_mtl.m → 只有 widen 变
Q=$T/implrepo; mkdir -p $Q/runtime/src $Q/graphics/metal $Q/graphics/nvn/gfx/nvn; for f in runtime/src/widen.c graphics/metal/gal_present.m graphics/metal/fit_judge.h graphics/nvn/gfx/nvn/nvn_mtl.m runtime/src/caps.c runtime/src/fps.c runtime/src/cpatch.c; do echo v1 > $Q/$f; done
hq() { python3 $P hash $C $Q | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k {print $2}'; }
a1=$(hq widen); b1=$(hq fps60); echo v2 > $Q/runtime/src/fps.c; a2=$(hq widen); b2=$(hq fps60); echo v2 > $Q/graphics/nvn/gfx/nvn/nvn_mtl.m; a3=$(hq widen); b3=$(hq fps60)
ck "⑩ 哈希算进宿主实现：改 fps.c 只变 fps60、改直连出图层只变 widen" '[ "$a1" = "$a2" ] && [ "$b1" != "$b2" ] && [ "$a2" != "$a3" ] && [ "$b2" = "$b3" ]'
# ⑪–⑬ 各平台同一份清单（10-29 维护者：原先只有 ipa.sh 生成，普查 / Mac 局 / 安卓都没清单，宽屏退回已验证名单门、整局 16:9）
SR=$H/pack/stage_caps.sh   # 10-29 出包线：清单从改写阶段拆成独立轻阶段（自己的键），改写阶段不再出
ck "⑪ 产物根：能力清单阶段一次判定（--both）出发布口径 s2a_caps.tsv 与 --all-caps 的 s2a_caps.all.tsv，两份都进它的 ROOT_REPLAY；改写阶段不出；ipa.sh 只取用、不再调 gen_caps.sh；--all-caps 提交产物根前换回发布口径" \
  'grep -qF "gen_caps.sh\" \"\$G\" \"\$W\" \"\$W/s2a_caps.tsv\"" $SR && grep -qF "\"\$W/s2a_caps.tsv\" --both \"\$W/s2a_caps.all.tsv\"" $SR && grep "ROOT_REPLAY=" $SR | grep -qF "s2a_caps.tsv s2a_caps.all.tsv" \
   && ! grep -qE "^[^#]*gen_caps\.sh" $H/pack/stage_rewrite.sh && grep -qE "^[^#]*stage_caps\.sh" $H/pack/refresh.sh \
   && ! grep -qE "^[^#]*bash .*gen_caps\.sh" $H/pack/ipa.sh && grep -qF "cp \"\$W/s2a_caps.all.tsv\" \"\$W/s2a_caps.tsv\"" $H/pack/ipa.sh \
   && grep -qF "cp \"\$W/s2a_caps.tsv\" \"\$W/.s2a_caps.release.tsv\"" $H/pack/ipa.sh && grep -qF "mv -f \"\$W/.s2a_caps.release.tsv\" \"\$W/s2a_caps.tsv\"" $H/pack/ipa.sh'
# ⑪b --native（11-02 维护者：原生档手测包）：取 ipa.sh 里那一行在夹具产物根上执行——手算期望：widen / fps60 变 0，direct / gyro 原样，发布口径留在 .s2a_caps.release.tsv
NW=$T/nat; mkdir -p $NW; printf 'widen\t1\t# a\nfps60\t1\t# b\ndirect\t1\t# c\ngyro\t1\t# d\n' > $NW/s2a_caps.tsv; cp $NW/s2a_caps.tsv $NW/want_release.tsv
NL=$(grep '^\[ \$NATIVE = 1 \] && { cp' $H/pack/ipa.sh); ( W=$NW; NATIVE=1; fail() { echo "$*"; exit 1; }; eval "$NL" )
ck "⑪b --native：widen=$(v $NW/s2a_caps.tsv widen) fps60=$(v $NW/s2a_caps.tsv fps60) direct=$(v $NW/s2a_caps.tsv direct) gyro=$(v $NW/s2a_caps.tsv gyro)；发布口径备份原样；与 --all-caps 互斥" \
  '[ "$(v $NW/s2a_caps.tsv widen)" = 0 ] && [ "$(v $NW/s2a_caps.tsv fps60)" = 0 ] && [ "$(v $NW/s2a_caps.tsv direct)" = 1 ] && [ "$(v $NW/s2a_caps.tsv gyro)" = 1 ] && cmp -s $NW/.s2a_caps.release.tsv $NW/want_release.tsv && grep -qF -- "--all-caps 与 --native 不能同时给" $H/pack/ipa.sh'
# Mac：宿主非 iOS 分支在装载前按模块目录（产物根）读清单；日志带原因（普查 census.py caps_state 读）
HM=$H/runtime/src/host_main.c
ck "⑫ Mac 路径：host_main.c 非 iOS 分支在首次 load_session_modules 之前调 s2a_caps_apply(dir)，caps.c 日志带「原因：」" \
  'awk "/^#if !TARGET_OS_IPHONE/{f=1} f&&/s2a_caps_apply\(dir\)/{c=NR} /load_session_modules\(NULL\)/{l=NR} END{exit !(c && l && c < l)}" $HM && [ "$(grep -c "原因：%s" $H/runtime/src/caps.c)" = 3 ]'
# 安卓：资源包带清单进游戏数据根、运行时装载前读、caps.c 编进游戏目标
#   找单引号用 grep -F 字面串，不用 \x27：GNU grep 的 BRE 不认这个转义，按字面找「x27」，Linux 上本项必红（11-01 #933 / #1252 撞到）
ck "⑬ 安卓路径：make_pack 把 s2a_caps.tsv 放进游戏数据根，runtime.c 装载前 s2a_caps_apply(game_data_dir)，Runtime.cmake 编入 caps" \
  'grep -qF "'"'"'s2a_caps.tsv'"'"')" $H/android/tools/make_pack.py && awk "/s2a_caps_apply\(r->services.game_data_dir\)/{c=NR} /load_modules_from_source\(r->module_source/{l=NR} END{exit !(c && l && c < l)}" $H/android/native/runtime/runtime.c && grep -q "set(core .* caps " $H/android/core-link/Runtime.cmake'
# ⑭–⑯ 同局 A/B 结论（docs/名单_60帧逻辑速度/<程序号>.tsv，tools/fps_ab_ledger.py 入账，11-02）：红 → fps60 0（任何来源都关）；绿、没有别的帧率来源 → fps60 1 + fps60_display 1、来源写 A/B 绿（放行列不再改开关，全引擎默认开）；
#   绿但有帧率表（fps.tsv 自己管出图间隔）→ fps60 1、不写 fps60_display
reg; fps; cov; ab() { mkdir -p $G/docs/名单_60帧逻辑速度; printf '程序号\t构建号\t款\t结论\tρ\tq\t依据\t日期\t放行\n%s\t%s\tmk8d\t%s\t%s\t2.0\t普查\t2026-11-02\t%s\n' "$PID" "$BID" "$1" "$2" "${3:-}" > $G/docs/名单_60帧逻辑速度/$PID.tsv; }
ab 红 2.03; r=$(run o14); ck "⑭ 同局 A/B 红 → fps60 0、原因带 ρ（rc=${r}；$(why $T/o14.tsv fps60)）" '[ $r = 0 ] && [ "$(v $T/o14.tsv fps60)" = 0 ] && case "$(why $T/o14.tsv fps60)" in *逻辑速度红*同局*2.03*) true;; *) false;; esac'
rm -f $C/fps.tsv; ab 绿 1.02 是; r=$(run o15); ck "⑮ 同局 A/B 绿且放行、没有别的帧率来源 → fps60 1 + fps60_display 1（rc=${r}；$(why $T/o15.tsv fps60)）" '[ $r = 0 ] && [ "$(v $T/o15.tsv fps60)" = 1 ] && [ "$(v $T/o15.tsv fps60_display)" = 1 ]'
ab 绿 1.02; r=$(run o15b); ck "⑮b 同局 A/B 绿、放行空、没有别的帧率来源 → 照开 fps60 1 + fps60_display 1、来源写 A/B 绿（rc=${r}；$(why $T/o15b.tsv fps60)）" '[ $r = 0 ] && [ "$(v $T/o15b.tsv fps60)" = 1 ] && [ "$(v $T/o15b.tsv fps60_display)" = 1 ] && case "$(why $T/o15b.tsv fps60)" in *同局\ A/B\ 绿*1.02*) true;; *) false;; esac'
ab 绿 1.02 是; touch $C/fps.tsv; r=$(run o16); ck "⑯ 同局 A/B 绿但有帧率表 → fps60 1、不写 fps60_display（rc=${r}）" '[ $r = 0 ] && [ "$(v $T/o16.tsv fps60)" = 1 ] && [ -z "$(v $T/o16.tsv fps60_display)" ]'
rm -rf $G/docs/名单_60帧逻辑速度
# ⑰ --both（11-03：两种口径一次判定，引擎推导读 RomFS 只做一次）与分两次调用逐字节相同
r1=$(run o17a); r2=$(run o17b --all-caps); r3=$(S2A_CAPS_REPO=$G bash $H/pack/gen_caps.sh mk8d $C $T/o17c.tsv --both $T/o17d.tsv > $T/o17.log 2>&1; echo $?)
ck "⑰ --both 两份与分两次逐字节相同（rc=${r1}/${r2}/${r3}）" '[ "$r1$r2$r3" = 000 ] && cmp -s $T/o17a.tsv $T/o17c.tsv && cmp -s $T/o17b.tsv $T/o17d.tsv'
[ $bad = 0 ] && echo "gen_caps 单测全过" || { echo "gen_caps 单测有不通"; exit 1; }
