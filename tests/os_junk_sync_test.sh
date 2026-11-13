#!/bin/bash
# 门禁覆盖：pack/jobs/layout.py pack/sysdata_need.py launchers/macos/frontend/Sources/NX2Apple/EnvironmentView.swift launchers/windows/launcher/App/LibraryPage.cs pack/roots.sh
# 「系统自动生成的文件」三端一份（v0.2.3 遍历清理，#343 同类）：作业层 layout.OS_JUNK / OS_JUNK_PREFIX 为准，Mac / Windows 前端判空文件夹照抄同一组
#   期望：三处的名字集合相同、前缀都是 ._；has_content 对只有 .DS_Store / ._x / desktop.ini 的目录 → False，多一个普通文件 → True
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
names() { grep -o '"\(\.DS_Store\|desktop\.ini\|Thumbs\.db\|[A-Za-z._]*\)"' <<< "$1" | tr -d '"' | grep -v '^\._$' | sort -u | tr '\n' ' '; }
py=$(grep -m1 '^OS_JUNK = ' "$H/pack/jobs/layout.py"); sw=$(grep -m1 'let osJunk: Set<String>' "$H/launchers/macos/frontend/Sources/NX2Apple/EnvironmentView.swift")
cs=$(grep -m1 'HashSet<string> OsJunk' "$H/launchers/windows/launcher/App/LibraryPage.cs")
sh=$(grep -m1 '^_ROOT_OS_JUNK=' "$H/pack/roots.sh")   # 产物根删除（_root_rm）清系统文件用的名单（#369）
sd=$(grep -m1 '^OS_JUNK = ' "$H/pack/sysdata_need.py")   # 系统数据阶段判玩家目录有没有内容、算内容身份（exFAT 普查）
ck "五处名字集合一致（作业层：$(names "$py")）" '[ -n "$(names "$py")" ] && [ "$(names "$py")" = "$(names "$sw")" ] && [ "$(names "$py")" = "$(names "$cs")" ] && [ "$(names "$py")" = "$(names "$sh")" ] && [ "$(names "$py")" = "$(names "$sd")" ]'
ck "四处都认 ._ 前缀" 'grep -q "startswith(\"\._\")" "$H/pack/sysdata_need.py" && grep -q "^OS_JUNK_PREFIX = \"\._\"" "$H/pack/jobs/layout.py" && grep -q "hasPrefix(\"\._\")" "$H/launchers/macos/frontend/Sources/NX2Apple/EnvironmentView.swift" && grep -q "StartsWith(\"\._\"" "$H/launchers/windows/launcher/App/LibraryPage.cs"'
mkdir -p "$T/a" "$T/b"; : > "$T/a/.DS_Store"; : > "$T/a/._x.nsp"; : > "$T/a/desktop.ini"; cp -p "$T/a/"* "$T/a/".* "$T/b/" 2> /dev/null; : > "$T/b/game.nsp"
o=$(cd "$H/pack/jobs" && python3 -c "import sys, layout; print(layout.has_content(sys.argv[1]), layout.has_content(sys.argv[2]), layout.has_content(sys.argv[3]))" "$T/a" "$T/b" "$T/none")
ck "has_content：只有系统文件 → False、多一个普通文件 → True、不存在 → False（${o}）" '[ "$o" = "False True False" ]'
[ $bad = 0 ] && echo "os_junk_sync 单测全过" || { echo "os_junk_sync 单测有不通"; exit 1; }
