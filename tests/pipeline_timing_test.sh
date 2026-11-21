#!/bin/bash
# 门禁显卡：共享（建 Metal 设备在本机显卡上跑、不按显示时钟判：取共享显卡锁，与按显示时钟判的独占步错开；11-20 读写锁）
# 门禁覆盖：tools/pipeline_timing.m tests/fixtures/pipeline_timing/*
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -mmacosx-version-min=15.0 "$H/tools/pipeline_timing.m" -framework Foundation -framework Metal -o "$T/probe"
xcrun -sdk macosx metal -std=metal3.1 -c "$H/tests/fixtures/pipeline_timing/shader.metal" -o "$T/shader.air"
xcrun -sdk macosx metallib "$T/shader.air" -o "$T/shader.metallib"
"$T/probe" metal3 "$T/shader.metallib" "$H/tests/fixtures/pipeline_timing/cases.json" > "$T/ok.json"
python3 - "$T/ok.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: report = json.load(f)
assert report['backend'] == 'metal3' and report['failures'] == 0
assert [r['name'] for r in report['results']] == ['vertex_id', 'vertex_buffer']
assert all(r['status'] == 'ok' and r['milliseconds'] >= 0 for r in report['results'])
assert report['over_1s'] == [i for i, r in enumerate(report['results']) if r['milliseconds'] > 1000]
assert report['over_5s'] == [i for i, r in enumerate(report['results']) if r['milliseconds'] > 5000]
coverage = report['coverage']
assert {x['name']: x['status'] for x in coverage['vertex']} == {'fixture_vertex': 'covered', 'fixture_attributes': 'covered', 'fixture_unused_vertex': 'uncovered'}
assert {x['name']: x['status'] for x in coverage['fragment']} == {'fixture_fragment': 'covered', 'fixture_unused_fragment': 'uncovered'}
assert coverage['other_stages'] == [{'name': 'fixture_compute', 'function_type': 3}]
assert not coverage['uninspectable'] and not coverage['failed_pairs']
print('Metal 3 管线计时：', [(r['name'], round(r['milliseconds'], 3)) for r in report['results']], 'ms')
PY
python3 - "$H/tests/fixtures/pipeline_timing/cases.json" "$T/bad.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: rows = json.load(f)
rows[1]['fragment'] = 'missing_function'
with open(sys.argv[2], 'w') as f: json.dump(rows, f)
PY
if "$T/probe" metal3 "$T/shader.metallib" "$T/bad.json" > "$T/fail.json"; then echo '缺函数应失败' >&2; exit 1; fi
python3 - "$T/fail.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: report = json.load(f)
assert report['failures'] == 1
assert report['results'][0]['status'] == 'ok' and report['results'][1]['status'] == 'error'
assert '函数不存在' in report['results'][1]['error']
assert {x['name']: x['status'] for x in report['coverage']['vertex']}['fixture_attributes'] == 'failed_only'
assert report['coverage']['failed_pairs'] == [{'index': 1, 'vertex': 'fixture_attributes', 'fragment': 'missing_function'}]
PY
if "$T/probe" metal3 "$T/missing.metallib" "$T/bad.json" > /dev/null 2>&1; then echo '缺 metallib 应失败' >&2; exit 1; fi

python3 - "$H/tests/fixtures/pipeline_timing/cases.json" "$T/unsupported.json" <<'PYTEST'
import json, sys
with open(sys.argv[1]) as f: rows = json.load(f)
rows[0]['depth'] = 'depth32float'
with open(sys.argv[2], 'w') as f: json.dump(rows, f)
PYTEST
if "$T/probe" metal3 "$T/shader.metallib" "$T/unsupported.json" > "$T/unsupported-result.json"; then echo '未知状态应失败' >&2; exit 1; fi
python3 - "$T/unsupported-result.json" <<'PYTEST'
import json, sys
with open(sys.argv[1]) as f: report = json.load(f)
assert report['failures'] == 1 and report['results'][0]['status'] == 'error'
PYTEST
