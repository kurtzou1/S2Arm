#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/tools/direct/direct_lib.sh translator/gl_shaders.py
# 直连库离线翻译降级汇总（v0.3.1 拿不准不停）：纯 GL 款，假 gl_shaders.py 只打汇总行、写表头（期望按输入手写）：
#   ① 「成功 0、失败 2」退 0 → direct_lib 退 0、keys.tsv 空、产物根 degrade.direct.tsv = 表头 + 「direct gl_failed 2 <玩家提示>」（原先 gl_shaders 退 1、整款停）
#   ② 「成功 3、失败 1」退 0、出库 → direct_lib 退 0、degrade.direct.tsv 记 gl_failed 1
#   ③ 「成功 2、失败 0」→ 不写 degrade.direct.tsv（上一轮留下的也删掉）
#   ④ 「成功 2、失败 1」但 iPhone 目标一支不剩（只有 Mac 编成，审计 P1-176 两个目标各剔各的）→ direct_lib 退 0、keys.tsv 空、不报「没出库」
#   ①' 成功 0、失败 2 的黄字写「编译失败 2 支」，不写成「运行时拼源码的引擎」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1：期望 $2 → 真结果 $3"; else echo "不通 $1：期望 $2 → 真结果 $3"; bad=1; fi; }
F=$T/repo; mkdir -p $F/graphics/tools/direct $F/graphics/nvn/tools $F/pack $F/tools $F/translator $T/bin
cp "$H/graphics/tools/direct/direct_lib.sh" $F/graphics/tools/direct/
printf 'import sys\nprint("gl\\tstub")\n' > $F/graphics/nvn/tools/gfx_api.py
echo 'prog_id() { echo 0100000000000000; }' > $F/pack/srcs.sh; echo 'prog_tick() { :; }' > $F/tools/progress.sh
printf 'import os, sys\na=sys.argv[sys.argv.index("--")+1:]; os.execv(a[0], a)\n' > $F/tools/nostall.py
cat > $F/translator/gl_shaders.py <<'EOF'
import os, pathlib, sys
ok, failed = map(int, os.environ["FAKE_GL"].split())
out = pathlib.Path(sys.argv[sys.argv.index("--ios") + 1]) / "gl"; out.mkdir(parents=True, exist_ok=True)
ios = 0 if os.environ.get("FAKE_IOS_EMPTY") else ok
(out / "gl_shaders.tsv").write_text("# h1\n# h2\n# h3\n" + "".join(f"k{i}\tvert\t-\tsrc\n" for i in range(ios)))
if ios: (out / "gl_shaders.metallib").write_bytes(b"lib")
print(f"GLSL 汇总：成功 {ok}、失败 {failed}、跳过 0")
EOF
for b in glslangValidator spirv-cross; do printf '#!/bin/bash\n' > $T/bin/$b; chmod +x $T/bin/$b; done
G=$T/game; mkdir -p $G/romfs $G/exefs; echo x > $G/exefs/main
run() { rm -rf $T/out; FAKE_GL="$1" PATH="$T/bin:$PATH" S2A_PY="$(command -v python3)" S2A_DIRECT_CACHE=$T/cache J=1 bash $F/graphics/tools/direct/direct_lib.sh $G $T/out > $T/log 2>&1; echo $?; }
r=$(run "0 2"); ck "① 成功 0 失败 2：退出码" 0 "$r"
ck "① keys.tsv 为空" 0 "$([ -f $T/out/keys.tsv ] && grep -c . $T/out/keys.tsv; [ -f $T/out/keys.tsv ] || echo 无)"
ck "① degrade.direct.tsv 记 gl_failed 2" "direct gl_failed 2" "$(grep -v '^#' $G/degrade.direct.tsv 2> /dev/null | cut -f1-3 | tr '\t' ' ')"
ck "① 带玩家提示" 1 "$(grep -c '这款有 2 个着色器没能提前编好' $G/degrade.direct.tsv 2> /dev/null)"
ck "①' 空表黄字按失败数写" 1 "$(grep -c '离线一支没编成（编译失败 2 支）' $T/log)"
r=$(run "3 1"); ck "② 成功 3 失败 1：退出码" 0 "$r"
ck "② degrade.direct.tsv 记 gl_failed 1" "direct gl_failed 1" "$(grep -v '^#' $G/degrade.direct.tsv 2> /dev/null | cut -f1-3 | tr '\t' ' ')"
r=$(run "2 0"); ck "③ 成功 2 失败 0：退出码" 0 "$r"
ck "③ 不留 degrade.direct.tsv" 无 "$([ -e $G/degrade.direct.tsv ] && echo 有 || echo 无)"
r=$(FAKE_IOS_EMPTY=1 run "2 1"); ck "④ iPhone 目标一支不剩：退出码" 0 "$r"
ck "④ keys.tsv 为空" 0 "$([ -f $T/out/keys.tsv ] && grep -c . $T/out/keys.tsv; [ -f $T/out/keys.tsv ] || echo 无)"
ck "④ 不报没出库" 0 "$(grep -c '没出' $T/log)"
[ $bad = 0 ] && echo "🟢 direct_lib_degrade_test 全通" || { echo "🔴 direct_lib_degrade_test 有不通"; tail -5 $T/log; exit 1; }
