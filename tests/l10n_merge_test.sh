#!/bin/bash
# 门禁覆盖：tools/l10n_merge.py .gitattributes
# 翻译表合并器单测（11-09：#221 #238 都往 Localizable.json 文件尾追加，先合一支另一支就冲突退回）：临时仓库登记合并器，两支各改依次合进 main。
# 期望（按规则手写）：
#   ① 条目表两支各在尾部追加一条 → 两次合并都不冲突，结果是合法 JSON：原条目在前、先合的、后合的依次在后，各一份
#   ② 键值表两支各加一个键、一支改了另一个键 → 不冲突，三处改动都在
#   ③ 两支把同一条英文改成不同的 → 仍冲突（留给人）
#   ④ 一支删了一条、另一支没动它 → 删掉
#   ⑤ .xcstrings（Xcode「" : "」格式）两支各在 strings 下加一个键 → 不冲突，两个键都在，仍是 Xcode 格式
#   ⑥ .strings 两支各在不同位置加一条（k1 后 / k2 后）、一支改 k3 → 不冲突，顺序 k1 a k2 b k3、k3 是改后的
#   ⑦ .strings 同一个键两边改成不同 → 仍冲突；⑧ .strings 注释两边都改 → 冲突；⑧b 只对侧加空行 → 不冲突、两侧新键都在
#   ⑩ experience 表（手排格式：顶层多行、对象数组一条一行，同真表）：两支各加一个码、各把 revision 5→6 → 不冲突、都在、revision 7
#   ⑮ 合并后格式保持本侧原样（11-11：旧驱动合完 json.dumps(indent=2) 把 1330 行的表展开成 6549 行，发版带入检查按行判 v0.2.9 两个热修「缺行」）
#   ⑫ 同一个码两边改成不同值 → 冲突；⑯ 冲突时本侧文件不被重排；⑬ 只一边加 revision → 取那边
#   ⑭ 对象数组按 id 合：各加 c / d → a b d c、仍一条一行；⑭b 同 id 改成不同值 → 冲突
#   ⑰ 真实回放 11-11 17:30 那次合并：行数 ≤ 1340、与当时合并结果语义相等
#   ⑨ 手排格式的 JSON（短数组写在一行，写不回原样）两支各加一个键 → 仍冲突（不碰，交人）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid GIT_CONFIG_GLOBAL=/dev/null
R=$T/r; git init -q -b main $R; cd $R
git config merge.s2a-l10n.driver "python3 $H/tools/l10n_merge.py %O %A %B %P"
printf 'L.json merge=s2a-l10n\nK.json merge=s2a-l10n\nX.xcstrings merge=s2a-l10n\nS.strings merge=s2a-l10n\nE.json merge=s2a-l10n\nlaunchers/shared/experience.v1.json merge=s2a-l10n\n' > .gitattributes
ent() { printf ' {\n  "source": "%s",\n  "en": "%s"\n }' "$1" "$2"; }
lst() { local s='[' sep=''; while [ $# -gt 0 ]; do s="$s$sep"$'\n'"$(ent "$1" "$2")"; sep=','; shift 2; done; printf '%s\n]\n' "$s"; }
lst 甲 A 乙 B > L.json; printf '{\n  "k1": "一",\n  "k2": "二"\n}\n' > K.json; git add -A; git commit -qm base
git checkout -q -b b1; lst 甲 A 乙 B 丙 C > L.json; printf '{\n  "k1": "一",\n  "k2": "二",\n  "k3": "三"\n}\n' > K.json; git commit -qam b1
git checkout -q main; git checkout -q -b b2; lst 甲 A 乙 B 丁 D > L.json; printf '{\n  "k1": "壹",\n  "k2": "二",\n  "k4": "四"\n}\n' > K.json; git commit -qam b2
git checkout -q main; git merge -q --no-edit b1 > /dev/null 2>&1; m1=$?; git merge -q --no-edit b2 > /dev/null 2>&1; m2=$?
ck "① 条目表两支尾部追加：不冲突（rc ${m1} / ${m2}），合法 JSON，顺序 甲乙丙丁" '[ $m1 = 0 ] && [ $m2 = 0 ] && [ "$(python3 -c "import json;print(\"\".join(e[\"source\"] for e in json.load(open(\"L.json\"))))")" = 甲乙丙丁 ]'
ck "② 键值表：k1 改成壹、k3 k4 都在" '[ "$(python3 -c "import json;d=json.load(open(\"K.json\"));print(d[\"k1\"],d[\"k3\"],d[\"k4\"])")" = "壹 三 四" ]'
git checkout -q -b c1 main; lst 甲 A1 乙 B 丙 C 丁 D > L.json; git commit -qam c1
git checkout -q -b c2 main; lst 甲 A2 乙 B 丙 C 丁 D > L.json; git commit -qam c2
git checkout -q main; git merge -q --no-edit c1 > /dev/null 2>&1; git merge -q --no-edit c2 > /dev/null 2>&1; m3=$?; git merge --abort 2> /dev/null
ck "③ 同一条两边改成不同 → 仍冲突（rc ${m3}）" '[ $m3 != 0 ]'
git checkout -q -b d1 main; lst 甲 A1 丙 C 丁 D > L.json; git commit -qam d1
git checkout -q -b d2 main; lst 甲 A1 乙 B 丙 C 丁 D 戊 E > L.json; git commit -qam d2
git checkout -q main; git merge -q --no-edit d1 > /dev/null 2>&1; git merge -q --no-edit d2 > /dev/null 2>&1; m4=$?
ck "④ 一支删乙、另一支加戊 → 不冲突（rc ${m4}），乙没了、戊在" '[ $m4 = 0 ] && [ "$(python3 -c "import json;print(\"\".join(e[\"source\"] for e in json.load(open(\"L.json\"))))")" = 甲丙丁戊 ]'
xc() { python3 -c 'import json,sys; print(json.dumps({"sourceLanguage":"zh-Hans","strings":{k:{"localizations":{"en":{"stringUnit":{"state":"translated","value":k.upper()}}}} for k in sys.argv[1:]},"version":"1.0"},ensure_ascii=False,indent=2,separators=(",", " : ")))' "$@"; }
st() { printf '/* 注释 %s */\n' "$1"; shift; for k in "$@"; do printf '"%s" = "%s";\n' "${k%%=*}" "${k#*=}"; done; }
git checkout -q main; xc ka kb > X.xcstrings; st 一 k1=1 k2=2 k3=3 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1\n}\n' > E.json; git add -A; git commit -qm base2
git checkout -q -b x1 main; xc ka kb kc > X.xcstrings; st 一 k1=1 a=A k2=2 k3=3 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1,\n  "b": 2\n}\n' > E.json; git commit -qam x1
git checkout -q -b x2 main; xc ka kb kd > X.xcstrings; st 一 k1=1 k2=2 b=B k3=三 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1,\n  "c": 3\n}\n' > E.json; git commit -qam x2
git checkout -q main; git merge -q --no-edit x1 > /dev/null 2>&1; git merge -q --no-edit x2 > /dev/null 2>&1; m5=$?
ck "⑤ .xcstrings 两支各加键：kc kd 都在、仍是「\" : \"」格式" 'python3 -c "import json;d=json.load(open(\"X.xcstrings\"));assert {\"kc\",\"kd\"}<=set(d[\"strings\"])" 2> /dev/null && grep -q "\" : " X.xcstrings'
ck "⑥ .strings 两支不同位置各加一条、一支改 k3：顺序 k1 a k2 b k3、k3=三" '[ "$(grep -o "^\"[^\"]*\"" S.strings | tr -d "\"" | tr "\n" " ")" = "k1 a k2 b k3 " ] && grep -q "^\"k3\" = \"三\";" S.strings'
ck "⑨ 手排 JSON 两支各加键 → 仍冲突（rc ${m5}，E.json 判未合并、本侧原样不改写）" '[ $m5 != 0 ] && git ls-files -u E.json | grep -q . && grep -q "\"b\": 2" E.json && ! grep -q "\"c\"" E.json'
git merge --abort 2> /dev/null; git checkout -q -f main
git checkout -q -b y1 main; st 一 k1=1 k2=二 k3=3 > S.strings; git commit -qam y1
git checkout -q -b y2 main; st 一 k1=1 k2=贰 k3=3 > S.strings; git commit -qam y2
git checkout -q main; git merge -q --no-edit y1 > /dev/null 2>&1; git merge -q --no-edit y2 > /dev/null 2>&1; m7=$?; git merge --abort 2> /dev/null; git reset -q --hard y1~1
ck "⑦ .strings 同键两边改成不同 → 冲突（rc ${m7}）" '[ $m7 != 0 ]'
git checkout -q -b z1 main; st 甲 k1=1 k2=2 k3=3 > S.strings; git commit -qam z1
git checkout -q -b z2 main; st 乙 k1=1 k2=2 k3=3 k4=4 > S.strings; git commit -qam z2
git checkout -q main; git merge -q --no-edit z1 > /dev/null 2>&1; git merge -q --no-edit z2 > /dev/null 2>&1; m8=$?; git merge --abort 2> /dev/null
ck "⑧ .strings 注释两边都改 → 冲突（rc ${m8}）" '[ $m8 != 0 ]'
# ⑧b 只对侧改了非条目行（加空行 + 新键）、本侧只加键 → 不冲突；空行留着、两个新键都在（11-14 sgrade-2 zh-Hant 被误判冲突）
git checkout -q -f main; git checkout -q -b w0 main; st 一 k1=1 k2=2 k3=3 > S.strings; git commit -qam w0
git checkout -q -b w1 w0; st 一 k1=1 k2=2 a=A k3=3 > S.strings; git commit -qam w1
git checkout -q -b w2 w0; { st 一 k1=1 k2=2 k3=3; echo; printf '"b" = "B";\n'; } > S.strings; git commit -qam w2
git checkout -q w1; git merge -q --no-edit w2 > /dev/null 2>&1; m9=$?
ck "⑧b 只对侧加空行：不冲突（rc ${m9}），空行在、键 k1 k2 a k3 b" '[ $m9 = 0 ] && [ "$(grep -c "^$" S.strings)" -ge 1 ] && [ "$(grep -o "^\"[^\"]*\"" S.strings | tr -d "\"" | tr "\n" " ")" = "k1 k2 a k3 b " ]'
git merge --abort 2> /dev/null; git checkout -q -f main
XP=launchers/shared/experience.v1.json; git checkout -q -f main; mkdir -p launchers/shared
# 手排格式（同真表）：顶层多行、对象数组一条一行。xe <revision> <errors 条目…（code=zh）>；items 固定 a b
xe() { python3 - "$XP" "$@" <<'XPY'
import json, sys
p, rev, *es = sys.argv[1:]
row = lambda d: json.dumps(d, ensure_ascii=False)
L = ['{', '  "contract": "s2a.experience.v1",', f'  "revision": {rev},', '  "languages": ["zh-Hans", "en"],', '', '  "errors": [']
L += ['    ' + row({'code': c, 'zh-Hans': z}) + (',' if k < len(es) - 1 else '') for k, (c, z) in enumerate(e.split('=') for e in es)]
L += ['  ],', '', '  "launcher": {', '    "items": [', '      {"id": "a", "zh-Hans": "甲"},', '      {"id": "b", "zh-Hans": "乙"}', '    ]', '  }', '}']
open(p, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
XPY
}
codes() { python3 -c "import json;print(' '.join(e['code'] for e in json.load(open('$XP'))['errors']))"; }
xe 5 E1=一; git add -A; git commit -qm xbase
git checkout -q -b e1 main; xe 6 E1=一 E2=二; git commit -qam e1
git checkout -q -b e2 main; xe 6 E1=一 E3=三; git commit -qam e2
git checkout -q e1; cp $XP $T/ours10; git merge -q --no-edit e2 > /dev/null 2>&1; m10=$?
ck "⑩ 两支各加一个码、各把 revision 5→6 → 不冲突（rc ${m10}）、E1 E2 E3 都在、revision 7" '[ $m10 = 0 ] && [ "$(codes)" = "E1 E3 E2" -o "$(codes)" = "E1 E2 E3" ] && python3 -c "import json;assert json.load(open(\"$XP\"))[\"revision\"]==7"'
ck "⑮ 格式保持本侧原样：与本侧比只多对侧那一条、revision 那一行改数字、逗号随之补（差 ≤ 3 行），没有整份重排" '[ "$(wc -l < $XP | tr -d " ")" = "$(( $(wc -l < $T/ours10 | tr -d " ") + 1 ))" ] && [ "$(diff $T/ours10 $XP | grep -c "^[<>]")" -le 5 ] && grep -q "^    {\"code\": \"E3\", \"zh-Hans\": \"三\"}" $XP && ! grep -q "^      \"code\"" $XP && [ "$(grep -c "\"revision\"" $XP)" = 1 ]'
git checkout -q -f -b f1 main; xe 6 E1=一 E4=四; git commit -qam f1
git checkout -q -b f2 main; xe 5 E1=一 E5=五; git commit -qam f2
git checkout -q f1; git merge -q --no-edit f2 > /dev/null 2>&1; m13=$?
ck "⑬ 只一边加 revision → 取那边 6（rc ${m13}）、E4 E5 都在" '[ $m13 = 0 ] && python3 -c "import json;d=json.load(open(\"$XP\"));assert d[\"revision\"]==6 and {\"E4\",\"E5\"}<={e[\"code\"] for e in d[\"errors\"]}"'
git checkout -q -f -b g1 main; xe 5 E1=壹; git commit -qam g1
git checkout -q -b g2 main; xe 5 E1=幺; git commit -qam g2
git checkout -q g1; git merge -q --no-edit g2 > /dev/null 2>&1; m12=$?
ck "⑫ 同一个码两边改成不同值 → 冲突（rc ${m12}）" '[ $m12 != 0 ]'
ck "⑯ 冲突时不重排：本侧文件里仍是一条一行（没有展开成多行对象）" '! grep -q "^      \"code\"" $XP'
git merge --abort 2> /dev/null; git checkout -q -f main
git checkout -q -b l1 main; perl -0pi -e 's/("id": "b", "zh-Hans": "乙"\})/$1,\n      {"id": "c", "zh-Hans": "丙"}/' $XP; git commit -qam l1
git checkout -q -b l2 main; perl -0pi -e 's/("id": "b", "zh-Hans": "乙"\})/$1,\n      {"id": "d", "zh-Hans": "丁"}/' $XP; git commit -qam l2
git checkout -q l1; git merge -q --no-edit l2 > /dev/null 2>&1; m14=$?
ck "⑭ 数组按 id 合：各加 c / d → 不冲突（rc ${m14}）、顺序 a b d c（对侧新增 d 插在它在对侧的前一项 b 之后）、仍一条一行" '[ $m14 = 0 ] && [ "$(python3 -c "import json;print(\" \".join(e[\"id\"] for e in json.load(open(\"$XP\"))[\"launcher\"][\"items\"]))")" = "a b d c" ] && grep -q "^      {\"id\": \"d\", \"zh-Hans\": \"丁\"},$" $XP'
git checkout -q -f -b l3 main; perl -pi -e 's/"乙"/"贝"/' $XP; git commit -qam l3
git checkout -q -b l4 main; perl -pi -e 's/"乙"/"北"/' $XP; git commit -qam l4
git checkout -q l3; git merge -q --no-edit l4 > /dev/null 2>&1; m14b=$?; git merge --abort 2> /dev/null; git checkout -q -f main
ck "⑭b 同 id b 改成不同值 → 冲突（rc ${m14b}）" '[ $m14b != 0 ]'
# ⑰ 真实回放（11-11 17:30 那次：旧驱动把 1330 行手排表展开成 6549 行）：基 162c7501b、本侧 763cc6572、对侧 5c03d563d
if git -C "$H" cat-file -e 82b3d742:$XP 2> /dev/null && git -C "$H" cat-file -e 162c7501b:$XP 2> /dev/null; then
  for c in o:162c7501b a:763cc6572 b:5c03d563d; do git -C "$H" show ${c#*:}:$XP > $T/r${c%%:*}; done
  python3 "$H/tools/l10n_merge.py" $T/ro $T/ra $T/rb $XP; m17=$?
  ck "⑰ 真实回放 17:30：不冲突（rc ${m17}）、行数 ≤ 1340（实得 $(wc -l < $T/ra | tr -d ' ')）、与当时的合并结果语义相等" '[ $m17 = 0 ] && [ "$(wc -l < $T/ra | tr -d " ")" -le 1340 ] && python3 -c "import json,subprocess,sys;t=json.loads(subprocess.run([\"git\",\"-C\",sys.argv[1],\"show\",\"82b3d742:$XP\"],capture_output=True,text=True).stdout);d=json.load(open(sys.argv[2]),object_pairs_hook=lambda p:(len({k for k,_ in p})==len(p) or sys.exit(\"重复键\")) and dict(p));assert d==t" "$H" $T/ra'
else echo "跳 ⑰（浅克隆取不到 11-11 的提交）"; fi
[ $bad = 0 ] && echo "l10n_merge 单测全过"; exit $bad
