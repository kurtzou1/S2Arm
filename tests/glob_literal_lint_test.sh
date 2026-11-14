#!/bin/bash
# 门禁只看：tools/glob_literal_lint.py pack/* launchers/* graphics/tools/direct/* graphics/tools/shbake/srcpack.py
# glob 路径字面量守卫单测（tools/glob_literal_lint.py，约 1 秒）：bash tests/glob_literal_lint_test.sh
# 期望（按规则手写）：① 本仓库出货代码 0 处；② 坏写法夹具（glob.glob(os.path.join(root, '*.pk'))、iglob 拼变量）各报 1 行；
#   ③ 好写法夹具（glob.escape 包着的、整段常量的、行尾 glob-literal-ok 的）不报；④ 路径带 [2] 时坏写法真找不到、好写法找得到；⑤ srcpack 在 [2] 目录下写得进读得回（#1009 原样）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o=$(python3 "$H/tools/glob_literal_lint.py" "$H" 2>&1); r=$?
ck "① 本仓库出货代码没有未转义的 glob（命中：${o:0:300}）" '[ $r = 0 ] && [ -z "$o" ]'
mkdir -p "$T/r/pack"
cat > "$T/r/pack/bad.py" <<'X'
import glob, os
def a(root): return glob.glob(os.path.join(root, '*.pk'))
def b(d): return list(glob.iglob(d + '/*.log'))
X
cat > "$T/r/pack/good.py" <<'X'
import glob, os
def a(root): return glob.glob(os.path.join(glob.escape(root), '*.pk'))
def b(): return glob.glob('/fixed/dir/*.txt')
def c(p): return glob.glob(p)   # glob-literal-ok: 调用方传的就是模式
X
o=$(python3 "$H/tools/glob_literal_lint.py" "$T/r" 2>&1); r=$?
ck "② 坏写法两处都报（实际：$(echo "$o" | tr '\n' ' ')）" '[ $r = 1 ] && [ "$(echo "$o" | grep -c "^pack/bad.py:")" = 2 ]'
ck "③ 好写法不报" '! echo "$o" | grep -q "good.py"'
mkdir -p "$T/[2]NS库/src" && printf x > "$T/[2]NS库/src/p1.pk"
n=$(python3 -c 'import glob,os,sys; d=os.path.join(sys.argv[1],"[2]NS库"); print(len(glob.glob(os.path.join(d,"src","*.pk"))), len(glob.glob(os.path.join(glob.escape(d),"src","*.pk"))))' "$T")
ck "④ 路径带 [2]：未转义找到 0 个、转义后找到 1 个（实际 ${n}）" '[ "$n" = "0 1" ]'
# ⑤ #1009 原样：抽取目录在「[2]NS库」下，生产写端写一支、生产读端要读得回来（修前读端 0 支 → 合并抽取第一支就 KeyError）
k=$(python3 -c 'import sys,os; sys.path.insert(0, os.path.join(sys.argv[1], "graphics/tools/shbake")); import srcpack
x = os.path.join(sys.argv[2], "[2]NS库", "s2x"); w = srcpack.Writer(x); w.put("000084a91b9e57a2", b"code", b"ctl"); w.flush()
s = srcpack.Src(x); print(len(s), s.get("000084a91b9e57a2") == (b"code", b"ctl"))' "$H" "$T")
ck "⑤ srcpack 在「[2]」目录下读得回写进去的那支（实际 ${k}）" '[ "$k" = "1 True" ]'
[ $bad = 0 ] && echo "✅ glob 路径字面量守卫全通" || { echo "🔴 glob 路径字面量守卫有不通"; exit 1; }
