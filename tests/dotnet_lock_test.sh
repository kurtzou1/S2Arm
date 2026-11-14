#!/bin/bash
# 门禁覆盖：tools/dotnet_lock.c
# 同一棵树 C# 编译串行（tools/dotnet_lock.c，门禁开头现编；11-10 / 11-11）：假 dotnet 也是编出来的程序（记子命令、开始 / 结束时刻、两个环境变量，睡 NAP 秒），约 15 秒
#   期望按规则手写：① 两份 build 同时起 → 运行区间不重叠；② 别人持锁时 dotnet x.dll 不等锁、1 秒内跑完；③ 持锁的 build 被 kill -9 → 下一份 3 秒内跑完；
#   ⑥ env -i 只给 DOTNET（S2A_DOTNET_REAL 不在）：自己按 PATH 找真 dotnet、跳过自己（启动器作业环境单测 userenv ③，11-11）
#   ④ 真 dotnet 看到 MSBUILDDISABLENODEREUSE=1；⑤ 调用方给的 DYLD_INSERT_LIBRARIES 原样到真 dotnet（脚本包装会被 SIP 清掉，11-11 服务层 t_native_provider 红）
#   ⑦ 真 dotnet 拉起一个常驻子进程（同 Roslyn 编译服务 VBCSCompiler：继承打开的文件描述符、构建结束后不退）再退出 → 下一份 build 3 秒内跑完
#      （11-11 门禁机：锁 fd 随 exec 留在 dotnet 里、被编译服务继承，锁永远不放，graphics/gate.sh 连挂两次）；⑧ 包装的退出码 = 真 dotnet 的退出码
#   ③ 的「被杀」按门禁的杀法杀整个进程组（包装 + 真 dotnet）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
cc -O2 -o "$T/dotnet" "$H/tools/dotnet_lock.c" || { echo "不通 编译 tools/dotnet_lock.c"; exit 1; }
cat > "$T/fake.c" <<'F'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
static double now(void) { struct timeval t; gettimeofday(&t, 0); return t.tv_sec + t.tv_usec / 1e6; }
int main(int c, char **v) {
    FILE *f = fopen(getenv("LOGF"), "a"); const char *nr = getenv("MSBUILDDISABLENODEREUSE"), *dy = getenv("DYLD_INSERT_LIBRARIES");
    fprintf(f, "%s 开始 %.3f nr=%s dy=%s\n", c > 1 ? v[1] : "-", now(), nr ? nr : "", dy ? dy : ""); fflush(f);
    if (getenv("DAEMON") && fork() == 0) { setsid(); sleep(60); _exit(0); }   // ⑦：常驻子进程，继承全部打开的 fd
    if (!(c > 1 && strstr(v[1], ".dll"))) { const char *n = getenv("NAP"); usleep((useconds_t)((n ? atof(n) : 2) * 1e6)); }
    fprintf(f, "%s 结束 %.3f\n", c > 1 ? v[1] : "-", now()); fclose(f); return getenv("RC") ? atoi(getenv("RC")) : 0; }
F
cc -O2 -o "$T/fake" "$T/fake.c" || { echo "不通 编译假 dotnet"; exit 1; }
export S2A_DOTNET_REAL=$T/fake S2A_DOTNET_LOCK=$T/lk LOGF=$T/log; D=$T/dotnet
"$D" build & a=$!; sleep 0.2; "$D" build & b=$!; wait $a $b
ov=$(python3 -c 'import sys
ev = [l.split() for l in open(sys.argv[1])]
s = [float(x[2]) for x in ev if x[1] == "开始"]; e = [float(x[2]) for x in ev if x[1] == "结束"]
print("不重叠" if len(s) == 2 and max(s) >= min(e) - 0.05 else "重叠 %s %s" % (s, e))' $T/log)
ck "① 两份 build 同时起 → 运行区间不重叠（${ov}）" '[ "$ov" = 不重叠 ]'
ck "④ 真 dotnet 看到 MSBUILDDISABLENODEREUSE=1" 'grep -q "nr=1" $T/log'
: > $T/log; NAP=5 "$D" build & a=$!; sleep 0.5; t0=$SECONDS; "$D" x.dll; dt=$((SECONDS - t0)); wait $a
ck "② 别人持锁时 dotnet x.dll 不等锁（${dt} 秒）" '[ $dt -le 1 ]'
. "$H/tools/safe_killpg.sh"; set -m; : > $T/log; NAP=30 "$D" build & a=$!; set +m; sleep 0.5; safe_killpg KILL "$a" "$D build"; wait $a 2> /dev/null; t0=$SECONDS; NAP=0 "$D" build; dt=$((SECONDS - t0))
ck "③ 持锁的 build 被 kill -9 → 下一份 3 秒内跑完（${dt} 秒）" '[ $dt -le 3 ]'
printf 'int s2a_dl_test_marker(void) { return 1; }\n' > $T/e.c; cc -shared -o $T/empty.dylib $T/e.c   # 真能插入的空库（插不存在的库 dyld 直接中止）
: > $T/log; env DYLD_INSERT_LIBRARIES=$T/empty.dylib "$D" x.dll 2> /dev/null
ck "⑤ DYLD_INSERT_LIBRARIES 原样传到真 dotnet（$(grep -o 'dy=[^ ]*' $T/log | head -1)）" 'grep -q "dy=$T/empty.dylib" $T/log'
mkdir -p $T/sh $T/rb $T/h; cp $T/dotnet $T/sh/dotnet; cp $T/fake $T/rb/dotnet; : > $T/log
env -i HOME=$T/h PATH=$T/sh:$T/rb LOGF=$T/log $T/sh/dotnet x.dll; r6=$?
ck "⑥ env -i 只给包装：PATH 上跳过自己、找到真 dotnet（rc=${r6}）" '[ $r6 = 0 ] && grep -q "^x.dll 开始" $T/log'
: > $T/log; DAEMON=1 NAP=0 "$D" build; t0=$SECONDS; NAP=0 perl -e 'alarm 10; exec @ARGV' "$D" build; r7=$?; dt=$((SECONDS - t0))
pkill -f "$T/fake" 2> /dev/null
ck "⑦ 真 dotnet 留下常驻子进程后，下一份 build 3 秒内跑完（${dt} 秒，rc=${r7}）" '[ $r7 = 0 ] && [ $dt -le 3 ]'
RC=3 NAP=0 "$D" build; r8=$?
ck "⑧ 包装退出码 = 真 dotnet 退出码（${r8}，应 3）" '[ $r8 = 3 ]'
# ⑨ 编译并发封顶（11-13）：没自己给 -m 的编译类子命令紧跟子命令补 -m:4；显式 -m / -maxcpucount、S2A_DOTNET_M=0、restore、dotnet x.dll 都不补；S2A_DOTNET_M=6 补 -m:6
printf '#!/bin/bash\necho "$*" >> "$ARGF"\n' > $T/argv.sh; chmod +x $T/argv.sh; export ARGF=$T/argf
m9() { : > $T/argf; env S2A_DOTNET_REAL=$T/argv.sh S2A_DOTNET_LOCK= "$@" > /dev/null 2>&1; cat $T/argf; }
ck "⑨a build 无 -m → 补 -m:4（$(m9 "$D" build p.csproj -c Release)）" '[ "$(m9 "$D" build p.csproj -c Release)" = "build -m:4 p.csproj -c Release" ]'
ck "⑨b 显式 -m:2 不动" '[ "$(m9 "$D" build -m:2 p.csproj)" = "build -m:2 p.csproj" ]'
ck "⑨c 显式 -maxcpucount:8 / /m 不动" '[ "$(m9 "$D" publish p.csproj -maxcpucount:8)" = "publish p.csproj -maxcpucount:8" ] && [ "$(m9 "$D" msbuild /m p.proj)" = "msbuild /m p.proj" ]'
ck "⑨d S2A_DOTNET_M=0 不补、=6 补 -m:6" '[ "$(m9 env S2A_DOTNET_M=0 "$D" build p)" = "build p" ] && [ "$(m9 env S2A_DOTNET_M=6 "$D" test p)" = "test -m:6 p" ]'
ck "⑨e restore / x.dll 不补；-- 之后的 -m 不算" '[ "$(m9 "$D" restore p)" = "restore p" ] && [ "$(m9 "$D" x.dll -m)" = "x.dll -m" ] && [ "$(m9 "$D" test p -- -m)" = "test -m:4 p -- -m" ]'
[ $bad = 0 ] && echo "C# 构建锁单测全过" || { echo "C# 构建锁单测有不通"; cat $T/log; exit 1; }
