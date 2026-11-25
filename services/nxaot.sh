#!/bin/bash
# S2Arm 的 NativeAOT 静态库：services/aot/S2A.Aot.csproj（服务层 + Ryujinx + NxGal）→ <整机缓存>/<平台>-<键>/libs2a_cs.a，最后一行输出链接参数（build.mk 把本脚本 stderr 记在各树 build/cs/*.err）。
# 用法：bash services/nxaot.sh [osx-arm64|ios-arm64|tvos-arm64] [--key|--files]（缺省 osx-arm64；--key 只打出缓存键、--files 列出进键的文件，都不编）。失败退出码非 0。
# 缓存：键 = 编译会读的全部输入（C# 源、工程文件、嵌入资源、ABI 头，不含说明 / 脚本 / 表格，见下面 keyfiles）+ dotnet 版本 + 平台的内容哈希，命中秒过；放整机级 ~/.s2arm/run/s2arm/cache/nxaot（S2A_CS_CACHE 可改）。
# 合成：S2A.Aot.o 与运行时的 libbootstrapperdll.o 用 ld -r 合成一个成员（-keep_private_externs）——
#   bootstrapperdll.o 只有加载时初始化函数，单独链会把整个运行时无条件拖进来；合进同一成员后宿主调 S2A_Init 才整块进来（旧库出包线 10-18 实测）。
set -euo pipefail
_s2a_d=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || _s2a_d=; while [ -n "$_s2a_d" ] && [ ! -f "$_s2a_d/tools/_timeout.sh" ] && [ "$_s2a_d" != / ]; do _s2a_d=${_s2a_d%/*}; done; { [ -n "$_s2a_d" ] && [ -f "$_s2a_d/tools/_timeout.sh" ] && . "$_s2a_d/tools/_timeout.sh"; } || :   # 下面 dotnet publish 套 timeout：Mac 没有 GNU timeout，用仓库的（#384）
RID=${1:-osx-arm64}; case $RID in ios-arm64|tvos-arm64|osx-arm64) ;; *) echo "🔴 nxaot：不认识的平台 $RID" >&2; exit 1;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd); B=${S2A_CS_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/nxaot}; mkdir -p "$B"   # 整机级缓存（10-20 出包提速）：键 = 源码内容哈希，各工作树 / 门禁镜像共用一份，原来每树 build/cs 各冷编一遍（冷 124 秒）
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
say() { echo "$*" >&2; }

SRCS=(services/nxaot.sh services/S2A.Services services/aot platform/apple/cs services/nuget.config compat/tree compat/packages graphics/metal/cs graphics/loop graphics/widen tests/visual/galrec graphics/metal/gal_abi.h graphics/metal/tools/abi_hash.py graphics/tools/direct/dsh translator/dmsh_xlate/Program.cs graphics/nvn/gfx/nvn/dmsh_chain.h
  graphics/vulkan/cache/ComputeTranslationProfile.cs graphics/tools/direct/compiler/Sha256.cs)   # 目录外单个编入的源（Ryujinx.Graphics.GAL / S2A.Dsh 的 Compile Include；10-30 前漏在键外，改它们会用旧库）
# 键只算编译真会读的文件（10-30 列车线，调研报告「按内容编译缓存」②）：说明 / 脚本 / 表格 / 图示不进键——三天里改到键目录的 92 个提交有 16 个只动了这些
#   （graphics/widen/scan 的 .sh/.py、graphics/widen/tables 的 .tsv、文档），原先照样整份重跑 ilc。工程里构建时真读的两个脚本 / 头（AbiHash.targets 调 abi_hash.py 读 gal_abi.h）写死保留。
#   键必须覆盖 MSBuild 认的全部编译输入（Compile / EmbeddedResource / AdditionalFiles + 工程文件）：tests/nxaot_key_test.sh 让 MSBuild 列出整个工程闭包的输入逐个核在键里
#   不算 Python 字节码缓存 / 访达附属文件（10-26：谁跑一次 Python 工具就多出 __pycache__/*.pyc、键就变，门禁并行单测里 nxaot_lock_test 前后两次键不同判红）
KEEP=(services/nxaot.sh graphics/metal/tools/abi_hash.py)
keyfiles() { { find "${SRCS[@]}" -type f -not -path '*/obj/*' -not -path '*/bin/*' -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '.DS_Store' \
    -not -name '*.md' -not -name '*.sh' -not -name '*.py' -not -name '*.tsv' -not -name '*.txt' -not -name '*.svg' -not -name '.gitignore' -not -name '*.patch'; printf '%s\n' "${KEEP[@]}"; } | LC_ALL=C sort -u; }
case ${2:-} in --files) cd "$ROOT" && keyfiles; exit 0;; esac   # 单测用：列出进键的文件（仓库相对路径）
K=$( { cd "$ROOT" && keyfiles | xargs shasum -a 256; "$DN" --version; echo "$RID"; } | shasum -a 256 | cut -c1-16)
case ${2:-} in --key) echo "$K"; exit 0;; esac   # 单测用：只算键、不编
O=$B/$RID-$K
# 锁按键（10-21 测试出包线：原先整机一把锁、且先拿锁再算键——门禁编 iOS 的几分钟里，所有命中缓存的出包 / Mac 局全排着，出包槽持有者干等 8 分钟）：
#   命中不拿锁（成品目录 mv 原子到位，看见就是完整的）；没命中才拿本键的锁，拿到后再看一次（别人刚编完就直接用）。持锁进程死了接管
hit() { [ -s "$O/libs2a_cs.a" ] && [ -s "$O/ldflags.txt" ] && [ -d "$O/rt" ]; }   # 缺 rt/ = 11-25 前的旧式条目（链接参数写死编译者 HOME 下 NuGet 包的绝对路径），按没命中重编
if ! hit; then
  until mkdir "$B/.lock-$RID-$K" 2>/dev/null; do p=$(cat "$B/.lock-$RID-$K/pid" 2>/dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -rf "$B/.lock-$RID-$K"; sleep 0.5; done
  echo $$ > "$B/.lock-$RID-$K/pid"; trap 'rm -rf "$B/.lock-$RID-$K"' EXIT
fi
if ! hit; then
    # 同时在编的不超过 S2A_NXAOT_BUILDS（缺省 2）份：ilc 一份吃满多核，各线树键各不相同时一起编会把整机压到负载 100+（10-21 01:0x 实测 110 / 18 核，门禁各步撞墙钟超时）
    nb=${S2A_NXAOT_BUILDS:-2}; slot=; until [ -n "$slot" ]; do for i in $(seq 1 "$nb"); do
      if mkdir "$B/.build-$i" 2>/dev/null; then echo $$ > "$B/.build-$i/pid"; slot=$B/.build-$i; break; fi
      p=$(cat "$B/.build-$i/pid" 2>/dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -rf "$B/.build-$i"; done; [ -n "$slot" ] || sleep 1; done
    trap 'rm -rf "$B/.lock-$RID-$K" "$slot"' EXIT
    say "nxaot：编 $RID NativeAOT 静态库（键 ${K}）→ ${O}"; t0=$(date +%s)
    rm -rf "$O.tmp"; mkdir -p "$O.tmp"
    timeout 1200 "$DN" publish "$ROOT/services/aot/S2A.Aot.csproj" -c Release -r "$RID" -nodeReuse:false -p:UseSharedCompilation=false \
        -p:PublishDir="$O.tmp/publish/" -v quiet > "$O.tmp/publish.log" 2>&1 || { say "🔴 nxaot：dotnet publish 失败（$O.tmp/publish.log）"; grep -E " error " "$O.tmp/publish.log" | sort -u | head -10 >&2; exit 1; }
    # 运行时包位置随 .NET 版本不同：PublishAotUsingRuntimePack（iOS）走 NuGet 包（downloadDependencies 里有版本），
    # 其它 RID（macOS 等）由 SDK 自带的 pack 提供（$DOTNET_ROOT/packs），project.assets.json 里没有版本行。
    # 两处都找，找到 libbootstrapperdll.o 为止；都没有才报红。
    RP=
    RV=$(python3 -c "import json,sys;j=json.load(open(sys.argv[1]))
print(next((d['version'].strip('[]').split(',')[0] for fw in j['project']['frameworks'].values() for d in fw.get('downloadDependencies',[]) if d['name']=='Microsoft.NETCore.App.Runtime.NativeAOT.'+sys.argv[2]), ''))" "$ROOT/services/aot/obj/project.assets.json" "$RID" 2> /dev/null || true)
    if [ -n "$RV" ]; then
      RP=${NUGET_PACKAGES:-$HOME/.nuget/packages}/microsoft.netcore.app.runtime.nativeaot.$RID/$RV/runtimes/$RID/native
    fi
    if [ -z "$RP" ] || [ ! -f "$RP/libbootstrapperdll.o" ]; then   # SDK 自带 pack：版本取 SDK 里装的那份
      for p in "${DOTNET_ROOT:-$(dirname "$(dirname "$(readlink -f "$DN" 2> /dev/null || echo "$DN")")")}"/packs/Microsoft.NETCore.App.Runtime.NativeAOT."$RID"/*/runtimes/"$RID"/native; do
        [ -f "$p/libbootstrapperdll.o" ] && { RP=$p; RV=$(basename "$(dirname "$(dirname "$(dirname "$p")")")"); break; }
      done
    fi
    [ -n "$RP" ] && [ -f "$RP/libbootstrapperdll.o" ] || { say "🔴 nxaot：运行时包不在 ${RP}（.NET 既没从 NuGet 给，SDK packs 里也没有）"; exit 1; }
    # Brotli：System.IO.Compression.Native 要它。微软官方运行时包同目录自带 libbrotli{enc,dec,common}.a；
    # 源码构建版 .NET（如 Homebrew，包里有 nonportable.txt）自带的 NativeAOT 包不带，下面按「有就链」会静默漏掉，最后链接才报 _Brotli* 未定义（10-24 #100 D01 实撞）。链接前查、直接说怎么办
    if [ -f "$RP/libSystem.IO.Compression.Native.a" ] && ! { [ -f "$RP/libbrotlienc.a" ] && [ -f "$RP/libbrotlidec.a" ] && [ -f "$RP/libbrotlicommon.a" ]; }; then
      say "🔴 nxaot：${DN} 用的 NativeAOT 运行时包（${RP}）没有 Brotli 静态库：这是源码构建版 .NET（如 Homebrew）的包，${RID} 版 C# 库链接会缺 _Brotli* 符号。改用微软官方 SDK：python3 pack/jobs/applenv.py --install dotnet（装到 ~/.dotnet，不要管理员密码），再 export DOTNET=~/.dotnet/dotnet DOTNET_ROOT=~/.dotnet；Homebrew 版可以留着"; exit 1
    fi
    (cd "$O.tmp" && ar x publish/S2A.Aot.a && xcrun ld -r -keep_private_externs -arch arm64 S2A.Aot.o "$RP/libbootstrapperdll.o" -o all.o \
        && libtool -static -o libs2a_cs.a all.o 2>/dev/null && rm -f S2A.Aot.o all.o) || { say "🔴 nxaot：合成 libs2a_cs.a 失败"; exit 1; }
    n=$(nm -gU "$O.tmp/libs2a_cs.a" 2>/dev/null | grep -c ' _S2A_Init$' || true)
    [ "$n" -eq 1 ] || { say "🔴 nxaot：libs2a_cs.a 里没有 S2A_Init 导出"; exit 1; }
    # 运行时静态库拷进本条目 rt/（约 11 MB，APFS 上 cp -c 是克隆不占盘），ldflags.txt 只记相对路径：缓存条目自带链接所需的一切。
    #   11-25 门禁 iOS 全量编译红：共用缓存（S2A_CS_CACHE）的 ldflags 写死了编译那个槽位 HOME 下 NuGet 包的绝对路径，槽位根挪盘删掉后，
    #   别的槽位命中这份就链接报 clang no such file（46 份里 31 份指向已删目录）；条目自包含后与谁编的、那个 HOME 还在不在无关
    mkdir -p "$O.tmp/rt"; L=
    for l in Runtime.WorkstationGC eventpipe-disabled standalonegc-disabled aotminipal stdc++compat System.Native System.Globalization.Native System.IO.Compression.Native System.Security.Cryptography.Native.Apple System.Net.Security.Native brotlienc brotlidec brotlicommon; do
        [ -f "$RP/lib$l.a" ] || continue
        cp -c "$RP/lib$l.a" "$O.tmp/rt/" 2> /dev/null || cp "$RP/lib$l.a" "$O.tmp/rt/" || { say "🔴 nxaot：拷运行时库 lib$l.a 进缓存失败"; exit 1; }
        L="$L rt/lib$l.a"
    done
    FW="-lc++ -lz -lcompression -framework Security -framework AudioToolbox -framework Network -framework Foundation -framework CoreFoundation -lobjc"
    case $RID in tvos-arm64) ;; *) FW="$FW -framework GSS";; esac; case $RID in osx-arm64) FW="$FW -framework CryptoKit";; esac   # Net.Security.Native 在 Mac / iOS 引 GSS；tvOS 没有 GSS 框架（tvOS 运行时包也不带 Net.Security.Native）
    echo "${L# } $FW" > "$O.tmp/ldflags.txt"
    echo "运行时包 ${RV}；用时 $(( $(date +%s) - t0 )) 秒" > "$O.tmp/info.txt"
    rm -rf "$O"; mv "$O.tmp" "$O"
fi
touch "$O"   # 取用即续租：gc 按目录时间判「30 分钟内用过」不删，链接方拿到路径后不会被清掉
# 按出包可重建缓存同一口径回收（pack/jobs/cache_retention.py trim：总量上限 = 0.25 ×（盘剩余 + 缓存总量），最久没用的先删）。
#   1 小时内用过的一律不删（上面刚续租本份）：10-21 原生层线实证「每平台只留最新 2 份」删掉了别的树刚拿到路径、还没链接完的那份，
#   ld 报 libs2a_cs.a not found，按用过的时间保护就不会。缓存在缺省位置时连同运行区里别的可重建缓存一起算总量，另指的（门禁共用）只算它自己。
#   每次调用都回收、不只在现编之后（11-15 合入运维）：原先只在现编分支里调，读不读 cache_retention.py 取决于缓存命没命中——
#   门禁 iOS 编译的出壳闭包核对第一次现编读到、同键重跑命中没读到，「先红后绿」被分诊判成不稳定放进 main（8dcd7da87）。回收一次实测 < 0.1 秒
RR=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm
if [ "$B" = "$RR/cache/nxaot" ]; then python3 "$ROOT/pack/jobs/cache_retention.py" trim "$RR" > /dev/null 2>&1; else python3 "$ROOT/pack/jobs/cache_retention.py" trim "$RR" "$B" > /dev/null 2>&1; fi
say "🟢 nxaot（${RID}）：$(cat "$O/info.txt")，libs2a_cs.a $(( $(stat -f %z "$O/libs2a_cs.a") >> 20 )) MB（键 ${K}）"
# 链接参数按缓存当前位置拼：rt/ 相对项前缀条目目录。条目目录带空格（缓存在「Application Support」下）时 rt/ 项用无空格别名——会原样进 make 的链接参数，
#   make 按空格拆（tools/nospace.sh；10-26 冷缓存带空格实跑 clang no such file '空格'）；ldflags.txt 本身不含空格，按空白切安全
source "$ROOT/tools/nospace.sh"; ON=$(s2a_nospace "$O"); IFS= read -r LN < "$O/ldflags.txt"; OUT="$O/libs2a_cs.a"
for w in $LN; do case $w in rt/*) OUT="$OUT $ON/$w";; *) OUT="$OUT $w";; esac; done; echo "$OUT"
