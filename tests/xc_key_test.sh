#!/bin/bash
# 在两种 sed 上用临时文件完成同一替换。
sed_edit() { sed -i.s2a-bak "$1" "$2" && rm -f "$2.s2a-bak"; }
# 着色器阶段键「GAL 翻译代码」分量单测（graphics/tools/shbake/xc_key.sh；四次编译，SPIRV-Cross 目标文件有缓存时约 40 秒）：bash tests/xc_key_test.sh
# 期望按规则手写（不跑被测实现推期望）：同一份源码换个目录 → 键相同；渲染器里加翻译用不到的代码（ObjC 类 + C 函数，旧做法下 ObjC 类是链接根、会进键）→ 键相同；
# 翻译入口 nxgal_prog_xc_mt 函数体里加一句 → 键变；改 SPIRV-Cross 源码（spirv_msl.cpp）→ 键变。改动都按结构打（追加 / 入口函数首行 / 源码文件尾），不依赖具体代码行
# 门禁覆盖：graphics/metal/* graphics/dsx/* graphics/third_party/* tools/toolchain.env compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures/Smaa*.bin graphics/nvn/gfx/nvn/nvn_hdr_policy.h
#   （隔离树必须带齐 xc_key 的构建输入；Makefile 没扩展名，按文件名推不出来——10-22 toolchain271 改 graphics/metal/Makefile 去 include toolchain.env，路由没带上本单测，main 红了才发现）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
LUT=compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures
mk() { mkdir -p "$T/$1/graphics" "$T/$1/tools" "$T/$1/$LUT" && cp -R "$H/graphics/metal" "$H/graphics/dsx" "$H/graphics/third_party" "$T/$1/graphics/" && rm -rf "$T/$1/graphics/metal/tests" && cp "$H/tools/toolchain.env" "$T/$1/tools/" && cp "$H/$LUT/SmaaAreaTexture.bin" "$H/$LUT/SmaaSearchTexture.bin" "$T/$1/$LUT/" && mkdir -p "$T/$1/graphics/nvn/gfx/nvn" && cp "$H/graphics/nvn/gfx/nvn/nvn_hdr_policy.h" "$T/$1/graphics/nvn/gfx/nvn/"; }   # 隔离树使用生产构建输入（gal_present.m 引 HDR 策略头 nvn_hdr_policy.h，同直连层一份）
key() { S2A_XCKEY_TREE=$T/$1 S2A_XCKEY_CACHE=${S2A_XCKEY_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/xckey} bash "$H/graphics/tools/shbake/xc_key.sh"; }
mk a; mk b; mk c; mk d; mk e; mk f
# e：Makefile 只加一个单测目标（编译参数不变）→ 键不变；f：OBJCFLAGS 加一个宏 → 键变（10-22 起键里是编译参数、不是整份 Makefile）
printf '\n$(OUT)/t_xkprobe: $(T_FBR)\n' >> "$T/e/graphics/metal/Makefile"
sed_edit 's/^OBJCFLAGS := /OBJCFLAGS := -DXK_PROBE=1 /' "$T/f/graphics/metal/Makefile"
# 探针打进出图代码 gal_present.m（翻译路径用不到）：原先取「字母序第一个 gal_*.m（排除 gal_prog / gal_spvx）」，10-22 加了翻译期 MSL 改写 gal_border.m 后排第一，
#   往翻译用得到的文件里加代码键变是对的，单测假设失效（不是键算法坏了）
F="$T/b/graphics/metal/gal_present.m"; [ -f "$F" ] || { echo "不通 没有 gal_present.m（单测探针落点要换）"; exit 1; }
printf '\n@interface XkProbe : NSObject\n@end\n@implementation XkProbe\n- (void)run { NSLog(@"xk probe"); }\n@end\nint xk_probe_dead(int x) { return x * 7 + 3; }\n' >> "$F"
python3 - "$T/c/graphics/metal" <<'PY'
import glob, re, sys
for p in glob.glob(sys.argv[1] + '/gal_*.m'):
    s = open(p).read(); m = re.search(r'nxgal_prog_xc_mt\([^;{]*\)\s*\{', s)
    if m: open(p, 'w').write(s[:m.end()] + ' { volatile int xk_probe = 1; (void)xk_probe; } ' + s[m.end():]); break
PY
printf '\nnamespace spirv_cross { int xk_probe_msl() { static volatile int v = 5; return v; } }\n' >> "$T/d/graphics/third_party/spirv_cross/spirv_msl.cpp"
sed_edit 's/static volatile int v = 5; return v; }/static volatile int v = 5; return v; } int xk_used = xk_probe_msl();/' "$T/d/graphics/third_party/spirv_cross/spirv_msl.cpp"
ck "三处改动都打上了（$(basename "$F") 追加、翻译入口加句、SPIRV-Cross 追加）" 'grep -q XkProbe "$F" && grep -rq "xk_probe = 1" "$T/c/graphics/metal" && grep -q xk_used "$T/d/graphics/third_party/spirv_cross/spirv_msl.cpp"'
ka=$(key a); kb=$(key b); kc=$(key c); kd=$(key d); ke=$(key e); kf=$(key f); k0=$(S2A_XCKEY_TREE=$H bash "$H/graphics/tools/shbake/xc_key.sh")
ck "原样四份都出了 16 位键（${ka}）" '[ ${#ka} = 16 ] && [ ${#kb} = 16 ] && [ ${#kc} = 16 ] && [ ${#kd} = 16 ]'
ck "同一份源码换目录 → 键相同（${k0} = ${ka}）" '[ "$k0" = "$ka" ]'
ck "渲染器加翻译用不到的 ObjC 类 + C 函数 → 键相同（${kb}）" '[ "$kb" = "$ka" ]'
ck "翻译入口函数体加一句 → 键变（${kc}）" '[ "$kc" != "$ka" ]'
ck "改 SPIRV-Cross → 键变（${kd}）" '[ "$kd" != "$ka" ]'
ck "Makefile 只加单测目标 → 键相同（${ke}）" '[ "$ke" = "$ka" ]'
ck "OBJCFLAGS 加宏 → 键变（${kf}）" '[ "$kf" != "$ka" ] && grep -q XK_PROBE "$T/f/graphics/metal/Makefile"'
[ $bad = 0 ] && echo "✓ xc_key 单测全过" || { echo "xc_key 单测有不通"; exit 1; }
