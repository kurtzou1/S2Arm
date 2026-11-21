#!/bin/bash
# 门禁覆盖：tools/jobs_l10n_lint.py tools/jobs_l10n_baseline.json pack/jobs launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json launchers/shared/experience.v1.json
# 作业层玩家句要有翻译（tools/jobs_l10n_lint.py，11-14 i18n 第四批）：名字带 lint，入队确定性快检查自动跑。期望按构造手写：
#   ① 假仓库：对照表有的整句、带 {0} 句式套得上的 f-string、按「；」拆开每段都有的句子（含「；」开头的拼句片段）、共享体验表的阶段名都算覆盖；共享表 launcher 界面句不算（两端翻译不取它）→ 只缺那 1 处
#   ② 加一句对照表没有的 → 退出 1，点名 pack/jobs/a.py:行 与原句
#   ③ docstring、log() / print() 参数、行尾「# 非玩家句」的不算 → 退出 0
#   ④ --baseline 记下缺口后再查 → 退出 0；基线里那句补进对照表后 → 退出 0 且提示「已补上，可跑 --baseline 收紧」
#   ⑤ pack/jobs/tests/ 下的不扫
#   ⑥ 真仓库：新增 0 处
#   ⑦ 四语翻译表顶层出现中文键（没放进 text 表）→ 退出 1、点名文件与原句；挪进 text 后 → 退出 0；真仓库放错层 0 处
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
D=$H/tools/jobs_l10n_lint.py
R=$T/r; mkdir -p $R/pack/jobs/tests $R/launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources $R/launchers/shared $R/tools
L=$R/launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json
printf '[\n {"source": "游戏已停止。", "en": "Game stopped."},\n {"source": "还剩 {0} 款", "en": "{0} left"},\n {"source": "甲句", "en": "A"},\n {"source": "乙句", "en": "B"}\n]\n' > $L
printf '{"launcher": {"items": [{"id": "x", "zh-Hans": "界面句不算", "en": "UI only"}]}, "stage_labels": {"s": {"zh-Hans": "共享句", "en": "Shared"}}}\n' > $R/launchers/shared/experience.v1.json
cat > $R/pack/jobs/a.py <<'PY'
def f(n):
    """文档里的中文不算"""
    a = "游戏已停止。"
    b = f"还剩 {n} 款"
    c = "甲句；乙句"
    c2 = "；乙句"
    d = "共享句"
    return a, b, c, d
X = "界面句不算"
PY
printf 'x = "测试里的中文不扫"\n' > $R/pack/jobs/tests/test_a.py
o=$(python3 $D $R 2>&1); r=$?
ck "① 整句 / 句式 / 拆段 / 共享阶段名都覆盖；共享表的界面句不算（翻译不取它）→ 只缺 1 处「界面句不算」" '[ $r = 1 ] && grep -q "缺翻译 1 处" <<< "$o" && grep -q "a.py:9 玩家句没有英文：「界面句不算」" <<< "$o"'
sed 's/^X = "界面句不算"$/X = "界面句不算"  # 非玩家句/' $R/pack/jobs/a.py > $R/a.tmp && mv $R/a.tmp $R/pack/jobs/a.py
printf 'e = "这句没翻"\n' >> $R/pack/jobs/a.py
o=$(python3 $D $R 2>&1); r=$?
ck "② 对照表没有的句子 → 退出 1、点名 a.py:10（${r}）" '[ $r = 1 ] && grep -q "pack/jobs/a.py:10 玩家句没有英文：「这句没翻」" <<< "$o"'
printf 'def g(log):\n    log("日志里的中文")\n    print("打印的中文")\n    return "内部比对用" # 非玩家句\n' > $R/pack/jobs/b.py
o=$(python3 $D $R 2>&1); r=$?
ck "③ 日志 / 打印 / 带标记的行不算 → 仍只有 a.py 一处（$(grep -c 🔴 <<< "$o")）" '[ $(grep -c 🔴 <<< "$o") = 1 ]'
python3 $D $R --baseline > /dev/null
o=$(python3 $D $R 2>&1); r=$?
ck "④a 记基线后 → 退出 0（${r}）、基线 1 条、新增 0" '[ $r = 0 ] && grep -q "基线 1 条），新增 0 处" <<< "$o"'
printf '[\n {"source": "游戏已停止。", "en": "Game stopped."},\n {"source": "还剩 {0} 款", "en": "{0} left"},\n {"source": "甲句", "en": "A"},\n {"source": "乙句", "en": "B"},\n {"source": "这句没翻", "en": "Now translated"}\n]\n' > $L
o=$(python3 $D $R 2>&1); r=$?
ck "④b 补进对照表后 → 退出 0（${r}）、提示 1 条可收紧" '[ $r = 0 ] && grep -q "基线里 1 条已补上，可跑 --baseline 收紧" <<< "$o"'
ck "⑤ tests/ 下的不扫" '! grep -q "测试里的中文" <<< "$o"'
o=$(python3 $D $H 2>&1); r=$?
ck "⑥ 真仓库：新增 0 处（${o##*$'\n'}）" '[ $r = 0 ] && grep -q "新增 0 处" <<< "$o"'
mkdir -p $R/launchers/shared/l10n; F=$R/launchers/shared/l10n/fr.json
printf '{\n "language": "fr",\n "text": {\n  "甲句": "A"\n },\n "放错层的句子": "Mal placé"\n}\n' > $F
o=$(python3 $D $R 2>&1); r=$?
ck "⑦a 顶层中文键 → 退出 1（${r}）、点名 fr.json「放错层的句子」" '[ $r = 1 ] && grep -q "l10n/fr.json 顶层有中文键.*「放错层的句子」" <<< "$o" && grep -q "放错层 1 处" <<< "$o"'
printf '{\n "language": "fr",\n "text": {\n  "甲句": "A",\n  "放错层的句子": "Mal placé"\n }\n}\n' > $F
o=$(python3 $D $R 2>&1); r=$?
ck "⑦b 挪进 text 后 → 退出 0（${r}）、放错层 0 处" '[ $r = 0 ] && grep -q "放错层 0 处" <<< "$o"'
o=$(python3 $D $H 2>&1)
ck "⑦c 真仓库：放错层 0 处" 'grep -q "放错层 0 处" <<< "$o"'
[ $bad = 0 ] && echo "jobs_l10n_lint 单测全过" || { echo "jobs_l10n_lint 单测有不通"; exit 1; }
