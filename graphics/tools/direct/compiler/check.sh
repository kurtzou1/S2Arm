#!/usr/bin/env bash
# C2 主机验收：合成 VS/FS/CS 走同一 DirectShaderCompiler（测试工程与 CLI 共编一份）。
# 覆盖：布局/反射/依赖、字节一致、附件变体、缺事实/坏 JSON/限额、四 set 分配、NativeAOT C ABI shim。
# 不建 Vulkan/Metal 设备；真实 GPU 语义属于 C3。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
tests="$repo/graphics/tools/direct/tests/compiler"
cli="$repo/graphics/tools/direct/compiler/cli"
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-direct-c2.XXXXXX")
trap 'rm -rf "$out"' EXIT

echo "== compiler tests =="
(cd "$tests" && dotnet run -c Release) | tee "$out/tests.log"

echo "== CLI request fixtures =="
(cd "$tests" && dotnet run -c Release -- --emit-requests "$out/requests")

echo "== translator closure identity (W2.1) =="
python3 "$repo/graphics/tools/direct/compiler/closure.py" --selftest
dotnet run -c Release --project "$cli" -- identity > "$out/identity-a.json"
dotnet run -c Release --project "$cli" -- identity > "$out/identity-b.json"
cmp "$out/identity-a.json" "$out/identity-b.json"
identity_closure=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["translatorClosure"])' "$out/identity-a.json")
case "$identity_closure" in
    s2a-dc1-*) ;;
    *) echo "identity is not an s2a-dc1 closure: $identity_closure" >&2; exit 1 ;;
esac
# 嵌入值与当前源码必须一致：源码改了没重建时，这里红。
closure_dir="$repo/graphics/tools/direct/compiler/obj/Release/net10.0"
[ -f "$closure_dir/direct-closure-inputs.txt" ] || { echo "closure inputs missing: build the compiler first" >&2; exit 1; }
python3 "$repo/graphics/tools/direct/compiler/closure.py" --root "$repo" \
    --list "$closure_dir/direct-closure-inputs.txt" --check "$closure_dir/DirectBuildIdentity.g.cs"
echo "identity: $identity_closure (CLI, twice identical, embedded == sources)"

echo "== closure input coverage / invalidation (W2.1 v2) =="
grep -q 'S2A.DirectCompiler.csproj' "$closure_dir/direct-closure-inputs.txt" \
    || { echo "closure inputs miss the compiler project file" >&2; exit 1; }
opt_a=$(python3 "$repo/graphics/tools/direct/compiler/closure.py" --root "$repo" \
    --list "$closure_dir/direct-closure-inputs.txt" --print --options "DefineConstants=A")
opt_b=$(python3 "$repo/graphics/tools/direct/compiler/closure.py" --root "$repo" \
    --list "$closure_dir/direct-closure-inputs.txt" --print --options "DefineConstants=B")
[ "$opt_a" != "$opt_b" ] || { echo "build options do not enter the closure identity" >&2; exit 1; }
echo "options invalidation: ok ($opt_a vs $opt_b)"

echo "== closure coverage audit =="
python3 "$repo/graphics/tools/direct/compiler/closure.py" --audit --root "$repo" \
    --project "$repo/graphics/tools/direct/compiler/S2A.DirectCompiler.csproj" \
    --cover "$repo/compat/tree/src/Ryujinx.Graphics.Gpu" \
    --cover "$repo/compat/tree/src/Ryujinx.Graphics.Shader" \
    --cover "$repo/compat/tree/src/Ryujinx.Graphics.GAL" \
    --cover "$repo/compat/tree/src/Ryujinx.Graphics.Texture" \
    --cover "$repo/compat/tree/src/Ryujinx.Graphics.Device" \
    --cover "$repo/compat/tree/src/Ryujinx.Common" \
    --cover "$repo/compat/tree/src/Spv.Generator" \
    --cover "$repo/graphics/tools/direct/compiler" \
    --cover "$repo/graphics/vulkan/cache" \
    --cover "$repo/graphics/widen/shader/SpirvCbufUse.cs"

echo "== enabled profile composition (device caps -> profile) =="
(cd "$tests" && dotnet run -c Release -- --emit-caps "$out/caps")
dotnet run -c Release --project "$cli" -- profile --caps "$out/caps/caps.json" \
    --output "$out/profile-a.json" >/dev/null
dotnet run -c Release --project "$cli" -- profile --caps "$out/caps/caps.json" \
    --output "$out/profile-b.json" >/dev/null
cmp "$out/profile-a.json" "$out/profile-b.json"
if dotnet run -c Release --project "$cli" -- profile --caps "$out/caps/caps.json" \
    --output "$out/profile-a.json" >/dev/null 2>&1; then
    echo "profile CLI overwrote an existing output" >&2; exit 1
fi
python3 - "$out/profile-a.json" "$out/identity-a.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding='utf-8'))
i = json.load(open(sys.argv[2], encoding='utf-8'))
assert p['schema'] == 's2a-direct-profile-v1', p['schema']
assert p['translatorClosure'] == i['translatorClosure'], (p['translatorClosure'], i['translatorClosure'])
assert p['profileHash'].startswith('sha256-') and len(p['profileHash']) == 71, p['profileHash']
assert p['supportLayout']['hash'].startswith('sha256-'), p['supportLayout']
assert p['capabilities']['supportsGeometryShader'] is False
print("profile:", p['profileHash'], p['capabilities']['vendorName'],
      "maxTextures=" + str(p['capabilities']['maximumTexturesPerStage']))
PY
echo "profile CLI: two runs byte-identical ($(wc -c < "$out/profile-a.json") bytes)"

echo "== offline CLI determinism =="
dotnet run -c Release --project "$cli" -- compile --request "$out/requests/graphics.json" --output "$out/first" >/dev/null
dotnet run -c Release --project "$cli" -- compile --request "$out/requests/graphics.json" --output "$out/second" >/dev/null
cmp "$out/first/program.json" "$out/second/program.json"
echo "offline CLI: two runs byte-identical ($(wc -c < "$out/first/program.json") bytes)"

echo "== CLI failure publishes nothing =="
printf '{"broken":' > "$out/bad.json"
if dotnet run -c Release --project "$cli" -- compile --request "$out/bad.json" --output "$out/bad-out" >/dev/null 2>&1; then
    echo "bad request unexpectedly succeeded" >&2; exit 1
fi
[ ! -e "$out/bad-out" ] || { echo "failed compile left output behind" >&2; exit 1; }
echo "offline CLI: bad request rejected, no output directory"

if command -v spirv-val >/dev/null 2>&1; then
    (cd "$tests" && dotnet run -c Release -- --emit-gs "$out/geometry")
    for stage in vs gs fs gs-Points gs-Lines gs-Triangles; do
        spirv-val --target-env vulkan1.1 "$out/geometry/$stage.spv"
    done
    echo "spirv-val: v2 VS/GS/FS and GS input topologies 6/6"
    python3 - "$out/first/program.json" "$out" <<'PY'
import base64, json, subprocess, sys
document = json.load(open(sys.argv[1], encoding='utf-8'))
for stage in document['content']['stages']:
    path = f"{sys.argv[2]}/{stage['stage']}.spv"
    open(path, 'wb').write(base64.b64decode(stage['spirv']))
    subprocess.run(['spirv-val', '--target-env', 'vulkan1.1', path], check=True)
print("spirv-val: vulkan1.1 clean for", ", ".join(s['stage'] for s in document['content']['stages']))
PY
else
    echo "spirv-val: NOT RUN (tool absent); structural SPIR-V checks only"
fi

python3 - "$out/first/program.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
c = d['content']
print("content hash:", d['contentHash'])
print("stages:", ", ".join(s['stage'] for s in c['stages']))
print("bindings:", ", ".join(f"{b['kind']}@{b['set']}:{b['binding']}" for b in c['bindings']))
print("dependencies:", len(c['dependencies']), "support layout:", c['supportLayout']['requiredSize'], "bytes")
PY
echo "direct compiler C2 check: ok"
