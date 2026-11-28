#!/bin/bash
# 门禁覆盖：translator/xlate_affected.tsv translator/xlate_affected_release.py translator/dmsh_chain.py translator/dmsh_xlate/* graphics/tools/direct/dsh/* compat/tree/src/Ryujinx.Graphics.Shader/* compat/tree/src/Ryujinx.Common/* compat/tree/src/Spv.Generator/* graphics/widen/shader/* graphics/widen/SpirvCbufUseText.cs pack/jobs/xlate_affected.py tests/xlate_affected_test.sh
# 翻译器修复清单（translator/xlate_affected.tsv）跟着翻译器走：清单最后一行的翻译器指纹 = 本树翻译器指纹（dmsh_chain.py --xfp）。
#   为什么：启动器按「包出自清单里哪一行之前」算受影响键（pack/jobs/xlate_affected.py），改了翻译器不登记一步，链就断了——之后的修复对这之间出的包一律判不了。
#   改翻译器的那笔提交同笔追加一行 step <改前指纹> <改后指纹> <扫了几款> <说明>（受影响键 translator/xlate_affected_gen.py 出）；发版追加 release <版本> <指纹>。
#   另核：清单每行都认得（xlate_affected.parse），key 行的改后指纹都有对应的 step 行，键是 16 位十六进制。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
command -v dotnet > /dev/null || [ -x "$HOME/.dotnet/dotnet" ] || { echo "缺 dotnet，算不了本树翻译器指纹（门禁环境未就绪）"; exit 75; }
python3 - "$H" <<'PY'
import os, re, subprocess, sys
h = sys.argv[1]; sys.path.insert(0, os.path.join(h, 'pack/jobs'))
import xlate_affected as xa
text = open(os.path.join(h, xa.LIST), encoding='utf-8').read()
bad = []
try:
    rows, keys = xa.parse(text)
except ValueError as e:
    print(f'🔴 xlate_affected：{e}'); sys.exit(1)
steps = {b for k, a, b in rows if k == 'step'}
bad += [f'key 行的改后指纹 {t} 没有对应的 step 行' for t in keys if t not in steps]
bad += [f'键 {k} 不是 16 位十六进制' for t in keys for k in keys[t] if not re.fullmatch(r'[0-9a-f]{16}', k)]
now = subprocess.run([sys.executable, os.path.join(h, 'translator/dmsh_chain.py'), '--xfp'], capture_output=True, text=True).stdout.strip().splitlines()
now = now[-1] if now else ''
last = rows[-1][2] if rows else None
if not now: bad.append('算不出本树翻译器指纹（dmsh_chain.py --xfp）')
elif last != now: bad.append(f'清单最后一行的指纹 {last} ≠ 本树翻译器指纹 {now}：改了翻译器要同笔追加 step {last} {now} <扫了几款> <说明>（受影响键用 translator/xlate_affected_gen.py 出）')
for b in bad: print(f'🔴 xlate_affected：{b}')
if bad: sys.exit(1)
print(f'✓ xlate_affected：{len(rows)} 行（{len(steps)} 步、{sum(len(v) for v in keys.values())} 个键），最后一行 = 本树翻译器指纹 {now}')
PY
