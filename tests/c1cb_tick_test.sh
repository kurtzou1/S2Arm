#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/batch/C1Cb.cs graphics/tools/direct/dsh/batch/Build.cs tests/c1cb_tick_test.sh
# 出库两张表后台遍的进度（11-20 010015100B514000：后台遍比编批库 / 两类变体晚完 85 秒，「等两张表」期间进度不动）：bash tests/c1cb_tick_test.sh（约 30 秒，编 dsh_batch）
#   Build.C1CbChild 分批起子进程 dsh_batch --c1cb <目录> --tick <阶段> <此前已算> <全遍支数>，子进程每算完一支往 S2A_PROGRESS 计一次（从「此前已算」接着计）
#   夹具：三支 k1/k2/k3_b.metal + _b.json（同 c1cb_dyn_reg_test 的常量读法）；--tick 直连库·两张表 5 8
#   期望（手写）：进度文件首行 5/8（接力起点）、末行 8/8（5 + 3 支，满了必写）；不带 --tick 不写进度文件；stdout 带不带 --tick 逐字节相同（只加进度，不改结果）
#   反证：不带 --tick 时进度文件为空（计数确实来自 --tick 这条路）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/c1cb_tick.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
(cd "$H/translator" && python3 -c 'import dsh_batch, shlex; print(shlex.join(dsh_batch.build()[0]))') > "$T/cmd" 2> "$T/b.log" || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
CMD=$(tail -n 1 "$T/cmd"); [ -n "$CMD" ] || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
mkdir -p "$T/a"
for k in k1 k2 k3; do
  cat > "$T/a/${k}_b.metal" <<'EOF'
struct _17 { float4 _m0[4096]; };
struct spvDescriptorSetBuffer0 { constant _17* fp_c3 [[id(0)]]; };
fragment float4 main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]) { return spvDescriptorSet0.fp_c3->_m0[1u]; }
EOF
  echo "{\"key\": \"${k}_b\", \"route\": \"B\", \"bindings\": [{\"msl_name\": \"fp_c3\", \"msl_type\": \"constant _17*\", \"arg_id\": 0, \"kind\": \"cbuf\", \"reg\": 0}]}" > "$T/a/${k}_b.json"
done
: > "$T/p1"; o1=$(S2A_PROGRESS=$T/p1 $CMD --c1cb "$T/a" -j 1 --tick 直连库·两张表 5 8 2> "$T/e1"); r=$?
ck "带 --tick：退出 0" 0 "$r"
ck "进度首行 = 接力起点 5/8" "直连库·两张表	5	8" "$(grep -v '^#' "$T/p1" | head -1 | cut -f2-)"
ck "进度末行 = 5 + 3 支 = 8/8" "直连库·两张表	8	8" "$(grep -v '^#' "$T/p1" | tail -1 | cut -f2-)"
ck "不写活动记录（旁路工作不改界面路数）" 0 "$(grep -c '^#dsh_activity' "$T/p1")"
: > "$T/p0"; o0=$(S2A_PROGRESS=$T/p0 $CMD --c1cb "$T/a" -j 1 2> "$T/e0"); r=$?
ck "不带 --tick：退出 0" 0 "$r"
ck "反证：不带 --tick 不写进度" 0 "$(wc -c < "$T/p0" | tr -d ' ')"
ck "结果三行、带不带 --tick 逐字节相同" "3 1" "$(grep -c '_b.metal	' <<< "$o1") $([ "$o1" = "$o0" ] && echo 1 || echo 0)"
# 进度文件被另一个写者开着（#2034：Windows 上父进程 / 接力子进程 / 并跑的 Ticker 同时追加，File.AppendAllText 只给读共享 → IOException、出包退出码 -1）：
#   另起一个进程以追加方式开着它（Windows 上 Python 的 open 不拒共享写），期间带 --tick 跑：期望照常退出 0、末行照写 8/8。Mac 没有强制共享锁，这条在 Mac 上修前也过，Windows 上修前红
: > "$T/p2"; python3 -c 'import sys, time; f = open(sys.argv[1], "a"); open(sys.argv[2], "w").close(); time.sleep(30)' "$T/p2" "$T/held" & HP=$!
for _ in $(seq 1 100); do [ -f "$T/held" ] && break; sleep 0.1; done
o2=$(S2A_PROGRESS=$T/p2 $CMD --c1cb "$T/a" -j 1 --tick 直连库·两张表 5 8 2> "$T/e2"); r=$?; kill $HP 2> /dev/null; wait $HP 2> /dev/null
ck "进度文件被另一进程开着写：退出 0" 0 "$r"
ck "进度文件被另一进程开着写：末行照写 8/8" "直连库·两张表	8	8" "$(grep -v '^#' "$T/p2" | tail -1 | cut -f2-)"
B=$H/graphics/tools/direct/dsh/batch/Build.cs
ck "Build.C1CbFill 查缓存仓按「直连库·两张表」逐支计（热仓全命中时这段也走）" 1 "$(grep -c 'new Ticker(C1CbTick, names.Count, 0, activity: false)' "$B")"
ck "Build.C1CbFill 后台遍子进程从命中数接着计到全遍支数" 1 "$(grep -c 'C1CbChild(todo, "bg", null, C1CbTick, tickBase: r.Count, tickTotal: names.Count)' "$B")"
ck "阶段名仍是「直连库·两张表」" 1 "$(grep -c 'const string C1CbTick = "直连库·两张表";' "$B")"
[ $bad = 0 ] && echo "c1cb_tick：全过" || echo "c1cb_tick：有失败"; exit $bad
