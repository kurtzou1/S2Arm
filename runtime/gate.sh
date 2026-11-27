#!/bin/bash
# 门禁路由：runtime/ graphics/ compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures/ tests/autoplay/ tests/build.mk Makefile */build.mk
# 门禁本机：vawin t_vawin：gate-host 内核占不到整块 64 GB 地址窗口（窗口内已有别人的映射 24 GB）
# 原生层门禁钩子（tools/gate.sh 在仓库根调）：宿主能构建 + 原生层单测全绿。末行「期望 → 真结果」。
# 子项键（tools/gate.sh 分派 gate-host 用，见本文件头「# 门禁本机：」）：runtime/tests 或 graphics/nvn/tests 下 C / Objective-C 单测的键（如 vawin / nvn_copy_stride），须有 native-test-<键> 构建目标。
#   GATE_SKIP="<键…>"：不跑这几组（别处另跑），应跑组数相应减少、末行写明；GATE_ONLY="<键…>"：只编跑这几组单测，不构建宿主。键对不上单测文件 = 红。
#   GATE_BUILD_ONLY=1（11-24 只编步）：每组只构建 native-test-<键> 的先决目标、不运行；构建过 = 绿，编译 / 链接错 = 红；宿主照常构建。
#     门禁把它作为合入前必跑步（整钩子慢、挪到合入后）：D-92BW 漏桩（dsh_stats 隐式声明、front_layer_race 缺符号）几秒就能编出来，原先跟着整钩子推到合入后、2 小时后才被守望定位。
#     做法：make 的规则外壳换成 tools/build_only_shell.sh，编 / 链照常、「运行 build/tests/t_<名>」那一行跳过；退出非 0 但没有编译 / 链接报错的组记「只编判不了」，不算红
# 逐组单独 make、逐组判（10-25）：原先一次 make 全部目标、只数「✓ t_」行，某组没出结果只记成「少一组」、红数 0、看不出是哪组，
#   且 make 遇第一处错就停、后面的组全没跑。现在每组一个 make（超时 GT 秒），没出结论的组也算红并点名原因：
#   构建失败（编译 / 链接报错）、超时、判据不符（有「✗ t_」行）、异常退出（rc 非 0、没有判据行）、没打结论行（rc=0 但没有「✓ t_」行）、没有构建目标（有单测文件、build.mk 没登记）。
#   有单测文件的组要 rc=0 且有「✓ t_」行、没有「✗ t_」行；build.mk 里没有单测文件的目标（ns2pro、touch_compat，打自己的通过行）只要 rc=0。
# 本机自测排在门禁后面：不在门禁里跑（没有 GATE2_PAR）就把自己降到 nice 15，子进程继承；门禁步的优先级由门禁自己定
[ -n "${GATE2_PAR:-}" ] || renice 15 -p $$ > /dev/null 2>&1 || true
# C# 编译串行（同 graphics/gate.sh：门禁 tools/gate.sh 已接则沿用，单独跑本钩子时这里接上）：各组并行时 graphics_session 的 nxaot（dotnet publish）
#   与别的组同编 compat/tree，共用 obj/ bin/ 互踩（11-23 开发者单独跑本钩子：NU5026 Ryujinx.Common.dll not found on disk；门禁里有锁、11-16 起没出过）
if [ -z "${S2A_DOTNET_LOCK:-}" ] && [ -f tools/dotnet_lock.c ] && mkdir -p build/dotnet_lock && cc -O2 -o build/dotnet_lock/dotnet tools/dotnet_lock.c 2> /dev/null; then
  export S2A_DOTNET_REAL=${DOTNET:-$HOME/.dotnet/dotnet} S2A_DOTNET_LOCK=$PWD/build/.dotnet_build.lock DOTNET=$PWD/build/dotnet_lock/dotnet PATH=$PWD/build/dotnet_lock:$PATH
fi
set -u
GT=300   # 每组无进展秒：连续这么久日志不长、进程树 CPU / 磁盘不涨、没有编译子进程才判挂死（tools/nostall.py）
GHX=${GATE_HARD_X:-4}   # 墙钟保底 = GT × GHX：只兜一直吃 CPU 的死循环。11-21：原先每组固定墙钟 300 秒，本机同时出候选（负载 70）时
#   graphics_session / nvn_red / nvn_vppack 正常推进只是变慢，被当超时判红；这几条单测本身没有墙钟判据。判据只问输出对不对，负载不造成假红
has_file() { [ -f "runtime/tests/t_$1.c" ] || [ -f "runtime/tests/t_$1.m" ] || [ -f "graphics/nvn/tests/t_$1.c" ] || [ -f "graphics/nvn/tests/t_$1.m" ]; }
# 子项键也认只有构建分片、没有单测源文件的组（runtime/tests/mk/<键>.mk：touch_compat、ns2pro 这类打自己通过行的目标；11-14 新门禁按组拆步要能单跑它们）
is_key() { has_file "$1" || [ -f "runtime/tests/mk/$1.mk" ]; }
for k in ${GATE_SKIP:-} ${GATE_ONLY:-}; do is_key "$k" || { echo "原生层：子项键 $k 在 runtime/tests 或 graphics/nvn/tests 下没有对应的 C / Objective-C 单测 → 红"; exit 1; }; done
# 跑一组并判：绿 → G+1；红 → R+1、记「键 原因」进 WHY、把细节行攒进 DET
G=0; R=0; WHY=; DET=; TM=; BON=0
# 组并行（10-28 质量线门禁提速：100 组逐个跑本机 212 秒、gate-host 276 秒，单组最慢 13 秒，瓶颈是串行）：每组一个 make 进后台，同时至多 NATIVE_GATE_J 组
#   （缺省核数一半），各组输出进临时目录，跑完按原顺序判。NVN 组共用的前置（宿主对象 / libnvn / 宽屏核心）先由 native-test-prereq 建一次，
#   各组带 NVN_TEST_PREBUILT=1 不再各自 FORCE 重入（并行时会同时写同一个库）。对负载 / 计时敏感、偶发过的组（SER）放最后串行跑
SER=" thread thread_plat svc_mem vawin vawin_ios26 "   # 11-19：nvn_bufreg_rate 改判登记表步数比、不再比墙钟，不怕抢核，移出串行组
J=${NATIVE_GATE_J:-$(( $(sysctl -n hw.ncpu 2> /dev/null || nproc 2> /dev/null || echo 4) / 2 ))}; [ "$J" -ge 1 ] 2> /dev/null || J=1
OUT=$(mktemp -d "${TMPDIR:-/tmp}/s2a_native_gate_XXXXXX"); trap 'rm -rf "$OUT"' EXIT
# 整步被外面停掉（门禁无进展看门狗、步时限发 TERM）时先说清还有哪几组在跑、各跑了多久、输出尾巴，再退：原先 EXIT 只删临时目录，
#   11-19 两轮「挂死：连续 300 秒无进展」的红里看不出是哪一组挂住（每组本有 GT 秒时限，看门狗先到说明那组的进程收不掉）
hung_report() {
  local f k n=0
  for f in "$OUT"/*.start; do [ -e "$f" ] || continue; k=${f##*/}; k=${k%.start}; [ -f "$OUT/$k.rc" ] && continue
    n=$((n + 1)); echo "✗ 组 ${k}：被停时还在跑（已 $(( $(date +%s) - $(cat "$f") )) 秒），输出尾部："; tail -8 "$OUT/$k.out" 2> /dev/null | sed 's/^/    /'; done
  [ $n = 0 ] && echo "被停时没有在跑的组（停在组外：前置构建 / 判定 / 记耗时）"
}
trap 'echo "原生层单测钩子被停（信号）：$(date +%T)"; hung_report; exit 143' TERM INT
TF=${S2A_NATIVE_GATE_TIMES:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/native_gate_times}; mkdir -p "${TF%/*}" 2> /dev/null || TF=   # 各组上次耗时（派发排序用，见 run_groups）。放树外：门禁每步 git clean -fdx，放 build/ 下永远读不到、「慢组先派」退回按名字排；只影响派发顺序，不影响判红绿；写法是临时文件 + 原子 mv，多树并发写安全
# 编译缓存（tools/cc_cache.sh）：门禁入口（tools/gate.sh）已开就不动；单独跑本钩子时这里开。一步编链的单测也经它逐源缓存（tools/ccshim/shim split_link）
[ -n "${S2A_CCACHE_BIN:-}" ] || { [ -f tools/cc_cache.sh ] && { source tools/cc_cache.sh; s2a_ccache_on "$PWD"; }; }
# 工具链目录解析一次传给每组的 make（11-14 门禁提速：没设时顶层 Makefile 每次解析都起 bash 跑 tools/toolchain.sh，350 组各一次）。
#   值就是 make 自己会解出的那个（取自 make -p），与不设时逐字相同
#   make -p 的变量 / 目标表只取一次，下面的组清单（TG）也从它取；GATE_ONLY 只跑点名的几组，不取
MP=; { [ -z "${GATE_ONLY:-}" ] || [ "${GATE_BUILD_ONLY:-}" = 1 ]; } && MP=$(make -pn 2> /dev/null)
[ -n "${S2A_DEVELOPER_DIR:-}${DEVELOPER_DIR:-}" ] || [ -z "$MP" ] || { d=$(sed -n 's/^DEVELOPER_DIR := //p' <<< "$MP" | head -1); [ -n "$d" ] && export DEVELOPER_DIR=$d; }
exec_group() {   # exec_group <键>：跑一组，输出 / 退出码 / 秒数写进 $OUT
  local k=$1 t0=$SECONDS rc
  date +%s > "$OUT/$k.start"
  if [ "${GATE_BUILD_ONLY:-}" = 1 ]; then   # 只编：规则照常编 / 链，「运行单测程序」那一行由 tools/build_only_shell.sh 跳过（多数组在规则里才编，没有先决目标可单独构建）
    NVN_TEST_PREBUILT=${NVN_TEST_PREBUILT:-} timeout -k 15 "$((GT * GHX))" make -s "native-test-$k" SHELL="$PWD/tools/build_only_shell.sh" > "$OUT/$k.out" 2>&1; rc=$?
    echo "$rc $((SECONDS - t0))" > "$OUT/$k.rc"; return; fi
  # -k 15：到时限先 TERM、15 秒后还没退就 KILL（单测进程收不掉时不拖到门禁看门狗把整步停了）
  if [ -f tools/nostall.py ]; then   # 无进展看门狗（门禁步一级早已在用，tools/gate.sh）；每组一个取证目录：挂死时 nostall 在这里留各进程调用栈
    mkdir -p "$OUT/$k.ns"; NVN_TEST_PREBUILT=${NVN_TEST_PREBUILT:-} timeout -k 15 "$((GT * GHX))" "${S2A_PY:-python3}" tools/nostall.py --watch "$OUT/$k.ns" "$GT" -- make -s "native-test-$k" > "$OUT/$k.out" 2>&1; rc=$?
  else NVN_TEST_PREBUILT=${NVN_TEST_PREBUILT:-} timeout -k 15 "$GT" make -s "native-test-$k" > "$OUT/$k.out" 2>&1; rc=$?; fi   # 缺 nostall.py（单测假仓库）= 旧行为
  echo "$rc $((SECONDS - t0))" > "$OUT/$k.rc"
}
judge() {   # judge <键>：按 $OUT 里这一组的结果判，绿 G+1 / 红 R+1 并记原因与细节
  local k=$1 o rc sec why=
  o=$(cat "$OUT/$k.out" 2> /dev/null); read -r rc sec < "$OUT/$k.rc" 2> /dev/null || { rc=1; sec=0; o="（没有结果：这一组没跑起来）"; }
  TM="${TM}${sec} ${k}"$'\n'   # 每组墙钟（10-28 梳理：原先只判红绿、不知道慢在哪组）
  if [ "${GATE_BUILD_ONLY:-}" = 1 ]; then   # 只编：编过 = 绿；只编不了单列；其余 = 构建失败（列报错行）
    [ "$rc" = 0 ] && { G=$((G + 1)); return; }
    # 退出非 0 但没有编译 / 链接报错（规则里别的步骤失败、运行行没认出被跑了）：只编判不了，不算红（只编只证编不编得过，不当运行判据用）
    grep -av '^ld: warning:' < <(printf '%s\n' "$o") | grep -aqE ': (fatal )?error:|^clang: error:|^ld: |^Undefined symbols' || { BON=$((BON + 1)); return; }
    R=$((R + 1)); WHY="${WHY}、${k} 构建失败（只编）"
    DET="${DET}✗ 组 ${k}：构建失败（只编）"$'\n'"$(grep -av '^ld: warning:' < <(printf '%s\n' "$o") | grep -aE ': (fatal )?error:|^clang: error:|^ld: |^Undefined symbols|^  "_|referenced from' | head -16)"$'\n'; return; fi
  if [ $rc = 124 ] && grep -aq "无进展看门狗" < <(printf '%s\n' "$o"); then why="挂死（连续 ${GT} 秒无进展：日志不长、进程树 CPU / 磁盘不涨）"
  elif [ $rc = 124 ] && [ -d "$OUT/$k.ns" ]; then why="超时（墙钟保底 $((GT * GHX)) 秒仍没跑完，期间一直有进展）"
  elif [ $rc = 124 ]; then why="超时（${GT} 秒）"
  elif [ $rc = 137 ]; then why="超时（TERM 后 15 秒仍不退、补了 KILL）"
  elif [ $rc = 125 ]; then why="没跑（NVN 共用前置构建失败，见上）"
  elif grep -aq '^✗ t_' < <(printf '%s\n' "$o"); then why="判据不符"
  # 「ld: warning:」不是构建错误（nvn_texu_pending 每次链接都打 ld: warning: ignoring duplicate libraries）：原先 ^ld: 连它一起认，运行时真失败（rc 非 0、
  #   没打 ✗ 行）被标成「构建失败」、细节只列报错行，真正的失败输出被藏掉（11-19 守望两次「✗ 组 nvn_texu_pending：构建失败」查不出原因）。先去掉警告行再判
  elif [ $rc != 0 ] && grep -av '^ld: warning:' < <(printf '%s\n' "$o") | grep -aqE '^[^ ]+:[0-9]+:[0-9]+: (fatal )?error:|^clang: error:|^ld: |^Undefined symbols'; then why="构建失败"
  elif [ $rc != 0 ]; then why="异常退出（rc=${rc}）"
  elif has_file "$k" && ! grep -aq '^✓ t_' < <(printf '%s\n' "$o"); then why="没打结论行（rc=0 但没有「✓ t_」行）"
  fi
  [ -z "$why" ] && { G=$((G + 1)); return; }
  R=$((R + 1)); WHY="${WHY}、${k} ${why}"
  # 细节：判据不符列全部「✗」行（不只尾部：打得早的判据行会被截掉，10-24 t_thread 偶发三次都看不出是哪条）；构建失败列报错行；其余给尾部
  local d
  case $why in
    构建失败) d=$(grep -av '^ld: warning:' < <(printf '%s\n' "$o") | grep -aE ': (fatal )?error:|^clang: error:|^ld: |^Undefined symbols|^  "_|referenced from|^      [_A-Za-z].* in ' | head -16);;   # 链接红连缺的符号名 / 谁引用一起带（11-05 nvn_rec_cover 偶发「Undefined symbols」只剩一行、定不了因）
    *) d=$(printf '%s\n' "$o" | red_excerpt)   # 判据不符 / 超时 / 异常退出 / 没打结论行：同一份摘录
       local sf; for sf in "$OUT/$k.ns"/nostall_stacks.*.log; do [ -f "$sf" ] && d="$d"$'\n'"--- 挂死取证（各进程调用栈，前 2 KB）"$'\n'"$(head -c 2048 "$sf" | iconv -c -f UTF-8 -t UTF-8)"; done;;
  esac
  # 红组的整份输出留下（11-23：$OUT 是临时目录、退出就删，摘录只有 4 KB；nvn_hybrid / nvn_rt_rgb9e5_view 时红时绿，摘录里连失败的那条判据都没留下，
  #   本机连跑 120 次复现不出，查不下去）。留到本树 build/tests/gate_red/，每组只留最近 5 份，路径写进细节
  local keep="${S2A_GATE_RED_KEEP:-build/tests/gate_red}" kf=
  if mkdir -p "$keep" 2> /dev/null; then kf="$keep/$k.$(date +%m%d-%H%M%S).$$.out"; cp "$OUT/$k.out" "$kf" 2> /dev/null || kf=
    ls -t "$keep/$k".*.out 2> /dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done; fi
  [ -n "$kf" ] && d="$d"$'\n'"（整份输出：$(cd "$(dirname "$kf")" && pwd)/$(basename "$kf")）"
  DET="${DET}✗ 组 ${k}：${why}"$'\n'"$d"$'\n'
}
# 红组的输出摘录（11-21 维护者：原先判据不符只取顶格「✗ / FAIL」行、其余只给末尾 10 行，单测缩进打的逐项「FAIL ①…」、崩溃行、
#   超时组被杀前打的取证都丢了，门禁日志只剩「11 项里 2 项不符」这类汇总，查因要本机连跑碰运气）：
#   按原顺序取「判据 / 红 / 崩溃」特征行 ∪ 末尾 20 行（不重复），封顶约 4 KB、按字节截后去掉截断的半个字。只用于红组，绿组日志不变
#   判据行（FAIL / ✗ / 不通）排最前：11-23 nvn_hybrid「19 项 1 项不符」三次红，前面几十行【红】环境噪声（地址窗口、着色器库没建）先占满 4 KB，
#   那条 FAIL 被截掉，留存日志里查不到是哪一项不符。其余特征行与末尾 20 行照原顺序跟在后面
red_excerpt() {
  awk '{ L[NR] = $0 } END { s = NR - 19
         for (i = 1; i <= NR; i++) if (L[i] ~ /FAIL|✗|不通/) { print L[i]; P[i] = 1 }
         for (i = 1; i <= NR; i++)
           if (!(i in P) && (i >= s || L[i] ~ /【红】|unrecognized selector|[Aa]ssertion|[Aa]ssert\(|signal|SIG[A-Z]+|Terminating app|uncaught exception|libc\+\+abi|Abort trap|Segmentation fault|Bus error|EXC_[A-Z_]+|panic|Killed/)) print L[i] }' \
    | head -c 4096 | iconv -c -f UTF-8 -t UTF-8
}
uses_pre() { grep -qs 'NVN_TEST_LIB\|NVN_TEST_HOST_OBJS' "runtime/tests/mk/$1.mk"; }   # 这组用 NVN 共用前置（库 / 宿主目标文件）
run_groups() {   # run_groups <键…>：前置建一次 → 非 SER 组按上次耗时从长到短并行 → SER 组串行 → 按传入顺序判
  # 派发顺序（11-14 门禁提速）：按上一次各组耗时从长到短（${TF}，本树 build/ 下；没记录的新组排最前，没有 ${TF} 就按传入顺序），最慢的组不再排到最后拖尾。
  #   前置照旧先建完再放组：用到前置产物的组有的登记在别的分片里（如 nvn_replay.mk 一份登记 4 组），按分片名认不全，
  #   和前置同时跑会两边同时 FORCE 重写同一个库（11-14 试过并行，宽屏核心发布目录被两边同时写坏、整片 NVN 组红）
  local k pre=0 pf= q
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
  q=$(printf '%s\n' "$@"); [ -s "$TF" ] && q=$(awk 'NR == FNR { t[$2] = $1; next } { print (($1 in t) ? t[$1] : 99999), FNR, $1 }' "$TF" - <<< "$q" | sort -k1,1nr -k2,2n | awk '{ print $3 }')
  for k in $q; do case $SER in *" $k "*) continue;; esac; [ -f "$OUT/$k.rc" ] && continue
    while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do wait -n 2> /dev/null || sleep 0.2; done
    exec_group "$k" &
  done; wait   # 也等后台的宿主构建（见下方）：SER 组怕抢核，要在全部并行的活之后单独跑
  for k in "$@"; do case $SER in *" $k "*) [ -f "$OUT/$k.rc" ] || exec_group "$k";; esac; done
  for k in "$@"; do judge "$k"; done
  # 记本次各组耗时，下次派发按它排（只记跑了的组；GATE_ONLY / 跳组时只更新跑到的那些）
  [ -n "$TF" ] && { { [ -s "$TF" ] && cat "$TF"; printf '%s' "$TM"; } | awk 'NF == 2 { t[$2] = $1 } END { for (k in t) print t[k], k }' > "$TF.tmp.$$" 2> /dev/null && mv -f "$TF.tmp.$$" "$TF"; } 2> /dev/null
  return 0
}
depskip() {   # depskip <键…>：可跳过的组（空格分隔）；不跳就什么都不打。见上方「按源文件跳组」
  [ -n "${GATE_CHANGED:-}" ] && [ "${NATIVE_GATE_DEPSKIP:-1}" != 0 ] || return 0
  local f c=() h=() st day key cd b k bo=; [ "${GATE_BUILD_ONLY:-}" = 1 ] && bo=1
  # 11-26 不再按目录分（原先只认 runtime/ graphics/ 下的 C 源：android/native 下的 C 源改了，只改它时清单空 → 全编；
  #   同 runtime 源一起改时它被忽略 → 编到它的组可能被跳，假绿）。C 系源文件不论在哪都和每组 make -n 的源文件比；
  #   头文件不论在哪：按 include 闭包换成源文件（11-27 起完整门禁同只编；完整门禁下没有源 include 它 → 全跑：可能是脚本 / 数据在读）；其余一切（Makefile / *.mk / 链接脚本 / 编译参数文件 / 生成器脚本 / 数据）
  #   都可能改编译结果、又不在源文件清单里，一改就全跑。GATE_CHANGED 是列车 / 守望给的「改动 ∩ 本钩子输入」，不是全部改动
  for f in $GATE_CHANGED; do case $f in
    *.c|*.m|*.mm|*.cpp|*.cc|*.S|*.s) c+=("$f");;
    # 头文件也收窄（只编 11-24、完整门禁 11-27）：按 #include / #import 静态闭包（tools/include_closure.py）求出受影响的源文件，并进 c，
    #   组按「源文件清单里有没有这些源」判跑不跑——改 .inc / .h 不再整钩子 478 组全跑（11-27 diag/tess-stage-dropped 只改 dsh_miss.inc 跑满 908 秒）
    *.h|*.inc|*.hpp|*.hh|*.def) h+=("$f");;
    *) return 0;;
  esac; done
  # 闭包算不出（脚本出错）→ 全跑：先收进变量再判退出码（原写法 `done < <(…) || return 0` 只看 while 的退出码，脚本失败时头文件被静默丢掉、同批的源照常收窄 = 假绿）
  #   完整门禁逐个头文件算：哪一个没有源 include 它（可能是脚本 / 数据在读、或用宏拼的 include）→ 全跑；只编一起算（没有源用到 = 不影响编译）
  if [ ${#h[@]} -gt 0 ]; then local x hs y
    if [ -n "$bo" ]; then hs=$(python3 -B tools/include_closure.py "${h[@]}" 2> /dev/null) || return 0
    else hs=; for y in "${h[@]}"; do x=$(python3 -B tools/include_closure.py "$y" 2> /dev/null) && [ -n "$x" ] || return 0; hs="$hs"$'\n'"$x"; done; fi
    while IFS= read -r x; do [ -n "$x" ] && c+=("$x"); done <<< "$hs"; fi
  [ ${#c[@]} -gt 0 ] || { [ -n "$bo" ] && [ ${#h[@]} -gt 0 ] && echo "$*"; return 0; }   # 只编：改的头文件没有源用到 → 一组都不用编
  st=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_depskip; day=$(date +%Y%m%d); mkdir -p "$st" 2> /dev/null || return 0
  [ -n "$bo" ] || [ -f "$st/full.$day" ] || { : > "$st/full.$day"; return 0; }   # 每天这台机器第一次：全跑（只编不做这一步：编译结果不随天变）
  # 缓存键带格式版本（v2：清单改存相对路径 + 共用前置清单）：旧版缓存里是绝对路径，跟 GATE_CHANGED 的相对路径永远对不上 → 有清单的组一律被跳（11-27 假绿根因）
  key=$({ cat Makefile */build.mk runtime/tests/mk/*.mk 2> /dev/null; echo depskip-v2; } | shasum | cut -c1-16); cd=$st/src.$key
  if [ ! -f "$cd/.done" ]; then b=$(mktemp -d "${TMPDIR:-/tmp}/s2a_depskip_XXXXXX"); mkdir -p "$cd"
    # 并行算（J 路，同组并行数）：串行 345 组约 400 秒，mk 一变就要重算，不并行会把省下的时间吃回去
    #   清单一律存仓库相对路径（11-27 假绿根因：make -n 打出的是工作树绝对路径 /…/trees/N/graphics/…，跟 GATE_CHANGED 的相对路径对不上，
    #   每组都判「没改到」被跳，contrib/pr2270-rb 一轮 0 组判绿、编译错进了 main）；共用前置（native-test-prereq）另存 _prereq.txt，
    #   用前置的组（uses_pre）按「自己的 ∪ 前置的」比（前置由钩子单独先建，不在该组自己的干跑输出里：改 nvn_mtl.m 原先一组都对不上）
    { printf '%s\n' "$@"; echo prereq; } | xargs -P "$J" -I{} sh -c 'make -n -B BUILD="$1" "native-test-$2" 2> /dev/null | grep -oE "[A-Za-z0-9_./+-]+\.(c|m|mm|cpp|cc|S|s)\b" | sed "s#^$3/##; s#^$4/##; s#^\./##" | sort -u > "$0/$2.txt"' "$cd" "$b" {} "$PWD" "$(pwd -P)"
    mv -f "$cd/prereq.txt" "$cd/_prereq.txt" 2> /dev/null
    rm -rf "${b:?}"; : > "$cd/.done"; fi
  # 规则里自己再调 $(MAKE) 的组（graphics_session 编整个带 S2A_CS 的宿主、nvn_abba、input_config_apple）：干跑列不全它们的源（11-14 实测
  #   graphics_session 串行干跑 0 个源、并行干跑 2 个），一律照跑。按规则文本静态认，不靠干跑输出
  local rec; rec=" $(grep -l '\$(MAKE)' runtime/tests/mk/*.mk 2> /dev/null | sed 's#.*/##; s#\.mk$##' | tr '\n' ' ') $(awk '/^native-test-[a-z_0-9]+:/{t=substr($1, 13); sub(/:$/, "", t)} /\$\(MAKE\)/{if (t) print t}' Makefile */build.mk 2> /dev/null | tr '\n' ' ') "
  # 只编：这几组自己再编整个宿主（graphics_session 一组 776 秒），宿主本身合入前已由「宿主构建」那段编过；拿出只编、留给合入后完整门禁
  local out=; for k in "$@"; do case $rec in *" $k "*) [ -n "$bo" ] && out="$out $k"; continue;; esac; [ -s "$cd/$k.txt" ] || continue
    if uses_pre "$k"; then [ -s "$cd/_prereq.txt" ] || continue; cat "$cd/$k.txt" "$cd/_prereq.txt"; else cat "$cd/$k.txt"; fi | grep -qxFf <(printf '%s\n' "${c[@]}") || out="$out $k"; done
  echo "${out# }"
}
summary() { local b=; [ "$BON" -gt 0 ] && b="；只编判不了 $BON 组"; [ $R = 0 ] && echo "绿 $G 组$b" || echo "绿 $G 组、红 $R 组（${WHY#、}）$b"; }
BOT=; [ "${GATE_BUILD_ONLY:-}" = 1 ] && BOT="（只编）"
slowest() { printf '%s' "$TM" | sort -rn | head -5 | awk '{printf "%s%s %s 秒", (NR > 1 ? "、" : ""), $2, $1}'; }
# 最慢 5 组单独一行，打在末行之前（末行格式 tools/gate.sh 要解析，不动）
timing() { [ -n "$TM" ] && echo "原生层单测最慢 5 组：$(slowest)；宿主构建 ${HB:-0} 秒"; }
if [ -n "${GATE_ONLY:-}" ]; then
  n=0; for k in $GATE_ONLY; do n=$((n + 1)); done; run_groups $GATE_ONLY
  [ $R = 0 ] || { printf '%s' "$DET"; timing; echo "原生层单测${BOT}（只跑 ${GATE_ONLY}）期望 $n 组全绿 → $(summary)"; exit 1; }
  timing; echo "原生层单测${BOT}（只跑 ${GATE_ONLY}）期望 $n 组全绿 → $(summary)"; exit 0
fi
# 宿主构建与单测组并行（11-14 门禁提速：原先先串行编完宿主再开组）：只编宿主、不跑它，组不用它的产物；两边都要的地址护栏库先建好，免得同时写同一个文件
[ "$(uname -s)" = Darwin ] && make -s "${BUILD:-build}/tests/libs2a_vaguard.dylib" > /dev/null 2>&1
{ t0=$SECONDS; make -s host > "$OUT/_host.out" 2>&1; echo "$? $((SECONDS - t0))" > "$OUT/_host.rc"; } &
# 组 = build.mk 登记的 native-test-* 目标 ∪ 单测文件（graphics/nvn/tests 的单测如 t_dsh_stats 也登记在 runtime/build.mk），减去 GATE_SKIP
SK=" ${GATE_SKIP:-} "; TG=" $(grep -oE '^native-test-[a-z_0-9]+' <<< "$MP" | sed 's/^native-test-//' | sort -u | tr '\n' ' ') "
case $TG in (*[![:space:]]*) ;; (*) echo "原生层单测目标列表为空 → 红"; exit 1;; esac
n=0
RUN=(); for k in $TG; do case $SK in *" $k "*) continue;; esac; RUN+=("$k"); n=$((n + 1)); done
# 按源文件跳组（11-14 门禁提速）：只在本批改动「只有 C 系源文件 / 头文件」时，跳过源文件清单里一个改动都没有的组（11-26 起不分目录；头文件按 include 闭包换成源）。
#   改动里有数据 / 脚本 / mk / Makefile / 链接脚本等任何非源文件、没给 GATE_CHANGED、今天这台机器还没全跑过 → 全跑。
#   每组源文件清单 = make -n -B native-test-<键> 里出现的 .c / .m / .mm / .cpp / .cc / .S / .s（不受增量构建影响），按 Makefile + */build.mk +
#   runtime/tests/mk/*.mk 的内容哈希缓存（变了重算）；清单算不出 / 为空的组照跑。11-14 模拟：今天 64 次触发本钩子的合并里 17 次只需跑 0–5 组
NDS=$(depskip "${RUN[@]}") || NDS=
if [ -n "$NDS" ]; then KEEP=(); SKN=0; for k in "${RUN[@]}"; do case " $NDS " in *" $k "*) SKN=$((SKN + 1));; *) KEEP+=("$k");; esac; done
  RUN=("${KEEP[@]}"); n=$((n - SKN)); fi
[ ${#RUN[@]} -gt 0 ] && run_groups "${RUN[@]}"
wait; read -r hrc HB < "$OUT/_host.rc" 2> /dev/null || { hrc=1; HB=0; }
[ "$hrc" = 0 ] || { tail -20 "$OUT/_host.out"; echo "宿主构建 期望 成功 → 失败"; exit 1; }
for f in runtime/tests/t_*.c runtime/tests/t_*.m graphics/nvn/tests/t_*.c; do
  [ -f "$f" ] || continue; k=${f##*/t_}; k=${k%.*}
  case $SK in *" $k "*) continue;; esac; case $TG in *" $k "*) continue;; esac
  n=$((n + 1)); R=$((R + 1)); WHY="${WHY}、${k} 没有构建目标（有 ${f}，build.mk 没登记 native-test-${k}）"
done
ex=; [ -n "${GATE_SKIP:-}" ] && ex="（${GATE_SKIP} 另跑）"; [ -n "${NDS:-}" ] && ex="${ex}（本批只改 C 源，按源文件清单跳过 $(wc -w <<< "$NDS" | tr -d ' ') 组）"
[ $R = 0 ] || { printf '%s' "$DET"; timing; echo "原生层单测${BOT} 期望 $n 组全绿 → $(summary)$ex"; exit 1; }
timing; echo "原生层：宿主构建成功；单测${BOT} 期望 $n 组全绿 → $(summary)$ex"
