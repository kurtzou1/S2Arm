#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.py translator/vk_shaders.py tests/direct_lib_win_test.sh
# 直连库 Vulkan 款 RomFS 没有 SPIR-V（游戏运行时生成：银河 1 / 2）的出法：bash tests/direct_lib_win_test.sh（假仓库 + 桩，约 1 秒）
#   11-05 维护者：出包从不允许起一局游戏；Windows 版是纯 Windows、不依赖 Mac。原先 Mac 上起宿主 60 秒抓 SPIR-V、Windows 上退 75 交回 Mac。
#   gfx_api.py 换成桩按 FAKE_API 报接口，RomFS 是空的（没有 SPIR-V），真 vk_shaders.py。Mac / Windows 是同一份 direct_lib.py、同一条路（11-20 起不经 Git Bash）。期望手写：
#   ①② 退 0、末行 🟡「出包不起局」；<out>/vk/vk_shaders.tsv 只有表头（首行「# s2arm-vk-lib <口径号>」= vk_lib.h S2A_VK_LIB_ABI，没有数据行）、没有 metallib、keys.tsv 为空；
#      留缓存那份 <缓存>/vkmac/vk/ 也只有表头
#   ③ 旧库残留：输出目录里先放一个 vk_shaders.metallib → 出完被删（不让旧库对着空表被载）
#   ④ 仓库里没有出包期起局抓着色器的脚本（graphics/tools/direct/vk_capture.sh）
#   ⑤ 跑局知识快照（S2A_RUN_KNOWLEDGE）的 vk_spv/ 里有 1 支设备现编存下的 SPIR-V → 不出空表，vk_shaders.py（这一项换成记参数的桩）收到的来源里有 <快照>/vk_spv、
#      日志一行「跑局知识里有设备现编存下的 SPIR-V 1 支」；①–③ 给空快照（不带 vk_spv/）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
P=$T/repo; mkdir -p $P/graphics/tools/direct $P/graphics/nvn/tools $P/translator $P/tools $T/bin
cp "$H/graphics/tools/direct/direct_lib.py" $P/graphics/tools/direct/; cp "$H/tools/progress.py" $P/tools/; cp "$H/graphics/nvn/tools/romfs_list.py" $P/graphics/nvn/tools/
cp "$H/translator/vk_shaders.py" $P/translator/; mkdir -p $P/tools; cp "$H/tools/pool_workers.py" $P/tools/;  # vk_shaders 经它取核数（#1332）
 cp "$H/graphics/tools/spirv_msl.py" $P/graphics/tools/; cp "$H/tools/nostall.py" $P/tools/
printf 'import os\nprint(os.environ.get("FAKE_API", "nvn") + "\\t桩")\n' > $P/graphics/nvn/tools/gfx_api.py
printf '#!/bin/sh\nexit 0\n' > $T/bin/spirv-cross
chmod +x $T/bin/*
ABI=$(sed -n 's/^#define S2A_VK_LIB_ABI \([0-9]*\).*/\1/p' "$H/graphics/nvn/gfx/vk/vk_lib.h")
G=$T/root; mkdir -p $G/romfs $G/exefs; echo main > $G/exefs/main; printf 'title_id\t0100abcd00000000\n' > $G/unpack.tsv
mkdir -p $T/kn0 $T/kn1/vk_spv; printf '\003\002\043\007abcdefghijklmnop' > $T/kn1/vk_spv/0123456789abcdef.spv
dl() { rm -rf $T/out $T/cache; mkdir -p $T/out/vk; [ -n "${2:-}" ] && echo stale > $T/out/vk/vk_shaders.metallib
  env S2A_PY="$(command -v python3)" S2A_DIRECT_CACHE=$T/cache S2A_RUN_KNOWLEDGE=${KNW:-$T/kn0} FAKE_API=vulkan PATH="$1:$PATH" python3 $P/graphics/tools/direct/direct_lib.py $G $T/out > $T/log 2>&1; echo $?; }
hdr() { [ "$(head -1 "$1")" = "# s2arm-vk-lib $ABI" ] && [ -z "$(grep -v '^#' "$1")" ]; }
ok() { [ "$1" = 0 ] && tail -1 $T/log | grep -q '🟡.*出包不起局' && hdr $T/out/vk/vk_shaders.tsv && [ ! -e $T/out/vk/vk_shaders.metallib ] && [ -f $T/out/keys.tsv ] && [ ! -s $T/out/keys.tsv ]; }
rc=$(dl $T/bin); ck "①② 退 0（真 ${rc}）、🟡 不起局、表只有表头（口径 ${ABI}）、没库、keys.tsv 空，缓存那份也只有表头" 'ok $rc && hdr $T/cache/vkmac/vk/vk_shaders.tsv && [ ! -e $T/cache/vkmac/vk/vk_shaders.metallib ]'
rc=$(dl $T/bin stale); ck "③ 输出目录里的旧库被删（真 ${rc}）" 'ok $rc'
ck "④ 仓库里没有出包期起局抓着色器的脚本" '[ ! -e "$H/graphics/tools/direct/vk_capture.sh" ]'
cat > $P/translator/vk_shaders.py <<STUB
import os, sys
open("$T/vkargs", "w").write("\\n".join(sys.argv[1:]))
a = [x for x in sys.argv[1:] if x != "--ios"]; ios = sys.argv[sys.argv.index("--ios") + 1]
for d in (a[-2], ios):
    os.makedirs(os.path.join(d, "vk"), exist_ok=True); open(os.path.join(d, "vk", "vk_shaders.metallib"), "wb").write(b"lib"); open(os.path.join(d, "vk", "vk_shaders.tsv"), "w").write("# s2arm-vk-lib $ABI\\n0123456789abcdef\\tvert\\t\\t-\\n")
STUB
rc=$(KNW=$T/kn1 dl $T/bin); ck "⑤ 快照里有设备现编 SPIR-V → 交 vk_shaders.py 翻（真 ${rc}）、来源含 <快照>/vk_spv、记一行 1 支" '[ "$rc" = 0 ] && grep -qx "$T/kn1/vk_spv" $T/vkargs && grep -q "跑局知识里有设备现编存下的 SPIR-V 1 支" $T/log'
# ⑥ 出库期间缓存目录有占用标记（11-07：清理器只认 <缓存>/*.stage.<活进程号>，Vulkan / OpenGL 分支原先不放，出包中途被扫到会被当成没人用）：
#   vk_shaders.py 换成桩，跑的当下看 <缓存>/vk.stage.* 在不在、号对应的进程活不活；出完标记删掉。没放标记的写法下「当下没有标记」→ 红（反证）
cat > $P/translator/vk_shaders.py <<STUB
import glob, os, sys
m = glob.glob("$T/cache/vk.stage.*"); alive = []
for f in m:
    try: os.kill(int(f.rsplit(".", 1)[1]), 0); alive.append(f)
    except (OSError, ValueError): pass
open("$T/vkstage", "w").write(f"{len(m)} {len(alive)}")
a = [x for x in sys.argv[1:] if x != "--ios"]; ios = sys.argv[sys.argv.index("--ios") + 1]
for d in (a[-2], ios):
    os.makedirs(os.path.join(d, "vk"), exist_ok=True); open(os.path.join(d, "vk", "vk_shaders.metallib"), "wb").write(b"lib"); open(os.path.join(d, "vk", "vk_shaders.tsv"), "w").write("# s2arm-vk-lib $ABI\nk\tv\n")
STUB
rm -f $T/vkstage; rc=$(KNW=$T/kn1 dl $T/bin); left=$(ls $T/cache/vk.stage.* 2> /dev/null | wc -l | tr -d ' ')
ck "⑥ 出库当下缓存目录有活的占用标记 vk.stage.<进程号>（当下 标记数 活着数 = $(cat $T/vkstage 2> /dev/null)），出完标记删掉（剩 ${left}）" '[ "$(cat $T/vkstage 2> /dev/null)" = "1 1" ] && [ "$left" = 0 ]'
[ $bad = 0 ] && echo "✓ direct_lib_win：全通" || { echo "✗ direct_lib_win：有不通"; tail -5 $T/log; }
exit $bad
