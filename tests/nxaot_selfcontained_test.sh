#!/bin/bash
# NativeAOT 缓存条目自包含单测（services/nxaot.sh，假 dotnet、临时缓存目录，约 5 秒）：bash tests/nxaot_selfcontained_test.sh
# 11-25 门禁 iOS 全量编译红：共用缓存的 ldflags.txt 写死编译槽位 HOME 下 NuGet 包的绝对路径，那个 HOME 删掉后别的槽位命中就 clang no such file。期望（按规则手写）：
#   ① 新式条目（有 rt/，ldflags.txt 记 rt/ 相对项）→ 命中，打出的链接参数 = 条目/libs2a_cs.a 条目/rt/libfoo.a -lc++
#   ② 旧式条目（没有 rt/，ldflags.txt 是别处的绝对路径）→ 不当命中、去编（假 dotnet 编失败），输出里不出现那个旧路径
#   ③ 缓存根带空格 → rt/ 项换成不带空格的别名，别名解析回条目里的同一个文件
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
printf '#!/bin/bash\n[ "$1" = --version ] && { echo 10.0.0-fake; exit 0; }\nexit 1\n' > $T/dotnet; chmod +x $T/dotnet
export DOTNET=$T/dotnet
key() { S2A_CS_CACHE=$1 bash "$H/services/nxaot.sh" osx-arm64 2>&1 | grep -oE '键 [0-9a-f]{16}' | head -1 | cut -d' ' -f2; }
mk() { mkdir -p "$1/rt"; echo lib > "$1/libs2a_cs.a"; echo rt > "$1/rt/libfoo.a"; echo "rt/libfoo.a -lc++" > "$1/ldflags.txt"; echo 假 > "$1/info.txt"; }
K=$(key "$T/c"); ck "取到缓存键（${K}）" '[ ${#K} = 16 ]'
O=$T/c/osx-arm64-$K; mk "$O"
o=$(S2A_CS_CACHE=$T/c timeout 120 bash "$H/services/nxaot.sh" osx-arm64 2> /dev/null); r=$?
ck "① 新式条目命中、链接参数拼到条目内（rc=${r}）" '[ $r = 0 ] && [ "$o" = "$O/libs2a_cs.a $O/rt/libfoo.a -lc++" ]'
rm -rf "$O"; mkdir -p "$O"; echo lib > "$O/libs2a_cs.a"; echo "/gone/homes/1/libs2a_cs.a /gone/homes/1/libfoo.a -lc++" > "$O/ldflags.txt"
o=$(S2A_CS_CACHE=$T/c timeout 120 bash "$H/services/nxaot.sh" osx-arm64 2>&1); r=$?
ck "② 旧式条目（无 rt/）不当命中、去编（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *"dotnet publish 失败"* ]] && [[ "$o" != *"/gone/"* ]]'
S="$T/有 空格/c"; KS=$(key "$S"); OS=$S/osx-arm64-$KS; mk "$OS"
o=$(S2A_CS_CACHE=$S TMPDIR=$T/tmp timeout 120 bash "$H/services/nxaot.sh" osx-arm64 2> /dev/null); r=$?
rtw=$(printf '%s\n' "$o" | grep -o '[^ ]*/rt/libfoo.a')
ck "③ 缓存根带空格：rt/ 项是无空格别名、指回条目里的文件（rc=${r}，${rtw}）" '[ $r = 0 ] && [ -n "$rtw" ] && [[ "$rtw" != *" "* ]] && [ "$(cat "$rtw")" = rt ] && [[ "$o" == *" -lc++" ]]'
[ $bad = 0 ] && echo "✓ nxaot 缓存自包含单测全过" || { echo "nxaot 缓存自包含单测有不通"; exit 1; }
