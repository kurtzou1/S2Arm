#!/bin/bash
# 门禁路由：runtime/ graphics/ compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures/ tests/autoplay/ tests/build.mk Makefile */build.mk
# 门禁本机：vawin t_vawin：gate-host 内核占不到整块 64 GB 地址窗口（窗口内已有别人的映射 24 GB）
# 原生层门禁钩子（tools/gate.sh 在仓库根调）：宿主能构建 + 原生层单测全绿。末行「期望 → 真结果」。
# 子项键（tools/gate.sh 分派 gate-host 用，见本文件头「# 门禁本机：」）：runtime/tests 或 graphics/nvn/tests 下 C / Objective-C 单测的键（如 vawin / nvn_copy_stride），须有 native-test-<键> 构建目标。
#   GATE_SKIP="<键…>"：不跑这几组（别处另跑），应跑组数相应减少、末行写明；GATE_ONLY="<键…>"：只编跑这几组单测，不构建宿主。键对不上单测文件 = 红。
# 逐组单独 make、逐组判（10-25）：原先一次 make 全部目标、只数「✓ t_」行，某组没出结果只记成「少一组」、红数 0、看不出是哪组，
#   且 make 遇第一处错就停、后面的组全没跑。现在每组一个 make（超时 GT 秒），没出结论的组也算红并点名原因：
#   构建失败（编译 / 链接报错）、超时、判据不符（有「✗ t_」行）、异常退出（rc 非 0、没有判据行）、没打结论行（rc=0 但没有「✓ t_」行）、没有构建目标（有单测文件、build.mk 没登记）。
#   有单测文件的组要 rc=0 且有「✓ t_」行、没有「✗ t_」行；build.mk 里没有单测文件的目标（ns2pro、touch_compat，打自己的通过行）只要 rc=0。
set -u
GT=300
has_file() { [ -f "runtime/tests/t_$1.c" ] || [ -f "runtime/tests/t_$1.m" ] || [ -f "graphics/nvn/tests/t_$1.c" ] || [ -f "graphics/nvn/tests/t_$1.m" ]; }
for k in ${GATE_SKIP:-} ${GATE_ONLY:-}; do has_file "$k" || { echo "原生层：子项键 $k 在 runtime/tests 或 graphics/nvn/tests 下没有对应的 C / Objective-C 单测 → 红"; exit 1; }; done
# 跑一组并判：绿 → G+1；红 → R+1、记「键 原因」进 WHY、把细节行攒进 DET
G=0; R=0; WHY=; DET=; TM=
# 组并行（10-28 质量线门禁提速：100 组逐个跑本机 212 秒、gate-host 276 秒，单组最慢 13 秒，瓶颈是串行）：每组一个 make 进后台，同时至多 NATIVE_GATE_J 组
#   （缺省核数一半），各组输出进临时目录，跑完按原顺序判。NVN 组共用的前置（宿主对象 / libnvn / 宽屏核心）先由 native-test-prereq 建一次，
#   各组带 NVN_TEST_PREBUILT=1 不再各自 FORCE 重入（并行时会同时写同一个库）。对负载 / 计时敏感、偶发过的组（SER）放最后串行跑
SER=" thread thread_plat svc_mem vawin vawin_ios26 nvn_bufreg_rate "   # nvn_bufreg_rate：耗时比判据，并行组抢核会抖
J=${NATIVE_GATE_J:-$(( $(sysctl -n hw.ncpu 2> /dev/null || nproc 2> /dev/null || echo 4) / 2 ))}; [ "$J" -ge 1 ] 2> /dev/null || J=1
OUT=$(mktemp -d "${TMPDIR:-/tmp}/s2a_native_gate_XXXXXX"); trap 'rm -rf "$OUT"' EXIT
exec_group() {   # exec_group <键>：跑一组，输出 / 退出码 / 秒数写进 $OUT
  local k=$1 t0=$SECONDS rc
  NVN_TEST_PREBUILT=${NVN_TEST_PREBUILT:-} timeout "$GT" make -s "native-test-$k" > "$OUT/$k.out" 2>&1; rc=$?
  echo "$rc $((SECONDS - t0))" > "$OUT/$k.rc"
}
judge() {   # judge <键>：按 $OUT 里这一组的结果判，绿 G+1 / 红 R+1 并记原因与细节
  local k=$1 o rc sec why=
  o=$(cat "$OUT/$k.out" 2> /dev/null); read -r rc sec < "$OUT/$k.rc" 2> /dev/null || { rc=1; sec=0; o="（没有结果：这一组没跑起来）"; }
  TM="${TM}${sec} ${k}"$'\n'   # 每组墙钟（10-28 梳理：原先只判红绿、不知道慢在哪组）
  if [ $rc = 124 ]; then why="超时（${GT} 秒）"
  elif [ $rc = 125 ]; then why="没跑（NVN 共用前置构建失败，见上）"
  elif grep -aq '^✗ t_' < <(printf '%s\n' "$o"); then why="判据不符"
  elif [ $rc != 0 ] && grep -aqE '^[^ ]+:[0-9]+:[0-9]+: (fatal )?error:|^clang: error:|^ld: |^Undefined symbols' < <(printf '%s\n' "$o"); then why="构建失败"
  elif [ $rc != 0 ]; then why="异常退出（rc=${rc}）"
  elif has_file "$k" && ! grep -aq '^✓ t_' < <(printf '%s\n' "$o"); then why="没打结论行（rc=0 但没有「✓ t_」行）"
  fi
  [ -z "$why" ] && { G=$((G + 1)); return; }
  R=$((R + 1)); WHY="${WHY}、${k} ${why}"
  # 细节：判据不符列全部「✗」行（不只尾部：打得早的判据行会被截掉，10-24 t_thread 偶发三次都看不出是哪条）；构建失败列报错行；其余给尾部
  local d
  case $why in
    判据不符) d=$(grep -aE '^(✗ |FAIL )' < <(printf '%s\n' "$o") | head -20);;   # FAIL：单测自己的判据行（t_dirty_growth / t_nvn_red 这样打，10-30 列车线：原先只认 ✗ 被丢）
    构建失败) d=$(grep -aE ': (fatal )?error:|^clang: error:|^ld: |^Undefined symbols|^  "_|referenced from|^      [_A-Za-z].* in ' < <(printf '%s\n' "$o") | head -16);;   # 链接红连缺的符号名 / 谁引用一起带（11-05 nvn_rec_cover 偶发「Undefined symbols」只剩一行、定不了因）
    *) d=$(tail -10 < <(printf '%s\n' "$o"));;
  esac
  DET="${DET}✗ 组 ${k}：${why}"$'\n'"$d"$'\n'
}
uses_pre() { grep -qs 'NVN_TEST_LIB\|NVN_TEST_HOST_OBJS' "runtime/tests/mk/$1.mk"; }   # 这组用 NVN 共用前置（库 / 宿主目标文件）
run_groups() {   # run_groups <键…>：前置建一次 → 非 SER 组并行 → SER 组串行 → 按传入顺序判
  local k pre=0 pf=
  for k in "$@"; do uses_pre "$k" && { pre=1; break; }; done
  # 前置没建成 = 用它的组都建不成：直接记红点名前置的报错，这些组记「没跑」，其余组照常并行
  #   （11-01 #1184 / #1299：原先退成串行、每组再各自 FORCE 重建同一个库，976 秒才红，前置失败原因不报）
  if [ $pre = 1 ]; then
    if make -s native-test-prereq > "$OUT/_prereq.out" 2>&1; then export NVN_TEST_PREBUILT=1
    else pf=1; R=$((R + 1)); WHY="${WHY}、NVN 共用前置构建失败"
      k=$(grep -aE ': (fatal )?error:|^clang: error:|^ld: |^Undefined symbols' "$OUT/_prereq.out" | head -10); [ -n "$k" ] || k=$(tail -10 "$OUT/_prereq.out")
      DET="${DET}✗ NVN 共用前置（make native-test-prereq）构建失败，用到它的组没跑："$'\n'"$k"$'\n'
    fi
  fi
  for k in "$@"; do [ -n "$pf" ] && uses_pre "$k" && { echo "125 0" > "$OUT/$k.rc"; : > "$OUT/$k.out"; }; done
  for k in "$@"; do case $SER in *" $k "*) continue;; esac; [ -f "$OUT/$k.rc" ] && continue
    while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do wait -n 2> /dev/null || sleep 0.2; done
    exec_group "$k" &
  done; wait
  for k in "$@"; do case $SER in *" $k "*) [ -f "$OUT/$k.rc" ] || exec_group "$k";; esac; done
  for k in "$@"; do judge "$k"; done
}
depskip() {   # depskip <键…>：可跳过的组（空格分隔）；不跳就什么都不打。见上方「按源文件跳组」
  [ -n "${GATE_CHANGED:-}" ] && [ "${NATIVE_GATE_DEPSKIP:-1}" != 0 ] || return 0
  local f c=() st day key cd b k
  for f in $GATE_CHANGED; do case $f in
    runtime/*.c|runtime/*.m|runtime/*.mm|runtime/*.cpp|runtime/*.cc|runtime/*.S|runtime/*.s|graphics/*.c|graphics/*.m|graphics/*.mm|graphics/*.cpp|graphics/*.cc|graphics/*.S|graphics/*.s) c+=("$f");;
    runtime/*|graphics/*|Makefile|*/build.mk|tests/autoplay/*|tests/build.mk|compat/*) return 0;;   # 非 C 源落在本钩子管的路径下：全跑
  esac; done
  [ ${#c[@]} -gt 0 ] || return 0
  st=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_depskip; day=$(date +%Y%m%d); mkdir -p "$st" 2> /dev/null || return 0
  [ -f "$st/full.$day" ] || { : > "$st/full.$day"; return 0; }   # 每天这台机器第一次：全跑
  key=$(cat Makefile */build.mk runtime/tests/mk/*.mk 2> /dev/null | shasum | cut -c1-16); cd=$st/src.$key
  if [ ! -f "$cd/.done" ]; then b=$(mktemp -d "${TMPDIR:-/tmp}/s2a_depskip_XXXXXX"); mkdir -p "$cd"
    # 并行算（J 路，同组并行数）：串行 345 组约 400 秒，mk 一变就要重算，不并行会把省下的时间吃回去
    printf '%s\n' "$@" | xargs -P "$J" -I{} sh -c 'make -n -B BUILD="$1" "native-test-$2" 2> /dev/null | grep -oE "[A-Za-z0-9_./+-]+\.(c|m|mm|cpp|cc|S|s)\b" | sed "s#^\./##" | sort -u > "$0/$2.txt"' "$cd" "$b" {}
    rm -rf "${b:?}"; : > "$cd/.done"; fi
  # 规则里自己再调 $(MAKE) 的组（graphics_session 编整个带 S2A_CS 的宿主、nvn_abba、input_config_apple）：干跑列不全它们的源（11-14 实测
  #   graphics_session 串行干跑 0 个源、并行干跑 2 个），一律照跑。按规则文本静态认，不靠干跑输出
  local rec; rec=" $(grep -l '\$(MAKE)' runtime/tests/mk/*.mk 2> /dev/null | sed 's#.*/##; s#\.mk$##' | tr '\n' ' ') $(awk '/^native-test-[a-z_0-9]+:/{t=substr($1, 13); sub(/:$/, "", t)} /\$\(MAKE\)/{if (t) print t}' Makefile */build.mk 2> /dev/null | tr '\n' ' ') "
  local out=; for k in "$@"; do case $rec in *" $k "*) continue;; esac; [ -s "$cd/$k.txt" ] || continue; grep -qxFf <(printf '%s\n' "${c[@]}") "$cd/$k.txt" || out="$out $k"; done
  echo "${out# }"
}
summary() { [ $R = 0 ] && echo "绿 $G 组" || echo "绿 $G 组、红 $R 组（${WHY#、}）"; }
slowest() { printf '%s' "$TM" | sort -rn | head -5 | awk '{printf "%s%s %s 秒", (NR > 1 ? "、" : ""), $2, $1}'; }
# 最慢 5 组单独一行，打在末行之前（末行格式 tools/gate.sh 要解析，不动）
timing() { [ -n "$TM" ] && echo "原生层单测最慢 5 组：$(slowest)；宿主构建 ${HB:-0} 秒"; }
if [ -n "${GATE_ONLY:-}" ]; then
  n=0; for k in $GATE_ONLY; do n=$((n + 1)); done; run_groups $GATE_ONLY
  [ $R = 0 ] || { printf '%s' "$DET"; timing; echo "原生层单测（只跑 ${GATE_ONLY}）期望 $n 组全绿 → $(summary)"; exit 1; }
  timing; echo "原生层单测（只跑 ${GATE_ONLY}）期望 $n 组全绿 → $(summary)"; exit 0
fi
t0=$SECONDS; make -s host > /tmp/s2a_native_gate_$$.log 2>&1 || { tail -20 /tmp/s2a_native_gate_$$.log; rm -f /tmp/s2a_native_gate_$$.log; echo "宿主构建 期望 成功 → 失败"; exit 1; }
rm -f /tmp/s2a_native_gate_$$.log; HB=$((SECONDS - t0))
# 组 = build.mk 登记的 native-test-* 目标 ∪ 单测文件（graphics/nvn/tests 的单测如 t_dsh_stats 也登记在 runtime/build.mk），减去 GATE_SKIP
SK=" ${GATE_SKIP:-} "; TG=" $(make -pn 2>/dev/null | grep -oE '^native-test-[a-z_0-9]+' | sed 's/^native-test-//' | sort -u | tr '\n' ' ') "
case $TG in (*[![:space:]]*) ;; (*) echo "原生层单测目标列表为空 → 红"; exit 1;; esac
n=0
RUN=(); for k in $TG; do case $SK in *" $k "*) continue;; esac; RUN+=("$k"); n=$((n + 1)); done
# 按源文件跳组（11-14 门禁提速）：只在本批改动「只有 runtime/ 或 graphics/ 下的 C 系源文件」时，跳过源文件清单里一个改动都没有的组。
#   改动里有头文件 / 数据 / 脚本 / mk / Makefile / build.mk / 别的门禁路由路径、没给 GATE_CHANGED、今天这台机器还没全跑过 → 全跑。
#   每组源文件清单 = make -n -B native-test-<键> 里出现的 .c / .m / .mm / .cpp / .cc / .S / .s（不受增量构建影响），按 Makefile + */build.mk +
#   runtime/tests/mk/*.mk 的内容哈希缓存（变了重算）；清单算不出 / 为空的组照跑。11-14 模拟：今天 64 次触发本钩子的合并里 17 次只需跑 0–5 组
NDS=$(depskip "${RUN[@]}") || NDS=
if [ -n "$NDS" ]; then KEEP=(); SKN=0; for k in "${RUN[@]}"; do case " $NDS " in *" $k "*) SKN=$((SKN + 1));; *) KEEP+=("$k");; esac; done
  RUN=("${KEEP[@]}"); n=$((n - SKN)); fi
[ ${#RUN[@]} -gt 0 ] && run_groups "${RUN[@]}"
for f in runtime/tests/t_*.c runtime/tests/t_*.m graphics/nvn/tests/t_*.c; do
  [ -f "$f" ] || continue; k=${f##*/t_}; k=${k%.*}
  case $SK in *" $k "*) continue;; esac; case $TG in *" $k "*) continue;; esac
  n=$((n + 1)); R=$((R + 1)); WHY="${WHY}、${k} 没有构建目标（有 ${f}，build.mk 没登记 native-test-${k}）"
done
ex=; [ -n "${GATE_SKIP:-}" ] && ex="（${GATE_SKIP} 另跑）"; [ -n "${NDS:-}" ] && ex="${ex}（本批只改 C 源，按源文件清单跳过 $(wc -w <<< "$NDS" | tr -d ' ') 组）"
[ $R = 0 ] || { printf '%s' "$DET"; timing; echo "原生层单测 期望 $n 组全绿 → $(summary)$ex"; exit 1; }
timing; echo "原生层：宿主构建成功；单测 期望 $n 组全绿 → $(summary)$ex"
