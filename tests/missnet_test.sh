#!/bin/bash
# tools/missnet.py 单测：造一局假日志 + 假现行包索引，期望值按规则手算（不跑被测脚本推）。退出 0 = 全过
#   日志 5 条 b2 + 1 条 v2：
#     ① s1,s2 缺省维度、配对在归档索引里、不在收集表 → 现静态已覆盖，不计
#     ② s1,s3 缺省维度、配对不在归档索引 → 运行时配对
#     ③ s1_wl,s2 → _wl
#     ④ s1,s2 采样 4 → 采样4
#     ⑤ sff,s2 → sff 不在现行包 gal.idx → 函数键不在现行包里，不计
#   另一局日志带「无着色器包」（同样有 b2 行）→ 整份不计，输出点名 1 局
#     v2 行不看
#   期望：收到 b2 5（不在现行包 1、已覆盖 1），漏网 3，预计 300 ms；去掉归档索引后 ① 不能扣 → 漏网 4
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/missnet_test.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=1; fi; }
mkdir -p "$T/sched/jobs/zz_1/out_1" "$T/roots/zz@v1/shaders" "$T/col"
printf '%s\n' zz@v1 > "$T/roots/zz@现行"
k() { printf 's%016x' "$1"; }
cat > "$T/sched/jobs/zz_1/out_1/host.log" <<EOF
[gal] 特化管线 b2 $(k 1) $(k 2) 0 1 0 0 1
[gal] 特化管线 b2 $(k 1) $(k 3) 0 1 0 0 1
[gal] 特化管线 b2 $(k 1)_wl $(k 2) 0 1 0 0 1
[gal] 特化管线 b2 $(k 1) $(k 2) 0 4 0 0 1
[gal] 特化管线 b2 $(k 255) $(k 2) 0 1 0 0 1
[gal] 特化管线 v2 $(k 1) $(k 3) 3 1 0 0 1 0:80:15:0:0:1:0:0:1:0
EOF
python3 - "$T/roots/zz@v1/shaders" <<'EOF'
import struct, sys
d = sys.argv[1]
def fnv64(t):
    x = 0xcbf29ce484222325
    for c in t.encode(): x = ((x ^ c) * 0x100000001b3) & 0xffffffffffffffff
    return x
# gal.idx：'GALI' 头，函数个数在偏移 16，条目从 24 起每条 16 字节（u64 键 + 偏移 + 长度）
keys = [1, 2, 3]
open(f'{d}/gal.idx', 'wb').write(b'GALI' + b'\0' * 12 + struct.pack('<II', len(keys), 0) + b''.join(struct.pack('<QII', k, 0, 0) for k in keys))
# gal_pso.idx：'GPSI' 头 4 × u32（魔数、版本、条数、0），条目 u64 键 + u32 片号 + u32 0
pk = [fnv64('s%016x,s%016x' % (1, 2))]
open(f'{d}/gal_pso.idx', 'wb').write(struct.pack('<4I', 0x49535047, 1, len(pk), 0) + b''.join(struct.pack('<QII', k, 0, 0) for k in pk))
EOF
run() { S2A_SCHED_DIR=$T/sched S2A_SHCOLLECT=$T/col S2A_ROOTS=$T/roots python3 "$R/tools/missnet.py" zz; }
o=$(run); echo "  $o"
ck "收到 b2 5、不在现行包 1、已覆盖 1" '[[ "$o" == *"收到 b2 5（函数键不在现行包里 1、现静态已覆盖 1）"* ]]'
ck "漏网 3：_wl / 采样4 / 运行时配对各 1，300 ms" '[[ "$o" == *"漏网 3"* && "$o" == *"_wl×1"* && "$o" == *"采样4×1"* && "$o" == *"运行时配对×1"* && "$o" == *"300 ms"* ]]'
mkdir -p "$T/sched/jobs/zz_2/out_1"; printf '[gal] 无着色器包（x）：首遇着色器现编\n[gal] 特化管线 b2 %s %s 0 1 0 0 1\n' "$(k 1)" "$(k 9)" > "$T/sched/jobs/zz_2/out_1/host.log"
o=$(run); echo "  $o"
ck "无着色器包的局整份不计、点名 1 局，漏网仍 3" '[[ "$o" == *"无着色器包、不计 1"* && "$o" == *"漏网 3"* ]]'
rm "$T/roots/zz@v1/shaders/gal_pso.idx"; o=$(run); echo "  $o"
ck "没有归档索引：不扣已覆盖，漏网 4" '[[ "$o" == *"漏网 4"* && "$o" == *"没有现行包归档索引"* ]]'
echo "missnet 单测：$([ $bad = 0 ] && echo 全过 || echo 有失败)"; exit $bad
