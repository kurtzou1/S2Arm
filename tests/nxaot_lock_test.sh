#!/bin/bash
# NativeAOT 静态库缓存锁单测（services/nxaot.sh，假 dotnet、临时缓存目录，约 5 秒）：bash tests/nxaot_lock_test.sh
# 期望（按规则手写）：缓存命中时不拿锁——别的键正在编（持有它自己的锁）、旧式整机锁被活进程占着，命中的也在持锁者活着时就返回（不等锁）、打 🟢 和库路径；
#   没命中且本键的锁被活进程占着 → 等（5 秒内不返回）；持锁进程死了 → 接管（不卡死）；同时在编的不超过 2 份（两个构建槽都被占 → 等，持有者死了接管）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
printf '#!/bin/bash\n[ "$1" = --version ] && { echo 10.0.0-fake; exit 0; }\nexit 1\n' > $T/dotnet; chmod +x $T/dotnet
export S2A_CS_CACHE=$T/c DOTNET=$T/dotnet
K=$(bash "$H/services/nxaot.sh" osx-arm64 2>&1 | grep -oE '键 [0-9a-f]{16}' | head -1 | cut -d' ' -f2)
ck "取到本树的缓存键（${K}）" '[ ${#K} = 16 ]'
# 10-26：键目录里冒出 Python 字节码缓存（并行单测 / 谁跑一次 graphics/widen 的工具）不改键——原先改键，门禁里本单测前后两次键不同、锁对不上判红
PYC=$H/graphics/widen/scan/__pycache__/nxaot_lock_probe.cpython-314.pyc; mkdir -p "$(dirname "$PYC")"; echo x > "$PYC"
K2=$(bash "$H/services/nxaot.sh" osx-arm64 2>&1 | grep -oE '键 [0-9a-f]{16}' | head -1 | cut -d' ' -f2); rm -f "$PYC"; rmdir "$(dirname "$PYC")" 2> /dev/null
ck "键目录里多出 __pycache__/*.pyc 不改键（${K} / ${K2}）" '[ "$K2" = "$K" ]'
mkdir -p $T/c/osx-arm64-$K/rt; echo lib > $T/c/osx-arm64-$K/libs2a_cs.a; echo "-lc++" > $T/c/osx-arm64-$K/ldflags.txt; echo 假 > $T/c/osx-arm64-$K/info.txt
# 命中不等锁：判「锁的持有者还活着时就已返回」，不判墙钟（11-01 gate-host 无缓存全套：算键要哈希 compat/tree 等全部源，高负载下单这一步就超原 5 秒线，rc=124 误红）。
#   持有者活到单测亲手杀它为止（sleep 600 只是寿命上界）；timeout 300 只防挂死——错的写法（命中也等锁）要等持有者死，到 300 秒被杀判红
sleep 600 & LIVE=$!
mkdir -p $T/c/.lock $T/c/.lock-osx-arm64-ffffffffffffffff; echo $LIVE > $T/c/.lock/pid; echo $LIVE > $T/c/.lock-osx-arm64-ffffffffffffffff/pid
touch -t 202610200000 $T/c/osx-arm64-$K; o=$(timeout 300 bash "$H/services/nxaot.sh" osx-arm64 2>&1); r=$?; kill -0 $LIVE 2> /dev/null && la=活着 || la=已退
ck "命中即续租：成品目录时间刷新到现在（gc 30 分钟内用过的不删）" '[ -n "$(find $T/c/osx-arm64-$K -maxdepth 0 -mmin -1)" ]'
ck "命中：别的键在编、整机锁被占也不等锁（rc=${r}，返回时持锁者${la}）" '[ $r = 0 ] && [ $la = 活着 ] && [[ "$o" == *🟢* ]] && [[ "$o" == *"$T/c/osx-arm64-$K/libs2a_cs.a -lc++"* ]]'
rm -rf $T/c/osx-arm64-$K; mkdir -p $T/c/.lock-osx-arm64-$K; echo $LIVE > $T/c/.lock-osx-arm64-$K/pid
timeout 5 bash "$H/services/nxaot.sh" osx-arm64 > /dev/null 2>&1; r=$?
ck "没命中、本键的锁被活进程占着 → 等（5 秒超时 rc=${r}）" '[ $r = 124 ]'
kill $LIVE 2>/dev/null; wait $LIVE 2>/dev/null
o=$(timeout 20 bash "$H/services/nxaot.sh" osx-arm64 2>&1); r=$?
ck "持锁进程死了 → 接管、去编（假 dotnet 编失败 rc=${r}，不是超时）" '[ $r != 124 ] && [[ "$o" == *"dotnet publish 失败"* ]] && [ ! -d $T/c/.lock-osx-arm64-$K ]'
rm -rf $T/c/osx-arm64-$K; sleep 60 & L2=$!; mkdir -p $T/c/.build-1 $T/c/.build-2; echo $L2 > $T/c/.build-1/pid; echo $L2 > $T/c/.build-2/pid
timeout 4 bash "$H/services/nxaot.sh" osx-arm64 > /dev/null 2>&1; r=$?
ck "没命中、两个构建槽都被活进程占着 → 等（4 秒超时 rc=${r}）" '[ $r = 124 ]'
kill $L2 2>/dev/null; wait $L2 2>/dev/null
o=$(timeout 20 bash "$H/services/nxaot.sh" osx-arm64 2>&1); r=$?
ck "构建槽持有者死了 → 接管去编，编完（失败）放槽（rc=${r}）" '[ $r != 124 ] && [[ "$o" == *"dotnet publish 失败"* ]] && [ ! -d $T/c/.build-1 ] && [ ! -d $T/c/.build-2 ]'
rm -rf $T; [ $bad = 0 ] && echo "✓ nxaot 缓存锁单测全过" || { echo "nxaot 缓存锁单测有不通"; exit 1; }
