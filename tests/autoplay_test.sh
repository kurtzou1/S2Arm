#!/bin/bash
# 自动玩家「AI 看屏驾驶」单测（假宿主 t_autoplay.c + 假驾驶员 fake_vision.sh，判据时钟 4 倍速）：bash tests/autoplay_test.sh
# 期望全部按规格手推（体验线_AI驾驶重构规格.md 单测清单），不跑被测实现也算得出：
#   ① 菜单按 A 变页  ② 没变化的键进 tried 并传给驾驶员  ③ 可玩但读数没到不打 MARK  ④ 双证打 MARK（字面、ap_mark.png、小结字段）
#   ⑤ 低帧（一帧 100 ms）放行仍对  ⑥ 步数上限 → 导航卡住 + ap_stuck.png  ⑦ 学路线第二局回放导航不问模型、到学过的进局页只问一次确认可操控  ⑧ 回放对不上交回 AI
set -u; H=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
read -r -a WEAK <<< "$(python3 "$H/../tools/weak_link_decl.py" flags autoplay)"   # 放行参数按 autoplay.c 的「弱链接[autoplay]」登记生成
clang -O1 -Wall -Werror -o $T/t_autoplay $H/autoplay/autoplay.c $H/autoplay/t_autoplay.c -framework CoreGraphics -framework ImageIO -framework CoreFoundation \
  "${WEAK[@]}" 2> $T/cc.log || { cat $T/cc.log; echo "不通 编译"; exit 1; }
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -fsyntax-only -Wall -Werror $H/autoplay/autoplay.c 2> $T/ios.log
ck "编译（-Wall -Werror）+ iOS SDK 语法编译$( [ -s $T/ios.log ] && head -2 $T/ios.log | tr '\n' ' ')" '[ ! -s $T/ios.log ]'
export S2A_AP_TIMESCALE=4 S2A_VISION_SH=$H/autoplay/fake_vision.sh S2A_AP_LOOP_S=4 S2A_AP_LEARN_DIR=$T/learn_none
run() { local d=$T/$1; shift; mkdir -p $d; env "$@" timeout 150 $T/t_autoplay $d "${SCN}" > /dev/null 2>&1; echo $? > $d/rc; }
MAP_OK='TITLE=A;MENU=A;GAME=LS_RIGHT:play'
SCN=ok      run ok      FAKE_MAP=$MAP_OK &
SCN=ok      run slow    FAKE_MAP=$MAP_OK S2A_TEST_FRAME_MS=100 &
SCN=lowdraw run low     FAKE_MAP=$MAP_OK S2A_AP_MAX_STEPS=6 &
SCN=lowdraw run lowesc  FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play55' FAKE_ESC_PLAY=1 S2A_AP_MAX_STEPS=8 &
SCN=lowdraw run lowno   FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play55' S2A_AP_MAX_STEPS=6 &
SCN=stuck   run stuck   FAKE_MAP='TITLE=A/B/X/Y' S2A_AP_MAX_STEPS=4 &
SCN=titlex  run tx      FAKE_MAP='TITLE=A/X;MENU=A;GAME=LS_RIGHT:play' S2A_AP_LEARN_DIR=$T/learn_x S2A_AP_PROGRAM_ID=0100000000ab0002 &
SCN=ok      run learn1  FAKE_MAP=$MAP_OK S2A_AP_LEARN_DIR=$T/learn S2A_AP_PROGRAM_ID=0100000000ab0001 &
SCN=pingpong run pp    FAKE_MAP='TITLE=A;MENU=B/X;GAME=LS_RIGHT:play' &
SCN=fwd      run fwd   FAKE_MAP='TITLE=A;MENU=B/Y/X;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=14 &   # 11-03 回头路第 2 次才拉黑：B / Y 各要走两趟，10 → 14 步
SCN=daynight run daynight FAKE_MAP='TITLE=A;MENU=B/Y/X;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=14 &   # 11-03 回头路第 2 次才拉黑：B / Y 各要走两趟，10 → 14 步
SCN=lag     run lag     FAKE_MAP=$MAP_OK &
SCN=lag     run lagslow FAKE_MAP=$MAP_OK S2A_TEST_FRAME_MS=400 S2A_TEST_LAG_FRAMES=75 &
SCN=anim    run anim    FAKE_MAP=$MAP_OK &
SCN=stuck   run esc     FAKE_MAP='TITLE=A/B/X/Y' S2A_AP_MAX_STEPS=4 &
SCN=ok      run front1  FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT' S2A_AP_MAX_STEPS=5 S2A_AP_LEARN_DIR=$T/learn_f S2A_AP_PROGRAM_ID=0100000000ab0003 &
SCN=ok      run psys    FAKE_MAP='TITLE=A;MENU=A;GAME=PLUS:play' S2A_AP_MAX_STEPS=5 &
SCN=ok      run plow    FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play55' S2A_AP_MAX_STEPS=5 &
SCN=tap2    run tap2    FAKE_MAP='TITLE=TOUCH:640,360;MENU=A;GAME=LS_RIGHT:play' &
SCN=atog    run atog    FAKE_MAP='TITLE=A;MENU=A/X;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=12 &
SCN=cut     run cut     FAKE_MAP='TITLE=PLUS;PAUSE=PLUS;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=12 &
SCN=navfail run navfail FAKE_MAP='TITLE=LEFT+A/TOUCH:640,360;MENU=A;GAME=LS_RIGHT:play;PAUSE=B' S2A_AP_MAX_STEPS=12 &
SCN=stay    run stay    FAKE_MAP='TITLE=R/A/X;MENU=A;GAME=LS_RIGHT:play' &
SCN=pager   run pager   FAKE_MAP='TITLE=RIGHT/A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=12 &
SCN=pagetext run pagetext FAKE_MAP='TITLE=RIGHT/A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=12 &
SCN=pausep  run pausep  FAKE_MAP='TITLE=A;MENU=A;GAME=PLUS;PAUSE=PLUS' S2A_AP_MAX_STEPS=8 &
SCN=pauseb  run pauseb  FAKE_MAP='TITLE=A;MENU=A;GAME=PLUS;PAUSE=A' S2A_AP_MAX_STEPS=8 &
SCN=waves   run waves   FAKE_MAP='TITLE=A/X;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=8 &
mkdir -p $T/live; printf 'REC:x\nTOUCH:1,2\nPASS:p\n' > $T/live/live.txt; ( sleep 2; echo REC:y >> $T/live/live.txt ) &
SCN=ok      run live    FAKE_MAP=$MAP_OK S2A_AP_LIVE=$T/live/live.txt &
# 自动玩家没开、只开实时通道（11-02：人玩 / 脚本局按需抓逐笔、脚本按键）：相对路径按输出目录解析；KEY:A 把标题页按进菜单，PASS 落图；自动玩家不起（不打 MARK、不写小结）
mkdir -p $T/liveoff; printf 'KEY:A\nKEY:BOGUS\nPASS:q\n' > $T/liveoff/lo.txt
SCN=ok      run liveoff FAKE_MAP=$MAP_OK S2A_AUTOPLAY=0 S2A_AP_LIVE=lo.txt S2A_T_LIVE_S=3 &
# 逻辑速度探测（S2A_AP_SPEED=1）：ok 场景按帧推进（每帧 1 像素）、speeda 按真实时间（每秒 30 像素）；30 / 60 帧各一局
SCN=speedmenu run sp_menu FAKE_MAP=$MAP_OK S2A_AP_SPEED=1 S2A_AP_LOOP_S=40 &
for c in "ok b30 33.333" "ok b60 16.667" "speeda a30 33.333" "speeda a60 16.667"; do set -- $c
  SCN=$1 run sp_$2 FAKE_MAP=$MAP_OK S2A_AP_SPEED=1 S2A_AP_LOOP_S=30 S2A_TEST_FRAME_MS=$3 & done
# 同局 A/B（S2A_AP_SPEED=ab）：60 帧（16.667 ms）起局，回原帧率那段假宿主帧间隔翻倍；ok 按帧推进、speeda 按真实时间
SCN=abfix run ab_b FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=150 S2A_TEST_FRAME_MS=16.667 &
SCN=abrt  run ab_a FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=150 S2A_TEST_FRAME_MS=16.667 &
SCN=abkick run ab_k FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=300 S2A_TEST_FRAME_MS=16.667 &
SCN=abmix run ab_m FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=150 S2A_TEST_FRAME_MS=16.667 &
# ㊿ 普查提前收局（S2A_AP_EARLY_S，11-04 维护者）：到 MARK 后 MARK 后段全部跑完 + 照常出帧 N 秒就收局，局内段不再跑满 S2A_AP_LOOP_S；没到 MARK 照旧给满局时
SCN=abfix run ef_ab  FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=600 S2A_AP_EARLY_S=20 S2A_TEST_FRAME_MS=16.667 &
SCN=ok    run ef_aud FAKE_MAP=$MAP_OK S2A_AP_LOOP_S=600 S2A_AP_EARLY_S=8 S2A_TEST_AUDIO_SEG_S=60 &
SCN=abkick run ef_kick FAKE_MAP=$MAP_OK S2A_AP_SPEED=ab S2A_AP_LOOP_S=600 S2A_AP_EARLY_S=5 S2A_TEST_FRAME_MS=16.667 &
SCN=stuck run ef_nm  FAKE_MAP='TITLE=A/B/X/Y' S2A_AP_MAX_STEPS=200 S2A_AP_EARLY_S=5 S2A_RUN_S=10 S2A_AP_VIS_LEFT_S=2 S2A_AP_END_LEFT_S=2 &
SCN=lang    run lang    FAKE_MAP='LANG=A/DOWN;EDIT=DOWN/A;ROW1=DOWN;OK=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=14 &
SCN=focus   run focus   FAKE_MAP='FOCUS0=A/DOWN;FOCUS1=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=8 &
SCN=titlex  run fbtried  FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=14 &
SCN=ok      run fbwait   FAKE_MAP='TITLE=WAIT;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=30 &
SCN=popback run popback FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=10 &
SCN=ring run ring FAKE_MAP='TITLE=A/X;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=14 &
SCN=sideways run sideways FAKE_MAP='TITLE=SL|SR;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=6 &
SCN=agree   run agree   FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=12 &
SCN=yesno   run yesno   FAKE_MAP='YES0=UP+A;YES1=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=8 &
SCN=scroll  run scroll  FAKE_MAP='SCROLL0=A/RIGHT_STICK_DOWN;SCROLL1=A;MENU=A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=8 &
SCN=coop    run coop    FAKE_MAP='TITLE=A/2:A/A;MENU=A;GAME=LS_RIGHT:play' &
SCN=pflash  run pflash  FAKE_MAP='TITLE=PLUS/A;MENU=A;GAME=LS_RIGHT:play;PAUSE=PLUS' S2A_AP_MAX_STEPS=16 &
SCN=pmenu   run pmenu   FAKE_MAP='TITLE=PLUS/A;MENU=PLUS/A;GAME=LS_RIGHT:play' S2A_AP_MAX_STEPS=16 &
SCN=cstay   run cstay   FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT:play' FAKE_ESC_MAP='TITLE=X' S2A_AP_MAX_STEPS=12 &
SCN=ok      run nokey   FAKE_MAP=$MAP_OK S2A_VISION_SH= S2A_VISION_BACKEND=or HOME=$T/nohome &
# ⑨b 显式 cli 后端（本机 claude CLI）：PATH 上没有 claude（只放 timeout）→ 起步报红、不问；⑨c 驾驶员回「不可用」（退出 3 + unavailable）→ 红停、只问 1 次、收局理由带原因
mkdir -p $T/nocli_bin; ln -sf "$(command -v timeout)" $T/nocli_bin/timeout
cat > $T/unavail_vision.sh << 'SHEOF'
#!/bin/bash
echo 1 >> "$(dirname "$1")/../unavail_calls"
echo '{"keys": [], "playable": false, "why": "本机 claude CLI 没登录（假）", "unavailable": true}' > "$2"
exit 3
SHEOF
SCN=ok      run nocli   FAKE_MAP=$MAP_OK S2A_VISION_SH= S2A_VISION_BACKEND=cli PATH=$T/nocli_bin:/usr/bin:/bin HOME=$T/nohome_c &
SCN=ok      run norelay FAKE_MAP=$MAP_OK S2A_VISION_SH= HOME=$T/nohome_d PATH=$T/nocli_bin:/usr/bin:/bin &
SCN=ok      run unavail FAKE_MAP=$MAP_OK S2A_VISION_SH=$T/unavail_vision.sh &
SCN=ok      run hold    FAKE_MAP=$MAP_OK S2A_AP_HOLD=A &
# ㉟ 局内段回放真机 padrec（S2A_AP_PADREC=<录像>@<起始帧>）：起始帧前一行（B，开放时先按住）、存档行跳过；之后 5 行、长 52 帧，A 从第 0 帧按到第 40 帧
printf '# 构建号 x\n90\t0x2\t0\t0\t0\t0\t0\n100\t0x1\t0\t0\t0\t0\t10\n120\t0x1\t-30000\t0\t0\t0\t20\n140\t0\t0\t0\t0\t0\t30\n145\t存档\t1\t40\n150\t0x2\t0\t0\t0\t0\t50\n152\t0\t0\t0\t0\t0\t60\n' > $T/pad.tsv
SCN=ok      run padrec  FAKE_MAP=$MAP_OK S2A_AP_PADREC=$T/pad.tsv@100 &
# ㊱ 相对路径按输出目录解析（iOS = 本次安装的 Documents）；㊲ 打不开：红行、局内段原地不动（不退回随机动作）
mkdir -p $T/padrel/padrec; cp $T/pad.tsv $T/padrel/padrec/pad.tsv
SCN=ok      run padrel  FAKE_MAP=$MAP_OK S2A_AP_PADREC=padrec/pad.tsv@100 &
SCN=ok      run padbad  FAKE_MAP=$MAP_OK S2A_AP_PADREC=/nonexistent/pad.tsv@100 &
# ㉗ 远程信箱（iOS 真机局：Mac 侧 tools/vision_bridge.sh 经 devicectl 答）：本机没有脚本也没有密钥；假桥只答本会话的请求、写 done；
#   开局前放一份上一局残留（v01.done 旧会话 + v01.json 答 B），自动玩家要清掉、不认
mkdir -p $T/remote/vision; echo old-1 > $T/remote/vision/v01.done; echo '{"keys": ["B"], "playable": false, "why": "残留"}' > $T/remote/vision/v01.json
remote_bridge() { local d=$1 n=1 s f; until [ -s $d/vision/session ] || [ -f $d/rc ]; do sleep 0.05; done; s=$(cat $d/vision/session 2> /dev/null)
  while [ ! -f $d/rc ]; do f=$(printf '%s/vision/v%02d' $d $n)
    if [ -f $f.req ] && [ "$(sed -n 's/^session=//p' $f.req)" = "$s" ]; then
      S2A_T_STATE=$d/state FAKE_MAP=$MAP_OK S2A_VISION_TRIED="$(sed -n 's/^tried=//p' $f.req)" S2A_VISION_ESCALATE="$(sed -n 's/^escalate=1$/1/p' $f.req)" bash $H/autoplay/fake_vision.sh $f.png $f.json
      echo "$s" > $f.done; n=$((n + 1)); fi; sleep 0.05; done; }
remote_bridge $T/remote &
SCN=ok      run remote  FAKE_MAP=$MAP_OK S2A_VISION_REMOTE=1 S2A_VISION_SH= HOME=$T/nohome_r &
wait
SCN=ok run learn2 FAKE_MAP='TITLE=;MENU=;GAME=LS_RIGHT:play' S2A_AP_LEARN_DIR=$T/learn S2A_AP_PROGRAM_ID=0100000000ab0001 &
SCN=ok run front2   FAKE_MAP='TITLE=A;MENU=A;GAME=LS_RIGHT' S2A_AP_MAX_STEPS=5 S2A_AP_LEARN_DIR=$T/learn_f S2A_AP_PROGRAM_ID=0100000000ab0003 &
SCN=ok run mism   FAKE_MAP=$MAP_OK S2A_AP_LEARN_DIR=$T/learn_x S2A_AP_PROGRAM_ID=0100000000ab0002 &
wait
L() { cat $T/$1/host.log 2> /dev/null; }; J() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" $T/$1/ap_summary.json $2 2> /dev/null; }
calls() { [ -f $T/$1/vision_calls.log ] && wc -l < $T/$1/vision_calls.log | tr -d ' ' || echo 0; }
# ①
ck "① 菜单按 A 变页：标题按 A → 画面变了、游戏进菜单" 'L ok | grep -q "按 A（第 1 下.*→ 画面变了" && L ok | grep -q "\[游戏\] 进 MENU"'
# ②
ck "② 没变化的键进 tried、传给驾驶员：标题按 A 没变 → 下一问 S2A_VISION_TRIED=A、驾驶员改答 X（实为：$(sed -n 2p $T/tx/vision_calls.log 2> /dev/null)）" 'L tx | grep -q "按 A（第 1 下.*→ 画面没变" && sed -n 2p $T/tx/vision_calls.log | grep -qx "TITLE X A"'
# ③
ck "③ 可玩但读数没到（局内绘制 30 < 3×20）：不打 MARK、日志写明、到步数上限收" '! L low | grep -q "S2A 标记 MARK" && L low | grep -q "模型说可操控但读数未到场景量级" && L low | grep -q "自动玩家结论：没到 MARK；导航卡住（步数上限 6 步）"'
# ④
mk=$(L ok | sed -n 's/^S2A 标记 MARK：帧 \([0-9]*\)$/\1/p' | head -1); gf=$(L ok | sed -n 's/^\[游戏\] 进 GAME 帧 \([0-9]*\)$/\1/p' | head -1)
ck "④ 双证打 MARK：MARK 帧 ${mk:-无} ≥ 进局帧 ${gf:-无}、结论行、ap_mark.png" '[ -n "$mk" ] && [ -n "$gf" ] && [ "$mk" -ge "$gf" ] && L ok | grep -q "^自动玩家结论：到 MARK；模型说可操控 + 读数到场景量级" && [ -s $T/ok/ap_mark.png ]'
ck "④ 小结字段：marked=True、mark_frame=${mk:-无}、vision_asks=3（实为 $(J ok vision_asks)）、presses=2（实为 $(J ok presses)）、局内段 ap_mid / ap_end 在、退出 0" \
  '[ "$(J ok marked)" = True ] && [ "$(J ok mark_frame)" = "$mk" ] && [ "$(J ok vision_asks)" = 3 ] && [ "$(J ok presses)" = 2 ] && [ -s $T/ok/ap_mid.png ] && [ -s $T/ok/ap_end.png ] && [ "$(cat $T/ok/rc)" = 0 ] && [ -s $T/ok/vision/v01.png ]'
# 测量窗口（局内段）截图线程不干活（11-04 能耗线 / 维护者定）：局内段只看上屏帧计数，截图请求 0 次；导航期照取摘要（> 0）。旧写法局内段每 20 ms 投一次，必 > 0
sr=$(L ok | sed -n 's/^自动玩家：截图请求 \([0-9]*\) 次，其中局内段 \([0-9]*\) 次.*/\1 \2/p' | tail -1)
ck "④ 局内段截图请求 0 次、导航期 > 0（实为 总 / 局内段 = ${sr:-无}）" '[ -n "$sr" ] && [ "${sr#* }" = 0 ] && [ "${sr% *}" -gt 0 ]'
# ⑤
ck "⑤ 低帧（一帧 100 ms）：仍按 A A 进局打 MARK、翻页 2（实为 $(J slow presses_changed)）" 'L slow | grep -q "S2A 标记 MARK" && [ "$(J slow presses_changed)" = 2 ]'
# ⑥
ck "⑥ 步数上限 4：结论「导航卡住（步数上限 4 步）」、ap_stuck.png、marked=False" 'L stuck | grep -q "^自动玩家结论：没到 MARK；导航卡住（步数上限 4 步）" && [ -s $T/stuck/ap_stuck.png ] && [ "$(J stuck marked)" = False ]'
# ⑦
lf=$T/learn/0100000000ab0001.tsv
ck "⑦ 学路线：首局写 3 步（A、A、MARK；实为 $(grep -v '^#' $lf 2> /dev/null | cut -f2 | tr '\n' ' ')）" '[ "$(grep -v "^#" $lf | cut -f2 | tr "\n" " ")" = "A A MARK " ]'
ck "⑦ 第二局回放：导航 0 问、进局页确认 1 问（实为 $(calls learn2) 问：$(cut -d' ' -f1 $T/learn2/vision_calls.log 2> /dev/null | tr '\n' ' ')）、回放 3 步（实为 $(J learn2 replayed_steps)）、打 MARK" '[ "$(calls learn2)" = 1 ] && grep -qx "GAME LS_RIGHT " $T/learn2/vision_calls.log && [ "$(J learn2 replayed_steps)" = 3 ] && L learn2 | grep -q "S2A 标记 MARK" && L learn2 | grep -q "回放到学过的进局页"'
# ⑧
ck "⑧ 回放对不上（学的是标题按 X，本局标题只认 A）：记「回放对不上」、交回 AI 问 1 次 + 进局页确认 1 次（实为 $(calls mism)）、打 MARK、路线重写成 A A MARK（实为 $(grep -v '^#' $T/learn_x/0100000000ab0002.tsv | cut -f2 | tr '\n' ' ')）" \
  'L mism | grep -q "回放对不上" && [ "$(calls mism)" = 2 ] && L mism | grep -q "S2A 标记 MARK" && [ "$(grep -v "^#" $T/learn_x/0100000000ab0002.tsv | cut -f2 | tr "\n" " ")" = "A A MARK " ]'
ck "⑨ 显式 OpenRouter 后端没有密钥：报红「视觉测试员不可用」（判定脚本据此记未判）、没到 MARK、0 按键" 'L nokey | grep -q "【红】自动玩家：视觉测试员不可用（S2A_VISION_BACKEND=or 要 OpenRouter 钥匙，没有 .*openrouter.key）" && [ "$(J nokey marked)" = False ] && [ "$(J nokey presses)" = 0 ]'
ck "⑨d 不设后端（自动选）：没有中转站钥匙和地址、PATH 上也没有 claude → 起步报红、没到 MARK、0 按键" 'L norelay | grep -q "【红】自动玩家：视觉测试员不可用（没有中转站钥匙和地址" && L norelay | grep -q "本机也没有 claude CLI" && [ "$(J norelay marked)" != true ]' 
ck "⑨b 显式 cli 后端（本机 claude CLI）PATH 上没有 claude：起步报红「本机没有 claude CLI」、没到 MARK、0 按键" 'L nocli | grep -q "【红】自动玩家：视觉测试员不可用（本机没有 claude CLI" && [ "$(J nocli marked)" = False ] && [ "$(J nocli presses)" = 0 ]'
ck "⑨c 驾驶员回「不可用」：红停（不当成没答连问 3 次；实问 $(wc -l < $T/unavail/unavail_calls 2> /dev/null | tr -d ' ') 次）、收局理由带原因（$(J unavail why | cut -c1-80)）" \
  'L unavail | grep -q "【红】自动玩家：驾驶员 #1 看屏驾驶员不可用：本机 claude CLI 没登录（假）" && [ "$(wc -l < $T/unavail/unavail_calls | tr -d " ")" = 1 ] && [ "$(J unavail marked)" = False ] && J unavail why | grep -q "导航卡住（看屏驾驶员不可用：本机 claude CLI 没登录（假））"'
ck "⑩ 回到问过的页带上答过的键：菜单答 B 退回标题、再到菜单时 S2A_VISION_TRIED 含 B、改答 X 进局打 MARK（实为：$(grep '^MENU' $T/pp/vision_calls.log 2> /dev/null | tr '\n' '|')）" 'grep -q "^MENU X B" $T/pp/vision_calls.log && L pp | grep -q "S2A 标记 MARK"'
ck "⑪ 点触第一下只选中、页面没换：自动补第二下进菜单，不多问模型（标题问 $(grep -c '^TITLE' $T/tap2/vision_calls.log 2> /dev/null) 次，要 1）、打 MARK、点触没反应 0 次" 'L tap2 | grep -q "点触（第二下）" && [ "$(grep -c "^TITLE" $T/tap2/vision_calls.log)" = 1 ] && L tap2 | grep -q "S2A 标记 MARK" && L tap2 | grep -q "点触没反应 0 次"'
ck "⑫ 页面刚出来不收键（菜单 1.5 秒）：A 第一次没反应 → 隔 2 秒再按进局、A 不进试过没用、打 MARK" 'L lag | grep -q "A 第一次没反应，隔 2 秒再按一次" && ! L lag | grep -q "试过没用的键 A" && L lag | grep -q "S2A 标记 MARK"'
ck "⑫ 出帧很慢（一帧 400 ms、4 倍速下真 100 ms，仿 gate-host 并发负载下出帧线程被挤）+ 不收键 75 帧：隔 2 秒且等够 2 秒的帧（60 帧）再按，A 不进试过没用、打 MARK" 'L lagslow | grep -q "A 第一次没反应，隔 2 秒再按一次" && ! L lagslow | grep -q "试过没用的键 A" && L lagslow | grep -q "S2A 标记 MARK"'
ck "⑬ MARK 延后读数：日志「MARK 延后 N 秒」、小结 mark_delay_s 在 0–5.5（实为 $(J ok mark_delay_s)）" 'L ok | grep -q "^自动玩家：MARK 延后 [0-9.]* 秒" && python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 <= v <= 5.5 else 1)" "$(J ok mark_delay_s)"'
ck "⑬ 局内画面一直在动：等稳定撞 5 秒上限照记 MARK，mark_delay_s 在 4.5–5.5（实为 $(J anim mark_delay_s)）" 'L anim | grep -q "S2A 标记 MARK" && python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 4.5 <= v <= 5.5 else 1)" "$(J anim mark_delay_s)"'
ck "⑭ 同一页问过 1 次再问仍走 Jev、问过 ≥ 2 次且上一问 Jev 没推进才升级、升级后下一问回 Jev（四问升级标记 实为 $(cut -d' ' -f2 $T/esc/vision_env.log 2> /dev/null | tr '\n' ' ')，要 0 0 1 0）" '[ "$(cut -d" " -f2 $T/esc/vision_env.log | tr "\n" " ")" = "0 0 1 0 " ]'
lf2=$T/learn_f/0100000000ab0003.tsv
ck "⑮ 没到 MARK 也写学路线前沿（不带 MARK；实为 $(grep -v '^#' $lf2 2> /dev/null | cut -f2 | tr '\n' ' ')）、第二局回放标题 / 菜单两步不问模型（回放 $(J front2 replayed_steps) 步、标题 / 菜单问 $(cat $T/front2/vision_calls.log 2> /dev/null | grep -c '^TITLE\|^MENU') 次；回放走完前沿撞步数上限时一问不问、没有问答记录 = 0 次）" '[ "$(grep -v "^#" $lf2 | cut -f2 | head -2 | tr "\n" " ")" = "A A " ] && ! grep -v "^#" $lf2 | cut -f2 | grep -qx MARK && [ "$(J front2 replayed_steps)" -ge 2 ] && [ "$(cat $T/front2/vision_calls.log 2> /dev/null | grep -c "^TITLE\|^MENU")" = 0 ]'
ck "⑯ 说可操控却答 PLUS（仿过场暂停页）：那一问判自相矛盾、不在那一问打 MARK（之后不带系统键再说可操控才进局）" 'L psys | grep -q "模型说可操控却答了 + / -" && [ "$(L psys | grep -n "自相矛盾" | head -1 | cut -d: -f1)" -lt "$(L psys | grep -n "S2A 标记 MARK" | head -1 | cut -d: -f1)" ] && L psys | sed -n "/自相矛盾/,/S2A 标记 MARK/p" | grep -q "驾驶员 #4"'
ck "⑯ 可操控概率 0.55 < 0.8：升级复核否决、不打 MARK；概率高（ok 局）照常进局" 'L plow | grep -q "升级复核 → 不是可操控场景" && ! L plow | grep -q "S2A 标记 MARK" && L ok | grep -q "S2A 标记 MARK"'
ck "⑰ 双人合作要二号加入（一号 A 没反应）：改答 2:A → 接上第二个手柄、二号加入（只亮一小块也算画面变了、清掉这页试过没用）→ 一号 A 进菜单、打 MARK（标题问答 实为 $(grep '^TITLE' $T/coop/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')，要 A 2:A A）" 'L coop | grep -q "接上第二个手柄（驾驶员要单独按二号手柄：2:A）" && L coop | grep -q "按 2:A（第 [0-9]* 下.*→ 画面变了" && L coop | grep -q "页内变了（同一页），这页试过没用的键 A 清空" && [ "$(grep "^TITLE" $T/coop/vision_calls.log | cut -d" " -f2 | tr "\n" " ")" = "A 2:A A " ] && L coop | grep -q "S2A 标记 MARK"'
ck "⑱ 页内来回（R / A 每按都变了又停在这页）：回到这页见过的页内状态记试过没用（R 翻回原状态、A 又翻到见过的亮块），改答 X 进菜单、打 MARK（标题问答 实为 $(grep '^TITLE' $T/stay/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')，要 R R A X）" '[ "$(grep "^TITLE" $T/stay/vision_calls.log | cut -d" " -f2 | tr "\n" " ")" = "R R A X " ] && L stay | grep -q "回到这页见过的页内状态（页内来回、没进展）" && L stay | grep -q "S2A 标记 MARK"'
ck "⑱b 多页协议（页页长得一样、只有页码块挪位）：RIGHT 每按都到这页没见过的页内状态，不拉黑；最后一页 RIGHT 没变、改答 A 进菜单、打 MARK（标题问答 实为 $(grep '^TITLE' $T/pager/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')，要 RIGHT×5 A）" '[ "$(grep "^TITLE" $T/pager/vision_calls.log | cut -d" " -f2 | tr "\n" " ")" = "RIGHT RIGHT RIGHT RIGHT RIGHT A " ] && ! L pager | grep -q "页内来回" && L pager | grep -q "S2A 标记 MARK"'
ck "⑱d 多页协议各页只差细节（1 像素细线，仿 11-02 太鼓协议只差字形）：RIGHT 每按都到这页没见过的页内状态，不拉黑；最后一页 A 进菜单、打 MARK（标题问答 实为 $(grep '^TITLE' $T/pagetext/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')，要 RIGHT×5 A）" '[ "$(grep "^TITLE" $T/pagetext/vision_calls.log | cut -d" " -f2 | tr "\n" " ")" = "RIGHT RIGHT RIGHT RIGHT RIGHT A " ] && ! L pagetext | grep -q "页内来回" && L pagetext | grep -q "S2A 标记 MARK"'
ck "⑱c 局内只答 +（低把握）：按 + 进压暗叠字的暂停页 → 关掉暂停推左摇杆整屏动了 + 读数到场景量级 → 打 MARK（进局理由 实为 $(J pausep why)）" 'L pausep | grep -q "像暂停菜单：关掉暂停" && L pausep | grep -q "S2A 标记 MARK" && J pausep why | grep -q "按 + 进了暂停菜单"'
ck "⑱e 暂停页是模糊不是压暗（仿 11-02 银河2）：局内按 + 进暂停、暂停里 A 回到按 + 前那页 = 关暂停（不算回头路、A 不拉黑）→ 推左摇杆整屏动了 + 读数到场景量级 → 打 MARK（进局理由 实为 $(J pauseb why)）" 'L pauseb | grep -q "= 关掉暂停，不算走回头路" && ! L pauseb | grep -q "走回头路），记为" && [ "$(J pauseb marked)" = True ]'
ck "⑲ 过场 + 只暂停（仿异度3）：认出 + 是开关（进暂停页、再按回原页）后，没暂停时答 + 不按、等过场自己播（不计步），步数上限 12 内进菜单打 MARK（等待 $(L cut | grep -c '这次不按、等') 次）" 'L cut | grep -q "PLUS 是开关（如暂停），之后它没开着时不再按它" && L cut | grep -q "PLUS 是开关.*现在没开着，这次不按" && L cut | grep -q "\[游戏\] 进 MENU" && L cut | grep -q "S2A 标记 MARK"'
ck "⑳ 菜单 A 进一页、再 A 退回（像开关）：A 不认作开关（只认 + / -），照常记走回头路、改答 X 进局打 MARK" '! L atog | grep -q "是开关" && L atog | grep -q "S2A 标记 MARK"'
ck "⑳b 整屏纯色帧（gstd≈0）+ 按了进全黑页（仿 11-03 戦国無双5 / 弹丸 / 数码 / 大富翁）：+ 不记开关（纯色过滤），继续按 A 进菜单打 MARK" '! L pflash | grep -q "是开关" && ! L pflash | grep -q "翻倍等" && L pflash | grep -q "S2A 标记 MARK"'
ck "⑳c PLUS 在两张不同菜单页来回（亮度相近）：+ 不记开关（压暗条件不满足），继续按 A 进局打 MARK" '! L pmenu | grep -q "是开关" && ! L pmenu | grep -q "翻倍等" && L pmenu | grep -q "S2A 标记 MARK"'
ck "㉑ 实时通道：起局前写的 REC:x、局中追加的 REC:y 各落一张图；PASS:p 要下一帧逐笔并截图到局目录 p.png；不认的行记日志（落图 $(ls $T/live/rec_*.bgra 2> /dev/null | wc -l | tr -d ' ') 张）" '[ -s $T/live/rec_x.bgra ] && [ -s $T/live/rec_y.bgra ] && [ -s $T/live/p.png ] && L live | grep -q "\[游戏\] 逐笔 下 1 帧" && L live | grep -q "实时通道不认的行「TOUCH:1,2」"'
ck "㉑b 自动玩家没开、只开实时通道：通道照起（相对路径按输出目录）、KEY:A 按进菜单、认不得的键串记红、PASS:q 落图；自动玩家没起（无小结、无 MARK）" 'L liveoff | grep -q "实时通道 .*liveoff/lo.txt" && L liveoff | grep -q "\[游戏\] 进 MENU" && L liveoff | grep -q "KEY:BOGUS 认不得" && [ -s $T/liveoff/q.png ] && [ ! -e $T/liveoff/ap_summary.json ] && ! L liveoff | grep -q "S2A 标记 MARK"'
# ㉒ vision.sh 试过没用过滤（按完整动作比）：拷进临时目录，升级后端换成打印固定答案的桩（不发网络），S2A_VISION_ESCALATE=1 跳过 Jev
mkdir -p $T/vf; cp $H/autoplay/vision.sh $H/autoplay/nav_rules.txt $T/vf/; python3 -c 'import zlib,struct,sys; r=b"".join(b"\0"+b"\0"*3*64 for _ in range(36)); c=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)); open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",64,36,8,2,0,0,0))+c(b"IDAT",zlib.compress(r))+c(b"IEND",b""))' $T/vf/s.png
vf() { printf 'import sys; print(%s)\n' "'$2'" > $T/vf/vision_or.py; S2A_VISION_BACKEND=or S2A_VISION_ESCALATE=1 S2A_VISION_TRIED="$1" bash $T/vf/vision.sh $T/vf/s.png $T/vf/o.json > /dev/null 2>&1; echo "$? $(cat $T/vf/o.json 2> /dev/null | python3 -c 'import json,sys; d = json.load(sys.stdin); print("+".join(d["keys"]) or d.get("empty", ""))' 2> /dev/null)"; rm -f $T/vf/o.json*; }
r1=$(vf "DOWN,A" '{"keys":["DOWN","A"],"playable":false,"why":"x"}'); r2=$(vf "A" '{"keys":["A:2"],"playable":false,"why":"x"}')
r3=$(vf "LS_RIGHT" '{"keys":["LS_RIGHT"],"playable":true,"why":"x"}'); r4=$(vf "DOWN+A" '{"keys":["DOWN","A"],"playable":false,"why":"x"}')
ck "㉒ 试过没用按完整动作比：DOWN、A 各自试过答 DOWN+A 照用（实为 ${r1}）、A 试过答长按 A:2 照用（${r2}）、说可操控不滤（${r3}）、整组 DOWN+A 试过才滤空（${r4}，11-03 起滤空不算失败：退出 0、keys 空、带 "empty": "tried" 交自动玩家兜底）" '[ "$r1" = "0 DOWN+A" ] && [ "$r2" = "0 A:2" ] && [ "$r3" = "0 LS_RIGHT" ] && [ "$r4" = "0 tried" ]'
# ㉒b 点触换算画布：78×36 截图（比 16:9 宽）答 TOUCH:39,18（正中）——给 S2A_VISION_TOUCH_W=1280（游戏不知道宽屏）x 按 1280 宽缩成 640；不给（游戏自己出宽图）宽随比例 780
python3 -c 'import zlib,struct,sys; r=b"".join(b"\0"+b"\0"*3*78 for _ in range(36)); c=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)); open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",78,36,8,2,0,0,0))+c(b"IDAT",zlib.compress(r))+c(b"IEND",b""))' $T/vf/w.png
vw() { printf 'import sys; print(%s)\n' "'{\"keys\":[\"TOUCH:39,18\"],\"playable\":false,\"why\":\"x\"}'" > $T/vf/vision_or.py; env S2A_VISION_BACKEND=or S2A_VISION_ESCALATE=1 "$@" bash $T/vf/vision.sh $T/vf/w.png $T/vf/o.json > /dev/null 2>&1; python3 -c 'import json,sys; print("+".join(json.load(sys.stdin)["keys"]))' < $T/vf/o.json 2> /dev/null; rm -f $T/vf/o.json*; }
t1=$(vw S2A_VISION_TOUCH_W=1280); t2=$(vw S2A_VISION_TOUCH_W=0)
ck "㉒b 点触画布：给 1280 换成 TOUCH:640,360（实为 ${t1}）、给 0 宽随画面比例 TOUCH:780,360（${t2}）" '[ "$t1" = "TOUCH:640,360" ] && [ "$t2" = "TOUCH:780,360" ]'
ck "㉓ 答 LEFT+A、LEFT 没动：A 不按（不选中指针下的空档），记 LEFT+A 试过没用、改答点触进菜单打 MARK" 'L navfail | grep -q "LEFT 按了没动，这组后面的键不按" && ! L navfail | grep -q "\[游戏\] 进 PAUSE" && L navfail | grep -q "S2A 标记 MARK"'
# ㉔ vision_or.py（S2A_VISION_BACKEND=or，11-12 起只剩 OpenRouter）顺序与 403 跳过（不联网）：临时家目录放假钥匙，拦 urllib 的请求按主机回假结果——
#   OpenRouter sonnet 403、kimi 答 A。期望：第一问 sonnet 403（记下）→ kimi 答出；再一问跳过 sonnet 直接 kimi；没钥匙 → 「不可用」退出 3
mkdir -p $T/vo/home/.s2arm/.secrets $T/vo/site $T/vo/nokey; echo k > $T/vo/home/.s2arm/.secrets/openrouter.key
cat > $T/vo/site/vo_fakenet.py << 'PYEOF2'
import io, json, os, urllib.error, urllib.request
def fake_open(self, req, data=None, timeout=None):
    url = req.full_url if hasattr(req, "full_url") else req; body = json.loads(req.data) if getattr(req, "data", None) else {}
    open(os.environ["VO_LOG"], "a").write(f"{url.split('/')[2]} {body.get('model')}\n")
    if "openrouter" in url and body.get("model", "").startswith("anthropic/"): raise urllib.error.HTTPError(url, 403, "forbidden", {}, io.BytesIO(b""))
    auth = (req.headers.get("Authorization") or "") if hasattr(req, "headers") else ""
    if "relay.test" in url: open(os.environ["VO_LOG"], "a").write(f"钥匙对 {auth == 'Bearer rk'}\n")
    u = {"prompt_tokens": int(os.environ.get("VO_PT", "5000"))} if "relay.test" in url else {}   # 中转站：输入 token 少于带图估计 = 丢图
    return io.BytesIO(json.dumps({"choices": [{"message": {"content": '{"keys":["A"],"playable":false,"why":"x"}'}}], "usage": u}).encode())
urllib.request.OpenerDirector.open = fake_open
_eu = os.path.expanduser   # 钥匙 / 缓存路径的「~」映射到临时家目录（不改 HOME：PIL 等装在用户 site-packages 里，换 HOME 就找不到）
os.path.expanduser = lambda p: os.environ["VO_HOME"] + p[1:] if p.startswith("~/") else _eu(p)
PYEOF2
# 拦截写成普通模块、包装命令先导入再 runpy 跑 vision_or.py（不用 sitecustomize：本机 Python 靠自己的 sitecustomize 挂 PIL 等目录，同名会顶掉它）
vo() { S2A_VISION_BACKEND=${VOB:-or} VO_HOME=$2 VO_LOG=$T/vo/$1.log python3 -c 'import sys, runpy; sys.path.insert(0, sys.argv[1]); import vo_fakenet; sys.argv = sys.argv[2:]; runpy.run_path(sys.argv[0], run_name="__main__")' $T/vo/site $H/autoplay/vision_or.py $T/vf/s.png 题 > $T/vo/$1.out 2> $T/vo/$1.err; echo $?; }
r1=$(vo r1 $T/vo/home); r2=$(vo r2 $T/vo/home); rn=$(vo rn $T/vo/nokey)
ck "㉔ OpenRouter 后端：sonnet 403 记下 → kimi 答出（$(tr '\n' ' ' < $T/vo/r1.log)）；再一问跳过 sonnet（$(tr '\n' ' ' < $T/vo/r2.log)）；没钥匙 → 不可用、退出 3（${rn}）、不发请求" \
  '[ "$r1" = 0 ] && grep -q "\"A\"" $T/vo/r1.out && [ "$(tr "\n" " " < $T/vo/r1.log)" = "openrouter.ai anthropic/claude-sonnet-5.5 openrouter.ai moonshotai/kimi-k3 " ] && [ "$r2" = 0 ] && [ "$(tr "\n" " " < $T/vo/r2.log)" = "openrouter.ai moonshotai/kimi-k3 " ] && [ "$rn" = 3 ] && grep -q "不可用" $T/vo/rn.err && [ ! -s $T/vo/rn.log ]'
# ㉔r 中转站（S2A_VISION_BACKEND=relay，11-13 起缺省）：钥匙 relay.key + 地址 relay.url 在临时家目录 → 只发中转站一次（模型 claude-sonnet-5、请求头带钥匙）答出 A，不碰 OpenRouter；
#   回的输入 token 少于带图估计（丢图）→ 加请求号再问，2 次都丢图 → 这一问没答出、退出 1；没钥匙 / 没地址 → 「不可用」退出 3、不发请求
mkdir -p $T/vr/home/.s2arm/.secrets $T/vr/nourl/.s2arm/.secrets $T/vr/nokey; echo rk > $T/vr/home/.s2arm/.secrets/relay.key; echo https://relay.test/v1/chat/completions > $T/vr/home/.s2arm/.secrets/relay.url; echo rk > $T/vr/nourl/.s2arm/.secrets/relay.key
q1=$(VOB=relay vo q1 $T/vr/home); q2=$(VOB=relay VO_PT=10 vo q2 $T/vr/home); q3=$(VOB=relay vo q3 $T/vr/nokey); q4=$(VOB=relay vo q4 $T/vr/nourl)
ck "㉔r 中转站后端：答出（$(tr '\n' ' ' < $T/vo/q1.log)）、退出 0（${q1}）；丢图 2 次 → 退出 1（${q2}；请求 $(grep -c relay.test $T/vo/q2.log) 次）；没钥匙 → 退出 3（${q3}）；没地址 → 退出 3（${q4}）、都不发请求" \
  '[ "$q1" = 0 ] && grep -q "\"A\"" $T/vo/q1.out && [ "$(tr "\n" " " < $T/vo/q1.log)" = "relay.test claude-sonnet-5 钥匙对 True " ] && grep -q "模型 中转站/claude-sonnet-5" $T/vo/q1.err && [ "$q2" = 1 ] && [ "$(grep -c relay.test $T/vo/q2.log)" = 2 ] && grep -q "判丢图" $T/vo/q2.err && [ "$q3" = 3 ] && grep -q "中转站后端不可用：没有钥匙" $T/vo/q3.err && [ ! -s $T/vo/q3.log ] && [ "$q4" = 3 ] && grep -q "中转站后端不可用：没有地址" $T/vo/q4.err && [ ! -s $T/vo/q4.log ]'
# ㉔c vision.sh：402 标记在 → 显式 Jev 后端也跳过 Jev；问 CLI，假 CLI 超时退出 124 → 日志记「超时」与 rc=124（修前管道末段 python 吞成 rc=0）、退出 1（偶发失败，不是不可用）
mkdir -p $T/vc/bin; cp $H/autoplay/vision.sh $H/autoplay/nav_rules.txt $T/vc/; printf 'import sys; open(sys.argv[0] + ".called", "w").close(); sys.exit(1)\n' > $T/vc/vision_or.py; printf 'import sys; open(sys.argv[2] + ".jev", "w").close(); sys.exit(1)\n' > $T/vc/vision_jev.py
printf '#!/bin/sh\ncat > /dev/null; exit 124\n' > $T/vc/bin/claude; chmod +x $T/vc/bin/claude; cp $H/autoplay/or402.py $T/vc/
#   402 标记 11-04 起是永久的、内容 = OpenRouter 钥匙指纹（or402.py；空标记算旧格式不生效）
printf 'fake-or-key\n' > $T/vc/ork; python3 -c 'import hashlib,sys; print(hashlib.sha256(b"fake-or-key").hexdigest()[:16])' > $T/vc/m402
PATH=$T/vc/bin:$PATH S2A_VISION_BACKEND=jev S2A_VISION_OR_KEY=$T/vc/ork S2A_OR_402_MARK=$T/vc/m402 bash $T/vc/vision.sh $T/vf/s.png $T/vc/o.json > /dev/null 2>&1; vcrc=$?
ck "㉔c 402 标记新 → 跳过 Jev（Jev 调了：$([ -f $T/vc/o.json.jev ] && echo 是 || echo 否)）；CLI 超时 → 记超时、rc=124、退出 1（${vcrc}；日志：$(tr '\n' ' ' < $T/vc/o.json.log | cut -c1-160)）" \
  '[ ! -f $T/vc/o.json.jev ] && grep -q "跳过 Jev" $T/vc/o.json.log && grep -q "claude CLI 超时" $T/vc/o.json.log && grep -q "升级后端失败 rc=124" $T/vc/o.json.log && [ "$vcrc" = 1 ]'
# ㉔d 显式 cli 后端 = 本机 claude CLI 直连（#788）：
#   假 CLI 按 stream-json 回结果行 → 用它的答案 A、退出 0、没碰 OpenRouter 脚本；
#   PATH 上没有 claude / CLI 报没登录 → 【红】「看屏驾驶员不可用」、答案 JSON 带 unavailable、退出 3
mkdir -p $T/vd/bin $T/vd/nocli; cp $H/autoplay/vision.sh $H/autoplay/nav_rules.txt $H/autoplay/or402.py $T/vd/; printf 'import sys; open(sys.argv[0] + ".called", "w").close(); sys.exit(1)\n' > $T/vd/vision_or.py
cat > $T/vd/bin/claude << 'SHEOF'
#!/bin/sh
cat > /dev/null
echo '{"type":"result","result":"{\"keys\":[\"A\"],\"playable\":false,\"why\":\"t\"}"}'
SHEOF
chmod +x $T/vd/bin/claude; ln -sf "$(command -v timeout)" $T/vd/nocli/timeout; PY3=$(command -v python3)
S2A_VISION_BACKEND=cli PATH=$T/vd/bin:$PATH bash $T/vd/vision.sh $T/vf/s.png $T/vd/a.json > /dev/null 2>&1; vda=$?
S2A_VISION_BACKEND=cli S2A_PY=$PY3 PATH=$T/vd/nocli:/usr/bin:/bin bash $T/vd/vision.sh $T/vf/s.png $T/vd/b.json > /dev/null 2> $T/vd/b.stderr; vdb=$?
printf '#!/bin/sh\ncat > /dev/null; echo "Not logged in · Please run /login" >&2; exit 1\n' > $T/vd/bin/claude
S2A_VISION_BACKEND=cli PATH=$T/vd/bin:$PATH bash $T/vd/vision.sh $T/vf/s.png $T/vd/c.json > /dev/null 2>&1; vdc=$?
ck "㉔d 显式 cli 后端本机 CLI：答出 A、退出 0（${vda}；$(tr -d '\n' < $T/vd/a.json 2> /dev/null | cut -c1-50)）、没碰 OpenRouter（$([ -f $T/vd/vision_or.py.called ] && echo 碰了 || echo 没碰)）；没有 CLI → 退出 3（${vdb}）带 unavailable；没登录 → 退出 3（${vdc}）" \
  '[ "$vda" = 0 ] && grep -q "\"A\"" $T/vd/a.json && [ ! -f $T/vd/vision_or.py.called ] && grep -q "升级后端 claude CLI" $T/vd/a.json.log && [ "$vdb" = 3 ] && grep -q "\"unavailable\": true" $T/vd/b.json && grep -q "【红】看屏驾驶员不可用：本机没有 claude CLI" $T/vd/b.json.log && grep -q "【红】看屏驾驶员不可用" $T/vd/b.stderr && [ "$vdc" = 3 ] && grep -q "\"unavailable\": true" $T/vd/c.json && grep -q "没登录" $T/vd/c.json.log'
# ㉔e 不设后端 = 自动选（11-13：外部贡献者没有中转站钥匙，缺省不该一上来就红停）：
#   有中转站钥匙和地址 → 走中转站（问 vision_or.py 且带 S2A_VISION_BACKEND=relay、不碰 CLI），日志写「后端自动选：relay」；
#   没有中转站钥匙 → 走本机 CLI（不碰 vision_or.py），日志写「后端自动选：cli」；选上中转站但 vision_or.py 报不可用（退出 3）→ 【红】不可用、退出 3，不静默落到 CLI
mkdir -p $T/ve/bin; cp $H/autoplay/vision.sh $H/autoplay/nav_rules.txt $H/autoplay/or402.py $T/ve/; echo rk > $T/ve/rk
cat > $T/ve/vision_or.py << 'PYEOF3'
import os, sys
open(sys.argv[0] + ".env", "w").write(os.environ.get("S2A_VISION_BACKEND", ""))
print('{"keys":["B"],"playable":false,"why":"r"}'); print("模型 中转站/claude-sonnet-5", file=sys.stderr)
PYEOF3
cat > $T/ve/bin/claude << 'SHEOF'
#!/bin/sh
cat > /dev/null; touch "$0.called"
echo '{"type":"result","result":"{\"keys\":[\"X\"],\"playable\":false,\"why\":\"c\"}"}'
SHEOF
chmod +x $T/ve/bin/claude
env -u S2A_VISION_BACKEND S2A_VISION_RELAY_KEY=$T/ve/rk S2A_VISION_RELAY_URL=https://relay.test/x PATH=$T/ve/bin:$PATH bash $T/ve/vision.sh $T/vf/s.png $T/ve/a.json > /dev/null 2>&1; vea=$?
vea_cli=$([ -f $T/ve/bin/claude.called ] && echo 碰了 || echo 没碰); vea_env=$(cat $T/ve/vision_or.py.env 2> /dev/null); rm -f $T/ve/vision_or.py.env
env -u S2A_VISION_BACKEND S2A_VISION_RELAY_KEY=$T/ve/none S2A_VISION_RELAY_URL=https://relay.test/x PATH=$T/ve/bin:$PATH bash $T/ve/vision.sh $T/vf/s.png $T/ve/c.json > /dev/null 2>&1; vec=$?
printf 'import sys; print("中转站后端不可用：没有钥匙（x）", file=sys.stderr); sys.exit(3)\n' > $T/ve/vision_or.py
env -u S2A_VISION_BACKEND S2A_VISION_RELAY_KEY=$T/ve/rk S2A_VISION_RELAY_URL=https://relay.test/x PATH=$T/ve/bin:$PATH bash $T/ve/vision.sh $T/vf/s.png $T/ve/b.json > /dev/null 2>&1; veb=$?
ck "㉔e 不设后端自动选：有中转站 → relay（后端变量 ${vea_env}）答出 B、退出 0（${vea}）、没碰 CLI（${vea_cli}）；没中转站钥匙 → cli 答出 X、退出 0（${vec}）、没碰 vision_or.py；中转站不可用 → 退出 3（${veb}）" \
  '[ "$vea" = 0 ] && grep -q "\"B\"" $T/ve/a.json && [ "$vea_env" = relay ] && [ "$vea_cli" = 没碰 ] && grep -q "后端自动选：relay" $T/ve/a.json.log && grep -q "升级后端 中转站" $T/ve/a.json.log && [ "$vec" = 0 ] && grep -q "\"X\"" $T/ve/c.json && grep -q "后端自动选：cli" $T/ve/c.json.log && [ ! -f $T/ve/vision_or.py.env ] && [ "$veb" = 3 ] && grep -q "\"unavailable\": true" $T/ve/b.json && grep -q "【红】看屏驾驶员不可用：中转站后端不可用" $T/ve/b.json.log'
# ㉔g 402 标记永久有效（11-04）：指纹对得上的标记过了 2 小时仍跳过 Jev；指纹对不上（换了钥匙）→ 不算，照问 Jev
mkdir -p $T/vg; cp $H/autoplay/vision.sh $H/autoplay/nav_rules.txt $H/autoplay/or402.py $T/vg/; printf 'import sys; sys.exit(1)\n' > $T/vg/vision_or.py
printf 'import sys; open(sys.argv[2] + ".jev", "w").close(); sys.exit(1)\n' > $T/vg/vision_jev.py; mkdir -p $T/vg/bin; printf '#!/bin/sh\ncat > /dev/null; exit 1\n' > $T/vg/bin/claude; chmod +x $T/vg/bin/claude
printf 'k1\n' > $T/vg/ork; python3 -c 'import hashlib; print(hashlib.sha256(b"k1").hexdigest()[:16])' > $T/vg/m402; touch -t "$(date -v-2H +%Y%m%d%H%M)" $T/vg/m402
PATH=$T/vg/bin:$PATH S2A_VISION_BACKEND=jev S2A_VISION_OR_KEY=$T/vg/ork S2A_OR_402_MARK=$T/vg/m402 bash $T/vg/vision.sh $T/vf/s.png $T/vg/a.json > /dev/null 2>&1
printf 'k2\n' > $T/vg/ork
PATH=$T/vg/bin:$PATH S2A_VISION_BACKEND=jev S2A_VISION_OR_KEY=$T/vg/ork S2A_OR_402_MARK=$T/vg/m402 bash $T/vg/vision.sh $T/vf/s.png $T/vg/b.json > /dev/null 2>&1
ck "㉔g 402 标记永久：2 小时前的标记仍跳过 Jev（Jev 调了：$([ -f $T/vg/a.json.jev ] && echo 是 || echo 否)）；换钥匙后标记不算、照问 Jev（$([ -f $T/vg/b.json.jev ] && echo 问了 || echo 没问)）" \
  '[ ! -f $T/vg/a.json.jev ] && grep -q "跳过 Jev" $T/vg/a.json.log && [ -f $T/vg/b.json.jev ]'
ck "㉕ 低绘制游戏（局内绘制 30 < 3×20）：Jev 低把握、升级后端连续 2 问确认可操控 + 绘制不低于基线 → 打 MARK；升级后端说不是 → 不打" 'L lowesc | grep -q "升级后端连续 2 问确认可操控" && L lowesc | grep -q "S2A 标记 MARK" && ! L lowno | grep -q "S2A 标记 MARK"'
ck "㉖ 怪猎语言页（11-01 Spare-host 现场）：改选里 A 来回被拉黑、DOWN 在改选里没反应；回到普通状态后 DOWN 不该还算试过没用 → 挪到确定、A 进菜单、打 MARK" 'L lang | grep -q "S2A 标记 MARK" && L lang | grep -q "语言页 → OK"'
ck "㉗ 远程信箱（本机无脚本无密钥、假桥答）：清掉上局残留、走信箱问 3 次、按 2 下、打 MARK（实为 asks $(J remote vision_asks) presses $(J remote presses) marked $(J remote marked)）" \
  'L remote | grep -q "驾驶员走远程信箱" && L remote | grep -q "远程信箱，截图 vision/v01.png" && [ "$(J remote marked)" = True ] && [ "$(J remote vision_asks)" = 3 ] && [ "$(J remote presses)" = 2 ] && ! L remote | grep -q "按 B"' 
ha=$(L hold | sed -n 's/^\[游戏\] 局内 \([0-9]*\) 帧，A 最长连按 \([0-9]*\) 帧$/\1 \2/p'); oa=$(L ok | sed -n 's/^\[游戏\] 局内 \([0-9]*\) 帧，A 最长连按 \([0-9]*\) 帧$/\1 \2/p')
# ㉘ 按键事件判（11-03 gate-host 无缓存全套负载高：不设时点按 0.15 秒标称 4.5 帧，自动玩家线程醒晚、假宿主按绝对时刻补帧，按出 8 帧 > 5 假红）：
#   设了 → MARK 后局内随机动作（首个是 B、再推摇杆）都叠着 A，「别的键按着而 A 松开」= 0 帧且 A 按着 > 0 帧；不设 → 首个动作 B 单按，该数 > 0（种子固定，手推序列 B LR LR A Y …）
hp=$(L hold | sed -n 's/^\[游戏\] MARK 后局内 A 按着 \([0-9]*\) 帧，别的键按着而 A 松开 \([0-9]*\) 帧$/\1 \2/p'); op=$(L ok | sed -n 's/^\[游戏\] MARK 后局内 A 按着 \([0-9]*\) 帧，别的键按着而 A 松开 \([0-9]*\) 帧$/\1 \2/p')
ck "㉘ S2A_AP_HOLD=A：局内段全程按住 A（MARK 后 A 按着 / 别的键按着而 A 松开 = ${hp:-无} 帧；不设时 ${op:-无}；局内帧 / A 最长连按 = ${ha:-无}，不设时 ${oa:-无}）" \
  'L hold | grep -q "局内段全程按住 A" && [ -n "$hp" ] && [ "${hp% *}" -gt 0 ] && [ "${hp#* }" = 0 ] && [ -n "$op" ] && [ "${op#* }" -gt 0 ]'
ck "㉙ 动画背景页（下半屏每帧自己在动）：采到动画格、A 判没变记试过没用，改答 X 进菜单、打 MARK（标题问答 实为 $(grep '^TITLE' $T/waves/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  'L waves | grep -q "格自己在动（动画背景）" && grep -q "^TITLE X A" $T/waves/vision_calls.log && [ "$(J waves marked)" = True ]'
ck "㉚ 往前回到已到过的页不算回头：菜单答 B / Y 退回标题后，标题的 A 不被拉黑、菜单改答 X 进局打 MARK（标题问答 实为 $(grep '^TITLE' $T/fwd/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')；菜单 $(grep '^MENU' $T/fwd/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  '! grep -q "^TITLE 无" $T/fwd/vision_calls.log && grep -q "^MENU X" $T/fwd/vision_calls.log && [ "$(J fwd marked)" = True ]'
ck "㉚b 标题页背景换了昼夜（亮度相关低、字和框不变）仍认成同一页：菜单 B / Y 退回后标题的 A 不被当回头路拉黑、菜单改答 X 进局打 MARK（标题问答 实为 $(grep '^TITLE' $T/daynight/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  '! grep -q "^TITLE 无" $T/daynight/vision_calls.log && grep -q "^MENU X" $T/daynight/vision_calls.log && [ "$(J daynight marked)" = True ]'
# ㉛ 逻辑速度探测 + 判据（期望手算：假宿主画面 64 宽，探测缩略图 128 宽 = 2 倍；B 类每帧 1 像素 → 30 帧 60、60 帧 120 像素/秒，ρ≈2 = q 判红；
#    A 类每秒 30 像素 → 两局都 60 像素/秒，ρ≈1 判绿）。假宿主帧间隔与自动玩家时钟同按 4 倍速，判据只看比值
jb=$(python3 $H/../tools/fps_speed_judge.py $T/sp_b30 $T/sp_b60 2>&1); jbr=$?
ja=$(python3 $H/../tools/fps_speed_judge.py $T/sp_a30 $T/sp_a60 2>&1); jar=$?
ck "㊶ 驾驶员答的全是试过的键（11-03 归族 A：原先算驾驶员失败、连 3 次收局）：代码按固定顺序兜底挑没试过的动作，标题只认 X 也走到 X、打 MARK" \
  'L fbtried | grep -q "代码兜底按这页没试过的 X" && ! L fbtried | grep -q "驾驶员连续 3 次没给出" && [ "$(J fbtried marked)" = True ]'
ck "㊷ 驾驶员一直说等（答空）：等满 10 次不算失败，之后代码兜底（A:1.5）进菜单、打 MARK" \
  'L fbwait | grep -q "驾驶员说等（第 10 次）" && L fbwait | grep -q "一直说等，代码兜底" && ! L fbwait | grep -q "驾驶员连续 3 次没给出" && [ "$(J fbwait marked)" = True ]'
ck "㊸ 弹窗唯一出口第一次回到更早的页不拉黑（11-03 归族 C：路易吉洋馆 DLC 弹窗）：菜单 A 回标题只记一条边，同版式第二个弹窗按 A 进局、打 MARK（菜单问答 $(grep '^MENU' $T/popback/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  'L popback | grep -q "第 1 次，先不拉黑" && ! L popback | grep -q "走回头路），记为" && [ "$(J popback marked)" = True ]'
ck "㊹ 单只 Joy-Con 横握页要 SL+SR 同按（11-03 归族 E：Super Mario Party）：驾驶员答 SL|SR 认得、同按进菜单、打 MARK" \
  'L sideways | grep -q "按键 \[SL|SR\]" && [ "$(J sideways marked)" = True ]'
px=$($T/t_autoplay $T pixmove 2> /dev/null | tr '\n' ' ')
ck "㊺ 浅色细焦点框挪动（11-03 归族 F：泡姆泡姆条款页 DOWN 实际挪了焦点、细节摘要最大 4.3 < 6 判没变）：逐像素判据认得出、细节摘要认不出；同帧、只闪一个小点都不算变（实为 ${px}）" \
  '[ "$px" = "挪框 逐像素 1 细节摘要 0 同帧 逐像素 0 细节摘要 0 小点 逐像素 0 细节摘要 0 " ]'
st=$($T/t_autoplay $T stseen 2>/dev/null | tr '\n' ' ')
ck "㊼ 同版式弹窗连弹只换标题字（11-04 归族 B：真女神转生V / 数码宝贝）：页内状态逐像素第三道认得出换字、同帧仍判见过；旧两道摘要判同（实为 ${st}）" \
  '[ "$st" = "首帧 见过 0 同帧 见过 1 换字 见过 0 旧两道判同 1 " ]'
ck "㊽ 弹窗页出口只回到进它的那一页（环，11-04 归族 A：Snipperclips 选人数页 A → 准备手柄弹窗 → A 回选人数页）：第 2 次回头路拉黑弹窗 A 时，进弹窗的标题 A 也记为标题试过没用，驾驶员改答 X 进局、打 MARK" 'L ring | grep -q "第 2 页的出口只回到第 1 页（环；" && grep -q "^TITLE X A" $T/ring/vision_calls.log && [ "$(J ring marked)" = True ]'
# ㊾ 期望手算：标题第 1 问是新页、第 2 / 3 / 4 问是回到问过 1 / 2 / 3 次的页；前 3 问快档都答 A、每次只到了页内新状态（没离开这页）= 快档连续 3 问在页内打转，
#   第 4 问升级（升级标记 0 0 0 1），升级后端答 X 进菜单，菜单 A 进局、打 MARK。修前：A 每次算「页内有进展」、上一问没推进的标记一直是 0，从不升级，12 步用完
ck "㊾ 快档在页内打转不离开这页（11-04 c1104_r2 泰拉瑞亚角色创建页：haiku 连答 25 次 A、从没升级）：连续 3 问后升级，升级后端答 X 进菜单、打 MARK（标题升级标记 实为 $(grep '^TITLE' $T/cstay/vision_env.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')，要 0 0 0 1）" \
  '[ "$(grep "^TITLE" $T/cstay/vision_env.log | cut -d" " -f2 | tr "\n" " ")" = "0 0 0 1 " ] && [ "$(J cstay marked)" = True ]'
ck "㊻ 协议末页图例「+ 同意 / B 返回」、驾驶员只答 A（11-03 火影 16/16 页）：代码兜底先按 +、不先按 B 退回，进菜单打 MARK" \
  'L agree | grep -q "代码兜底按这页没试过的 PLUS" && ! L agree | grep -q "\[游戏\] 进 PAUSE" && [ "$(J agree marked)" = True ]'
ck "㊵ 读档确认「是 / 否」两项循环、高亮看不出（11-02 塞尔达智慧的再现真机：UP 判没变又重按一次挪回「否」、A 不按，自动玩家永远过不了）：方向键判没变不重按，下一问光标已在「是」、A 进菜单、打 MARK（标题问答 $(grep '^YES' $T/yesno/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  '! L yesno | grep -q "UP 第一次没反应" && grep -q "^YES1 A" $T/yesno/vision_calls.log && [ "$(J yesno marked)" = True ]'
ck "㉝ 焦点框是 1 像素细线（11-02 Minecraft 准备游玩页）：DOWN 只挪了焦点也要判「变了」、清掉这页试过没用的 A，焦点到「游玩」后 A 进菜单、打 MARK（标题问答 $(grep '^FOCUS' $T/focus/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  'L focus | grep -q "只有细节：焦点" && grep -q "^FOCUS1 A" $T/focus/vision_calls.log && [ "$(J focus marked)" = True ]'
ck "㉞ 长文本带滚动条（11-02 怪猎统计同意页）：A 没反应、模型答 RIGHT_STICK_DOWN（全称）要认成右摇杆下推，滚到底后 A 进菜单、打 MARK（问答 $(grep '^SCROLL' $T/scroll/vision_calls.log 2> /dev/null | cut -d' ' -f2 | tr '\n' ' ')）" \
  'grep -q "^SCROLL1 A" $T/scroll/vision_calls.log && [ "$(J scroll marked)" = True ]'
pa=$(L padrec | sed -n 's/^\[游戏\] 局内 \([0-9]*\) 帧，A 最长连按 \([0-9]*\) 帧$/\1 \2/p')
ck "㉟ 局内段回放 padrec：自第 100 帧起 5 行（录像 52 帧长）、放完，A 连按 ≥ 35 帧（局内帧 / A 最长连按 = ${pa:-无}；不回放时 ${oa:-无}）" \
  'L padrec | grep -q "回放手柄 .*自第 100 帧起 5 行（录像 52 帧长）" && L padrec | grep -q "手柄回放放完" && [ "${pa#* }" -ge 35 ] && [ "$(J padrec marked)" = True ]'
pr=$(L padrel | sed -n 's/^\[游戏\] 局内 \([0-9]*\) 帧，A 最长连按 \([0-9]*\) 帧$/\1 \2/p'); pb=$(L padbad | sed -n 's/^\[游戏\] 局内 \([0-9]*\) 帧，A 最长连按 \([0-9]*\) 帧$/\1 \2/p')
ck "㊱ 相对路径 padrec/pad.tsv 按输出目录解析：放完、A 连按 ≥ 35 帧（实为 ${pr:-无}）" \
  'L padrel | grep -q "回放手柄 $T/padrel/padrec/pad.tsv 自第 100 帧起 5 行" && L padrel | grep -q "手柄回放放完" && [ "${pr#* }" -ge 35 ]'
# ㊲ 局内有键帧数判 ≤ 5：菜单里进局那一下 A 的尾巴会落进局内头几帧；随机动作局几乎每帧都按着键（几十到上百帧）
kb=$(L padbad | sed -n 's/^\[游戏\] 局内有键 \([0-9]*\) 帧$/\1/p'); ko=$(L ok | sed -n 's/^\[游戏\] 局内有键 \([0-9]*\) 帧$/\1/p')
ck "㊲ 回放打不开：红行「没放成」、局内段原地不动（局内有键 ≤ 5 帧，实为 ${kb:-无}；随机动作局 ${ko:-无}）" \
  'L padbad | grep -q "S2A_AP_PADREC 打不开" && L padbad | grep -q "没放成，局内段原地不动" && [ "${kb:-99}" -le 5 ] && [ "${ko:-0}" -ge 30 ] && [ "$(J padbad marked)" = True ]'
ck "㉛ 逻辑速度：按帧推进 30 / 60 帧判红（rc ${jbr}：${jb}）、按真实时间判绿（rc ${jar}：${ja}）" '[ "$jbr" = 1 ] && [ "$jar" = 0 ]'
# ㉜ ㊴ 及 ㉛㉞㉟ 的时间都按假宿主游戏时钟（每出一帧加标称间隔）量：机器忙时出帧慢、拍图醒得晚，结论也不变（11-02 gate-host 负载 200+ 按墙钟量 ㉜ 一推只拍到 4 张、㊴ q 塌到 1 假红）
ck "㉜ 逻辑速度探测进局停在菜单：两根摇杆都推不动 → 按一下 B 退出再探一轮，第二轮右摇杆 6 / 6 有响应（时间按宿主游戏时钟）" 'L sp_menu | grep -q "时间按宿主游戏时钟" && L sp_menu | grep -q "按一下 B 退出菜单再探一轮" && L sp_menu | grep -q "右摇杆 6 / 6 推画面跟着横移"'
# ㉞ 同局 A/B 不按键量画面运动（期望手算：开段 60 帧、关段 30 帧，q≈2；按帧推进每 2 帧 1 像素 → 开 30 / 关 15 假宿主像素/秒，ρ≈2≈q 判红；
#    按真实时间每秒 15 像素 → 两段一样，ρ≈1 判绿；缩略图 128 宽是假宿主 64 宽的 2 倍，判据只看比值）
ck "㉞ 逻辑速度同局 A/B：按帧推进判红（$(L ab_b | grep -o '逻辑速度同局 A/B：[^（]*' | tail -1)）、按真实时间判绿（$(L ab_a | grep -o '逻辑速度同局 A/B：[^（]*' | tail -1)）" \
  'L ab_b | grep -q "逻辑速度同局 A/B：红：" && L ab_a | grep -q "逻辑速度同局 A/B：绿：" && L ab_b | grep -q "同局 A/B：回原帧率" && L ab_b | grep -q "同局 A/B：放开 60 帧" && L ab_b | grep -q "同局 A/B：测完照常"'
# ㉟ 走路按时间、镜头按帧（abmix，仿异度3 帧率表补了时间步、镜头仍按帧）：分项走路绿、镜头红 → 合起来判红；只量走路会判成假绿
ck "㉟ 逻辑速度两根摇杆分开判：走路 $(L ab_m | grep -o '逻辑速度分项（推左摇杆走）：[^：]*' | tail -1 | sed 's/.*：//')、镜头 $(L ab_m | grep -o '逻辑速度分项（推右摇杆转）：[^：]*' | tail -1 | sed 's/.*：//')、合起来 $(L ab_m | grep -o '逻辑速度同局 A/B：[^：]*' | tail -1 | sed 's/.*：//')" \
  'L ab_m | grep -q "逻辑速度分项（推左摇杆走）：绿" && L ab_m | grep -q "逻辑速度分项（推右摇杆转）：红" && L ab_m | grep -q "逻辑速度同局 A/B：红：推右摇杆转"'
# ㊳ 判据纯函数 sp_verdict（11-02 收紧；期望按规则手算：关段 ≥ 55 帧原生 60、q < 1.15 帧率没涨、关段速度 < 2 量不出、ρ < 0.8 场景不一致 → 判不出；
#   ρ ≤ min(1.25, √q) 绿，更快红。q 2 时上限 1.25：ρ 1.2 绿、1.4 红（旧规则 1.25 < ρ < q/1.25 = 1.6 判不出）；q 1.5 时上限 √1.5 = 1.2247：ρ 1.2 绿、1.3 红）
$T/t_autoplay $T verdict > $T/verdict.txt 2>&1
vw='0 判不出 （原生 60：关段已 ≥ 55 帧，开关不改帧率）
1 判不出 （开 60 帧帧率没涨：q < 1.15，无倍速风险）
2 判不出 （画面几乎不动，量不出）
3 判不出 （开段反而变慢，两段场景不一致）
4 绿 （逻辑按真实时间推进）
5 红 （按帧推进，开 60 帧游戏变快）
6 绿 （逻辑按真实时间推进）
7 红 （按帧推进，开 60 帧游戏变快）
8 红 （按帧推进，开 60 帧游戏变快）'
ck "㊳ 判据纯函数：原生 60 / 帧率没涨 / 量不出 / 场景不一致判不出，帧率涨了按 min(1.25, √q) 分绿红（不符行：$(diff <(echo "$vw") $T/verdict.txt | grep '^>' | head -2 | tr '\n' ' ')）" '[ "$(cat $T/verdict.txt)" = "$vw" ]'
# ㊴ 第一轮量不出就重测（abkick：MARK 后局内完全静止直到第一轮 A/B 测完，之后每 2 帧移 1 像素按帧推进）。期望手算：第一轮开段 60 帧、关段 30 帧（q≈2 ≥ 1.15）、
#   画面 0 像素/秒 → 判不出「量不出」并要求重测；局内段 20 秒后重测：同 ㉞ abfix 每 2 帧 1 像素 → 开 30 / 关 15 假宿主像素/秒，ρ≈2 > min(1.25, √2) → 红；最后一行是红
ck "㊴ 第一轮量不出（$(L ab_k | grep -E -o '逻辑速度同局 A/B：(绿|红|判不出)：[^（]*' | head -1)）→ 局内跑 20 秒重测（$(L ab_k | grep -E -o '逻辑速度同局 A/B：(绿|红|判不出)：[^（]*' | tail -1)）" \
  'L ab_k | grep -q "时间按宿主游戏时钟" && L ab_k | grep -E "逻辑速度同局 A/B：(绿|红|判不出)：" | head -1 | grep -q "判不出：.*量不出" && L ab_k | grep -q "重测一轮" && L ab_k | grep -E "逻辑速度同局 A/B：(绿|红|判不出)：" | tail -1 | grep -q "逻辑速度同局 A/B：红："'
# ㊿ 期望手算（判据时钟秒）：ef_ab 照常窗口 20 秒从 A/B 测完那帧起算、60 帧 → 收局时帧号 − 测完那帧 ≥ 20 × 60 × 0.9 = 1080（留一成给负载下少出的帧），
#   MARK 后总长（小结 wall_s − start_to_mark_s）远小于局内段 600 秒（< 300）；ef_aud 没有 A/B，声音段 60 秒 > N 8 秒：峰值行在提前收局行之前、MARK 后总长 ≥ 60；
#   ef_kick（负对照：第一轮判不出、20 秒后才重测，N 5 秒短于重测间隔）：不等重测段就收会没有「重测一轮」、末行不是红；
#   ef_nm 没到 MARK：不打提前收局行，按局时用完收尾（离收局只剩）
efw() { python3 -c "import json,sys; j = json.load(open(sys.argv[1])); print(round(j['wall_s'] - j['start_to_mark_s']))" $T/$1/ap_summary.json 2> /dev/null || echo -1; }
eab=$(L ef_ab | sed -n 's/^\[游戏\] 同局 A\/B：测完照常（帧 \([0-9]*\)）$/\1/p' | tail -1); efr=$(J ef_ab frames)
ck "㊿ 提前收局：A/B 测完（帧 ${eab:-无}）后照常出帧 ≥ 1080 帧才收（收局帧 ${efr:-无}），MARK 后共 $(efw ef_ab) 秒 < 300、A/B 照判红" \
  'L ef_ab | grep -q "提前收局（S2A_AP_EARLY_S=20）" && [ -n "$eab" ] && [ $((efr - eab)) -ge 1080 ] && [ "$(efw ef_ab)" -lt 300 ] && [ "$(efw ef_ab)" -ge 20 ] && L ef_ab | grep -q "逻辑速度同局 A/B：红：" && [ "$(J ef_ab marked)" = True ]'
lnum() { L $1 | grep -n -e "$2" | head -1 | cut -d: -f1; }   # 第一处匹配的行号（没有 = 空）
la=$(lnum ef_aud "稳态窗口：输出峰值"); lb=$(lnum ef_aud "提前收局（S2A_AP_EARLY_S=8）")
ck "㊿ 提前收局等旁观段：声音稳态窗口 60 秒跑完（峰值行 ${la:-无} 在提前收局行 ${lb:-无} 之前）才收，MARK 后共 $(efw ef_aud) 秒（要 60–300）" \
  '[ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] && [ "$(efw ef_aud)" -ge 60 ] && [ "$(efw ef_aud)" -lt 300 ]'
ka=$(lnum ef_kick "重测一轮"); kb=$(lnum ef_kick "提前收局（S2A_AP_EARLY_S=5）")
# ㊿b 段行带帧号（满屏补丁线 11-04：判据按帧剔 A/B 段，tools/ab_span.py）：ef_ab 的 A/B 段开始行带「改出帧状态，帧 N」、结束行带「帧 M」，M > N
abn=$(L ef_ab | sed -n 's/.*MARK 后段开始「逻辑速度同局 A\/B」（#[0-9]*，改出帧状态，帧 \([0-9]*\)）.*/\1/p' | head -1); abm=$(L ef_ab | sed -n 's/.*MARK 后段结束「逻辑速度同局 A\/B」（#[0-9]*，帧 \([0-9]*\)）.*/\1/p' | head -1)
ck "㊿b A/B 段行带帧号：开始帧 ${abn:-无}、结束帧 ${abm:-无}（结束 > 开始）" '[ -n "$abn" ] && [ -n "$abm" ] && [ "$abm" -gt "$abn" ]'
ck "㊿ 负对照：A/B 重测段没跑完不许提前收（重测一轮行 ${ka:-无} 在提前收局行 ${kb:-无} 之前、末行 $(L ef_kick | grep -E -o '逻辑速度同局 A/B：(绿|红|判不出)：' | tail -1)）" \
  '[ -n "$ka" ] && [ -n "$kb" ] && [ "$ka" -lt "$kb" ] && L ef_kick | grep -E "逻辑速度同局 A/B：(绿|红|判不出)：" | tail -1 | grep -q "逻辑速度同局 A/B：红："'
ck "㊿ 没到 MARK 不提前收：照旧按局时用完收尾（$(J ef_nm why)）" '! L ef_nm | grep -q "提前收局（S2A_AP_EARLY_S" && [ "$(J ef_nm marked)" = False ] && J ef_nm why | grep -q "离收局只剩"'
[ $bad = 0 ] && echo "autoplay 单测全过（45 类 / 52 局）"
