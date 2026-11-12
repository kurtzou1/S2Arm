#!/bin/bash
# 门禁计划的共用规则（被 source）：列车 tools/train.sh 与贡献者自检 tools/contrib_check.sh 用同一份，自检挑出的步骤 = 列车会跑的步骤
#   （10-27 名单线 lists/any-aspect：自检 13/13 绿、列车红在 graphics/gate.sh 的本机子项 t_gl_min——自检把 graphics/gate.sh 当第二层一律跳过，
#    在有数据的维护者机器上也跳；档位两边各写一份。单测 tests/gate_plan_same_test.sh 钉住两边清单相同）
#   gate_tier <改动文件清单（换行分隔）>   → doc / tool / full（doc 仍跑公开仓扫描）
#   gate_layer2_why <表> <步骤名>          第二层且本机缺它要的数据 → 打印原因、返回 0（不跑）；本机数据齐 / 不是第二层 → 返回 1（跑）
#     表 tools/contrib_layer2.tsv：步骤名（shell 通配）	原因	要的数据（空格分隔的路径，~ 与 $变量 展开；全都在才跑；不写 = 一律不跑）
# 文档类（doc 档 = 快车道：只跑公开仓扫描就合）：docs/、*.md、.github/ISSUE_TEMPLATE/（issue 模板 .yml，10-29 列车线：
#   rel/contrib-loop 只改文档 / 模板 / skill，因两个 .yml 模板被判 full 档、排 full 队）。基础文档范围仍与 tools/gate_route.py 同一条（GATE_DOC_RE）；定档另排除下面的敏感路径
GATE_DOC_RE='^docs/|\.md$|^\.github/ISSUE_TEMPLATE/'
gate_tier() {
  # 文件列表一律经管道喂（printf | grep），不用 here-string：bash 5.2 的 here-string 小的走管道（子进程先把内容整个写进去再 exec，
  #   macOS 管道扩不到 64K 时超过 16K 就自己卡死在写），大的走临时文件（TMPDIR 写不了就失败、判错档）。
  #   11-04 列车快档 11:01–12:02 卡死在这里（进程链 76607→70661→70674→70676），所有 doc / tool 支一小时过不去
  local F=$1 n; n=$(printf '%s\n' "$F" | grep -c .)
  # 会影响运行/排查的数据与技能不按普通文档跳过单测；其余旧档位规则不变。
  #   docs/site/notice.json（11-12）：启动器运行时读（Pages + 随包兜底），撤公告走 doc 档没跑 test_updater、main 全套红
  [ "$n" -eq "$(printf '%s\n' "$F" | grep -vE '^docs/.*\.tsv$|^docs/排查/|^skills/|^docs/site/notice\.json$' | grep -cE "$GATE_DOC_RE")" ] && { echo doc; return; }
  [ "$n" -eq "$(printf '%s\n' "$F" | grep -E "$GATE_DOC_RE"'|^tools/|^tests/|^pack/|^skills/' | grep -vcE '^tests/visual/')" ] && { echo tool; return; }
  echo full
}
gate_layer2_why() {
  local pat why need p e; while IFS=$'\t' read -r pat why need; do
    case $pat in \#*|'') continue;; esac; case $2 in $pat) ;; *) continue;; esac
    [ -n "${need:-}" ] || { echo "$why"; return 0; }
    for p in $need; do e=$(eval "echo $p" 2> /dev/null); [ -n "$e" ] && [ -e "$e" ] || { echo "$why"; return 0; }; done
    return 1
  done < "$1"; return 1; }
