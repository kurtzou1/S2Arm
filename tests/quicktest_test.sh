#!/bin/bash
# 快测单测（tools/quicktest/：one_game.sh 串流程、verdict.py 定性；解包 / 出包 / Mac 局换成桩，约 5 秒）：bash tests/quicktest_test.sh
# 期望（按规则手写）：
#   ① verdict.py --selftest 全绿（崩溃 / Break / 首帧 / 直连异常 / 稳定与偶发崩溃 / 红行去重）
#   ② 桩局出首帧、不崩 → 退出 0，结果.tsv 一行「通过」，工作目录删掉
#   ③ 第一局崩、补跑那局不崩 → 跑两局，记「偶发崩溃：客体代码（main+0x10）」，退出 1
#   ④ 解包报「32 位」→ 记「不支持：32位」，不出包、不起局
#   ④b 解包报原件探测出错（pack/srcs.sh「【红】机器原因：原件探测出错…」，11-05 没 .NET 运行时）→ 结论「未判」、第一个失败点就是那行去掉【红】、
#      不出包、不写 .留证（机器原因不留证）；不能记成游戏的「失败 解包」
#   ⑤ QT_KEEP=1 → 工作目录留下
#   ⑥ 不给源包 → 退出 2
#   ⑦ 自动玩家到 MARK（ap_summary.json marked）→ 末列「进局」= 是；给解包目录（exefs/main + unpack.tsv）→ 不调解包
#   ⑧ 只有直连（11-07）：entry_check 退出 5（根里没有本链直连库）→ 只起一局、不补跑，结论「失败」、第一失败点写明
#   ⑨ entry_check 退出 3、没有 host.log（局槽排队超时）→ 结论「未判」、第一失败点「局没起」，不记成首帧失败
#   ⑩ QT_PACK_ONLY=1：解包 + 出包后停，退出 0、结果.tsv 只有表头、工作目录留下且有 .qt_packed（款 tstub / 程序号 0100000000ABC000）、extract 删掉、不起局
#   ⑪ 源给 ⑩ 留下的工作目录 = 只跑局：不再解包 / 出包，起一局、记「通过」
#   ⑫ 留现场：进局的局日志目录里没有 run/；第一局崩（补跑一局）的失败局日志目录里有 run/ 与 run2/（局目录副本，含 host.log）
#   ⑬ 出包阶段失败（改写等把阶段日志写进 roots/.failed）→ 日志目录 pack_failed/ 里有那份阶段日志（工作目录删了也留得住）
#   ⑭ 点触卡页换主机档（10-30 S 级 ①）：掌机档通过、没进局、结论行「点触没反应 3 次」→ 再起一局主机档（docked）；主机档进局 → 末列「进局」= 是、
#      .进局档位 写 docked、host.log 换成主机档那局（掌机档那份改名 host_h.log）；只「点触没反应 1 次」→ 不复跑；主机档也没进局 → 照记掌机档、写 .主机档复跑；
#      docs/名单_进局档位.tsv 登记了这款（0100000000ABC000 docked）→ 只起一局、直接主机档
#   ⑰ 只有直连（11-07 拆精简档 / 通用局）：出包不带 --lite、不设 S2A_DUAL，起局不设 S2A_ENTRY_GFX
#   ⑱ keep_log.sh（11-02 维护者：MARK 行被截掉致满屏判不出局内）：3.6 MB 日志，MARK 行与原比例状态行在中段 → 留存后两行都在、仍按原顺序、总长 ≤ 1.5 + 1.2 + 0.5 MB 加两行说明；中段的长帧 / 慢帧分解行也留下（11-02 不卡定因）；
#      ≤ 2 MB 的日志逐字节原样
#   ⑲ 产物根里的 RomFS 共享存储整棵只读（pack/roots.sh _root_romfs_intern 的 chmod -R a-w）：收尾删工作目录要删干净、run.out 里 0 条「Permission denied」；
#      开工前工作目录里留着上一局的只读存储（QT_KEEP=1 看开工那次删）→ 删干净、旧文件不在；
#      删不掉（macOS chflags uchg 锁住一个文件，chmod 解不开）→ 恰好 1 行【红】带路径与原因、0 行 rm 原始报错、不静默
#   ⑮ verdict.py --touch-stuck：视觉答点触、理由引了屏上原文「请点触画面」→ 判点触卡页；理由没引原文（「按键无效改点触」）→ 不判
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"' EXIT; bad=0
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
python3 "$R/tools/quicktest/verdict.py" --selftest > "$T/st.out"; chk "① verdict 自测" 0 $?
F=$T/repo; mkdir -p "$F/tools/quicktest" "$F/pack/stages" "$F/pack/oneclick"
cp "$R"/tools/quicktest/*.sh "$R"/tools/quicktest/*.py "$F/tools/quicktest/"; cp "$R/pack/roots.sh" "$F/pack/"; mkdir -p "$F/pack/orch" && cp "$R/pack/orch/current.py" "$F/pack/orch/"
cat > "$F/pack/stages/unpack.sh" <<'EOF'
echo "unpack" >> "$FAKE/calls"; [ -f "$FAKE/bit32" ] && { echo "🔴 main.npdm 不是 64 位：32 位程序不支持"; exit 1; }
[ -f "$FAKE/probefail" ] && { echo "【红】机器原因：原件探测出错（nx_unpack --nacp-only 退出 131，不是游戏的问题）：You must install .NET to run this application. （/s/g.nsp）" >&2; echo "【红】列原始包失败（/s）" >&2; exit 1; }
while [ $# -gt 0 ]; do [ "$1" = --out ] && mkdir -p "$2"; shift; done; exit 0
EOF
cat > "$F/pack/oneclick/oneclick.sh" <<'EOF'
case " $* " in *" --lite "*) l=lite;; *) l=full;; esac; echo "$l ${S2A_DUAL:-unset}" >> "$FAKE/dual"
while [ $# -gt 0 ]; do [ "$1" = --out ] && O=$2; shift; done
echo "③ 款 tstub" ; echo "① 认出 本体（1.0，程序号 0100000000ABC000）"; mkdir -p "$O/roots/tstub@v1" "$O/logs"; echo tstub@v1 > "$O/roots/tstub@现行"; echo "pack" >> "$FAKE/calls"
if [ -f "$FAKE/rostore" ]; then s=$O/roots/.romfs_store/tstub/oc-1; mkdir -p "$s/a/b"; for i in 1 2 3; do echo x > "$s/a/b/f$i"; echo y > "$s/f$i"; done; chmod -R a-w "$s"; ln -s ../.romfs_store/tstub/oc-1 "$O/roots/tstub@v1/romfs"; fi
[ -f "$FAKE/locked" ] && chflags uchg "$O/roots/.romfs_store/tstub/oc-1/f1"
if [ -f "$FAKE/directgap" ]; then echo "🔴 刷新停在：【红】tstub 直连单轨停在 直连配置推导：直连缺口：配置推导不支持本款"; exit 1; fi
if [ -f "$FAKE/packfail" ]; then mkdir -p "$O/roots/.failed"; echo "PFRW gaps=1" > "$O/roots/.failed/tstub_main.log"; echo "【红】tstub 改写 main 失败"; exit 1; fi
EOF
mkdir -p "$F/priv"; export S2A_PRIVATE_TOOLS=$F/priv   # entry_check.sh 是维护方工具（同 tools/ab_pair.sh 的调法）
cat > "$F/priv/entry_check.sh" <<'EOF'
D=$3; echo "${S2A_ENTRY_GFX:-unset}" >> "$FAKE/gfx"; [ -f "$FAKE/nodirect" ] && { echo "🟡 待直连根"; exit 5; }
[ -f "$FAKE/noslot" ] && { echo "🟡 局没起 tstub handheld：局槽排队超时"; exit 3; }
rm -rf "$D"; mkdir -p "$D"; n=$(cat "$FAKE/runs" 2> /dev/null || echo 0); n=$((n + 1)); echo $n > "$FAKE/runs"
echo "$2" >> "$FAKE/modes"
for t in 1 3; do [ -f "$FAKE/touch$t" ] && { [ "$2" = handheld ] || [ -f "$FAKE/dockfail" ]; } && {
  printf '图形模式：通用\nnnMain → 首帧上屏 +900.0 ms\n[s2a] 自动玩家结论：没到 MARK；到放弃时限 90 秒没进可玩；按键 9 下（翻页 0）、探测 0 次；点触没反应 %s 次；小结 x（%s）\n' $t "$2" > "$D/host.log"
  printf 'h\n1\n2\n' > "$D/frames.tsv"; echo "收局 rc=0" > "$D/run.out"; echo 0 > "$D/run.rc"; echo '{"marked": false}' > "$D/ap_summary.json"; exit 1; }; done
if [ -f "$FAKE/crash1" ] && [ $n = 1 ]; then echo "CRASH 信号 11 地址 0x0 pc main+0x10" > "$D/host.log"; echo "收局 rc=139" > "$D/run.out"; echo 1 > "$D/run.rc"; exit 1; fi
printf '图形模式：通用\nnnMain → 首帧上屏 +900.0 ms\n' > "$D/host.log"; printf 'h\n1\n2\n' > "$D/frames.tsv"; echo "收局 rc=0" > "$D/run.out"; echo 0 > "$D/run.rc"
echo '{"marked": true}' > "$D/ap_summary.json"; echo "🟢 过"
EOF
run() { rm -rf "$T/fake" "$T/out"; mkdir -p "$T/fake" "$T/src"; for x in "$@"; do touch "$T/fake/$x"; done
  FAKE=$T/fake bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > "$T/run.out" 2>&1; echo $?; }
rc=$(run); chk "② 通过退出码" 0 "$rc"; chk "② 结论" "通过" "$(tail -1 "$T/out/结果.tsv" | cut -f4)"
chk "② 工作目录已删" no "$([ -d "$T/out/work/src" ] && echo yes || echo no)"
rc=$(run crash1); chk "③ 偶发崩溃退出码" 1 "$rc"; chk "③ 跑了两局" 2 "$(cat "$T/fake/runs")"
chk "③ 第一失败点" "偶发崩溃：客体代码（main+0x10）（首帧前）" "$(tail -1 "$T/out/结果.tsv" | cut -f5)"
rc=$(run bit32); chk "④ 32 位" "不支持：32位" "$(tail -1 "$T/out/结果.tsv" | cut -f5)"; chk "④ 没出包" no "$(grep -qx pack "$T/fake/calls" && echo yes || echo no)"
rc=$(run probefail); chk "④b 探测出错：结论 / 第一个失败点" "未判|机器原因：原件探测出错（nx_unpack --nacp-only 退出 131，不是游戏的问题）：You must install .NET to run this application. （/s/g.nsp）" "$(tail -1 "$T/out/结果.tsv" | cut -f4,5 | tr '\t' '|')"
chk "④b 探测出错：没出包、不留证" "no no" "$(grep -qx pack "$T/fake/calls" && echo yes || echo no) $([ -f "$T/out/logs/src/.留证" ] && echo yes || echo no)"
rm -rf "$T/fake" "$T/out"; mkdir -p "$T/fake"; FAKE=$T/fake QT_KEEP=1 bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > /dev/null 2>&1
chk "⑤ QT_KEEP 留工作目录" yes "$([ -d "$T/out/work/src/roots" ] && echo yes || echo no)"
bash "$F/tools/quicktest/one_game.sh" > /dev/null 2>&1; chk "⑥ 不给源包" 2 $?
rc=$(run); chk "⑦ 进局列" "是" "$(tail -1 "$T/out/结果.tsv" | cut -f16)"
rm -rf "$T/fake" "$T/out" "$T/x"; mkdir -p "$T/fake" "$T/x/exefs"; touch "$T/x/exefs/main" "$T/x/unpack.tsv"
FAKE=$T/fake QT_NAME=t1 bash "$F/tools/quicktest/one_game.sh" "$T/x" "$T/out" > /dev/null 2>&1
chk "⑦ 解包目录入口：只出包、不解包" "pack" "$(tr '\n' ' ' < "$T/fake/calls" | sed 's/ $//')"; chk "⑦ 解包目录入口：结论" "通过" "$(tail -1 "$T/out/结果.tsv" | cut -f4)"
rm -rf "$T/fake" "$T/out"; mkdir -p "$T/fake"; touch "$T/fake/nodirect"; FAKE=$T/fake bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > /dev/null 2>&1
chk "⑧ 只有直连、缺直连库不补跑（只起一局）" "unset" "$(tr '\n' ' ' < "$T/fake/gfx" | sed 's/ $//')"; chk "⑧ 结论：失败、第一失败点写明直连库没出" "失败	直连库没出（根里没有本链直连库）" "$(tail -1 "$T/out/结果.tsv" | cut -f4,5)"
rc=$(run noslot); chk "⑨ 局没起：结论 / 第一失败点" "未判 局没起" "$(tail -1 "$T/out/结果.tsv" | cut -f4,5 | tr '\t' ' ')"
rm -rf "$T/fake" "$T/out" "$T/out2"; mkdir -p "$T/fake" "$T/src"; FAKE=$T/fake QT_PACK_ONLY=1 QT_NAME=k1 bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > /dev/null 2>&1
chk "⑩ 只出包：退出 0" 0 $?; chk "⑩ 只出包：不记行" 1 "$(grep -c . "$T/out/结果.tsv")"
chk "⑩ 只出包：.qt_packed 款 / 程序号" "tstub 0100000000ABC000" "$(cut -f1,2 "$T/out/work/k1/.qt_packed" 2> /dev/null | tr '\t' ' ')"
chk "⑩ 只出包：extract 删掉、roots 留着" "no yes" "$([ -d "$T/out/work/k1/extract" ] && echo yes || echo no) $([ -d "$T/out/work/k1/roots" ] && echo yes || echo no)"
chk "⑩ 只出包：没起局" no "$([ -f "$T/fake/runs" ] && echo yes || echo no)"
FAKE=$T/fake QT_NAME=k1 bash "$F/tools/quicktest/one_game.sh" "$T/out/work/k1" "$T/out2" > /dev/null 2>&1
chk "⑪ 只跑局：没再解包 / 出包" "unpack pack" "$(tr '\n' ' ' < "$T/fake/calls" | sed 's/ $//')"
chk "⑪ 只跑局：结论 / 款 / 程序号" "通过 tstub 0100000000ABC000" "$(tail -1 "$T/out2/结果.tsv" | cut -f4,2,3 | awk -F'\t' '{print $3, $1, $2}')"
rc=$(run); chk "⑫ 进局的局不留现场" no "$([ -d "$T/out/logs/src/run" ] && echo yes || echo no)"
rc=$(run crash1); chk "⑫ 失败的局留现场（run / run2 都在、带 host.log）" "yes yes" "$([ -f "$T/out/logs/src/run/host.log" ] && echo yes || echo no) $([ -f "$T/out/logs/src/run2/host.log" ] && echo yes || echo no)"
rc=$(run packfail); chk "⑬ 出包失败留阶段日志" "PFRW gaps=1" "$(cat "$T/out/logs/src/pack_failed/tstub_main.log" 2> /dev/null)"
rc=$(run touch3); chk "⑭ 点触卡页：先掌机档、再主机档" "handheld docked" "$(tr '\n' ' ' < "$T/fake/modes" | sed 's/ $//')"
chk "⑭ 主机档进局：结论 / 进局" "通过 是" "$(tail -1 "$T/out/结果.tsv" | cut -f4,16 | tr '\t' ' ')"
chk "⑭ .进局档位 / 主日志是主机档那局 / 掌机档改 _h" "docked 没有点触行 有" "$(cut -f1 "$T/out/logs/src/.进局档位" 2> /dev/null) $(grep -q 点触没反应 "$T/out/logs/src/host.log" && echo 有点触行 || echo 没有点触行) $(grep -q '点触没反应 3 次' "$T/out/logs/src/host_h.log" 2> /dev/null && echo 有 || echo 无)"
rc=$(run touch1); chk "⑭ 点触没反应 1 次：不复跑" "handheld" "$(tr '\n' ' ' < "$T/fake/modes" | sed 's/ $//')"
rc=$(run touch3 dockfail); chk "⑭ 主机档也没进局：照记掌机档、写 .主机档复跑" "否 yes no" "$(tail -1 "$T/out/结果.tsv" | cut -f16) $([ -f "$T/out/logs/src/.主机档复跑" ] && echo yes || echo no) $([ -f "$T/out/logs/src/.进局档位" ] && echo yes || echo no)"
mkdir -p "$F/docs"; printf '# 进局档位\n程序号\t档位\t依据\t日期\n0100000000ABC000\tdocked\tx\t2026-10-30\n' > "$F/docs/名单_进局档位.tsv"
rc=$(run touch3); chk "⑭ 档位表登记过：只起一局、直接主机档" "docked" "$(tr '\n' ' ' < "$T/fake/modes" | sed 's/ $//')"; rm -f "$F/docs/名单_进局档位.tsv"
mkdir -p "$T/vs/vision"; printf '{"keys": ["TOUCH:640,360"], "why": "画面写着「请点触画面」"}' > "$T/vs/vision/v01.json"
chk "⑮ 视觉引了屏上点触原文 → 点触卡页" "屏上要点触（vision/v01.json）" "$(python3 "$R/tools/quicktest/verdict.py" --touch-stuck "$T/vs")"
printf '{"keys": ["TOUCH:640,360"], "why": "按键无效，改点触开始项"}' > "$T/vs/vision/v01.json"
python3 "$R/tools/quicktest/verdict.py" --touch-stuck "$T/vs" > /dev/null; chk "⑮ 理由没引原文 → 不判（退出 1）" 1 $?
rc=$(run directgap); chk "⑯ 只出直连后出包停在直连推导 → 第一失败点「出包：直连缺口」（不再并进「出包：改写」）" "出包：直连缺口" "$(tail -1 "$T/out/结果.tsv" | cut -f5)"
rm -rf "$T/fake" "$T/out"; mkdir -p "$T/fake" "$T/src"; FAKE=$T/fake bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > /dev/null 2>&1
chk "⑰ 只有直连：出包档 / S2A_DUAL / 局图形" "full unset unset" "$(cat "$T/fake/dual") $(head -1 "$T/fake/gfx")"
python3 - "$T/big.log" <<'PYEOF'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(30000): f.write(f'[x] 填充 {i} ' + 'a' * 40 + '\n')
    f.write('[s2a] S2A 标记 MARK：帧 845\n[dm] [nvn-mtl] 出图原比例居中（16:9 原比例页）（第 900 次出图起）：画面\n')
    f.write('[s2a] [longframe] frame 19151 (440.00 s) whole frame 2644.0 ms\n[slowframe]\t19151\t@frame_ms=2644.017\n')
    for i in range(30000): f.write(f'[x] 填充 {i} ' + 'b' * 40 + '\n')
PYEOF
bash "$R/tools/quicktest/keep_log.sh" "$T/big.log" "$T/kept.log"
chk "⑱ 超 2 MB：中段 MARK 行与原比例状态行留下、MARK 在前" "845 900" "$(grep -o -E '帧 845|第 900 次' "$T/kept.log" | tr -dc '0-9 \n' | tr '\n' ' ' | sed 's/^ *//;s/ *$//;s/  */ /g')"
chk "⑱ 超 2 MB：中段长帧 / 慢帧分解行留下（不卡定因用）" 2 "$(grep -c -E '^\[s2a\] \[longframe\] frame 19151 |^\[slowframe\].19151.' "$T/kept.log")"
chk "⑱ 超 2 MB：留存长度 ≤ 3.2 MB" 1 "$([ "$(wc -c < "$T/kept.log")" -le 3200200 ] && echo 1 || echo 0)"
head -c 1000 "$T/big.log" > "$T/small.log"; bash "$R/tools/quicktest/keep_log.sh" "$T/small.log" "$T/small_kept.log"
chk "⑱ ≤ 2 MB 原样" 0 "$(cmp -s "$T/small.log" "$T/small_kept.log"; echo $?)"
rc=$(run rostore); chk "⑲ 只读 RomFS 存储：通过、工作目录删干净" "0 no" "$rc $([ -e "$T/out/work/src" ] && echo yes || echo no)"
chk "⑲ 只读 RomFS 存储：run.out 里 Permission denied / 【红】删不掉 行数" "0 0" "$(grep -c 'Permission denied' "$T/run.out") $(grep -c '删不掉' "$T/run.out")"; chmod -R u+w "$T/out" 2> /dev/null
rm -rf "$T/fake" "$T/out"; mkdir -p "$T/fake" "$T/out/work/src/roots/.romfs_store/old/x"; echo old > "$T/out/work/src/roots/.romfs_store/old/x/stale"; chmod -R a-w "$T/out/work/src/roots/.romfs_store"
FAKE=$T/fake QT_KEEP=1 bash "$F/tools/quicktest/one_game.sh" "$T/src" "$T/out" > "$T/run.out" 2>&1
chk "⑲ 开工前删上一局只读存储：旧文件不在、0 条 Permission denied" "no 0" "$([ -e "$T/out/work/src/roots/.romfs_store/old" ] && echo yes || echo no) $(grep -c 'Permission denied' "$T/run.out")"
chmod -R u+w "$T/out" 2> /dev/null
if command -v chflags > /dev/null; then
  rc=$(run rostore locked); L=$T/out/work/src/roots/.romfs_store/tstub/oc-1/f1
  chk "⑲ 删不掉：恰好 1 行【红】带工作目录路径、0 行 rm 原始报错" "1 0" "$(grep '【红】' "$T/run.out" | grep -c "删不掉 $T/out/work/src") $(grep -c '^rm: ' "$T/run.out")"
  chk "⑲ 删不掉：红行带原因（锁住的文件路径）" 1 "$(grep '【红】' "$T/run.out" | grep -cF "$L")"
  chflags nouchg "$L" 2> /dev/null; chmod -R u+w "$T/out" 2> /dev/null
else echo "⚪ ⑲ 删不掉：本机没有 chflags（非 macOS），跳过"; fi
[ $bad = 0 ] && echo "快测单测全绿" || { echo "快测单测有红"; exit 1; }
