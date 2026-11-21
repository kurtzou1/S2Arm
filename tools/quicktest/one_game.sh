#!/bin/bash
# 快测单款：一条命令回答「这款游戏零配置能不能起来、第一个失败点在哪」，典型 4–5 分钟（维护方 10-26 普查 151 款的中位：解包 93 秒、精简出包 24 秒、Mac 局 102 秒）。
#   bash tools/quicktest/one_game.sh <源包文件夹 | 解包目录> [<输出目录>]
#   给解包目录（有 exefs/main 与 unpack.tsv，pack/stages/unpack.sh extract 的产物）就跳过 ① 解包：远端机没有 prod.keys，
#   普查（tools/census/census.sh）本机解包后把解包目录同步到 gate-host / Spare-host，出包与跑局在那边从这里接着做
#   ① 解包（pack/stages/unpack.sh extract，用你自己的 prod.keys）→ ② 出包（oneclick --from-extract --target mac：改写 / 系统数据 / 追加内容 / RomFS 索引 /
#   直连配置推导 / 抽取 / 直连库，不给玩家出包）→ ③ Mac 零配置直连局（不设 S2A_GFX，自动玩家开）≤ QT_RUN_S 秒，崩了同一产物根自动补一局
#   → ④ tools/quicktest/verdict.py 定性 → 往 <输出目录>/结果.tsv 追加一行，并打一行摘要。
#   Mac 局走 维护方 entry_check.sh（${S2A_PRIVATE_TOOLS}）（与能力关 / 开对照局 tools/ab_pair.sh 同一入口：同存档 / 进局路线挑选、独占局槽、宿主局外先编），
#   末列「进局」= 自动玩家到 MARK（游戏场景里可操作）。只有直连（11-07 拆通用模式：精简档 --lite、QT_DUAL=0 通用局两条一并删）：
#   根里没出成本链直连库就记直连失败。
# 输出目录缺省 ./build/quicktest；每款工作目录 <输出目录>/work/<名>，跑完删掉（QT_KEEP=1 留下，之后可拿产物根 roots/ 里指针文件 <款>@现行 记的版本目录直接起局复现、不用再出包）；
#   日志精简留在 <输出目录>/logs/<名>/（unpack / oneclick / refresh 的红黄行、host.log（超 2 MB 留头尾 + 中间判据关键行，tools/quicktest/keep_log.sh）、ap_mark / ap_mid / ap_end、最后一张视觉截图 last_vision.png）。
# 环境：QT_RUN_S 局秒数（缺省 100）；QT_RUN_EXTEND 局时顺延上限（缺省 300 秒：自动玩家等视觉模型的秒数不算局时，宿主到点按它顺延，局墙钟同步加）；QT_KEYS prod.keys（缺省 ~/.switch/prod.keys）；QT_MEM_MB 宿主常驻上限（缺省 7680 MB = 目标机 17 Pro Max 单进程上限 8191 MB − 0.5 GB 余量；来源：11-06 测试设备1 六局真机 host.log「进程足迹 + 系统给本进程剩余」恒 8191 MB；旧 5120 无依据作废，维护者 11-06 定）；QT_KEEP=1 留产物；
#   QT_TITLE_ID=<16 位程序号>：文件夹里不止一个本体（游戏 + 同系列小工具）时指定测哪一款（缺省按大小自动认主游戏，判不出就报红，10-26 #456）；
#   S2A_SLOT_RUN（只在我方机器上设）：② 出包段前加「$S2A_SLOT_RUN <QT_SLOT 前缀，缺省 quicktest>-<名> --」取本机机器槽；没设就直接跑；
#   QT_UNPACK_S=<秒>：源是解包目录时，结果里记的解包秒（普查本机解包、远端接着出包时由 census.sh 带来）；
#   QT_NAME=<名> 工作 / 日志目录名（缺省取源文件夹名）；QT_UNPACK_ONLY=1 只做 ① 解包：失败照常记一行、退出 1，成功不记行、
#   留下 <输出目录>/work/<名>/extract、退出 0（解包失败的归类只在这里一处）。
#   QT_PACK_ONLY=1 做完 ① ② 就停：失败照常记一行、退出 1；成功不记行、删中间的 extract、在 <输出目录>/work/<名> 写 .qt_packed
#   （款 / 程序号 / 解包秒 / 出包秒）、退出 0。源给这样一个已出包的工作目录（有 .qt_packed）= 只跑局：跳过 ① ②，起局、定性、记一行
#   ——普查本机出包（密钥在本机、与正式包分开走资源），工作目录同步到 gate-host / Spare-host 只跑 Mac 局（tools/census/census.sh）。
# 退出码：0 = 通过；1 = 失败（结论与第一失败点见摘要）；2 = 参数问题。
set -u
SRC=${1:-}; [ -n "$SRC" ] && [ -d "$SRC" ] || { echo "用法：bash tools/quicktest/one_game.sh <源包文件夹 | 解包目录> [<输出目录>]"; exit 2; }
# 源在 exfat 机械盘（单读者）且我方读锁脚本存在 → 默认走读锁（S2A_HDD_READ 显式设了含置空就照它）：快测直读与普查拷贝、别线解包并发抢磁头，实测三读者时 10 MB 小读 15 秒读不完（11-02）。读锁脚本不存在（贡献者机器）= 不变
if [ -z "${S2A_HDD_READ+x}" ] && [ -x "${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/hdd_read.sh" ] && mount | grep -q "^$(df -P "$SRC" 2> /dev/null | awk 'NR==2{print $1}') on .*(exfat"; then export S2A_HDD_READ=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/hdd_read.sh; fi
FX=; [ -f "$SRC/exefs/main" ] && [ -f "$SRC/unpack.tsv" ] && FX=$(cd "$SRC" && pwd -P)
PK=; [ -f "$SRC/.qt_packed" ] && PK=$(cd "$SRC" && pwd -P)   # 只跑局：源是 QT_PACK_ONLY 留下的工作目录
ROOT=$(cd "$(dirname "$0")/../.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
[ ! -f "$ROOT/tools/data_vol_check.sh" ] || "${BASH:-/bin/bash}" "$ROOT/tools/data_vol_check.sh" || exit 125   # 同 oneclick：数据卷没挂载 / 被真目录替换就明确报错
# 整款（出包 + Mac 局）在本机算一道（tools/cores.sh s2a_lanes）：同机别的出包按真实在跑道数分核，跑局期间也占一份（11-01 普查远端撤掉固定 S2A_JOBS=2）
source "$ROOT/tools/cores.sh"; export S2A_LANE_PID=$$; s2a_lanes > /dev/null
B=${2:-$ROOT/build/quicktest}; mkdir -p "$B/logs" "$B/work"; B=$(cd "$B" && pwd)
N=${QT_NAME:-$(basename "$SRC" | tr -c 'A-Za-z0-9_\n-' '_' | cut -c1-40)}; O=${PK:-$B/work/$N}; KL=$B/logs/$N; RUN_S=${QT_RUN_S:-100}
# 删工作目录统一走 pack/roots.sh 的 _root_rm：产物根的 RomFS 共享存储（roots/.romfs_store/）整棵只读，裸 rm -rf 删不掉、逐文件报 Permission denied（11-04 普查 c1104_r2 每款漏 2–6 GB、run.out 灌到 13 MB）；
#   删不掉报红一行（路径 + 报错条数 + 首条原因），rm 的逐文件报错不进日志
source "$ROOT/pack/roots.sh"
qt_rm() { _root_rm_red "$1" 快测; }
[ -n "$PK" ] || { qt_rm "$O"; mkdir -p "$O"; touch "$O/.quicktest"; }; mkdir -p "$KL"
T=$B/结果.tsv
[ -f "$T" ] || printf '源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n' > "$T"
cd "$ROOT" || exit 2
G=-; PID=-; US=0; PS=0; MS=0; V=""
red1() { grep -a -h -E "【红】|🔴" "$@" 2> /dev/null | tail -1 | perl -CSD -ne 'chomp; print substr($_,0,200)' | tr '\t' ' '; }
# ① 解包（给的是解包目录就跳过）
t0=$(date +%s); X=${FX:-$O/extract}
if [ -n "$PK" ]; then IFS=$'\t' read -r G PID US0 PS < "$PK/.qt_packed"; urc=0
elif [ -n "$FX" ]; then urc=0; else
  bash pack/stages/unpack.sh extract --src "$SRC" --out "$X" --keys "${QT_KEYS:-$HOME/.switch/prod.keys}" --log "$KL/unpack.log" ${QT_TITLE_ID:+--title-id "$QT_TITLE_ID"} > "$KL/unpack.out" 2>&1; urc=$?
fi
[ -n "$FX" ] && [ -n "${QT_UNPACK_S:-}" ] && US0=$QT_UNPACK_S   # 源是别处解好的解包目录（普查本机解包、远端出包）：解包秒由调用方带来
US=${US0:-$(( $(date +%s) - t0 ))}; prc=$urc
[ "${QT_UNPACK_ONLY:-0}" = 1 ] && [ $urc = 0 ] && { echo "$US" > "$KL/unpack_s"; echo "快测 ${N}：解包好 ${US}s → $X"; exit 0; }
# ② 出包（Mac 目标；只跑局时跳过）
if [ $urc = 0 ] && [ -z "$PK" ]; then
  t0=$(date +%s); : > "$KL/.pack_start"   # 出包开始的标记：比它新的直连编不过清单才是这次的
  ${S2A_SLOT_RUN:+$S2A_SLOT_RUN "${QT_SLOT:-quicktest}-$N" --} bash pack/oneclick/oneclick.sh --from-extract "$X" --target mac --out "$O" > "$KL/oneclick.log" 2>&1; prc=$?
  PS=$(( $(date +%s) - t0 ))
  for f in refresh.log unpack.log seed.log; do [ -f "$O/logs/$f" ] && grep -a -E "【红】|【黄】|🔴" "$O/logs/$f" | head -40 > "$KL/$f.red"; done
  cp "$O/logs/timing.tsv" "$KL/" 2> /dev/null
  G=$(grep -a -o -m1 "款 [A-Za-z0-9_-]*" "$KL/oneclick.log" | cut -d' ' -f2); G=${G:--}
  PID=$(grep -a -m1 "① 认出" "$KL/oneclick.log" | grep -o "程序号 [0-9A-Fa-f]\{16\}" | cut -d' ' -f2); PID=${PID:--}
  # 直连编不过的键清单（direct_lib.py 写进直连缓存 logs/）：拷进局日志，普查总表「直连编不过」列读它；这次出包之前写的旧清单不拷
  DCL=${S2A_DIRECT_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/direct/$(echo "${PID:-}" | tr a-z A-Z)}/logs/direct_fail.log
  [ -f "$DCL" ] && [ "$DCL" -nt "$KL/.pack_start" ] && cp "$DCL" "$KL/direct_fail.tsv"   # -nt 是 bash 内建，Linux 同样可用（不用 macOS 的 stat -f）
  # 出库日志（汇总行：着色器缓存命中、#1429 验收的「ast mem order kept」等）：同样只拷这次出包写的；直连缓存可被淘汰、远端缓存不拉回，局日志里这份才留得住
  DBL=$(dirname "$DCL")/build.log; [ -f "$DBL" ] && [ "$DBL" -nt "$KL/.pack_start" ] && cp "$DBL" "$KL/direct_build.log"
fi
# 出包段结束：本道登记标「mac」，之后同机别的出包分核时不再算这一道（跑局吃的 CPU 由 cores.sh 按实际占用扣，tools/cores.sh s2a_lanes）
echo mac > "${S2A_LANE_DIR:-$HOME/.s2a/lanes}/$$" 2> /dev/null || true
if [ "${QT_PACK_ONLY:-0}" = 1 ] && [ $urc = 0 ] && [ $prc = 0 ]; then
  printf '%s\t%s\t%s\t%s\n' "$G" "$PID" "$US" "$PS" > "$O/.qt_packed"; [ -n "$FX" ] || { [ "${QT_KEEP_EXEFS:-0}" = 1 ] && cp -R "$O/extract/exefs" "$KL/exefs" 2> /dev/null; rm -rf "$O/extract"; }   # QT_KEEP_EXEFS=1（普查 Spare-host 本地化）：出包后删解包目录前把 exefs（几十 MB）留进日志目录，api_census 静态读用
  echo "快测 ${N}：出包好 ${G}（${PID}）解包 ${US}s 出包 ${PS}s → $O"; exit 0
fi
if [ $urc != 0 ]; then
  m=$(red1 "$KL/unpack.out"); [ -n "$m" ] || m=$(tail -1 "$KL/unpack.out")
  # 原件探测出错（pack/srcs.sh src_ids：nx_unpack --nacp-only 非 0，没有 .NET 运行时 / 缺密钥 / 读盘出错）是机器原因：记「未判」（普查下次重排），
  #   第一个失败点就是那行原话（11-05 after_r2 v4：探测全挂，15 款被记成游戏「失败 解包」）
  pm=$(grep -a -m1 '机器原因：原件探测出错' "$KL/unpack.out" | tr '\t' ' '); pm=${pm#*【红】}
  if [ -n "$pm" ]; then V="未判	${pm:0:200}	-	-	-	-	-	-	${m:--}	-"
  else
    case $m in *32\ 位*) F=不支持：32位;; *哈希*|*[Hh]ash*) F=解包：源文件校验不过（先换一份完整原件再判）;; *) F=解包;; esac
    V="失败	$F	-	-	-	-	-	-	${m:--}	-"
  fi
elif [ $prc != 0 ]; then
  m=$(red1 "$KL/oneclick.log")
  case $m in
    *32\ 位*) F=不支持：32位;;
    *刷新停在*) case $m in *直连单轨停在*|*直连缺口*) F=出包：直连缺口;; *改写*|*推导*) F=出包：改写;; *着色器*) F=出包：着色器;; *系统数据*) F=出包：系统数据;; *) F=出包：刷新其它;; esac;;
    *) F=出包;;
  esac
  V="失败	$F	-	-	-	-	-	-	${m:--}	-"
else
  # 动作环拉到局时长（S2A_AP_LOOP_S）：到 MARK 后接着玩到 RUN_S 才收局，局内 0 崩照局时长判（缺省动作环 60 秒跑完就收局）
  # 进局档位（10-30 维护者 S 级 ①）：docs/名单_进局档位.tsv 登记过主机档（docked）的款直接主机档起局，其余掌机档；不全局切
  DOCK=handheld; [ "$PID" != - ] && awk -F'\t' -v p="$PID" '$1 == p && $2 == "docked" {f = 1} END {exit !f}' docs/名单_进局档位.tsv 2> /dev/null && DOCK=docked
  mac_once() {   # mac_once <局目录> <日志后缀> [<档位>]：维护方 entry_check.sh（${S2A_PRIVATE_TOOLS}） 起局，局本身秒数记进 MS；直连单轨（10-30 维护者）：根里没有本链直连库（退出 5）记直连失败、不补跑通用局
    local t1 erc; t1=$(date +%s)
    env -u S2A_GFX ${MENV[@]+"${MENV[@]}"} S2A_ROOTS="$O/roots" S2A_LOOP_SEC="$RUN_S" S2A_RUN_EXTEND_MAX=${QT_RUN_EXTEND:-300} S2A_LOOP_CAP=$((RUN_S + 35 + ${QT_RUN_EXTEND:-300})) S2A_AP_LOOP_S="$RUN_S" S2A_MEM_MB=${QT_MEM_MB:-7680} \
      bash "${S2A_PRIVATE_TOOLS:?Mac 局要设 S2A_PRIVATE_TOOLS（entry_check.sh 是维护方工具）}/entry_check.sh" "$G" "${3:-$DOCK}" "$1" > "$KL/entry$2.out" 2>&1; erc=$?
    [ $erc = 5 ] && { cp "$KL/entry$2.out" "$KL/entry$2.direct_missing"; echo "【红】$G 直连局起不来：根里没有本链直连库（只有直连）" >> "$KL/entry$2.out"; }
    MS=$(( $(date +%s) - t1 ))
    cp "$1/run.out" "$KL/run_mac$2.out" 2> /dev/null
    [ -f "$1/host.log" ] && bash tools/quicktest/keep_log.sh "$1/host.log" "$KL/host$2.log"   # 超 2 MB 留头尾 + 中间的判据关键行（keep_log.sh）
    cp "$1"/shots/fit_*.png "$KL/" 2> /dev/null   # 满屏判据存的红帧 / 留黑边段第一帧（分层看图用；工作目录跑完会删）
    cp "$1/ap_mark.png" "$KL/ap_mark$2.png" 2> /dev/null; cp "$1/ap_end.png" "$KL/ap_end$2.png" 2> /dev/null; cp "$1/ap_summary.json" "$KL/ap_summary$2.json" 2> /dev/null
    cp "$1/ap_mid.png" "$KL/ap_mid$2.png" 2> /dev/null
    cp "$1/frames.tsv" "$KL/frames$2.tsv" 2> /dev/null   # 每帧读数：普查五问（packq/bin/autorun.py collect-batch → quality_check）的帧率 / 直连列要它，没带回时两列只能记没数据（10-31 c1031v Slay 到了 MARK 仍「0 帧」）
    # 最后一张视觉截图：ap_end.png 是收局时才存的，收局崩了就没有（10-29 普查），远端局目录跑完即清，不留它就看不到停在哪一页
    local lv; lv=$(ls -t "$1"/vision/*.png 2> /dev/null | head -1); [ -n "$lv" ] && cp "$lv" "$KL/last_vision$2.png"; }
  mac_once "$O/run" ""; MS1=$MS
  if [ -f "$KL/entry.direct_missing" ]; then   # 直连单轨（10-30 维护者）：根里没有本链直连库 = 直连这条链路本身失败，记「失败」、第一失败点写明（不是「未判」，也不补跑通用局）
    V="失败	直连库没出（根里没有本链直连库）	-	-	-	-	-	-	直连单轨：不补跑通用局	-"
  elif [ ! -s "$O/run/host.log" ]; then   # 局没起（entry_check 退出 3：独占局槽排队超时 / 宿主构建失败）：不是游戏的失败点，记「未判」
    m=$(grep -a -h -E "🔴|🟡" "$KL/entry.out" 2> /dev/null | tail -1 | perl -CSD -ne 'chomp; print substr($_,0,200)' | tr '\t' ' ')
    V="未判	局没起	-	-	-	-	-	-	${m:--}	-"
  else
    V=$("$PY" tools/quicktest/verdict.py "$O/run")
    case $(echo "$V" | cut -f8) in 否|收局|-) ;; *) mac_once "$O/run2" _2; MS=$MS1; V=$("$PY" tools/quicktest/verdict.py "$O/run" "$O/run2");; esac   # 局内崩了才补跑（第 8 列崩溃；收局崩溃不补跑）
    # 点触卡页换主机档（10-30 维护者 S 级 ①：掌机档要点触的页，自动玩家点了没反应；主机档游戏改走按键）：掌机档通过但没进局、
    #   verdict.py --touch-stuck 判点触卡页 → 同一产物根 S2A_DOCKED=1 再跑一局。进了局就用主机档这局（日志换成主名、掌机档那份改 _h 后缀），
    #   写 .进局档位（census.py dock 登记进 docs/名单_进局档位.tsv，下次直接主机档起局）；主机档也没进局照记掌机档结果，写 .主机档复跑 留原因
    if [ "$DOCK" = handheld ] && [ "$(echo "$V" | cut -f1)" = 通过 ] && [ "$(echo "$V" | cut -f10)" != 是 ] && TW=$("$PY" tools/quicktest/verdict.py --touch-stuck "$O/run"); then
      mac_once "$O/run_d" _d docked; MS=$((MS1 + MS)); VD=$("$PY" tools/quicktest/verdict.py "$O/run_d")
      if [ "$(echo "$VD" | cut -f1)" = 通过 ] && [ "$(echo "$VD" | cut -f10)" = 是 ]; then
        for f in "$KL"/*_d.* "$KL"/*_2.*; do [ -e "$f" ] || continue; case $f in *_d.*) ;; *) mv "$f" "${f%_2.*}_h2.${f##*_2.}"; continue;; esac
          b=${f%_d.*}; e=${f##*_d.}; [ -e "$b.$e" ] && mv "$b.$e" "${b}_h.$e"; mv "$f" "$b.$e"; done
        V=$VD; printf 'docked\t%s\n' "$TW" > "$KL/.进局档位"
      else printf '主机档也没进局（%s）\t%s\n' "$(echo "$VD" | cut -f1-2 | tr '\t' ' ')" "$TW" > "$KL/.主机档复跑"; fi
    fi
    # 原生档（11-02 维护者：分清是游戏本身跑不起来，还是满屏 / 60 帧弄坏的）：QT_NATIVE_TIER=1 且局内失败（崩溃类）或不崩但首帧没出图 →
    #   同一产物根再跑一局能力全关（满屏关、60 帧关、不做 60 帧 A/B = 16:9 + 原生帧率；只换运行时开关，不重新出包），
    #   结论写 logs/<名>/.原生档（结论 / 第一个失败点 / 首帧 / 进局，tab 分隔），普查总表「原生档」列读它；Mac局秒只记主局。出包失败走不到这里（出包和能力无关）
    if [ "${QT_NATIVE_TIER:-0}" = 1 ] && { [ "$(echo "$V" | cut -f1)" = 失败 ] || [ "$(echo "$V" | cut -f3)" != 是 ]; }; then
      MS0=$MS; MENV=(-u S2A_AP_SPEED -u S2A_FPS_AB S2A_FPS60=0 S2A_WIDEN_CAPS=0 S2A_WIDEN_VERIFIED=0); mac_once "$O/run_n" _n; MENV=(); MS=$MS0
      if [ -s "$O/run_n/host.log" ]; then VN=$("$PY" tools/quicktest/verdict.py "$O/run_n"); printf '%s\t%s\t%s\t%s\n' "$(echo "$VN" | cut -f1)" "$(echo "$VN" | cut -f2)" "$(echo "$VN" | cut -f3)" "$(echo "$VN" | cut -f10)" > "$KL/.原生档"
      else printf '未判\t局没起\t-\t-\n' > "$KL/.原生档"; fi
    fi
  fi
fi
# 留现场（维护者 10-29：Servonauts 的 Break 原生层要复现，局目录却已清）：失败或没进局 → 局目录（含补跑局）整份拷进日志目录
#   （截图 / 自动玩家轨迹 / frames.tsv / ryu 等，十几 MB；根快照 in_snap 局后已删）；出包失败 → 完整出包日志。通过且进局的照旧不留
if [ "$(echo "$V" | cut -f1)" != 通过 ] || [ "$(echo "$V" | cut -f10)" != 是 ]; then
  for r in run run2 run_d run_n; do [ -d "$O/$r" ] && { mkdir -p "$KL/$r"; cp -R "$O/$r/." "$KL/$r/" 2> /dev/null; rm -rf "$KL/$r/in_snap"; }; done
  [ $prc != 0 ] && [ -d "$O/logs" ] && cp -R "$O/logs" "$KL/pack_logs" 2> /dev/null
  [ $prc != 0 ] && [ -d "$O/roots/.failed" ] && cp -R "$O/roots/.failed" "$KL/pack_failed" 2> /dev/null   # 阶段失败日志（改写 / 着色器 / 直连库 / ipa，红行里的路径随工作目录一起删；10-29 Minecraft 改写 PFRW 失败日志没留住）
fi
# 留证（维护者 10-29：太鼓直连黑屏要查为什么只抽到 70 条着色器，普查却已清掉中间产物）：直连异常 / 首帧没出图 / GPU 类 / 出包失败 →
#   出包日志 + 抽取目录 split/ 下的 .log / .tsv（着色器映射表等清单，不含着色器本体）拷进日志目录、随结果拉回，写 .留证（原因一行）；
#   普查据此把本机那份解包目录留到批次收尾（tools/census/census.sh）。其余失败照旧只留局目录
case $(echo "$V" | cut -f2) in 机器原因*) EVID=0;; 直连异常*|首帧*|*GPU*|出包*) EVID=1;; *) EVID=$([ $prc != 0 ] && echo 1 || echo 0);; esac   # 机器原因的未判不留证（同 census.sh）
if [ "$EVID" = 1 ]; then
  [ -d "$O/logs" ] && [ ! -d "$KL/pack_logs" ] && cp -R "$O/logs" "$KL/pack_logs" 2> /dev/null
  # split/ 在哪由出包流程定（本机流程 <工作目录>/extract/split；源给解包目录时可能在源里）：按 shader_map.tsv 找，找到几处拷几处
  find "$O" ${FX:+"$FX"} -maxdepth 4 -name shader_map.tsv 2> /dev/null | while read -r sm; do d=$(dirname "$sm"); t="$KL/split/$(basename "$(dirname "$d")")_$(basename "$d")"
    mkdir -p "$t"; find "$d" -maxdepth 1 -type f \( -name '*.log' -o -name '*.tsv' \) -size -20M -exec cp {} "$t/" \; 2> /dev/null; done
  echo "$(echo "$V" | cut -f2)" > "$KL/.留证"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SRC" "$G" "$PID" "$(echo "$V" | cut -f1-2)" "$US" "$PS" "$MS" "$(echo "$V" | cut -f3-)" >> "$T"
VERD=$(echo "$V" | cut -f1); FAIL=$(echo "$V" | cut -f2)
echo "快测 ${N}：${G}（${PID}）$VERD $FAIL ｜解包 ${US}s 出包 ${PS}s Mac局 ${MS}s ｜首帧 $(echo "$V" | cut -f3) 帧 $(echo "$V" | cut -f5) ｜日志 $KL"
[ "$VERD" = 通过 ] && [ ! -f "$KL/ap_mark.png" ] && echo "  提示：起来了但自动玩家没到可操作场景（没有 ap_mark.png），看 $KL/ap_end.png 卡在哪一页"
case $FAIL in
  *客体代码*) echo "  下一步：S2A_DIAG_DUMP=<模块>+0x<偏移> 在崩点前读寄存器（docs/快速测试与精修流程.md 第 3 节），或 S2A_IPC_RECORD 录调用流和 Ryujinx 对拍";;
  *Break*) echo "  下一步：游戏自己报错退出，多半是某个系统服务回答不对：S2A_IPC_RECORD 录两边调用流，tools/ipc_diff.py 找第一处分歧";;
  首帧) echo "  下一步：看 host.log 的【红】行与线程现场（S2A_STALL_DUMP_S），没出图先查是不是卡在等服务 / 等 GPU";;
esac
[ "${QT_KEEP:-0}" = 1 ] || { [ -f "$O/.quicktest" ] && qt_rm "$O"; }
[ "$VERD" = 通过 ]
