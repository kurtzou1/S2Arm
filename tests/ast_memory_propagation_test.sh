#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Direct assertions on the production AST optimizer; no GPU or game data.
# 门禁只看：tests/ast_memory_propagation/* tests/ast_memory_propagation_test.sh compat/tree/src/Ryujinx.Graphics.Shader/StructuredIr/AstOptimizer.cs tests/shader_cases/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# Resolve the repository's pinned SDK, not whichever SDK the caller's cwd selects.
cd "$ROOT/compat/tree"
dotnet build "$ROOT/tests/ast_memory_propagation/AstMemoryPropagation.csproj" -c Release \
  --artifacts-path "$OUT/dotnet" -o "$OUT/tool" \
  -p:UseSharedCompilation=false -m:1 -v minimal
dotnet "$OUT/tool/dsh_cmp.dll"
# #1429 验收计数（AstMemoryOrderStats，直连出库汇总行「ast mem order kept」读它）：真 Maxwell 二进制（tests/shader_cases 全部用例，用它的 run.py 编码）
#   过生产翻译器。#1414 实测当时的 75 份用例有 27 份 SPIR-V 变化（均为 storage 读跨写）；「只用一次」按出现次数算后计数口径为 26（见下）。
#   两条专用顺序用例（读后写回、不同地址写）也必须记录保留的读。
python3 -B - "$ROOT/tests/shader_cases" "$OUT/cases" <<'PY'
import json, sys, pathlib
here, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); sys.path.insert(0, str(here)); out.mkdir()
from run import binary
m = []
for i, p in enumerate(sorted(here.glob('*/*.json'))):
    if p.parent.name in ('obj', 'bin'): continue
    c = json.loads(p.read_text()); b = out / f'{i}.bin'; b.write_bytes(binary(c)); m.append({'id': c['id'], 'stage': c['stage'], 'binary': str(b)})
(out / 'manifest.json').write_text(json.dumps(m))
PY
dotnet "$OUT/tool/dsh_cmp.dll" --maxwell "$OUT/cases/manifest.json" > "$OUT/kept.tsv"
python3 -B - "$OUT/cases/manifest.json" "$OUT/kept.tsv" <<'PY'
import json, sys

with open(sys.argv[1]) as manifest:
    cases = json.load(manifest)
with open(sys.argv[2]) as output:
    rows = [line.rstrip('\n').split('\t') for line in output]
expected_ids = {case['id'] for case in cases}
kept = {i: int(n) for i, n in rows}
if len(expected_ids) != len(cases) or len(kept) != len(rows) or kept.keys() != expected_ids:
    sys.exit('FAIL memory-order counter must report each manifest case exactly once')

order_cases = ('integer/zz_load_store_order_known_red', 'integer/zz_load_store_order_different_address')
other = {i: n for i, n in kept.items() if i not in order_cases}
hit = sorted(i for i, n in other.items() if n > 0)
bad = [f'{i} kept {kept.get(i)}' for i in order_cases if not kept.get(i)]
print(f'memory-order kept: cases {len(kept)}, order shapes {[kept.get(i) for i in order_cases]}, other cases with kept>0 {len(hit)}/{len(other)}, other cases kept 0 {len(other) - len(hit)}')
# 26（原 27）：integer/add_imnmx 那个读跨写的定义在同一父节点里出现两次，「只用一次」改按出现次数算后不进传播分支、直接保留，
#   不再经过 #1414 的计数（保留的结果与原先相同；见 AstOptimizer Occurrences）
if len(hit) != 26: bad.append(f'expected 26 cases changed by #1414, counter hit {len(hit)}: {hit}')
if bad: sys.exit('FAIL ' + '; '.join(bad))
print('PASS memory-order counter')
PY
