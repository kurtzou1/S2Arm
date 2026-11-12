#!/bin/bash
# 真机转储着色器并进直连抽取单测（translator/rt_dump_merge.py，约 1 秒）：bash tests/rt_dump_merge_test.sh
# 造一支合成的 Switch 2 计算着色器（NVN2 控制段：魔数 0x98761234、版本 0xc9、+0x44 代码长、+0x56 阶段 5、+0x58 线程组、+0x64 共享字节；不含游戏内容），
# 期望值按 ns2_shaders.py 头注的键公式与 shader_split.py 记录格式手写：
#   ① 文件名 = sha256(控制段前 0x48 字节、+0x20..+0x27 与 +0x30..+0x33 置零 ‖ 代码区)[:16] → 退出 0；cs_rt.bin 一条记录（'BTCDBTCD' + 0x38 头，+0x28 控制段长、+0x2c 代码长，代码在前）；
#      shader_map.tsv 追加「cs_rt.bin 0 compute <键> rt-dump:<键>」；答案表追加 {"local":[32,4,1],"shared":5104}（共享 5100 向上按 16 对齐）
#   ② 再跑一次：已在表里，不重复追加（表行数不变），退出 0
#   ③ 文件名与重算键不符 → 跳过这一支、打 [WARN]、退出 0、不写包（v0.3.1 拿不准不停 ⑭；原先报红退非 0、整个合并停）
#   ④ 控制段 +0x44 与代码长不符 → 同 ③：跳过、[WARN]、退出 0
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-python3}; TOOL=$H/translator/rt_dump_merge.py
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() {   # mk <目录> <代码长> <+0x44 写的长度> [<文件名键，缺省按公式>]
  "$PY" - "$@" <<'PY'
import hashlib, os, struct, sys
d, n, n44 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ctl = bytearray(0xd8); ctl[:4] = b'\x34\x12\x76\x98'; ctl[4:8] = b'\xc9\0\0\0'
struct.pack_into('<I', ctl, 0x20, 0x1234); struct.pack_into('<I', ctl, 0x30, 0x18a0); struct.pack_into('<I', ctl, 0x44, n44)
ctl[0x56] = 5; struct.pack_into('<3I', ctl, 0x58, 32, 4, 1); struct.pack_into('<I', ctl, 0x64, 5100)
code = bytes((i * 7 + 3) & 0xff for i in range(n))
kc = bytearray(ctl[:0x48]); kc[0x20:0x28] = bytes(8); kc[0x30:0x34] = bytes(4)
k = sys.argv[4] if len(sys.argv) > 4 else hashlib.sha256(bytes(kc) + code).hexdigest()[:16]
os.makedirs(d, exist_ok=True); open(f'{d}/{k}.ctl', 'wb').write(ctl); open(f'{d}/{k}.code', 'wb').write(code); print(k)
PY
}
init() { rm -rf "$1"; mkdir -p "$1/pkg"; printf 'package\tindex\tstage\tdm_ctl_sha16\tsource\n' > "$1/map.tsv"; printf '# 答案表\n' > "$1/facts.tsv"; }
init $T/a; K=$(mk $T/a/dump 512 512)
o1=$("$PY" "$TOOL" $T/a/dump $T/a/pkg $T/a/map.tsv $T/a/facts.tsv 2>&1); r1=$?
rec=$("$PY" -c "import struct,sys;b=open(sys.argv[1],'rb').read();print(b[:8]==b'BTCDBTCD', struct.unpack_from('<2I',b,0x28), len(b))" $T/a/pkg/cs_rt.bin 2> /dev/null)
ck "① 并入：rc=${r1}、「${o1}」、记录 ${rec}、表末行「$(tail -1 $T/a/map.tsv)」、答案「$(tail -1 $T/a/facts.tsv)」" \
  "[ $r1 = 0 ] && [ \"\$rec\" = 'True (216, 512) 784' ] && [ \"\$(tail -1 $T/a/map.tsv)\" = \"\$(printf 'cs_rt.bin\t0\tcompute\t%s\trt-dump:%s' $K $K)\" ] && [ \"\$(tail -1 $T/a/facts.tsv)\" = \"\$(printf '%s\t{\"local\":[32,4,1],\"shared\":5104}' $K)\" ]"
n2=$(wc -l < $T/a/map.tsv); o2=$("$PY" "$TOOL" $T/a/dump $T/a/pkg $T/a/map.tsv $T/a/facts.tsv 2>&1); r2=$?
ck "② 再跑不重复：rc=${r2}、表行 ${n2} → $(wc -l < $T/a/map.tsv)、「${o2}」" "[ $r2 = 0 ] && [ $n2 = \$(wc -l < $T/a/map.tsv) ] && [[ \"\$o2\" == *'已在表里 1 支'* ]]"
init $T/b; mk $T/b/dump 512 512 0123456789abcdef > /dev/null
o3=$("$PY" "$TOOL" $T/b/dump $T/b/pkg $T/b/map.tsv $T/b/facts.tsv 2>&1); r3=$?
ck "③ 键不符跳过：rc=${r3}、「${o3}」" "[ $r3 = 0 ] && [[ \"\$o3\" == *'与文件名不符'*'跳过这一支'* ]] && [[ \"\$o3\" == *'坏了跳过 1 支'* ]] && [ ! -e $T/b/pkg/cs_rt.bin ]"
init $T/c; mk $T/c/dump 512 256 > /dev/null
o4=$("$PY" "$TOOL" $T/c/dump $T/c/pkg $T/c/map.tsv $T/c/facts.tsv 2>&1); r4=$?
ck "④ 代码长不符跳过：rc=${r4}、「${o4}」" "[ $r4 = 0 ] && [[ \"\$o4\" == *'+0x44'*'跳过这一支'* ]] && [ ! -e $T/c/pkg/cs_rt.bin ]"
[ $bad = 0 ] && echo "rt_dump_merge 单测全过" || { echo "rt_dump_merge 单测有不通"; exit 1; }
