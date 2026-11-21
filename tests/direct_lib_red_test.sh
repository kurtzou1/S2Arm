#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.py tests/direct_lib_red_test.sh
# 直连库报红带子命令原文（#1725 / #1730 / #1744：玩家诊断只有「出包未完成。」，direct_lib 的 🔴 行不带失败子命令的原文）：bash tests/direct_lib_red_test.sh（假仓库 + 桩，约 2 秒）
#   期望手写：
#   ① 合并抽取（merge_extract.py）以 1 退出、stderr 有特征串 → direct_lib 退 1，最后一行 🔴 带「merge_extract.py 退出码 1」与特征串，原文在日志路径之前
#   ② 判图形接口（gfx_api.py，取标准输出那种调法）以 1 退出、只在 stderr 写特征串 → 🔴 行带「gfx_api.py 退出码 1」与特征串
#   ③ 子命令刷出 60 行长输出 → 🔴 行只带最后 20 行（第 41–60 行在、第 40 行不在）、原文部分不超过 1600 字节；仍是一行
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
P=$T/repo; mkdir -p $P/graphics/tools/direct $P/graphics/nvn/tools $P/graphics/nvn/games $P/translator $P/tools $T/prof
cp "$H/graphics/tools/direct/direct_lib.py" $P/graphics/tools/direct/; cp "$H/tools/progress.py" "$H/tools/pool_workers.py" "$H/tools/clonedir.py" $P/tools/
cat > $P/graphics/nvn/tools/gfx_api.py <<'PY'
import os, sys
if os.environ.get('FAKE_GFX_FAIL'): print('SIG_GFX_STDERR_4b1 读 NSO 导入表失败', file=sys.stderr); sys.exit(1)
print('nvn\t桩')
PY
printf 'print("%s")\n' "$T/prof" > $P/graphics/nvn/games/game.py; : > $P/graphics/nvn/games/zero_skip.tsv
printf 'def version(): return "v1"\n' > $P/translator/dmsh_chain.py
printf 'game\t0100AAAA00000000\n' > $T/prof/game.tsv
cat > $P/graphics/tools/direct/merge_extract.py <<'PY'
import os, sys
n = int(os.environ.get('FAKE_LINES', '3'))
for i in range(1, n + 1): print(f'合并输出第 {i} 行 ' + 'y' * int(os.environ.get('FAKE_W', '10')))
print('Traceback (most recent call last):\nKeyError: SIG_MERGE_STDERR_51c', file=sys.stderr); sys.exit(1)
PY
G=$T/root; mkdir -p $G/romfs $G/exefs $G/extract/pkg $G/extract/split $G/extract/s2x; echo main > $G/exefs/main; printf 'title_id\t0100aaaa00000000\n' > $G/unpack.tsv
printf 'split\t1\ns2a_extract\t2\n' > $G/extract/ok; echo s > $G/extract/split.log; echo x > $G/extract/s2x.log
D() { env S2A_PY="$(command -v python3)" S2A_DIRECT_CACHE=$T/cache S2A_DIRECT_TARGETS=ios S2A_DISK_FREE_G=999 J=1 "$@" python3 $P/graphics/tools/direct/direct_lib.py $G $T/out 2>/dev/null; }
o=$(D); r=$?; l=$(printf '%s\n' "$o" | grep '🔴' | tail -1)
ck "① 合并抽取退 1 → 退 1（真 ${r}）、🔴 行带子命令名 / 退出码 / stderr 特征串、原文在路径前（${l:0:160}…）" \
  '[ $r = 1 ] && [[ "$l" == *"合并抽取失败：merge_extract.py 退出码 1："*SIG_MERGE_STDERR_51c*"merge.log）" ]]'
o=$(D FAKE_GFX_FAIL=1); r=$?; l=$(printf '%s\n' "$o" | grep '🔴' | tail -1)
ck "② 判图形接口退 1、特征串只在 stderr → 🔴 行带「gfx_api.py 退出码 1」与特征串（${l}）" '[ $r = 1 ] && [[ "$l" == *"gfx_api.py 退出码 1"*SIG_GFX_STDERR_4b1* ]]'
o=$(D FAKE_LINES=60 FAKE_W=60); r=$?; l=$(printf '%s\n' "$o" | grep '🔴' | tail -1); raw=${l#*merge_extract.py 退出码 1：}; raw=${raw%（*}
nb=$(printf '%s' "$raw" | wc -c | tr -d ' ')
ck "③ 长输出只带末尾：第 60 行在、第 40 行不在、原文 ${nb} 字节 ≤ 1600 + 省略号、一行" \
  '[ $r = 1 ] && [[ "$raw" == *"第 60 行"* ]] && [[ "$raw" != *"第 40 行 "* ]] && [ "$nb" -le 1610 ] && [ "$(printf "%s\n" "$o" | grep -c "🔴")" = 1 ]'
[ $bad = 0 ] && echo "🟢 直连库报红带原文单测全通" || { echo "直连库报红带原文单测：有不通"; printf '%s\n' "$o" | tail -3; exit 1; }
