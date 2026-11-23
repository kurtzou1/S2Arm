#!/bin/bash
# 自检与列车挑出的门禁步骤必须相同（10-27 名单线 lists/any-aspect：自检 13/13 绿，列车 15 步红在 graphics/gate.sh 的本机子项——
#   自检把有数据的第二层也一律跳过，档位两边各写一份）。
# 临时克隆本仓库（体检换成「工具齐全」的桩，其余真实脚本），提交一组覆盖 doc / tool / 钩子负责文件的改动，对同一改动集：
#   ① 列车清单 = tools/gate_plan.sh gate_tier 定档 + GATE_LIST=1 tools/gate.sh（列车 train.sh 同此调用）
#   ② 自检清单 = CONTRIB_LIST_ONLY=1 tools/contrib_check.sh --base <基线>（第一层，一行一步）
#   第二层数据都在（假家目录里建齐表里的路径）→ ① = ② 逐行相同；数据都不在 → ② = ① 去掉第二层表登记的步，且至少少一步（防空转）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_gate_plan_same_XXXXXX"); trap 'rm -rf "$T"' EXIT
bad=0; ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# --shared：历史对象经 alternates 引用本仓库、不复制（11-16 门禁提速：--no-hardlinks 每次复制 800 多 MB 对象约 6 秒）；克隆只在本单测里活着、用完即删
git clone -q --shared "$H" "$T/r" 2> /dev/null || git clone -q "$H" "$T/r" || { echo "不通 克隆失败"; exit 1; }
cd "$T/r" || exit 1; g() { git -c user.name=t -c user.email=t@t "$@"; }
# 路由缓存（tools/gate_route.py，按内容寻址：覆盖面按树指纹、点名词表按文件内容摘要）和本仓库共用一份，克隆里的几次门禁规划不必各自冷算
gc=$(git -C "$H" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) && mkdir -p "$gc/s2a-gate-route" && ln -s "$gc/s2a-gate-route" "$(git rev-parse --git-common-dir)/s2a-gate-route" 2> /dev/null || :
# 当前工作树里未提交的本组改动也带进来（单测在自检 / 门禁里跑时 HEAD 已含；手动跑时可能还没提交）
(cd "$H" && git diff HEAD) | git apply --whitespace=nowarn 2> /dev/null
printf '#!/bin/bash\necho "✅ 工具齐全（单测桩）"\n' > tools/doctor.sh; g add -A; g commit -q -m base --allow-empty; BASE=$(git rev-parse HEAD)
# 改动集：文档 + 工具 + 单测 + graphics/gate.sh 负责的画面代码（会路由到钩子 graphics/gate.sh，第二层）+ tests/visual（另一个第二层钩子）
echo x >> docs/常见问题.md; echo '# x' >> tools/gate_plan.sh; echo '# x' >> tests/gate_plan_same_test.sh
f=$(git ls-files 'graphics/nvn/gfx/gl/*.inc' | head -1); [ -n "$f" ] && echo '// x' >> "$f"
v=$(git ls-files 'tests/visual/*.sh' | head -1); [ -n "$v" ] && echo '# x' >> "$v"
g add -A; g commit -q -m change
F=$(git -c core.quotepath=off diff --name-only "$BASE" HEAD)
# 下面 ①② 的逐行对比在「全部层」口径下做（两边都不按层裁，第二层钩子才在清单里）：列车实际导出 GATE_LAYER=pre、自检 11-05 起缺省也是 pre，
#   两者在 pre 口径下另比一次（文件末「缺省层」一条）
train_list() { local ti; ti=$(bash -c 'source tools/gate_plan.sh && gate_tier "$1"' _ "$F")
  env ${2+GATE_LAYER=$2} GATE_LIST=1 GATE_TIER=$ti GATE_CHANGED="$(tr '\n' ' ' <<< "$F")" bash tools/gate.sh 2> /dev/null | grep -v '^路由：' | grep .; }
contrib_list() { if [ $# -ge 2 ]; then env GATE_LAYER="$2" CONTRIB_LIST_ONLY=1 HOME=$1 bash tools/contrib_check.sh --base "$BASE"; else env -u GATE_LAYER CONTRIB_LIST_ONLY=1 HOME=$1 bash tools/contrib_check.sh --base "$BASE"; fi 2> /dev/null | grep -v '^✅' | grep .; }
mkdir -p "$T/full" "$T/empty"
while IFS=$'\t' read -r pat why need; do case $pat in \#*|'') continue;; esac
  for p in ${need:-}; do e=$(HOME="$T/full" bash -c 'eval "echo $1"' _ "$p"); mkdir -p "$(dirname "$e")"; [ -e "$e" ] || mkdir -p "$e"; done; done < tools/contrib_layer2.tsv
TL=$(env -u GATE_LAYER bash -c "$(declare -f train_list); F=\"\$1\"; train_list" _ "$F"); CF=$(contrib_list "$T/full" ""); CE=$(contrib_list "$T/empty" "")
# Linux 自检只跑可移植子集：列车完整清单仍保留 Apple 步，不能为对齐而删掉未跑记录。
RUNNABLE=$TL; APPLE=
if [ "$(uname -s)" = Linux ]; then
  APPLE=$(grep $'\t需苹果工具链$' <<< "$TL")
  RUNNABLE=$(grep -v $'\t需苹果工具链$' <<< "$TL")
  AGFX=$'钩子 graphics/gate.sh\t需苹果工具链'; AVIS=$'钩子 tests/visual/gate.sh\t需苹果工具链'
  ck "Linux 完整清单保留 Apple 钩子标记，可移植步骤非空" 'grep -qxF "$AGFX" <<< "$APPLE" && grep -qxF "$AVIS" <<< "$APPLE" && [ -n "$RUNNABLE" ]'
fi
L2=$(while IFS= read -r st; do st=${st%$'\t需苹果工具链'}; HOME=$T/empty bash -c 'source tools/gate_plan.sh; gate_layer2_why tools/contrib_layer2.tsv "$1" > /dev/null' _ "$st" < /dev/null && echo "$st"; done <<< "$TL")
ck "列车清单非空且含第二层钩子（$(grep -c . <<< "$TL") 步，第二层 $(grep -c . <<< "$L2") 步）" '[ "$(grep -c . <<< "$TL")" -ge 3 ] && grep -q "^钩子 graphics/gate.sh" <<< "$TL"'
ck "第二层数据齐：自检清单 = 本机可执行清单（$(grep -c . <<< "$CF") / $(grep -c . <<< "$RUNNABLE") 步）" '[ "$CF" = "$RUNNABLE" ]'
ck "第二层数据不在：自检清单 = 本机可执行清单去掉第二层（$(grep -c . <<< "$CE") 步）" '[ "$CE" = "$(grep -vxF -f <(echo "$L2") <<< "$RUNNABLE")" ] && [ -n "$L2" ]'
# Linux 第二层摘要：清单仍由真实 gate 生成，仅拦截执行入口代替昂贵步骤。
if [ "$(uname -s)" = Linux ]; then
  mkdir -p "$T/bin"
  # contrib 的执行入口已改为 bash "$ITO"，不能再用 timeout PATH 桩拦截。
  # 仅此摘要进程使用受控 bash：真实 gate 只准列清单，绝不执行门禁。
  REAL_BASH=$(command -v bash)
  cat > "$T/bin/bash" <<'SH'
#!/bin/bash
case ${1:-} in
  "$S2A_TEST_IDLE_TIMEOUT")
    printf 'stub\n' >> "${S2A_TEST_TIMEOUT_MARK:?}"
    IFS=$'\t' read -ra selected <<< "${GATE_RERUN:-}"
    for step in "${selected[@]}"; do [ -n "$step" ] && echo "🟢 $step"; done
    ;;
  tools/gate.sh)
    [ "${GATE_LIST:-}" = 1 ] || { echo '拒绝摘要夹具执行真实门禁' >&2; exit 97; }
    exec "$S2A_TEST_REAL_BASH" "$@"
    ;;
  tools/contrib_check.sh|tools/doctor.sh) exec "$S2A_TEST_REAL_BASH" "$@" ;;
  *) echo "拒绝摘要夹具未知 bash 入口：${1:-}" >&2; exit 97 ;;
esac
SH
  chmod +x "$T/bin/bash"
  # helper 可能前插仓库 bin：显式包含它并先验证解析，失配就停止。
  SUMMARY_PATH="$T/bin:$PWD/tools/bin:$PATH"
  RESOLVED=$(PATH="$SUMMARY_PATH" "$REAL_BASH" -c 'source tools/_timeout.sh; source tools/_timeout.sh; command -v bash')
  ck "Linux 摘要加载真实 timeout helper 后仍选中隔离 bash" '[ "$RESOLVED" = "$T/bin/bash" ]'
  [ "$RESOLVED" = "$T/bin/bash" ] || exit 1
  # 本例核全部层的第二层归属；缺省 pre 的合同由文件末独立对拍。
  SUMMARY=$(GATE_LAYER= PATH="$SUMMARY_PATH" S2A_TEST_REAL_BASH="$REAL_BASH" S2A_TEST_IDLE_TIMEOUT="$PWD/tools/idle_timeout.sh" S2A_TEST_TIMEOUT_MARK="$T/timeout.used" HOME="$T/empty" bash tools/contrib_check.sh --base "$BASE" 2>/dev/null)
  ck "Linux 摘要实际调用执行桩且仅一次" '[ "$(cat "$T/timeout.used" 2>/dev/null)" = stub ]'
  SECOND=$(grep '^- 第二层' <<< "$SUMMARY")
  SKIPPED=$(grep '^- 缺工具没跑' <<< "$SUMMARY")
  ck "Linux gfx / visual 缺数据属于第二层，不计为第一层缺工具" '[[ "$SECOND" == *"钩子 graphics/gate.sh"* && "$SECOND" == *"钩子 tests/visual/gate.sh"* && "$SKIPPED" != *"钩子 graphics/gate.sh"* && "$SKIPPED" != *"钩子 tests/visual/gate.sh"* ]]'
fi
# 只改文档的改动集（列车推送被拒后补跑「main 新增改动路由到的步」就这样调）：清单只有公开仓扫描，不能出现结论行（10-28 18:20 补跑把结论行当步跑、整批重做）
DL=$(GATE_LIST=1 GATE_TIER=full GATE_CHANGED="docs/常见问题.md README.md" bash tools/gate.sh 2> /dev/null | grep -v '^路由：' | grep .)
ck "只改文档的清单只有公开仓扫描（实得 $(grep -c . <<< "$DL") 行：${DL:0:60}）" '[ "$DL" = "公开仓扫描" ]'
# #949：期望按属主路径规则手写。读取真实列车 tier 定义，直接调用；不运行列车/队列。
# $0 指回生产 train.sh，保证其中的同目录 source 与正式/冻结副本语义相同。
TRAIN_TIER=$(python3 - <<'PY'
from pathlib import Path
import re
import os
p = Path(os.environ.get('S2A_PRIVATE_TOOLS', 'tools')) / 'train.sh'
if not p.exists():
    raise SystemExit(0)   # 公开检出没有列车（维护方设施）：列车一腿退成公共定档，只比公共定档与真实门禁
s = p.read_text()
m = re.search(r'(?ms)^tier\(\) \{.*?(?=^rd\(\))', s)
if not m:
    raise SystemExit('找不到生产 tier 函数边界')
print(m.group(0))
PY
) || exit 1
# 路径矩阵只测定档：复制真实 gate/helper/train 到最小假仓库，避免每例扫描整仓路由。
# 清单只列步骤，不执行下面的占位钩子或扫描；TSV 的真实路由另在完整克隆里验一次。
FULL_REPO=$PWD
mkdir -p "$T/tier/tools" "$T/tier/native"
cp tools/gate.sh tools/gate_plan.sh tools/public_repo_scan.py "$T/tier/tools/"
[ -z "$TRAIN_TIER" ] || cp "${S2A_PRIVATE_TOOLS:-tools}/train.sh" "$T/tier/tools/"
printf '#!/bin/bash\nexit 1\n' > "$T/tier/native/gate.sh"   # 列表阶段绝不能执行
cd "$T/tier" || exit 1
g init -q; g add -A; g commit -q -m classifier-fixture; g update-ref refs/remotes/origin/main HEAD
train_tier() { if [ -z "$TRAIN_TIER" ]; then bash -c 'source tools/gate_plan.sh; gate_tier "$1"' _ "$1"; else bash -c "$TRAIN_TIER"$'\n''tier "$1"' "$PWD/tools/train.sh" "$1"; fi; }
list_tier() {
  if [ "$1" = '公开仓扫描' ]; then echo doc
  elif grep -qE '^(钩子 |iOS 全量编译|Ryujinx 补丁核对)' <<< "$1"; then echo full
  elif grep -qx '语法' <<< "$1"; then echo tool
  else echo unknown; fi
}
check_tier() {
  local paths=$1 expected=$2 shared train observed
  shared=$(bash -c 'source tools/gate_plan.sh; gate_tier "$1"' _ "$paths")
  train=$(train_tier "$paths")
  LAST_GATE_LIST=$(GATE_LIST=1 GATE_TIER=$train GATE_CHANGED="$(tr '\n' ' ' <<< "$paths")" bash tools/gate.sh 2>/dev/null | grep -v '^路由：' | grep .)
  observed=$(list_tier "$LAST_GATE_LIST")
  ck "路径定档 [$paths] 期望 $expected → 公共 $shared / 列车 $train / 真实门禁 $observed" '[ "$shared" = "$expected" ] && [ "$train" = "$expected" ] && [ "$observed" = "$expected" ]'
}
check_tier 'docs/名单_60帧.tsv' tool
check_tier 'docs/发布验收.tsv' tool
check_tier 'docs/名单_验证账.tsv' tool
check_tier 'docs/nested/table.tsv' tool
check_tier 'docs/排查/花屏与贴图错.md' tool
check_tier 'docs/排查/notes.txt' tool
check_tier 'skills/gfx-triage/SKILL.md' tool
check_tier 'skills/native-triage/rules.json' tool
check_tier 'docs/常见问题.md' doc
check_tier 'README.md' doc
check_tier '.github/ISSUE_TEMPLATE/bug.yml' doc
check_tier '.github/ISSUE_TEMPLATE/request.yaml' doc
check_tier 'android/README.md' doc
check_tier 'docs/ordinary.json' doc   # 非指定敏感路径仍维持原规则
check_tier $'docs/名单_60帧.tsv\nREADME.md' tool
check_tier $'skills/gfx-triage/SKILL.md\nruntime/src/example.c' full
check_tier 'tools/example.py' tool
check_tier 'tests/visual/example.sh' full
check_tier $'docs/名单_60帧.tsv\ndocs/发布验收.tsv' tool
LAST_GATE_LIST=$(cd "$FULL_REPO" && GATE_LIST=1 GATE_TIER=tool GATE_CHANGED='docs/名单_60帧/0100726014352000.tsv docs/发布验收.tsv' bash tools/gate.sh 2>/dev/null | grep -v '^路由：' | grep .)
for name in cap_card_sources_test capability_card_test compatibility_report_test shared_path_test; do
  ck "TSV实际门禁清单选中 $name" 'grep -qx "单测 $name" <<< "$LAST_GATE_LIST"'
done
# gate.sh 只允许降 doc，不能把调用者显式给的档位向上抬，空改动不改档。
check_explicit() {
  local requested=$1 paths=$2 expected=$3 observed listing
  listing=$(GATE_LIST=1 GATE_REV=origin/main GATE_TIER=$requested GATE_CHANGED="$paths" bash tools/gate.sh 2>/dev/null | grep -v '^路由：' | grep .)
  observed=$(list_tier "$listing")
  ck "显式档 $requested / [$paths] 期望 $expected → $observed" '[ "$observed" = "$expected" ]'
}
check_explicit full 'docs/名单_60帧.tsv' full
check_explicit doc 'docs/名单_60帧.tsv' doc
check_explicit tool 'runtime/src/example.c' tool
check_explicit full 'docs/常见问题.md' doc
check_explicit tool '' tool
check_explicit full '' full
# 缺省层（11-05 门禁精简）：自检不设 GATE_LAYER = 合入前层，与列车（导出 GATE_LAYER=pre）同一清单
TP=$(cd "$T/r" && train_list x pre); CP=$(cd "$T/r" && contrib_list "$T/full")
TP_RUNNABLE=$TP
if [ "$(uname -s)" = Linux ]; then
  # 与上面的全部层对拍同口径：列车保留 Apple 标记，自检只证本机可执行子集。
  PRE_NATIVE=$'钩子 runtime/gate.sh\t需苹果工具链'
  ck "Linux pre 完整清单保留 native Apple 钩子" 'grep -qxF "$PRE_NATIVE" <<< "$TP"'
  TP_RUNNABLE=$(grep -v $'\t需苹果工具链$' <<< "$TP")
fi
ck "缺省层：自检不设层的清单 = 列车 pre 本机可执行清单（$(grep -c . <<< "$CP") / $(grep -c . <<< "$TP_RUNNABLE") 步）" '[ -n "$TP_RUNNABLE" ] && [ "$CP" = "$TP_RUNNABLE" ]'
[ $bad = 0 ] && echo "✓ gate_plan_same 单测全过" || { echo "gate_plan_same 单测有不通"; diff <(echo "$TL") <(echo "$CF") | head -20; exit 1; }
