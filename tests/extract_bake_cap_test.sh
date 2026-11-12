#!/bin/bash
# 门禁覆盖：graphics/tools/direct/extract.sh
# 抽取路数按内存封顶（#711：Windows 16 GB 抽取 MemoryError）：bash tests/extract_bake_cap_test.sh（约 1 秒）
# 调用方把 J 设成直连库编译路数（16 GB 可开 23 路）、S2A_CPU_BAKE 设成按内存封顶的重活路数（16 GB 8 路）。用桩 Python 记下 extract.sh 交给
#   S2Arm 抽取（nxsh_extract，拿一半：(J + 1) / 2）的 J，期望手算：
#   ① J=23 S2A_CPU_BAKE=8 → 抽取总路数封到 8，nxsh_extract 拿 4（旧版拿 12）
#   ② J=23、没给 S2A_CPU_BAKE → 照旧 12
#   ③ J=4 S2A_CPU_BAKE=8（J 本来就小）→ 不放大，nxsh_extract 拿 2
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
mkdir -p "$T/root/romfs" "$T/root/exefs"; : > "$T/root/exefs/main"
cat > "$T/py" <<'EOF'
#!/bin/bash
for a in "$@"; do case $a in */nxsh_extract.py) echo "$J" >> "$T_LOG"; exit 0;; esac; done
exit 0
EOF
chmod +x "$T/py"
run() { : > "$T/log"; env -u S2A_CPU_BAKE T_LOG="$T/log" S2A_PYTHON="$T/py" "$@" bash "$H/graphics/tools/direct/extract.sh" "$T/root" "$T/x" > /dev/null 2>&1; head -1 "$T/log"; }
ck() { if [ "$2" = "$3" ]; then echo "通 $1：期望 $2 → 真结果 $3"; else echo "不通 $1：期望 $2 → 真结果 $3"; bad=1; fi; }
ck "① J=23 S2A_CPU_BAKE=8：S2Arm 抽取拿的路数" 4 "$(run J=23 S2A_CPU_BAKE=8)"
ck "② J=23、没给 S2A_CPU_BAKE：照旧" 12 "$(run J=23)"
ck "③ J=4 S2A_CPU_BAKE=8：不放大" 2 "$(run J=4 S2A_CPU_BAKE=8)"
[ $bad = 0 ] && echo "🟢 extract_bake_cap_test 全通" || { echo "🔴 extract_bake_cap_test 有不通"; exit 1; }
