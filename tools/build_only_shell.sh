#!/bin/bash
# 原生层钩子「只编」模式的 make 规则外壳（runtime/gate.sh GATE_BUILD_ONLY=1 用 make SHELL=本脚本）：
#   规则里的编译 / 链接 / 建目录 / 生成照常执行；「运行单测程序」那一行（命令是 build/tests/t_<名>，前面可带 timeout N、环境变量赋值、./）跳过不跑。
#   含编译器的行（cc / clang / xcrun / swiftc / ld / ar / libtool，-o build/tests/t_x 这种）一律照跑。只认 make 的「-c 一行」调法，其余原样交给 bash
[ "${1:-}" = -c ] || exec /bin/bash "$@"
l=$2
if grep -qE '(^|[;&|(]|^[[:space:]]*)[[:space:]]*(timeout( -[a-z] [0-9]+)? [0-9.]+[smh]? +|[A-Za-z_][A-Za-z0-9_]*=[^ ]* +|env +)*(\./)?[^ ;&|]*build[^ ;&|]*/tests/t_[A-Za-z0-9_]+([[:space:];&|]|$)' <<< "$l" \
   && ! grep -qE '(^|[[:space:];&|(])(cc|c\+\+|clang|clang\+\+|gcc|xcrun|swiftc|ld|ar|libtool|metal)([[:space:]]|$)' <<< "$l"; then
  echo "只编：跳过运行 ${l:0:120}"; exit 0; fi
exec /bin/bash -c "$l"
