#!/bin/bash
# 宽屏门禁离线库缓存键单测（tests/visual/widen_lib_key.sh；四次编译，SPIRV-Cross 目标文件有缓存时约 40 秒）：bash tests/visual/widen_lib_key_test.sh
# 期望按规则手写：同一份源码换目录 → 键相同；渲染器里加翻译用不到的代码（ObjC 类 + C 函数）→ 键相同（旧键 = graphics/metal 全文件哈希，这条红）；
# 翻译入口 nxgal_prog_xc_mt 函数体加一句 → 键变；改打包脚本 gal_offline.py → 键变。改动按结构打（追加 / 入口函数首行 / 文件尾），不依赖具体代码行
set -u; H=$(cd "$(dirname "$0")/../.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
LUT=compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures
mk() { mkdir -p "$T/$1/graphics" "$T/$1/tools" "$T/$1/$LUT" && cp -R "$H/graphics/metal" "$H/graphics/dsx" "$H/graphics/third_party" "$T/$1/graphics/" && rm -rf "$T/$1/graphics/metal/tests" && cp "$H/tools/toolchain.env" "$T/$1/tools/" && cp "$H/$LUT/SmaaAreaTexture.bin" "$H/$LUT/SmaaSearchTexture.bin" "$T/$1/$LUT/" && mkdir -p "$T/$1/graphics/nvn/gfx/nvn" && cp "$H/graphics/nvn/gfx/nvn/nvn_hdr_policy.h" "$T/$1/graphics/nvn/gfx/nvn/"; }   # gal_present.m 引 HDR 策略头（同 tests/xc_key_test.sh 隔离树）
key() { bash "$H/tests/visual/widen_lib_key.sh" "$T/$1"; }
mk a; mk b; mk c; mk e
F="$T/b/graphics/metal/gal_present.m"
[ -f "$F" ] || { echo "不通 没有 gal_present.m（单测探针落点要换）"; exit 1; }
printf '\n@interface WkProbe : NSObject\n@end\n@implementation WkProbe\n- (void)run { NSLog(@"wk probe"); }\n@end\nint wk_probe_dead(int x) { return x * 7 + 3; }\n' >> "$F"
python3 - "$T/c/graphics/metal" <<'PY'
import glob, re, sys
for p in glob.glob(sys.argv[1] + '/gal_*.m'):
    s = open(p).read(); m = re.search(r'nxgal_prog_xc_mt\([^;{]*\)\s*\{', s)
    if m: open(p, 'w').write(s[:m.end()] + ' { volatile int wk_probe = 1; (void)wk_probe; } ' + s[m.end():]); break
PY
printf '\n# wk probe\n' >> "$T/e/graphics/metal/tools/gal_offline.py"
ck "三处改动都打上了（$(basename "$F") 追加、翻译入口加句、gal_offline.py 追加）" 'grep -q WkProbe "$F" && grep -rq "wk_probe = 1" "$T/c/graphics/metal" && grep -q "wk probe" "$T/e/graphics/metal/tools/gal_offline.py"'
ka=$(key a); kb=$(key b); kc=$(key c); ke=$(key e); mk x; kx=$(key x)
ck "原样四份都出了 16 位键（${ka}）" '[ ${#ka} = 16 ] && [ ${#kb} = 16 ] && [ ${#kc} = 16 ] && [ ${#ke} = 16 ]'
ck "同一份源码换目录 → 键相同（${kx} = ${ka}）" '[ "$kx" = "$ka" ]'
ck "渲染器加翻译用不到的 ObjC 类 + C 函数 → 键相同（${kb}）" '[ "$kb" = "$ka" ]'
ck "翻译入口函数体加一句 → 键变（${kc}）" '[ "$kc" != "$ka" ]'
ck "改打包脚本 gal_offline.py → 键变（${ke}）" '[ "$ke" != "$ka" ]'
[ $bad = 0 ] && echo "✓ 宽屏门禁离线库键单测全过" || { echo "宽屏门禁离线库键单测有不通"; exit 1; }
