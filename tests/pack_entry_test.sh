#!/bin/bash
# 门禁覆盖：*.sh *.py
# 出包入口同一条流水线（10-26 维护者 / 维护者「出包各种加速手段和最新流程要在 iOS 和 macOS 上都部署好，不要这儿新那旧的」）：
#   ① 玩家 / 正式出包入口最终都经过 pack/refresh.sh（直连优先 + C.3 通用 lazy + 链接版超体积不出等都在这一条里），平台差异只靠 S2A_PACK_PLAT；
#   ② 只服务通用模式的出包阶段（pack/stage_shaders.sh、pack/stages/shaders.sh、pack/stage_direct_gk.sh，11-07 删）没有任何脚本 / 作业再调——
#      10-26 启动器 Mac 打包就是自己逐段调、只出通用全量：侍魂晓预建管线 38 分钟、直连库一个都不出；
#   ③ 进度计划只有直连两种（ipa_dual / build_dual），步骤 id 都存在。静态检查，不出包
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import re, subprocess, sys
h = sys.argv[1]; bad = []
files = subprocess.run(['git', '-C', h, 'ls-files', '*.sh', '*.py'], capture_output=True, text=True).stdout.split()
allow = ('tests/', 'docs/')
call = re.compile(r'(bash|exec|c\.run\(\s*\[)[^#\n]*?(stage_shaders\.sh|stages/shaders\.sh|stage_direct_gk\.sh)')
for f in files:
    if f.startswith(allow): continue
    try: txt = open(f'{h}/{f}', encoding='utf-8', errors='replace').read()
    except OSError: continue
    for n, line in enumerate(txt.splitlines(), 1):
        code = line.split('#', 1)[0]
        if call.search(code): bad.append(f'{f}:{n} 还调已删的通用着色器阶段：{line.strip()[:120]}')
need = {'pack/jobs/build.py': 'pack/refresh.sh', 'pack/ipa.sh': 'refresh.sh', 'pack/oneclick/oneclick.sh': 'refresh.sh', 'pack/jobs/ipa.py': 'pack/oneclick/oneclick.sh'}
for f, s in need.items():
    if s not in open(f'{h}/{f}', encoding='utf-8').read(): bad.append(f'{f} 不经过 {s}')
# 启动器 Mac 打包调 refresh.sh 时必须自带原始包目录与读取工具：不给 S2A_GAME_SRC 就去扫 ~/Downloads（玩家机上弹授权框），
#   不给 S2A_NX_UNPACK 就按源码现编（启动器只带运行时、没有 SDK）——10-26 侍魂晓新流程第一次就停在 aoc
bp = open(f'{h}/pack/jobs/build.py', encoding='utf-8').read()
for k in ('S2A_GAME_SRC', 'S2A_NX_UNPACK', 'S2A_KEYS'):
    if k not in bp: bad.append(f'pack/jobs/build.py 调 refresh.sh 没给 {k}')
sys.path.insert(0, f'{h}/pack/jobs'); import milestones as ms
ids = {m for m, *_ in ms.MILESTONES}
for k, plan in ms.PLANS.items():
    if not set(plan) <= ids: bad.append(f'进度计划 {k} 有不存在的步骤：{set(plan) - ids}')
if set(ms.PLANS) != {'ipa_dual', 'build_dual', 'ipa_downstream'}: bad.append(f'进度计划应只有直连两种加下游方案一种（ipa_downstream，pack/jobs/downstream.py），实有 {sorted(ms.PLANS)}')
for b in bad: print('不通', b)
print(f'pack_entry：扫 {len(files)} 个脚本，{len(bad)} 处不符' if bad else f'pack_entry 单测全过（扫 {len(files)} 个脚本，4 个入口经 refresh.sh，计划 {len(ms.PLANS)} 份）')
sys.exit(1 if bad else 0)
PY
