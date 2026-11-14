#!/usr/bin/env bash
# 宿主单测 + 负对照：android/native/gfx_plat/flag_cache.h（nvn_plat_flag 的线程内读数缓存）。不需要 NDK / 设备 / 外部库。
# 负对照：对头文件的临时副本各改坏一处（名字比较、缺省处理、过期判断、有无标记），用例必须变红并报出对应的 FAIL。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo/build/flag-cache-test"
out=$(mktemp -d "$repo/build/flag-cache-test/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
cflags=(-std=c11 -O1 -Wall -Wextra -Werror)
cc "${cflags[@]}" -I "$repo/android/native/gfx_plat" "$repo/android/tests/nvk_flag_cache_test.c" -o "$out/test"
"$out/test"
# 同一份用例在 ASan / UBSan 下再跑一遍（越界写名字表、有符号溢出等）
if cc "${cflags[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -I "$repo/android/native/gfx_plat" "$repo/android/tests/nvk_flag_cache_test.c" -o "$out/test_asan" 2> "$out/asan.err"; then
    "$out/test_asan" > /dev/null
    echo 'PASS: ASan/UBSan 下同一份用例绿'
else
    echo 'SKIP: 本机编译器不带 ASan/UBSan（只影响这一小段，普通档已经跑过）'
fi
mkdir -p "$out/mut"
mutate() {   # <名字> <锚点> <替换> <期望出现的 FAIL 片段>
    python3 - "$repo/android/native/gfx_plat/flag_cache.h" "$out/mut/flag_cache.h" "$2" "$3" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
a, b = sys.argv[3], sys.argv[4]
if s.count(a) != 1: raise SystemExit('负对照锚点不是恰好 1 处: ' + a)
pathlib.Path(sys.argv[2]).write_text(s.replace(a, b), encoding='utf-8')
PY
    cc "${cflags[@]}" -I "$out/mut" -I "$repo/android/native/gfx_plat" "$repo/android/tests/nvk_flag_cache_test.c" -o "$out/mutant"
    if "$out/mutant" > "$out/mutant.log" 2>&1; then echo "FAIL: 负对照 $1 没有被用例抓到" >&2; exit 1; fi
    if ! grep -q "$4" "$out/mutant.log"; then echo "FAIL: 负对照 $1 红了，但不是预期的 $4：" >&2; head -n 8 "$out/mutant.log" >&2; exit 1; fi
    echo "PASS: 负对照 $1 被抓到（$4）"
}
mutate 不比较名字 '(!strcmp(e->name, name))' '(1)' 'T6'
mutate 命中返回缓存里的缺省 'return e->has ? e->val : dflt;
            slot = e; break;   // 过期：就地重读' 'return e->val;
            slot = e; break;   // 过期：就地重读' 'T3'
mutate 永不过期 'if (now < e->until) return' 'if (1) return' 'T2'
mutate 边界多算一拍 'if (now < e->until) return' 'if (now <= e->until) return' 'T2'
mutate 没设当成有值 'slot->has = (uint8_t)has;' 'slot->has = 1;' 'T3'
mutate 值零当成没设 'const int has = rd(name, &v, user) != 0;' 'const int has = rd(name, &v, user) != 0 && v != 0;' 'T4'
mutate 名字上限少一个字节 'if (n >= FC_NAME_MAX) return rd(name, &v, user) ? v : dflt;' 'if (n >= FC_NAME_MAX - 1) return rd(name, &v, user) ? v : dflt;' 'T8'
echo 'nvk_flag_cache 宿主单测 + 7 个负对照：全部符合预期'