#!/bin/bash
# 门禁覆盖：tools/devices.sh
# 设备独占名单（tools/devices.sh s2a_device_pick，11-13：某台测试设备归一条线独占、维护者日常手机永不选）：期望按构造手写
#   代码内置名单（S2A_DEVICES_NO_LOCAL=1：测试设备1 / 2 = …0001 / …0002，Duo = …0003），不核 USB，测试根隔离锁与互斥目录
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0; n=0
ok() { n=$((n + 1)); if [ "$1" = "$2" ]; then echo "✓ $3"; else echo "✗ $3：期望「$1」→ 真结果「$2」"; bad=1; fi; }
pick() { env S2A_DEVICES_NO_LOCAL=1 S2A_DEVICE_NO_USB_CHECK=1 S2A_TEST_ROOT="$T/root" S2A_SCHED_DIR="$T/sched" S2A_DEVICE_EXCLUSIVE="$T/excl.tsv" \
  bash -c 'source "$0/tools/devices.sh" > /dev/null 2>&1; s2a_device_pick "$1" 2> /dev/null' "$H" "$1"; }
mkdir -p "$T/root" "$T/sched"; : > "$T/excl.tsv"
ok 1 "$(pick iphone)" "① 名单空：两台 iphone 负载相同 → 机号小的 1"
printf '# 注释行不算\n00000000-0000000000000001\t某线\t单测\n' > "$T/excl.tsv"
ok 2 "$(pick iphone)" "② 测试设备1 独占 → iphone 挑 2"
ok 2 "$(pick any)" "③ any 同样跳过 1（2 与 Duo 负载相同取机号小的 2）"
printf '00000000-0000000000000001\ta\tx\n00000000-0000000000000002\tb\ty\n' > "$T/excl.tsv"
ok "" "$(pick iphone)" "④ 两台 iphone 都独占 → iphone 挑不出（返回非零、不落到独占机）"
ok 3 "$(pick any)" "⑤ any 只剩 Duo"
rm -f "$T/excl.tsv"; ok 1 "$(pick iphone)" "⑥ 名单文件不存在 → 照常挑"
echo "device_exclusive_test：$n 项，$([ $bad = 0 ] && echo 全绿 || echo 有红)"; exit $bad
