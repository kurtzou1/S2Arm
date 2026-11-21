#!/bin/bash
# 按款的产物内容指纹（10-29 维护者：改公共脚本不许触发全款重出——不用整棵源码树的哈希）：tools/pack_fp.sh <款> [<提交>]
#   指纹 = 该款各阶段键（本树代码对共享现行根只算键：改写 / 能力清单 / 界面布局 / 追加内容 / RomFS 索引 / 抽取 / 直连配置 / 直连库 / 直连门键 / 管线种子表 / 计算管线归档 / 着色器；
#           各阶段键已是「输入内容 + 只影响该阶段的代码」）
#        + 出包选项（PQ_EXTRA：--all-caps 时包里换成 s2a_caps.all.tsv；能力清单本身是独立阶段 caps，键在阶段键里）
#        + App 程序源码（runtime ios graphics translator services compat Makefile 与包壳文件；去掉 graphics/tools、各处 tests/、*_test.*、*.md——它们不编进程序）。
#   不进指纹：出包 / 调度 / 门禁脚本本身（pack/*.sh、tools/）——它们变了而上面三样没变，包的内容就不变，不重出。
#   给了 <提交> 时在专用工作树（S2A_PACK_FP_WT，缺省 ~/.s2arm/wt/packq_fp，加锁）检出它再算；不给 = 用本树。算不出（没有共享现行根等）退出 1、不打指纹。
set -u
G=${1:?款}; C=${2:-}
if [ -n "$C" ] && [ -z "${PACK_FP_IN_WT:-}" ]; then
  W=${S2A_PACK_FP_WT:-$HOME/.s2arm/wt/packq_fp}; T=$(cd "$(dirname "$0")/.." && pwd); LK=$W.lock; w0=$SECONDS
  until mkdir "$LK" 2> /dev/null; do p=$(cat "$LK/pid" 2> /dev/null); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$LK"; [ $((SECONDS - w0)) -ge 600 ] && exit 1; sleep 2; done
  echo $$ > "$LK/pid"; trap 'rm -rf "$LK"' EXIT
  if [ -d "$W" ]; then git -C "$W" checkout -q --detach "$C" 2> /dev/null || exit 1; else git -C "$T" worktree add -q --detach "$W" "$C" 2> /dev/null || exit 1; fi
  ( cd "$W" && PACK_FP_IN_WT=1 bash tools/pack_fp.sh "$G" ); exit $?
fi
R=$(git rev-parse --show-toplevel 2> /dev/null) || R=$(cd "$(dirname "$0")/.." && pwd)   # 算当前目录所在那棵树（复演旧提交时脚本可能来自别处）
source "$R/pack/roots.sh"; CUR=$(root_cur_in "$S2A_ROOTS_SHARED" "$G" 2> /dev/null) || exit 1   # 共享根的现行（指针文件）
K=$(mktemp); CP=$(mktemp); trap 'rm -f "$K" "$CP"' EXIT
for s in rewrite caps uilayout aoc romfsidx extract direct_profile direct direct_gk direct_seed direct_cpso shaders; do
  if [ "${S2A_PACK_FP_KEYS:-}" = recorded ]; then   # 单测：假产物根只有 .stage_* 记录、算不了键，取根里记的键
    [ -s "$CUR/.stage_$s" ] && printf '%s\t%s\n' "$s" "$(cat "$CUR/.stage_$s")" >> "$K"; continue; fi
  f=$R/pack/stage_$s.sh; [ -f "$f" ] || continue
  ( cd "$R" && S2A_ROOT_CUR=$CUR S2A_STAGE_KEYS=$K S2A_DUAL=${S2A_DUAL:-1} timeout 240 bash "$f" "$G" > /dev/null 2>&1 < /dev/null )
done
[ -s "$K" ] || exit 1
echo "extra=${PQ_EXTRA:-}" > "$CP"   # 能力清单已是独立阶段（pack/stage_caps.sh，键在上面）；包用发布口径还是 --all-caps 那份由出包选项定
APP=$(git -C "$R" ls-tree -r HEAD -- runtime ios graphics translator services compat Makefile pack/app.entitlements \
  | grep -vE $'\t(graphics/tools/|[^\t]*/tests?/|[^\t]*_test\\.[a-z]+$|[^\t]*\\.md$)' | git -C "$R" hash-object --stdin)
{ LC_ALL=C sort "$K"; echo "caps $(grep -v '^#' "$CP" | shasum -a 256 | cut -c1-16)"; echo "app $APP"; } | shasum -a 256 | cut -c1-16
