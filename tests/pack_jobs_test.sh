#!/bin/bash
# 门禁覆盖：pack/jobs/*.py pack/jobs/tests/*.py docs/site/notice.json
# 启动器任务层单测进门禁（10-27 维护者：pack/jobs/tests 原先只挂在 launchers/macos/gate.sh 钩子下，tool 档不跑钩子，
#   名单线 lists/save-zero 改 pack/jobs/saves.py 判 tool 档、test_saves.py 没进门禁）：bash tests/pack_jobs_test.sh
# 选测：GATE_CHANGED（门禁给的改动清单）里只有 pack/jobs/<模块>.py → 只跑 import / 点名了这些模块的 pack/jobs/tests/test_*.py；
#   改到 pack/jobs/tests/ 下的文件（含 jobcase.py）、或没给 GATE_CHANGED → 全跑（235 个约 55 秒）
set -u; cd "$(dirname "$0")/.." || exit 1
mods=(); all=; [ -n "${GATE_CHANGED:-}" ] || all=1
for f in ${GATE_CHANGED:-}; do case $f in
  pack/jobs/tests/*) all=1;;
  pack/jobs/*.py) m=${f#pack/jobs/}; mods+=("${m%.py}");; esac; done
if [ -n "$all" ] || [ ${#mods[@]} = 0 ]; then sel=(pack/jobs/tests/test_*.py)
else sel=($(for t in pack/jobs/tests/test_*.py; do for m in "${mods[@]}"; do grep -qE "(^|[^A-Za-z0-9_])${m}([^A-Za-z0-9_]|$)" "$t" && { echo "$t"; break; }; done; done))
  [ ${#sel[@]} -gt 0 ] || sel=(pack/jobs/tests/test_*.py); fi   # 改的模块没有单测点名它：全跑（宁多勿漏）
echo "pack/jobs 单测：跑 ${#sel[@]} 份（$(printf '%s ' "${sel[@]##*/}")）"
# 单测不许往工作树里写东西（11-09：mock 改全进程 os.name = "nt" 时新建的 Path 变成 WindowsPath，「/var/folders/…/job.json」写成工作树根的
#   「\var\folders…」杂文件，两次被 git add -A 带进提交）：每份跑完比一次工作树里未跟踪的文件，多出来的判这份不通、点名
untracked() { git ls-files --others --exclude-standard 2> /dev/null | LC_ALL=C sort; }
# 按文件并行跑（11-14 列车提速：68 份串行合计 413 秒，最大一份 test_jobs 106 秒；PACK_JOBS_PAR 路并行，缺省 4，整步约降到最大那份），
#   各份输出进临时目录，跑完按原顺序判、打印（输出格式不变）。
#   「单测不许往工作树里写」改成整体前后比一次：并行时分不清是哪一份写的，多出来的文件全部点名、判不通
P=${PACK_JOBS_PAR:-4}; OD=$(mktemp -d "${TMPDIR:-/tmp}/packjobs.XXXXXX"); trap 'rm -rf "$OD"' EXIT
u0=$(untracked)
# 大份先起：按文件大小从大到小（不写死文件名——单测里点名具体测试文件，路由器会顺着它们的引用把无关的改动也挂到本单测，11-14 gate_route_matrix_test 红）
order=(); while IFS= read -r t; do order+=("$t"); done < <(ls -S "${sel[@]}")
printf '%s\0' "${order[@]}" | xargs -0 -P "$P" -n 1 sh -c '
  # 作业层测试一律不起后台商店查询（S2A_BANNER_FETCH=0）：它脱离作业、往测试的临时 library/ 写，收尾删目录时偶发 Directory not empty（11-10）
  n=$(basename "$1"); S2A_BANNER_FETCH=0 python3 -B -m unittest discover -s pack/jobs/tests -p "$n" > "$0/$n.out" 2>&1; echo $? > "$0/$n.rc"' "$OD"
bad=0; for t in "${sel[@]}"; do
  n=${t##*/}; o=$(cat "$OD/$n.out" 2> /dev/null); rc=$(cat "$OD/$n.rc" 2> /dev/null || echo 99)
  if [ "$rc" = 0 ]; then echo "通 ${n}：$(grep -E '^Ran ' <<< "$o")"
  else echo "不通 ${n}（rc=${rc}）"; tail -15 <<< "$o" | sed 's/^/    | /'
    # 失败用例的完整报错进门禁日志（tools/gate.sh 收「  ┊」行最多 400 行，不受末尾 12 行截断；同 XCTest 点名 13d9383df）：
    #   每个「ERROR: / FAIL: 用例名」起到 unittest 的分隔线为止（含调用栈），每份最多 80 行。11-09 test_saves 负载下红，日志只剩「FAILED (errors=1)」定不了因
    awk '/^(ERROR|FAIL): /{on=1} on && /^-{20,}$/ && seen{on=0} on{print; seen=1} /^(ERROR|FAIL): /{seen=0}' <<< "$o" | head -80 | sed "s/^/  ┊ ${n} /"
    bad=1; fi
done
new=$(LC_ALL=C comm -13 <(echo "$u0") <(untracked))
if [ -n "$new" ]; then echo "不通：跑完工作树里多了文件（单测要写临时目录；并行跑分不清是哪一份，全部点名）"; sed 's/^/    | /' <<< "$new" | head -10; bad=1; fi
[ $bad = 0 ] && echo "pack/jobs 单测全过" || { echo "pack/jobs 单测有不通"; exit 1; }
