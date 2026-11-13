#!/bin/bash
# 门禁覆盖：translator/dmsh_xlate_bin/* translator/dmsh_chain.lock translator/dmsh_chain.py translator/dmsh_xlate/* compat/tree/src/Ryujinx.Graphics.Shader/* compat/tree/src/Ryujinx.Common/* compat/tree/src/Spv.Generator/* graphics/widen/shader/* graphics/widen/SpirvCbufUseText.cs tests/dmsh_lock_consistency_test.sh
# 翻译器二进制、锁文件、仓库源码三者一致（合入前层；11-12 v0.3.3 事故：#798 重编了翻译器没刷 translator/dmsh_chain.lock，列车绿着合入，到发版候选核锁才 4/4 不符）。
# 只核与机器无关的三条（dmsh_chain.py --check-tools 还核本机 spirv-cross / metal 版本，换台机器就不同，进不了门禁）：
#   ① 仓库里 4 个翻译器 DLL 的指纹 = 锁文件记的（重编没刷锁 → 红）
#   ② 翻译器 DLL 里嵌的源码指纹（dmsh_xlate.dll --source-sha）= 仓库源码算出的（改了源码没重编 → 红）
#   ③ 锁文件记的 xlate_source = 仓库源码算出的
# 修法：bash translator/dmsh_xlate/publish.sh && python3 translator/dmsh_chain.py --update-lock，同一笔提交。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
command -v dotnet > /dev/null || [ -x "$HOME/.dotnet/dotnet" ] || { echo "缺 dotnet，读不了翻译器嵌的源码指纹（门禁环境未就绪）"; exit 75; }
python3 - "$H" <<'PY'
import os, sys, subprocess, shutil
h = sys.argv[1]; sys.path.insert(0, os.path.join(h, 'translator'))
import dmsh_chain as c
lock = dict(l.rstrip('\n').split('\t', 1) for l in open(c.LOCK) if '\t' in l and not l.startswith('#'))
bad = []
for dll in ('dmsh_xlate.dll', 'Ryujinx.Graphics.Shader.dll', 'Ryujinx.Common.dll', 'S2Arm.Gfx.Widen.Shader.dll'):
    now = c.sha16(os.path.join(c.XLATE_DIR, dll))
    if lock.get(dll) != now: bad.append(f'① {dll}：锁 {lock.get(dll)} / 仓库里的二进制 {now}（重编翻译器后没跑 dmsh_chain.py --update-lock）')
dn = os.environ.get('DOTNET') or (os.path.expanduser('~/.dotnet/dotnet') if os.path.exists(os.path.expanduser('~/.dotnet/dotnet')) else shutil.which('dotnet'))
emb = subprocess.run([dn, os.path.join(c.XLATE_DIR, 'dmsh_xlate.dll'), '--source-sha'], capture_output=True, text=True).stdout.strip()
src = c.xlate_source_sha()
if emb != src: bad.append(f'② 翻译器嵌的源码指纹 {emb or "（读不出）"} / 仓库源码 {src}（改了翻译器源码没重编：bash translator/dmsh_xlate/publish.sh）')
if lock.get('xlate_source') != src: bad.append(f'③ 锁文件 xlate_source {lock.get("xlate_source")} / 仓库源码 {src}')
for b in bad: print('✗ ' + b)
print(('✓ 翻译器二进制 / 锁文件 / 仓库源码一致（4 个 DLL + 源码指纹）') if not bad else f'✗ 翻译链锁不一致 {len(bad)} 处')
sys.exit(1 if bad else 0)
PY
