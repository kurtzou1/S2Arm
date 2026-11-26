#!/bin/bash
# 门禁覆盖：tools/mem_admit.sh translator/dsh_batch.py pack/refresh.sh tools/mem_peak_sample.py tools/mem_peak.tsv tools/plock.sh tools/phys_footprint.py tools/flock_hold.py
# 内存准入单测（tools/mem_admit.sh，11-04 维护者第 4 项）：约 30 秒，退出 0 = 全过。上限固定 10 GB（S2A_MEM_TOTAL_GB），三款各估 4 GB，期望按规则手算：
#   ① 4 + 4 = 8 ≤ 10：前两个放行；第 3 个 8 + 4 = 12 > 10 → 排队，admit.log 有【排队】行写明等谁（dsh/a、dsh/b）和差 2.0 GB，且命令没起
#   ② 第 1 个结束后账内 4 GB，4 + 4 = 8 ≤ 10 → 第 3 个放行
#   ③ 实测峰值写回：命令真占约 300 MB，跑完 peak.tsv 有该键一行、来源「实」、值 ≥ 0.2 GB
#   ⑤ 实测优先：本款有实测就按本款实测，不按同类最大 × 1.5
#   ⑥ 没实测过的款（生键）：同类实测样本 ≥ 10 → 最大值 × 1.5（估值表的类别下限行不参与）；样本 < 10 → 核数比例（上限 × 核数 ÷ 物理核数，封顶一半）、
#     同类最大 × 1.5、估值表类别下限行「<类别> *」三者取大（审计 #1534 P1-113：空实测表不按核数比例少占账）；直连库（dsh）的核数比例换成实测模型
#     （主进程 + metal 峰值 + (J − 1) × metal p90）；生键打一行【黄】写明按什么估的
#   ⑦ 插空：队首放不下时，后面放得下的先走
#   ⑧ 防饿死：前面有票排满 S2A_MEM_STARVE_S 秒、且本机空闲 + 可回收（S2A_MEM_AVAIL_GB）放得进，就给它预留，后面放得下的也不再插空
#   ⑭ 防饿死只给放得进的：排满的票在本机空闲 + 可回收下放不进 → 降回普通排队，后面的小票照样插空（11-04 晚生键 50 GB 挡住 12 张票）
#   ⑮ 估值（非实测）超过上限 / 本机物理内存（#1229）→ 不再永久拒绝：打【黄】按上限预留、账里有别人时排队、账空独占跑，跑完写回本款实测
#   ⑮b 同类估值只用正常跑完的样本（#1229 / #1122：一条跑飞被杀的 143.2 GB 读数让 24 GB 机器上所有新游戏估 214.8 GB）：
#     第 7 列退出码非 0 的行、没记退出码却超过物理内存的旧行不进同类最大值；写回时记退出码
#   ⑮c 本款自己那行就是跑飞值（#1312 评审）：当估值处理、封顶上限独占跑；跑成功（退出码 0）后新实测覆盖它，命令签名不同也覆盖
#   ⑰b 读不到物理内存但给了 S2A_MEM_TOTAL_GB：按它定上限照常跑（#1312 评审：只在两样都没有时报红）
#   ⑰ 没有 sysctl 的出包机：物理内存读 /proc/meminfo 的 MemTotal（审计 #1534 P1-114），估值单照常放行
#   ⑯ 门禁步 / 单测里没给 S2A_MEM_DIR → 报【红】退出 125，缺省共享账本目录不建不写
#   ⑰ 给了出包进度文件 S2A_PROGRESS：排队时最新【排队】行写进 <进度文件>.wait（进程号<TAB>行），放行后删掉（审计 #1534 P1-110：出包心跳读它）
#   ⑨ 核数：内存够、核不够（账内核数 + 本作业 > 上限）→ 排队，原因行写「核」；占核的结束后放行
#   ⑩ 夹具随测试退出：测试目录被删（收尾 trap 的 rm -rf）后，占内存夹具与它的 mem_admit 3 秒内都退出
#     （11-04 门禁超时杀掉本单测，trap 删了目录、只杀到 mem_admit；夹具死等已删目录里的 .go，在 gate-host 上挂了 3 小时）
#   ⑩b 测试进程被 KILL（收尾 trap 不跑、目录还在）→ 夹具 3 秒内也退出（11-11 本机两个夹具空转 41 小时）
#   ⑪ dsh_batch.py build 直接调用也过准入：账本出现 dsh/<键> 的 use 行、核数 = -j，且只有这一行（不重复记账）
#   ㉓ 按此刻可用内存放（S2A_MEM_AVAIL_MB）：本单 + 账内各单还没用到的预留 > 可用 → 排队；负控给大可用直接放行
#   ㉔ 账锁被别的作业占着、一轮等不到（S2A_MEM_LOCK_S）→ 接着排，锁放了就放行，不报 125（#2241）
#   ④ 负控：S2A_MEM_ADMIT=0（去掉准入）同样三个申请，第 3 个不排队直接起 → 用例 ① 的「第 3 个被挡」在此红，证明用例 ① 测的是准入本身
set -u; unset J S2A_CPU_BAKE S2A_MEM_KEY; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 固定等待的下限（11-18 单测 53 → 约 40 秒）：「确认仍在排队」0.5 秒 = 2.5 个轮询周期（S2A_MEM_POLL=0.2）；要采峰值的命令睡 0.5–0.8 秒 ≥ 2 个采样周期
#   （S2A_MEM_SAMPLE_S=0.2）；防饿死用例的 sleep 1.5 不动（S2A_MEM_STARVE_S 按整秒比，最少 1 秒）
# 等待上限只防卡死（条件到了立刻返回）：缺省 60 秒。11-18 Linux 主机影子跑负载 15–20 时 15 秒上限不够、mem_admit 还没写出排队行就超时，①⑫⑰㉑ 连红。
#   waitf 的上限是第 2 个参数（原先取 $3，调用处写的上限从没生效）
waitf() { local i; for i in $(seq 1 "${2:-600}"); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
waitg() { local i; for i in $(seq 1 "${3:-600}"); do grep -q "$2" "$1" 2> /dev/null && return 0; sleep 0.1; done; return 1; }
printf 'dsh\ta\t4\t估\ndsh\tb\t4\t估\ndsh\tc\t4\t估\nmem\tbig\t0.3\t估\nappbuild\tp\t4\t估\ndsh\td\t2\t估\n' > "$T/seed.tsv"
export S2A_MEM_TOTAL_GB=10 S2A_MEM_SEED=$T/seed.tsv S2A_MEM_POLL=0.2 S2A_MEM_SAMPLE_S=0.2 S2A_MEM_SAY_S=1 S2A_MEM_AVAIL_GB=100   # 此刻可用内存固定 100 GB：只 ㉓ 测可用内存，其余用例不随本机负载变
# 一道「占着内存直到放行文件出现」的命令：起了就写 <D>/<名>.in；目录没了（测试收尾删了 ${T}）或测试进程没了就退出（11-11：测试被 KILL 时收尾 trap 不跑、目录还在，
#   两个夹具空转 41 小时、每秒各起 10 个 sleep；见 ⑩b）
hold() { local D=$1 N=$2; bash "$H/tools/mem_admit.sh" dsh "$N" -- bash -c 'touch "$1/$2.in"; while [ ! -e "$1/$2.go" ] && [ -d "$1" ] && kill -0 '"$$"' 2> /dev/null; do sleep 0.1; done' _ "$D" "$N" > "$D/$N.out" 2>&1 & }

A=$T/on; mkdir -p "$A"; export S2A_MEM_DIR=$A/mem S2A_MEM_LOCK=$A/mem.flock
hold "$A" a; waitf "$A/a.in"; hold "$A" b; waitf "$A/b.in"
ck "① 前两个（4 + 4 ≤ 10）放行" '[ -e "$A/a.in" ] && [ -e "$A/b.in" ]'
S2A_PROGRESS=$A/prog.tsv hold "$A" c; waitg "$A/mem/admit.log" '【排队】mem_admit dsh/c'; sleep 0.5
ck "① 第 3 个（8 + 4 > 10）被挡：命令没起" '[ ! -e "$A/c.in" ]'
ck "① admit.log 有排队原因行：写明等谁（dsh/a）与差 2.0 GB" 'grep "【排队】mem_admit dsh/c" "$A/mem/admit.log" | grep -q "dsh/a" && grep "【排队】mem_admit dsh/c" "$A/mem/admit.log" | grep -q "差 2.0 GB"'
ck "⑫ 排队行写明预留来源：「需 4.0 GB（估）」（11-04 Switch2 线：看不出等的是缺省估值）" 'grep "【排队】mem_admit dsh/c" "$A/mem/admit.log" | grep -q "需 4.0 GB（估）"'
ck "⑰ 给了出包进度文件：排队行同时写进 <进度文件>.wait（进程号<TAB>【排队】行），出包心跳读它（审计 #1534 P1-110）" 'grep -q "【排队】mem_admit dsh/c：需 4.0 GB" "$A/prog.tsv.wait" && kill -0 "$(cut -f1 "$A/prog.tsv.wait")"'
touch "$A/a.go"; waitf "$A/c.in" 300   # 按事件等，上限 30 秒：11-04 本机 1 分钟负载 50–60 时 10 秒上限 3 次红 1 次
ck "② 第 1 个结束后第 3 个放行（4 + 4 ≤ 10）" '[ -e "$A/c.in" ]'
ck "⑰ 放行后 <进度文件>.wait 删掉（心跳不再报在等）" '[ ! -e "$A/prog.tsv.wait" ]'
touch "$A/b.go" "$A/c.go"; wait

# ㉑ 优先类别（11-07 维护者：启动器最高优先，App 打包排队等 CPU）：上限 10，a / b 各占 4；优先类 appbuild/p 要 4 先排队，之后普通 dsh/d 要 2
#   （8 + 2 ≤ 10 本来放得进）→ d 不插空、在等；a 结束后 p 先放行，d 在它之后放行（b 4 + p 4 + d 2 = 10）。期望手算：p 起在 d 之前
P=$T/prio; mkdir -p "$P"; export S2A_MEM_DIR=$P/mem S2A_MEM_LOCK=$P/mem.flock
holdc() { local D=$1 C=$2 N=$3; bash "$H/tools/mem_admit.sh" "$C" "$N" -- bash -c 'touch "$1/$2.in"; while [ ! -e "$1/$2.go" ] && [ -d "$1" ] && kill -0 '"$$"' 2> /dev/null; do sleep 0.1; done' _ "$D" "$N" > "$D/$N.out" 2>&1 & }
holdc "$P" dsh a; waitf "$P/a.in"; holdc "$P" dsh b; waitf "$P/b.in"
holdc "$P" appbuild p; waitg "$P/mem/admit.log" '【排队】mem_admit appbuild/p'; holdc "$P" dsh d; waitg "$P/mem/admit.log" '【排队】mem_admit dsh/d'; sleep 0.5
ck "㉑ 优先类 appbuild/p 在等时，放得进的普通 dsh/d 不插空（d 没起）、排队行写明让优先类" '[ ! -e "$P/d.in" ] && grep "【排队】mem_admit dsh/d" "$P/mem/admit.log" | grep -q "优先类别 appbuild/p"'
touch "$P/a.go"; waitf "$P/p.in" 300
# p 放行后账内 4 + 4 = 8，d 要 2 → 8 + 2 ≤ 10 本来就放得进：d 可能紧跟着放行（原先断言「d 仍在等」靠 d 下一次轮询前抢先检查，负载高时偶发红）。
#   判先后看账本日志的放行行：p 的在前，d 的在后或还没有
lp=$(grep -n "放行 appbuild/p" "$P/mem/admit.log" | head -1 | cut -d: -f1); ld=$(grep -n "放行 dsh/d" "$P/mem/admit.log" | head -1 | cut -d: -f1)
ck "㉑ a 结束后优先类 p 先放行（admit.log 里 p 的放行行在 d 之前）" '[ -e "$P/p.in" ] && [ -n "$lp" ] && { [ -z "$ld" ] || [ "$lp" -lt "$ld" ]; }'
touch "$P/b.go"; waitf "$P/d.in" 300
ck "㉑ b 结束后 d 放行" '[ -e "$P/d.in" ]'
touch "$P/p.go" "$P/d.go"; wait
export S2A_MEM_DIR=$A/mem S2A_MEM_LOCK=$A/mem.flock

# ③ 实测峰值写回
bash "$H/tools/mem_admit.sh" mem big -- python3 -c 'import time; b = bytearray(b"x") * (300 * 1024 * 1024); time.sleep(0.8)' > "$A/big.out" 2>&1; brc=$?
row=$(awk -F'\t' '$1=="mem" && $2=="big"{print $3, $4}' "$A/mem/peak.tsv" 2> /dev/null)
ck "③ 命令成功（实 ${brc}），peak.tsv 记下 mem/big：「${row}」来源为实、值 ≥ 0.2 GB" '[ $brc = 0 ] && [ "${row#* }" = 实 ] && awk -v v="${row% *}" "BEGIN{exit !(v+0 >= 0.2)}"'
ck "③ 下次按实测：再申请时放行行标「实」" 'bash "$H/tools/mem_admit.sh" mem big -- true > /dev/null 2> "$A/again.err"; grep -q "mem/big：预留.*（实）" "$A/mem/admit.log"'

# ⑤⑥ 取值：实测表 dsh 10 行（k0–k8 各 1.0、y 4.0，实）→ 同类最大 4.0 × 1.5 = 6.0；pk 类 9 行（各 1.0，实）样本不够；物理核数固定 4（S2A_MEM_CORES_MAX）
#   估值表类别下限行 dsh * 50 / pk * 7 / ds3 * 2：dsh 样本够 10 条，不看下限（仍 6.0，不是 50）；
#   pk 生键：核数比例 10 × 1 ÷ 4 = 2.5、同类 1.0 × 1.5 = 1.5、下限 7 → 取 7.0（旧版不读下限、给 2.5）；
#   ds3 类 3 行（1.0、1.0、2.0，实）：核数比例 2.5，同类最大 2.0 × 1.5 = 3.0，下限 2 → 取 3.0
M=$T/need; mkdir -p "$M/mem"; export S2A_MEM_DIR=$M/mem S2A_MEM_LOCK=$M/mem.flock S2A_MEM_SEED=$M/seed.tsv S2A_MEM_CORES_MAX=4
printf 'dsh\t*\t50\t估\npk\t*\t7\t估\nds3\t*\t2\t估\n' > "$M/seed.tsv"
{ for i in 0 1 2 3 4 5 6 7 8; do printf 'dsh\tk%s\t1.0\t实\t2026-11-04\npk\tp%s\t1.0\t实\t2026-11-04\n' $i $i; done; printf 'dsh\ty\t4.0\t实\t2026-11-04\n'
  printf 'ds3\ta\t1.0\t实\t2026-11-04\nds3\tb\t1.0\t实\t2026-11-04\nds3\tc\t2.0\t实\t2026-11-04\n'; } > "$M/mem/peak.tsv"
bash "$H/tools/mem_admit.sh" dsh k0 -- true > /dev/null 2>&1
ck "⑤ 本款有实测（dsh/k0 1.0 实）按本款：预留 1.0 GB（实），不是同类 6.0" 'grep -q "放行 dsh/k0：预留 1.0 GB（实）" "$M/mem/admit.log"'
bash "$H/tools/mem_admit.sh" dsh z -- true > /dev/null 2>&1
ck "⑥ 没实测过的 dsh/z、同类 10 样本：预留 6.0 GB（= 4.0 × 1.5，同类实测最大×1.5），不是 dsh * 50" 'grep -q "放行 dsh/z：预留 6.0 GB（生键·同类实测最大×1.5）" "$M/mem/admit.log"'
bash "$H/tools/mem_admit.sh" pk q -- true > /dev/null 2>&1
ck "⑥ pk 类只有 9 个样本（< 10）：生键取估值表类别下限 pk * 7 = 7.0 GB（大于核数比例 2.5、同类 1.0 × 1.5）" 'grep -q "放行 pk/q：预留 7.0 GB（生键·类别下限" "$M/mem/admit.log"'
bash "$H/tools/mem_admit.sh" ds3 fixture -- true > /dev/null 2>&1
ck "⑥ 生键 ds3/fixture（同类 3 样本、最大 2.0）：预留 3.0 GB = 2.0 × 1.5（大于核数比例 2.5、类别下限 ds3 * 2）" 'grep -q "放行 ds3/fixture：预留 3.0 GB（生键·同类实测最大×1.5" "$M/mem/admit.log"'
ck "⑥ 生键打【黄】写明按什么估：dsh/z 6.0、ds3/fixture 3.0、pk/q 7.0（类别下限）" 'grep -q "【黄】mem_admit dsh/z：生键（实测表、估值表都没有本键），按同类实测最大×1.5估 6.0 GB" "$M/mem/admit.log" && grep -q "【黄】mem_admit ds3/fixture：生键.*估 3.0 GB" "$M/mem/admit.log" && grep -q "【黄】mem_admit pk/q：生键.*类别下限.*估 7.0 GB" "$M/mem/admit.log"'
ck "⑥ 本款有实测 / 估值表有本键的不打生键【黄】（dsh/k0）" '! grep -q "【黄】mem_admit dsh/k0" "$M/mem/admit.log"'
# ⑥ 空实测表 + 仓库估值表（tools/mem_peak.tsv）的机器上，没实测过的直连库按实测模型随路数预留（tools/cores.sh s2a_direct_mb 缺省值）：
#   2 路 = 1740 + 1065 + 1 × 420 = 3225 MB = 3.15 GB，向上取到 0.1 → 3.2 GB；不是核数比例 10 × 2 ÷ 4 = 5.0，也不是旧的类别下限 dsh * 7.8
E=$T/empty; mkdir -p "$E/mem"
S2A_MEM_DIR=$E/mem S2A_MEM_LOCK=$E/mem.flock S2A_MEM_SEED=$H/tools/mem_peak.tsv bash "$H/tools/mem_admit.sh" dsh new --cores 2 -- true > /dev/null 2>&1
ck "⑥ 空实测表 + 仓库估值表：dsh/new 2 路预留 3.2 GB（生键·直连库实测模型），不是 7.8 / 5.0" 'grep -q "放行 dsh/new：预留 3.2 GB（生键·直连库实测模型（2 路" "$E/mem/admit.log"'
unset S2A_MEM_CORES_MAX

# ⑦ 插空：上限 10。h（估 6）占着；big（估 8）排队首放不下（6 + 8 > 10）；small（估 1）后到、6 + 1 ≤ 10 → 先走，big 仍没起
# ⑧ 防饿死：S2A_MEM_STARVE_S=1，big 排满 1 秒后再来 small2（估 1，放得下）→ 不插空、没起；h 结束后 big 放行（0 + 8 ≤ 10），之后 small2 放行（8 + 1 ≤ 10）
Q=$T/fill; mkdir -p "$Q/mem"; export S2A_MEM_DIR=$Q/mem S2A_MEM_LOCK=$Q/mem.flock S2A_MEM_SEED=$Q/seed.tsv S2A_MEM_STARVE_S=600 S2A_MEM_AVAIL_GB=100
printf 'dsh\th\t6\t估\ndsh\tbig\t8\t估\ndsh\tsmall\t1\t估\ndsh\tsmall2\t1\t估\n' > "$Q/seed.tsv"
hold "$Q" h; waitf "$Q/h.in"; hold "$Q" big; waitg "$Q/mem/admit.log" '【排队】mem_admit dsh/big'
hold "$Q" small; waitf "$Q/small.in" 300
ck "⑦ 插空：队首 big（8）放不下时，后到的 small（1，6 + 1 ≤ 10）先走" '[ -e "$Q/small.in" ] && [ ! -e "$Q/big.in" ]'
touch "$Q/small.go"
export S2A_MEM_STARVE_S=1; sleep 1.5
hold "$Q" small2; waitg "$Q/mem/admit.log" '【排队】mem_admit dsh/small2.*dsh/big.*给它预留' 300   # 按条件等「给 big 预留」那条排队行（上限 30 秒），不靠固定 0.5 秒：负载高时那行写得晚
ck "⑧ 防饿死：big 已排满 1 秒，后到的 small2 放得下也不插空（没起，排队行写明给 big 预留）" '[ ! -e "$Q/small2.in" ] && grep "【排队】mem_admit dsh/small2" "$Q/mem/admit.log" | grep -q "dsh/big.*给它预留"'
touch "$Q/h.go"; waitf "$Q/big.in" 300; waitf "$Q/small2.in" 300
ck "⑧ h 结束后 big 先放行、small2 随后放行" '[ -e "$Q/big.in" ] && [ -e "$Q/small2.in" ]'
touch "$Q/big.go" "$Q/small2.go"; wait

# ⑭ 同 ⑧ 的布局，但本机空闲 + 可回收只有 7.5 GB（S2A_MEM_AVAIL_GB）：big（8）排满 1 秒也放不进 → 不给它预留；
#   后到的 small2（1，6 + 1 ≤ 10；1 + h 没用到的约 5.9 ≤ 7.5）照样插空、几秒内起；big 仍没起（账 6 + 1 + 8 > 10）
P=$T/fit; mkdir -p "$P/mem"; export S2A_MEM_DIR=$P/mem S2A_MEM_LOCK=$P/mem.flock S2A_MEM_SEED=$Q/seed.tsv S2A_MEM_STARVE_S=1 S2A_MEM_AVAIL_GB=7.5
hold "$P" h; waitf "$P/h.in"; hold "$P" big; waitg "$P/mem/admit.log" '【排队】mem_admit dsh/big'; sleep 1.5
hold "$P" small2; waitf "$P/small2.in" 300
ck "⑭ 排满的 big（8）在空闲 + 可回收 7.5 GB 下放不进：不占防饿死位，small2 5 秒内插空起、big 没起" '[ -e "$P/small2.in" ] && [ ! -e "$P/big.in" ] && ! grep "【排队】mem_admit dsh/small2" "$P/mem/admit.log" | grep -q "给它预留"'
touch "$P/h.go" "$P/small2.go"; waitf "$P/big.in" 300
ck "⑭ h、small2 结束后 big 照常放行（降级只是不锁全机，不是丢票）" '[ -e "$P/big.in" ]'
touch "$P/big.go"; wait
# ㉒ #235：账本路径带空格（玩家 Mac 的账本在 ~/Library/Application Support 下）+ 一张发车时刻不是数字的坏票（别的版本写的 / 写了一半）：
#   同 ⑧ 的布局，期望防饿死照常生效（big 排满后 small2 不插空）、坏票被跳过、不报 unbound variable。
#   旧码：for f in $(ls …) 把每张票的路径按空格切成三段，一张票也读不到 → small2 插空起（本项红）
# 下面按 bash 的英文报错「unbound variable」判「全程没有」：钉住报错语言，否则中文系统上 bash 报中文、这条反向断言假绿（11-16 维护者）
export LC_MESSAGES=C
S="$T/sp/Application Support"; mkdir -p "$S/mem"; export S2A_MEM_DIR=$S/mem S2A_MEM_LOCK=$S/mem.flock S2A_MEM_SEED=$Q/seed.tsv S2A_MEM_STARVE_S=600 S2A_MEM_AVAIL_GB=100
printf '%s\t1\tdsh\tbad\ton\t0\n' $$ > "$S/mem/q.1000.$$"   # 本测试进程持有（不被当死票清掉），第 5 列是文字
hold "$S" h; waitf "$S/h.in"; hold "$S" big; waitg "$S/mem/admit.log" '【排队】mem_admit dsh/big'
export S2A_MEM_STARVE_S=1; sleep 1.5
hold "$S" small2; waitg "$S/mem/admit.log" '【排队】mem_admit dsh/small2.*dsh/big.*给它预留' 300   # 按条件等「给 big 预留」那条排队行（上限 30 秒），不靠固定 0.5 秒：负载高时那行写得晚
ck "㉒ 路径带空格 + 坏票：big 排满 1 秒，small2 不插空（排队行写明给 big 预留）" '[ ! -e "$S/small2.in" ] && grep "【排队】mem_admit dsh/small2" "$S/mem/admit.log" | grep -q "dsh/big.*给它预留"'
touch "$S/h.go"; waitf "$S/big.in" 300; waitf "$S/small2.in" 300
ck "㉒ h 结束后 big、small2 依次放行；全程没有 unbound variable" '[ -e "$S/big.in" ] && [ -e "$S/small2.in" ] && ! grep -q "unbound variable" "$S"/*.out'
touch "$S/big.go" "$S/small2.go"; rm -f "$S/mem/q.1000.$$"; wait
unset S2A_MEM_STARVE_S; export S2A_MEM_SEED=$T/seed.tsv S2A_MEM_AVAIL_GB=100

# ⑮ 估值超过物理内存（#1229）：物理内存 8 GiB（S2A_MEM_PHYS_BYTES，上限 = 8 × 70% = 5.6 GB），估值表 dsh/huge 20、dsh/h 2。
#   h 占着时 huge 不起、排队（不是退 125）；h 结束后 huge 按上限 5.6 GB 独占放行、退出 0，admit.log 有【黄】写明封顶，没有【红】；跑完写回 dsh/huge 实测
#   旧码：huge 直接【红】退 125、命令不起（本项红）
X=$T/huge; mkdir -p "$X/mem"; printf 'dsh\thuge\t20\t估\ndsh\th\t2\t估\n' > "$X/seed.tsv"
xenv() { env -u S2A_MEM_TOTAL_GB S2A_MEM_DIR=$X/mem S2A_MEM_LOCK=$X/mem.flock S2A_MEM_SEED=$X/seed.tsv S2A_MEM_PHYS_BYTES=8589934592 "$@"; }
xenv bash "$H/tools/mem_admit.sh" dsh h -- bash -c 'touch "$1/h.in"; while [ ! -e "$1/h.go" ] && kill -0 '"$$"' 2> /dev/null; do sleep 0.1; done' _ "$X" > /dev/null 2>&1 & waitf "$X/h.in"
xenv bash "$H/tools/mem_admit.sh" dsh huge -- python3 -c 'import os, sys, time; open(sys.argv[1], "w").close(); b = bytearray(b"x") * (200 * 1024 * 1024); time.sleep(0.8)' "$X/ran" > /dev/null 2>&1 & xp=$!
waitg "$X/mem/admit.log" '【排队】mem_admit dsh/huge'; sleep 0.5
ck "⑮ 估值 20 GB > 物理内存 8 GB、账里有 h：huge 排队等（命令没起、进程还在），不是退 125" '[ ! -e "$X/ran" ] && kill -0 "$xp" 2> /dev/null && grep "【排队】mem_admit dsh/huge" "$X/mem/admit.log" | grep -q "需 5.6 GB"'
touch "$X/h.go"; wait "$xp"; xrc=$?
ck "⑮ h 结束后 huge 按上限 5.6 GB 独占放行：退出 ${xrc}（期望 0）、命令起了、有封顶【黄】、无【红】" '[ "$xrc" = 0 ] && [ -e "$X/ran" ] && grep -q "【黄】mem_admit dsh/huge：估值 20.0 GB（估）超过上限 5.6 GB（本机物理内存 8.0 GB），估值不是实测：按上限预留、账空独占跑" "$X/mem/admit.log" && grep -q "放行 dsh/huge：预留 5.6 GB" "$X/mem/admit.log" && ! grep -q "【红】" "$X/mem/admit.log"'
ck "⑮ 跑完写回 dsh/huge 实测（来源实、第 7 列退出码 0），下次按实测、不再封顶" '[ "$(awk -F"\t" "\$2==\"huge\"{print \$4 \"|\" \$7}" "$X/mem/peak.tsv")" = "实|0" ]'
wait
# ⑮b #1229 的形状：物理内存 24 GiB、10 核，实测表 dsh 3 行：1.5、2.4（rc 0）、143.2（旧行没记退出码，跑飞）→ 剔除 143.2，生键 dsh/new 10 路估 6.5（直连库实测模型 1740 + 1065 + 9 × 420 = 6585 MB，向上取 0.1 GB；> 2.4 × 1.5）；
#   再加一行 dsh/killed 30.0（第 7 列 137，被 Jetsam 杀）也剔除。旧码：143.2 × 1.5 = 214.8 GB → 退 125
Z=$T/poison; mkdir -p "$Z/mem"; : > "$Z/seed.tsv"
printf 'dsh\ta\t1.5\t实\t2026-11-10\tx\t0\ndsh\tb\t2.4\t实\t2026-11-10\ndsh\tran\t143.2\t实\t2026-11-10\ndsh\tkilled\t30.0\t实\t2026-11-10\tx\t137\n' > "$Z/mem/peak.tsv"
env -u S2A_MEM_TOTAL_GB S2A_MEM_DIR=$Z/mem S2A_MEM_LOCK=$Z/mem.flock S2A_MEM_SEED=$Z/seed.tsv S2A_MEM_PHYS_BYTES=25769803776 S2A_MEM_CORES_MAX=10 \
  bash "$H/tools/mem_admit.sh" dsh new --cores 10 -- touch "$Z/ran" > /dev/null 2>&1; zrc=$?
ck "⑮b 跑飞 143.2 与退出码 137 的 30.0 不进同类最大值：dsh/new 退出 ${zrc}（期望 0）、预留 6.5 GB（直连库实测模型），不是 214.8 / 45.0" '[ "$zrc" = 0 ] && [ -e "$Z/ran" ] && grep -q "放行 dsh/new：预留 6.5 GB（生键·直连库实测模型（10 路" "$Z/mem/admit.log"'
printf 'dsh\tc%s\t1.0\t实\t2026-11-10\tx\t0\n' 0 1 2 3 4 5 6 7 >> "$Z/mem/peak.tsv"   # 有效样本 10 条（a、b、c0–c7）：同类最大 2.4 × 1.5 = 3.6，来源写剔了 2 条
env -u S2A_MEM_TOTAL_GB S2A_MEM_DIR=$Z/mem S2A_MEM_LOCK=$Z/mem.flock S2A_MEM_SEED=$Z/seed.tsv S2A_MEM_PHYS_BYTES=25769803776 \
  bash "$H/tools/mem_admit.sh" dsh new2 -- true > /dev/null 2>&1
ck "⑮b 有效样本够 10 条：dsh/new2 预留 3.6 GB（= 2.4 × 1.5），来源写明剔除 2 条" 'grep -q "放行 dsh/new2：预留 3.6 GB（生键·同类实测最大×1.5（剔除跑失败 / 超物理内存的 2 条））" "$Z/mem/admit.log"'
# ⑮c 本款自己那行是跑飞值：24 GiB（上限 16.8），dsh/run 143.2 退出码 137、dsh/leg 143.2 旧行没记退出码 → 来源不是「实」、预留封顶 16.8 GB、打【黄】；
#   命令（签名与表里「old.sh」不同）退出 0、实测约 0.2 GB → 覆盖成新实测、第 7 列 0。旧码（4b2c74e4）：按「实」预留 143.2 GB 独占，且签名不同不往低改，以后每次独占
C=$T/selfbad; mkdir -p "$C/mem"; : > "$C/seed.tsv"
printf 'dsh\trun\t143.2\t实\t2026-11-10\told.sh\t137\ndsh\tleg\t143.2\t实\t2026-11-10\told.sh\n' > "$C/mem/peak.tsv"
for k in run leg; do env -u S2A_MEM_TOTAL_GB S2A_MEM_DIR=$C/mem S2A_MEM_LOCK=$C/mem.flock S2A_MEM_SEED=$C/seed.tsv S2A_MEM_PHYS_BYTES=25769803776 S2A_MEM_SAMPLE_S=0.2 \
  bash "$H/tools/mem_admit.sh" dsh $k -- python3 -c 'import time; b = bytearray(b"x") * (200 * 1024 * 1024); time.sleep(0.8)' > /dev/null 2>&1; done
crow() { awk -F'\t' -v k="$1" '$2==k{print $3 "|" $7}' "$C/mem/peak.tsv"; }
cok() { awk -v v="$(crow "$1")" 'BEGIN{split(v, a, "|"); exit !(a[1]+0 > 0 && a[1]+0 < 1 && a[2] == "0")}'; }
ck "⑮c 本款跑飞行（退出码 137 / 超物理内存旧行）按估值封顶：run、leg 都预留 16.8 GB、有封顶【黄】" 'grep -q "放行 dsh/run：预留 16.8 GB（实测跑失败（退出码 137），封顶上限独占）" "$C/mem/admit.log" && grep -q "放行 dsh/leg：预留 16.8 GB（旧实测超过物理内存（跑飞），封顶上限独占）" "$C/mem/admit.log"'
ck "⑮c 退出码 0 的新实测覆盖跑飞行（签名不同也覆盖）：run「$(crow run)」、leg「$(crow leg)」都 < 1 GB、退出码 0" 'cok run && cok leg'
# ⑰ 没有 sysctl 的出包机（审计 #1534 P1-114：Windows Git Bash / Linux）：PATH 上的假 sysctl 失败、假 /proc/meminfo 写 MemTotal 16777216 kB（16 GiB），估值 dsh/p 6 → 放行、命令起；
#   负对照同条件但没有 meminfo → 物理内存按 0，退 125（原缺陷的形状）
Y=$T/nosysctl; mkdir -p "$Y/mem" "$Y/bin"; printf 'dsh\tp\t6\t估\n' > "$Y/seed.tsv"; printf '#!/bin/bash\nexit 1\n' > "$Y/bin/sysctl"; chmod +x "$Y/bin/sysctl"; printf 'MemTotal:       16777216 kB\nMemAvailable:   12582912 kB\n' > "$Y/meminfo"
PATH=$Y/bin:$PATH S2A_MEM_DIR=$Y/mem S2A_MEM_LOCK=$Y/mem.flock S2A_MEM_SEED=$Y/seed.tsv S2A_MEM_MEMINFO=$Y/meminfo bash "$H/tools/mem_admit.sh" dsh p -- touch "$Y/ran" > /dev/null 2>&1; yrc=$?
ck "⑰ 没有 sysctl、MemTotal 16 GiB：估值 6 GB 放行，退出 ${yrc}（期望 0）、命令起了" '[ "$yrc" = 0 ] && [ -e "$Y/ran" ]'
PATH=$Y/bin:$PATH env -u S2A_MEM_TOTAL_GB S2A_MEM_DIR=$Y/mem S2A_MEM_LOCK=$Y/mem.flock S2A_MEM_SEED=$Y/seed.tsv S2A_MEM_MEMINFO=$Y/none bash "$H/tools/mem_admit.sh" dsh p -- true > /dev/null 2>&1; nrc=$?
ck "⑰ 负对照：没有 sysctl 也没有 meminfo、也没给 S2A_MEM_TOTAL_GB → 退出 ${nrc}（期望 125，读不到物理内存报【红】）" '[ "$nrc" = 125 ] && grep -q "【红】mem_admit dsh/p：读不到本机物理内存" "$Y/mem/admit.log"'
PATH=$Y/bin:$PATH S2A_MEM_TOTAL_GB=10 S2A_MEM_DIR=$Y/mem S2A_MEM_LOCK=$Y/mem.flock S2A_MEM_SEED=$Y/seed.tsv S2A_MEM_MEMINFO=$Y/none bash "$H/tools/mem_admit.sh" dsh p -- touch "$Y/ran2" > /dev/null 2>&1; trc=$?
ck "⑰b 读不到物理内存但给了 S2A_MEM_TOTAL_GB=10：本款（实）照常放行，退出 ${trc}（期望 0）、命令起了" '[ "$trc" = 0 ] && [ -e "$Y/ran2" ]'

# ⑯ 单测防线：门禁步内（GATE_IN_STEP=1）没给 S2A_MEM_DIR，缺省账本在 HOME 下 → 【红】退出 125、命令没起、缺省目录没建
G=$T/guard; mkdir -p "$G/home"
env -u S2A_MEM_DIR -u S2A_MEM_LOCK HOME="$G/home" GATE_IN_STEP=1 bash "$H/tools/mem_admit.sh" dsh fixture -- touch "$G/ran" > /dev/null 2> "$G/err"; grc=$?
ck "⑯ 门禁步里没给 S2A_MEM_DIR：退出 ${grc}（期望 125）、命令没起、缺省账本目录没建、报【红】" '[ "$grc" = 125 ] && [ ! -e "$G/ran" ] && [ ! -e "$G/home/.s2arm" ] && grep -q "【红】mem_admit dsh/fixture：在门禁步" "$G/err"'
env -u S2A_MEM_DIR -u S2A_MEM_LOCK -u GATE_IN_STEP HOME="$G/home" S2A_TEST_ROOT="$G" bash "$H/tools/mem_admit.sh" dsh fixture -- touch "$G/ran" > /dev/null 2>&1; grc=$?
ck "⑯ 单测（S2A_TEST_ROOT）里没给 S2A_MEM_DIR：同样退出 ${grc}（期望 125）、缺省目录没建" '[ "$grc" = 125 ] && [ ! -e "$G/ran" ] && [ ! -e "$G/home/.s2arm" ]'
GATE_IN_STEP=1 S2A_MEM_DIR=$G/mem S2A_MEM_LOCK=$G/mem.flock bash "$H/tools/mem_admit.sh" dsh fixture -- touch "$G/ran" > /dev/null 2>&1; grc=$?
ck "⑯ 显式给了 S2A_MEM_DIR 照常放行（退出 ${grc}）" '[ "$grc" = 0 ] && [ -e "$G/ran" ]'

# ⑨ 核数：上限 4 核、内存 10 GB。h（1 GB、3 核）占着；x（1 GB、2 核）内存够（2 ≤ 10）、核不够（3 + 2 > 4）→ 排队；h 结束后放行
K=$T/core; mkdir -p "$K/mem"; export S2A_MEM_DIR=$K/mem S2A_MEM_LOCK=$K/mem.flock S2A_MEM_SEED=$K/seed.tsv S2A_MEM_CORES_MAX=4
printf 'dsh\th\t1\t估\ndsh\tx\t1\t估\n' > "$K/seed.tsv"
bash "$H/tools/mem_admit.sh" dsh h --cores 3 -- bash -c 'touch "$1/h.in"; while [ ! -e "$1/h.go" ] && kill -0 '"$$"' 2> /dev/null; do sleep 0.1; done' _ "$K" > /dev/null 2>&1 & waitf "$K/h.in"
bash "$H/tools/mem_admit.sh" dsh x --cores 2 -- bash -c 'touch "$1/x.in"; while [ ! -e "$1/x.go" ] && kill -0 '"$$"' 2> /dev/null; do sleep 0.1; done' _ "$K" > /dev/null 2>&1 &
waitg "$K/mem/admit.log" '【排队】mem_admit dsh/x'; sleep 0.5
ck "⑨ 内存够（1 + 1 ≤ 10）但核不够（3 + 2 > 4）：x 没起，排队行写明差 1 核" '[ ! -e "$K/x.in" ] && grep "【排队】mem_admit dsh/x" "$K/mem/admit.log" | grep -q "差 1 核"'
touch "$K/h.go"; waitf "$K/x.in" 300
ck "⑨ h 结束后 x 放行（0 + 2 ≤ 4）" '[ -e "$K/x.in" ]'
touch "$K/x.go"; wait; unset S2A_MEM_CORES_MAX

# ⑬ 借键不污染实测（11-04 Switch2 线借 dsh/memrt_host0 跑别的命令，实测 0.4 覆盖了 5.7）：表里 kb 5.7、签名「bash own.sh」；
#   本次命令「python3 -c import time; time.sleep(0.5)」（签名 = 前 3 参数去目录）实测约 0.1 → kb 不往低改、仍 5.7 签名不变，admit.log 有【黄】；
#   kc 签名与本次相同 → 按实测往低改；kd 旧行没签名 → 值不降（5.7）、签名记成本次
W=$T/sig; mkdir -p "$W/mem"; export S2A_MEM_DIR=$W/mem S2A_MEM_LOCK=$W/mem.flock
printf 'dsh\tkb\t5.7\t实\t2026-11-04\tbash own.sh\ndsh\tkc\t5.7\t实\t2026-11-04\tpython3 -c import time; time.sleep(0.5)\ndsh\tkd\t5.7\t实\t2026-11-04\n' > "$W/mem/peak.tsv"
for k in kb kc kd; do bash "$H/tools/mem_admit.sh" dsh $k -- python3 -c 'import time; time.sleep(0.5)' > /dev/null 2>&1; done
row() { awk -F'\t' -v k="$1" '$2==k{print $3 "|" $6}' "$W/mem/peak.tsv"; }
ck "⑬ 借键（签名不同）不往低改：kb「$(row kb)」= 5.7|bash own.sh，且有【黄】行" '[ "$(row kb)" = "5.7|bash own.sh" ] && grep -q "【黄】mem_admit dsh/kb：本次命令「python3 -c import time; time.sleep(0.5)」" "$W/mem/admit.log"'
ck "⑬ 同一命令按实测往低改：kc「$(row kc)」< 5.7" 'awk -v v="$(row kc)" "BEGIN{split(v, a, \"|\"); exit !(a[1]+0 > 0 && a[1]+0 < 5.7 && a[2] == \"python3 -c import time; time.sleep(0.5)\")}"'
ck "⑬ 旧行没签名：值不降、记上本次签名：kd「$(row kd)」= 5.7|python3 -c import time; time.sleep(0.5)" '[ "$(row kd)" = "5.7|python3 -c import time; time.sleep(0.5)" ]'

# ㉓ 按此刻可用内存放（S2A_MEM_AVAIL_MB，与 tools/cores.sh 同一个变量）：上限 10 GB，可用 4096 MB = 4.0 GB。
#   a（估 4）账空放行；d（估 2）：账内预留 4 + 2 = 6 ≤ 10，但 a 至今只用了几 MB，没用到的预留约 3.9 GB，2 + 3.9 > 4.0 → 排队，排队行写明可用 4.0 GB；a 结束后 d 放行
#   负控：同样两单、可用给 100000 MB → d 直接放行（证明挡住它的是可用内存这一条）。旧码不认 S2A_MEM_AVAIL_MB、不看可用：d 直接放行（本项红）
V=$T/avail; mkdir -p "$V"; export S2A_MEM_DIR=$V/mem S2A_MEM_LOCK=$V/mem.flock S2A_MEM_SEED=$T/seed.tsv
( unset S2A_MEM_AVAIL_GB; export S2A_MEM_AVAIL_MB=4096; hold "$V" a; waitf "$V/a.in"; hold "$V" d; waitg "$V/mem/admit.log" '【排队】mem_admit dsh/d'; sleep 0.5
  ck "㉓ 可用 4096 MB：a（4）放行，d（2）因没用到的预留 + 本单 > 可用排队、没起" '[ -e "$V/a.in" ] && [ ! -e "$V/d.in" ] && grep "【排队】mem_admit dsh/d" "$V/mem/admit.log" | grep -q "本机此刻可用 4.0 GB"'
  touch "$V/a.go"; waitf "$V/d.in" 300
  ck "㉓ a 结束后 d 放行" '[ -e "$V/d.in" ]'
  touch "$V/d.go"; wait; exit $bad ) || bad=1
V=$T/avail_neg; mkdir -p "$V"; export S2A_MEM_DIR=$V/mem S2A_MEM_LOCK=$V/mem.flock
( unset S2A_MEM_AVAIL_GB; export S2A_MEM_AVAIL_MB=100000; hold "$V" a; waitf "$V/a.in"; hold "$V" d; waitf "$V/d.in" 300
  ck "㉓ 负控：可用 100000 MB 时 d 不排队直接放行" '[ -e "$V/d.in" ]'
  touch "$V/a.go" "$V/d.go"; wait; exit $bad ) || bad=1

# ⑪ dsh_batch.py build 直接调用（不经 refresh.sh）：DSH_BATCH_CMD 换成占着不走的桩；期望账本有且只有一行 use，类别/键 = dsh/g1、第 6 列核数 = 3（-j 3）
D=$T/dshb; mkdir -p "$D/mem"; export S2A_MEM_DIR=$D/mem S2A_MEM_LOCK=$D/mem.flock S2A_MEM_SEED=$T/seed.tsv
DSH_BATCH_FP=x DSH_BATCH_CMD="[\"bash\", \"-c\", \"touch $D/d.in; while [ ! -e $D/d.go ]; do sleep 0.1; done\", \"_\"]" \
  python3 "$H/translator/dsh_batch.py" build --game g1 -j 3 > "$D/out" 2>&1 & waitf "$D/d.in" 300
ck "⑪ dsh_batch.py build 直调进账：use 行 1 条、dsh/g1、3 核（实 $(cat "$D"/mem/use.* 2> /dev/null | cut -f3,4,6 | tr '\t\n' ' ')）" '[ "$(cat "$D"/mem/use.* 2> /dev/null | wc -l | tr -d " ")" = 1 ] && [ "$(cat "$D"/mem/use.* | cut -f3,4,6 | tr "\t" " ")" = "dsh g1 3" ]'
touch "$D/d.go"; wait
# ④ 负控：去掉准入，第 3 个不排队
N=$T/off; mkdir -p "$N"; export S2A_MEM_DIR=$N/mem S2A_MEM_LOCK=$N/mem.flock S2A_MEM_ADMIT=0
hold "$N" a; waitf "$N/a.in"; hold "$N" b; waitf "$N/b.in"; hold "$N" c; waitf "$N/c.in" 300
ck "④ 负控（S2A_MEM_ADMIT=0）：第 3 个直接起 = 用例 ① 的「被挡」在无准入时红" '[ -e "$N/c.in" ] && [ ! -e "$N/mem/admit.log" ]'
touch "$N/a.go" "$N/b.go" "$N/c.go"; wait
# ⑩ 夹具随测试退出
R=$T/reap; mkdir -p "$R"; export S2A_MEM_DIR=$T/reap_mem S2A_MEM_LOCK=$T/reap_mem.flock S2A_MEM_ADMIT=1; mkdir -p "$S2A_MEM_DIR"
hold "$R" x; hp=$!; waitf "$R/x.in"; fp=$(pgrep -f "^bash -c touch .* $R x$" | head -1)
rm -rf "$R"; for i in $(seq 1 30); do kill -0 "$hp" 2> /dev/null || { [ -n "$fp" ] && kill -0 "$fp" 2> /dev/null; } || break; sleep 0.1; done
ck "⑩ 测试目录删掉后夹具（pid ${fp:-没找到}）与 mem_admit（pid ${hp}）3 秒内都退出" '[ -n "$fp" ] && ! kill -0 "$fp" 2> /dev/null && ! kill -0 "$hp" 2> /dev/null'
# ⑩b 测试进程被 KILL：另起一个 bash 当「测试」，在里面起夹具，再 KILL 它（trap 不跑、目录留着）
R=$T/reapk; mkdir -p "$R"
bash -c "H='$H'; $(declare -f hold); hold '$R' y; sleep 60" & sp=$!; waitf "$R/y.in"; fp=$(pgrep -f "^bash -c touch .* $R y$" | head -1)
kill -KILL $sp; for i in $(seq 1 30); do { [ -n "$fp" ] && kill -0 "$fp" 2> /dev/null; } || break; sleep 0.1; done
ck "⑩b 测试进程被 KILL、目录还在 → 夹具（pid ${fp:-没找到}）3 秒内退出" '[ -n "$fp" ] && [ -d "$R" ] && ! kill -0 "$fp" 2> /dev/null'
# ㉔ 账锁一时轮不到不是故障（#2241：十几单同时排队、各自每 2 秒进锁判账，有一单连续 60 秒没抢到账锁就报 125 不起）：
#   外面占住账锁 3 秒（S2A_MEM_LOCK_S=1 = 每次只等 1 秒），mem_admit 应接着排、锁放了就放行，命令照常起；期望手算：等待 ≥ 2 秒、退出 0、命令跑过
K=$T/lockbusy; mkdir -p "$K"; export S2A_MEM_DIR=$K/mem S2A_MEM_LOCK=$K/mem.flock
sleep 30 & kp=$!; kh=$(python3 "$H/tools/flock_hold.py" "$K/mem.flock" "$kp" take lockbusy_test)
( sleep 3; kill "$kh" 2> /dev/null ) & t0=$SECONDS
S2A_MEM_LOCK_S=1 bash "$H/tools/mem_admit.sh" dsh d -- touch "$K/ran" > /dev/null 2> "$K/err"; krc=$?; kdt=$((SECONDS - t0)); kill $kp 2> /dev/null
ck "㉔ 账锁被占 3 秒（每次只等 1 秒）：接着排、锁放后放行（退出 ${krc}、等了 ${kdt} 秒、命令$([ -e "$K/ran" ] && echo 跑过 || echo 没跑)）" '[ $krc = 0 ] && [ -e "$K/ran" ] && [ $kdt -ge 2 ]'
ck "㉔ 轮不到账锁时排队行写明原因（账锁轮不到），不报红" 'grep -q "【排队】mem_admit dsh/d：账锁" "$K/mem/admit.log" && ! grep -q "【红】" "$K/err"'
[ $bad = 0 ] && echo "✓ mem_admit_test：全部通过" || { echo "✗ mem_admit_test：有不通"; exit 1; }
