#!/bin/bash
# 宽屏表随同一次出包出（graphics/widen/scan/auto_pkg.sh，10-25 维护者「一次出包就是完整包」）单测，闭环换成桩、不起局，约 5 秒：bash tests/widen_auto_pkg_test.sh
# 门禁覆盖：graphics/widen/scan/auto_pkg.sh graphics/widen/scan/auto_table.sh pack/ipa.sh pack/refresh.sh pack/stage_rewrite.sh pack/oneclick/oneclick.sh
# 假产物根同 tests/widen_auto_table_test.sh（候选 0x10 / 0x20 / 0x30，桩：点集同时含 0x10、0x20 才过）。期望（手算）：
#   ① start → wait：后台真跑 auto_table.sh（桩闭环），wait 等到收尾，自动表 = main:0x10,main:0x20；copy 拷进出包工作根
#   ② list 选表：仓库有掌机档 → 掌机档取仓库那张、主机档取自动那张；start 遇仓库表不起（kick 日志不新增）
#   ④ 闭环选存档：同构建号 > 同构建号带后缀 > 同款别的构建号（存档是只读种子）
#   ③ wait 上限：锁目录一直在 → 上限 1 秒到点打【黄】、退出 0（本包不带表，不卡死出包）
#   ⑤ wait 按事件等：start 起的后台进程没退、锁还没拿 → 等它退出（不赌秒数）
#   ⑥ 满屏关的包不起闭环（维护者 11-02 满屏发布缺省关）：发布口径（S2A_ALL_CAPS=0）、没有补丁 → wanted 不要、start 不起（kick 日志不新增）；
#      补丁 [caps] widen 1 → 要；补丁只有 [widen.enable.handheld] 段 → 要；补丁 [caps] widen 0 → 不要；auto_kick.sh 同样不起
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=1; fi; }
r=$T/roots/zz@v1; mkdir -p "$r/exefs"; printf '%s\n' zz@v1 > "$T/roots/zz@现行"
{ head -c 64 /dev/zero; printf 'BIDBIDBIDBIDBID1'; } > "$r/exefs/main"; B=$(xxd -s 0x40 -l 16 -p "$r/exefs/main")
printf '模块\t偏移\t种类\t证据\nmain\t0x10\tf2w\tx\nmain\t0x20\tmovz\tx\nmain\t0x30\taspdiv\tx\n' > "$r/widen_sites.tsv"
cat > "$T/stub.sh" <<'STUB'
#!/bin/bash
G=$1; D=$2; S=$3; W=${5:-}
if [ "$W" = --rejudge-write ]; then E=$S2A_WIDEN_DIR/${G}_$(cat "$D/bid"); mkdir -p "$E"; echo "$S" > "$E/widen_enable.$S2A_LOOP_MODE.tsv"; exit 0; fi
mkdir -p "$D"; echo "$STUB_BID" > "$D/bid"; printf '①\t过\tx\n' > "$D/verdict.tsv"
if [ "${S2A_SCREEN_W:-}" = 1922 ]; then printf 'S2A 标记 MARK：帧 100\n[宽] 点 main+0x10 首次命中\n[宽] 点 main+0x20 首次命中\n[宽] 点 main+0x30 首次命中\n' > "$D/host.log"; exit 1; fi
case ",$S," in *,main:0x10,*) case ",$S," in *,main:0x20,*) exit 0;; esac;; esac; exit 1
STUB
chmod +x "$T/stub.sh"
P() { env STUB_BID=$B S2A_ROOTS=$T/roots S2A_WIDEN_AUTO=$T/auto S2A_WIDEN_DIR=$T/tables S2A_AUTO_LOOP=$T/stub.sh S2A_ALL_CAPS=1 "$@"; }   # ①–⑤ 测闭环本身：按全能力包（满屏开）起
# ①
P bash "$H/graphics/widen/scan/auto_pkg.sh" start zz handheld > /dev/null
o=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" wait zz handheld 60)
ck "① wait 等到收尾、有表（${o}）" 'grep -q "有表" <<< "$o" && [ "$(cat "$T/auto/zz_$B/widen_enable.handheld.tsv" 2>/dev/null)" = main:0x10,main:0x20 ]'
w=$T/pkgroot; mkdir -p "$w/exefs"; cp "$r/exefs/main" "$w/exefs/main"
o=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" copy zz "$w")
ck "① copy 进出包工作根（${o}）" '[ "$(cat "$w/widen_enable.handheld.tsv" 2>/dev/null)" = main:0x10,main:0x20 ]'
# ②
mkdir -p "$T/tables/zz_$B" "$T/auto/zz_$B"; echo repo > "$T/tables/zz_$B/widen_enable.handheld.tsv"; echo autodock > "$T/auto/zz_$B/widen_enable.docked.tsv"; printf '过\tv\tx\n' > "$T/auto/zz_$B/docked.status"
l=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" list zz "$B" | sed "s|$T/||" | tr '\n' ' ')
ck "② list：掌机取仓库、主机取自动（${l}）" '[ "$l" = "tables/zz_$B/widen_enable.handheld.tsv auto/zz_$B/widen_enable.docked.tsv " ]'
# 起不起是 start 同步定的（起了才打「已起」、kick 日志由后台出表进程异步写）：按 start 的回显判，不靠 sleep 1 等 kick 日志（10-26 gate-host 高负载下 1 秒内后台未必写日志，起了也可能判成没起）
n0=$(wc -l < "$T/auto/zz.kick.log" 2>/dev/null || echo 0); os=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" start zz handheld)
ck "② 仓库有表时 start 不起（回显「${os}」、kick 日志行数 $n0 → $(wc -l < "$T/auto/zz.kick.log" 2>/dev/null || echo 0)）" '[[ "$os" != *已起* ]] && [ "$(wc -l < "$T/auto/zz.kick.log" 2>/dev/null || echo 0)" = "$n0" ]'
# ③
rm -f "$T/tables/zz_$B/widen_enable.handheld.tsv"; mkdir -p "$T/auto/zz_$B/.lock.handheld"; s=$SECONDS
o=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" wait zz handheld 1); rc=$?
ck "③ 锁一直在：上限到点打【黄】、退出 0、不卡（rc ${rc}，$((SECONDS - s)) 秒）" '[ $rc = 0 ] && grep -q "【黄】" <<< "$o" && [ $((SECONDS - s)) -lt 30 ]'
# ③b 出包不等（10-25 维护者：宽屏出表不卡出包关键路径，pack/ipa.sh 传 0）：锁还在、上限 0 → 立刻打【黄】「还没收尾」、退出 0，返回时锁仍在（没等它）
o=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" wait zz handheld 0); rc=$?
ck "③b 上限 0：不等、打【黄】、退出 ${rc}、返回时出表还在跑（锁在）" '[ $rc = 0 ] && [[ "$o" == 【黄】*还没收尾* ]] && [ -d "$T/auto/zz_$B/.lock.handheld" ]'
ck "③b pack/ipa.sh 出包时缺省不等（传 \${S2A_WIDEN_WAIT_S:-0}）" 'grep -qF "auto_pkg.sh\" wait \"\$G\" handheld \"\${S2A_WIDEN_WAIT_S:-0}\"" "$H/pack/ipa.sh"'
# ⑤ 按事件等（11-01 main 偶发红：满载时后台 2 秒内还没拿到锁，旧 wait 睡 2 秒就当收尾、报「没出表」）：start 记的后台进程还活着、锁还没拿 →
#   wait 等它退出才收尾。手算：进程号文件指向一个 sleep 3，不建锁、不出表 → wait 至少 3 秒、报「没出表」（旧代码睡 2 秒就返回，红）
rmdir "$T/auto/zz_$B/.lock.handheld"; rm -f "$T/auto/zz_$B/widen_enable.handheld.tsv"; sleep 3 & echo $! > "$T/auto/zz_$B/.kick.handheld"; s=$SECONDS
o=$(P bash "$H/graphics/widen/scan/auto_pkg.sh" wait zz handheld 60)
ck "⑤ 后台还没拿锁、进程还活着：wait 等它退出（$((SECONDS - s)) 秒、${o}）" '[ $((SECONDS - s)) -ge 3 ] && grep -q "没出表" <<< "$o"'
wait
# ④ 闭环选存档（graphics/widen/scan/save_pick.sh）：同构建号 > 同构建号带后缀（取最新）> 同款别的构建号（取最新），别款同前缀不算
SV=$T/saves; B1=00000000000000000000000000000001; B2=00000000000000000000000000000002; mkdir -p "$SV"
sp() { S2A_SAVES=$SV bash "$H/graphics/widen/scan/save_pick.sh" "$@" | sed "s|$SV/||"; }
B3=00000000000000000000000000000003
mkdir -p "$SV/zz_$B2"; sleep 1; mkdir -p "$SV/zz_$B2@day"; sleep 1; mkdir -p "$SV/zzx_$B3" "$SV/zz_notes"
ck "④ 没有同构建号：借同款别的构建号里最新的（$(sp zz $B1)），别款同前缀 zzx_（构建号也不同）/ 非构建号目录不算" '[ "$(sp zz $B1)" = "zz_$B2@day" ]'
# 同构建号别的款名（10-26：硬盘普查名 t0100fd8022daa000 与 smg2 同一份 main，存档只登记在 smg2 名下）：比「同款别的构建号」优先
mkdir -p "$SV/zw_$B1"; ck "④ 同构建号别的款名（zzx_）优先于同款别的构建号（zw_<B1>）（$(sp zw $B3)）" '[ "$(sp zw $B3)" = "zzx_$B3" ]' 
ck "④ 同构建号带后缀（$(sp zz $B2)）——有完全同名时取同名" '[ "$(sp zz $B2)" = "zz_$B2" ]'
rm -rf "$SV/zz_$B2"; ck "④ 只剩带后缀的同构建号（$(sp zz $B2)）" '[ "$(sp zz $B2)" = "zz_$B2@day" ]'
ck "④ 一份都没有（款名、构建号都不沾）：不打印（$(sp yy 00000000000000000000000000000004)）" '[ -z "$(sp yy 00000000000000000000000000000004)" ]'
# 社区档（save_import.py 没给产物根时写成全 0 构建号 <款>_000…0@community）：没有同构建号时被借用（10-28 名单线：双人成行真机局没带上）
Z=00000000000000000000000000000000; mkdir -p "$SV/cc_$Z@community"; B5=00000000000000000000000000000005; ck "④ 只有全 0 构建号的社区档：借用（$(sp cc $B5)）" '[ "$(sp cc $B5)" = "cc_$Z@community" ]'
# 借来的存档游戏版本新于游戏（11-02 星露谷：1.4.4 社区档借给 1.3.33 的包，读档即 Break）：第 3 个参数给产物根（unpack.tsv display_version）就不借；
#   版本手写——主存档 + Backup/ 一份，都是 SaveGame 直接下一层 gameVersion 1.4.4、player 下另有嵌套的；游戏 1.3.33 → 不借、1.4.4 → 借、不给产物根 → 照旧借
SD=t0100e65002bb8000; mkdir -p "$SV/${SD}_$Z@community/account/F/Backup" "$T/gv13" "$T/gv14"; printf '构建号：%s\n导入：tools/save_import.py，布局 jksv，程序号 0100e65002bb8000，类型 account\n' $Z > "$SV/${SD}_$Z@community/来源.txt"
for f in F/F F/Backup/F.bak; do printf '<?xml version="1.0" encoding="utf-8"?><SaveGame><player><gameVersion>1.4.4</gameVersion></player><gameVersion>1.4.4</gameVersion></SaveGame>' > "$SV/${SD}_$Z@community/account/$f"; done
printf 'display_version\t1.3.33\n' > "$T/gv13/unpack.tsv"; printf 'display_version\t1.4.4\n' > "$T/gv14/unpack.tsv"
ck "④ 存档游戏版本 1.4.4：游戏 1.3.33 不借（$(sp $SD $B5 "$T/gv13" 2> /dev/null)）、1.4.4 借（$(sp $SD $B5 "$T/gv14" 2> /dev/null)）、不给产物根照旧借" '[ -z "$(sp $SD $B5 "$T/gv13" 2> /dev/null)" ] && [ "$(sp $SD $B5 "$T/gv14" 2> /dev/null)" = "${SD}_$Z@community" ] && [ "$(sp $SD $B5)" = "${SD}_$Z@community" ]'
# 出包（pack/ipa.sh）与 Mac 局同口径：取存档走 save_pick.sh，不再自己只认 <款>_<构建号>
ck "④ ipa.sh 取存档调 save_pick.sh、带产物根（按游戏版本挑）" 'grep -q "^SA=\$(bash \"\$R/graphics/widen/scan/save_pick.sh\".* \"\$W\")" "$H/pack/ipa.sh"'
# ⑥
PD=$T/patches; Q() { env S2A_ROOTS=$T/roots S2A_WIDEN_AUTO=$T/auto6 S2A_WIDEN_DIR=$T/tables S2A_AUTO_LOOP=$T/stub.sh S2A_ALL_CAPS=0 S2A_PATCH_DIR=$PD "$@"; }
o=$(Q bash "$H/graphics/widen/scan/auto_pkg.sh" start t0100000000000042 handheld)
ck "⑥ 发布口径、没有补丁 → start 不起（${o}）" 'grep -q "不起闭环" <<< "$o" && [ ! -e "$T/auto6/t0100000000000042.kick.log" ]'
o=$(Q bash "$H/graphics/widen/scan/auto_kick.sh" t0100000000000042)
ck "⑥ 发布口径、没有补丁 → auto_kick 不起（${o}）" 'grep -q "不起闭环" <<< "$o" && [ ! -e "$T/auto6/t0100000000000042.kick.log" ]'
mkdir -p $PD/0100000000000042
printf 'program\t0100000000000042\n[caps]\nwiden\t1\t# x\n' > $PD/0100000000000042/patch.tsv; Q bash "$H/graphics/widen/scan/auto_pkg.sh" wanted t0100000000000042; r1=$?
printf 'program\t0100000000000042\n[widen.enable.handheld]\nmain\t0x10\tmovz\t1\n' > $PD/0100000000000042/patch.tsv; Q bash "$H/graphics/widen/scan/auto_pkg.sh" wanted t0100000000000042; r2=$?
printf 'program\t0100000000000042\n[caps]\nwiden\t0\n' > $PD/0100000000000042/patch.tsv; Q bash "$H/graphics/widen/scan/auto_pkg.sh" wanted t0100000000000042; r3=$?
ck "⑥ 补丁 widen 1 → 要（${r1}）、只有 [widen.enable] 段 → 要（${r2}）、widen 0 → 不要（${r3}）" '[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 1 ]'
# ⑦ 后台闭环从出包树的 clonefile 快照跑（11-05：后台闭环在出包树上读文件，出壳闭包按访问时间判、报「读到 shell.tsv 没登记的 18 个文件」）：
#   假仓库 rr 里 auto_table.sh 是桩（记自己的路径、读 tools/probe.txt、写完成标记）；probe.txt 访问时间先拨到 2026-01-01
#   → 桩路径在快照目录下、不在 rr 下；rr/tools/probe.txt 访问时间不变；后台跑完快照目录删掉
RR=$T/rr; mkdir -p "$RR/graphics/widen/scan" "$RR/tools"; cp "$H/graphics/widen/scan/auto_kick.sh" "$H/graphics/widen/scan/auto_pkg.sh" "$RR/graphics/widen/scan/"; cp "$H/tools/clonedir.py" "$RR/tools/"
printf '#!/bin/bash\necho "$0" > "%s/k7.path"; cat "$(dirname "$0")/../../../tools/probe.txt" > /dev/null; echo 完 > "%s/k7.done"\n' "$T" "$T" > "$RR/graphics/widen/scan/auto_table.sh"
if [ "$(uname)" = Darwin ]; then AT=(stat -f %a); else AT=(stat -c %X); fi   # 访问时间（秒）：BSD 与 GNU stat 格式串不同
echo probe > "$RR/tools/probe.txt"; touch -a -t 202601010000 "$RR/tools/probe.txt"; a0=$("${AT[@]}" "$RR/tools/probe.txt")
printf 'program\t0100000000000042\n[caps]\nwiden\t1\t# x\n' > $PD/0100000000000042/patch.tsv
o=$(Q env S2A_WIDEN_SNAP=$T/snap7 S2A_LOOP_MODE=handheld bash "$RR/graphics/widen/scan/auto_kick.sh" t0100000000000042)
for i in $(seq 1 100); do [ -e "$T/k7.done" ] && [ -z "$(ls -A "$T/snap7" 2> /dev/null)" ] && break; sleep 0.1; done
a1=$("${AT[@]}" "$RR/tools/probe.txt"); kp=$(cat "$T/k7.path" 2> /dev/null)
ck "⑦ 后台闭环脚本从快照起（${kp}）、不在出包树" '[ -n "$kp" ] && [[ "$kp" == "$T/snap7/"* ]]'
ck "⑦ 出包树文件访问时间不变（${a0} → ${a1}）" '[ "$a0" = "$a1" ]'
ck "⑦ 后台跑完快照删掉（剩：$(ls -A "$T/snap7" 2> /dev/null | tr '\n' ' ')）" '[ -e "$T/k7.done" ] && [ -z "$(ls -A "$T/snap7" 2> /dev/null)" ]'
echo "宽屏表随包单测：$([ $fail = 0 ] && echo 全过 || echo 有失败)"; exit $fail
