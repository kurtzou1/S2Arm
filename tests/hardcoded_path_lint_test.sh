#!/bin/bash
# 写死机器路径检查（tools/hardcoded_path_lint.py，11-27）单测：bash tests/hardcoded_path_lint_test.sh（约 1 秒）
# 期望（按规则手写）：
#   ① 本仓库 0 处
#   ② 坏写法夹具（非测试代码）各报 1 行：缺省值写死 R:\s2a…、D:/s2a/deps、U:\s2a_resident；R:\work 出包机专用盘；Mac 家目录下的人名路径（运行时拼出，源码里不写，免得公开仓扫描当成家目录泄露）；
#      私有规则表里的名字（夹具用虚构名 SYNTHETICMACHINE，公开仓不写真实用户名）
#   ③ 不报：注释里、Python 文档字符串里、行尾 hardcoded-path-ok、/Users/player 占位名、C:\Program Files 系统位置、D:\S2Arm 玩家提示示例
#   ④ 测试代码里：R:\lib、家目录假名夹具不报；D:\s2a 布局与私有名字照报
#   ⑤ 私有规则表读不到：只跳过 ③ 那条（照样报 ①②），并打提示
#   ⑥ 跨 5 行的多行字符串里只有第 3 行写死 R:\s2a：只报那 1 行（不把整段摊到每一行）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
L="python3 $H/tools/hardcoded_path_lint.py"
o=$(S2A_PRIVATE_SCAN_RULES=$T/none.json $L "$H" 2>/dev/null); r=$?
ck "① 本仓库 0 处（命中：${o:0:300}）" '[ $r = 0 ] && [ -z "$o" ]'
printf '{"machine_path_rules": ["\\\\bSYNTHETICMACHINE\\\\b"]}\n' > "$T/rules.json"
mkdir -p "$T/r/pack" "$T/r/tests"
cat > "$T/r/pack/bad.py" <<'X'
import os
A = os.environ.get("X", r"R:\s2a\deps\zstd")
B = "D:/s2a/deps/tool"
C = r"U:\s2a_resident\data"
D = r"R:\work\tmp"
F = "host=SYNTHETICMACHINE"
X
UH=/Us; UH=${UH}ers   # 家目录前缀运行时拼：源码里不出现「家目录前缀 + 人名」
printf 'E = "%s/synthetichome/project"\n' "$UH" >> "$T/r/pack/bad.py"
cat > "$T/r/pack/good.py" <<'X'
"""文档字符串里提到 R:\s2a 不算"""
import os
# 注释里的 D:\s2a\deps 不算
A = r"R:\s2a\x"   # hardcoded-path-ok：有意保留
B = "/Users/player/Games"
C = r"C:\Program Files\Git"
D = "把游戏库搬到短路径（比如 D:\\S2Arm）"
X
cat > "$T/r/tests/test_x.py" <<'X'
LIB = r"R:\lib\games"
BAD = r"D:\s2a\work"
WHO = "SYNTHETICMACHINE"
X
printf 'HOME = "%s/syntheticfixture/a"\n' "$UH" >> "$T/r/tests/test_x.py"
o=$(cd "$T/r" && S2A_PRIVATE_SCAN_RULES=$T/rules.json $L . pack/bad.py pack/good.py tests/test_x.py 2>/dev/null); r=$?
ck "② 坏写法 6 行全报、退 1（实 $(grep -c 'pack/bad.py' <<< "$o") 行，rc=${r}）" '[ $r = 1 ] && [ "$(grep -c "pack/bad.py" <<< "$o")" = 6 ]'
ck "③ 好写法一行都不报" '! grep -q "pack/good.py" <<< "$o"'
ck "④ 测试代码：夹具不报，布局与私有名字照报（各 1 行）" '[ "$(grep -c "tests/test_x.py" <<< "$o")" = 2 ] && grep -q "test_x.py:2:" <<< "$o" && grep -q "test_x.py:3:" <<< "$o"'
e=$(cd "$T/r" && S2A_PRIVATE_SCAN_RULES=$T/none.json $L . pack/bad.py 2>&1 >/dev/null); o=$(cd "$T/r" && S2A_PRIVATE_SCAN_RULES=$T/none.json $L . pack/bad.py 2>/dev/null)
ck "⑤ 私有表读不到：报 5 行（少私有名字那行）并提示" '[ "$(grep -c "pack/bad.py" <<< "$o")" = 5 ] && grep -q "读不到" <<< "$e"'
printf '%s\n' 'S = """第一行' '第二行' 'cd R:\s2a\work' '第四行' '"""' > "$T/r/pack/multi.py"
o=$(cd "$T/r" && S2A_PRIVATE_SCAN_RULES=$T/none.json $L . pack/multi.py 2>/dev/null)
ck "⑥ 多行字符串只报真有的那 1 行（实 $(grep -c 'multi.py' <<< "$o") 行）" '[ "$(grep -c "multi.py" <<< "$o")" = 1 ] && grep -q "multi.py:3:" <<< "$o"'
[ $bad = 0 ] && echo "hardcoded_path_lint 单测全过"; exit $bad
