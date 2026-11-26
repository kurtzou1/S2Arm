#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/batch/C1Cb.cs tests/c1cb_const_extent_test.sh
# 常量读范围表（C1Cb，cb_extent.tsv）给「有动态下标」的 uniform 槽也写常量下标读到哪（c<reg>:字节，#2237 / #1763）：bash tests/c1cb_const_extent_test.sh（约 30 秒，编 dsh_batch）
#   纸片马力欧 RPG 的片元着色器 fp_c14 常量读到 _m0[147]、同槽又有动态下标：原先整槽不出界（cb_ext = 0），宿主不知道该补零到哪；游戏只绑 16 字节时常量读越界、GPU 挂死。
#   夹具：k_b.metal 槽 0（fp_c3）读 _m0[147u] 和 _m0[i]（i 来自 fp_c4，动态），槽 1（fp_c4）只读 _m0[1u]
#   期望（手写）：退出 0、k_b 一行，槽 1 照旧「1:32」（2 × 16），槽 0 不出整槽界、出「c0:2368」（148 × 16）；旧 C1Cb 没有 c 记号 → 判红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/c1cb_cext.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
(cd "$H/translator" && python3 -c 'import dsh_batch, shlex; print(shlex.join(dsh_batch.build()[0]))') > "$T/cmd" 2> "$T/b.log" || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
CMD=$(tail -n 1 "$T/cmd"); [ -n "$CMD" ] || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
mkdir -p "$T/a"
cat > "$T/a/k_b.metal" <<'EOM'
struct _17 { float4 _m0[4096]; };
struct spvDescriptorSetBuffer0 { constant _17* fp_c3 [[id(0)]]; constant _17* fp_c4 [[id(1)]]; };
fragment float4 main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]) { int i = int((*spvDescriptorSet0.fp_c4)._m0[1u].x); return (*spvDescriptorSet0.fp_c3)._m0[147u] + (*spvDescriptorSet0.fp_c3)._m0[i]; }
EOM
echo '{"key": "k_b", "route": "B", "bindings": [{"msl_name": "fp_c3", "msl_type": "constant _17*", "arg_id": 0, "kind": "cbuf", "reg": 0}, {"msl_name": "fp_c4", "msl_type": "constant _17*", "arg_id": 1, "kind": "cbuf", "reg": 1}]}' > "$T/a/k_b.json"
o=$($CMD --c1cb "$T/a" -j 1 2> "$T/a.err"); r=$?
row=$(grep '^k_b.metal' <<< "$o" | head -1); toks=" $(cut -f4- <<< "$row") "
ck "退出 0" 0 "$r"
ck "只读常量下标的槽 1 照旧出整槽界 1:32" 1 "$([[ "$toks" == *" 1:32 "* ]] && echo 1 || echo 0)"
ck "有动态下标的槽 0 不出整槽界（没有 0:…）" 0 "$([[ "$toks" == *" 0:"* ]] && echo 1 || echo 0)"
ck "有动态下标的槽 0 出常量下标界 c0:2368（148 × 16）" 1 "$([[ "$toks" == *" c0:2368 "* ]] && echo 1 || echo 0)"
[ $bad = 0 ] && echo "c1cb_const_extent：全过" || { echo "c1cb_const_extent：有失败（输出：${o:0:300}）"; }; exit $bad
