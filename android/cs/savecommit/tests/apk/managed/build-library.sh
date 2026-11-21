#!/usr/bin/env bash
# 门禁手动：辅助脚本（构建辅助），可选托管探针库构建（要 BUILD_DIR / NDK / DOTNET 环境），本身不是单测
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Optional synthetic managed APP-domain probe. No device commands or installation.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
: "${BUILD_DIR:?Set the same dedicated external BUILD_DIR as apk/build.sh}"
: "${ANDROID_NDK_HOME:?Set installed NDK r29}"
: "${DOTNET:?Set installed official .NET 10 SDK executable}"
case "$BUILD_DIR" in /*) ;; *) echo 'BUILD_DIR must be absolute' >&2; exit 2;; esac
mkdir -p "$BUILD_DIR"; BUILD_DIR=$(cd "$BUILD_DIR" && pwd -P)
case "$BUILD_DIR/" in "$ROOT/"*) echo 'Build outputs must stay outside repository' >&2; exit 2;; esac
PROJECT=$HERE/SaveCommit.AppProbe.csproj
OBJ=$BUILD_DIR/managed/obj
# SDK selection of the NativeAOT runtime pack is publish-only. Preparation uses
# the same SDK publish property but performs Restore only, no compilation.
if [ "${1:-}" = --prepare ]; then
    "$DOTNET" restore "$PROJECT" -r linux-bionic-arm64 -p:_IsPublishing=true \
        -p:SelfContained=true -p:PublishAotUsingRuntimePack=true \
        -p:BaseIntermediateOutputPath="$OBJ/" -p:BaseOutputPath="$BUILD_DIR/managed/bin/" -p:NuGetAudit=false \
        --source https://api.nuget.org/v3/index.json --nologo
    exit 0
fi
case "${1:-}" in '') ;; *) echo 'Usage: build-library.sh [--prepare]' >&2; exit 2;; esac
: "${S2ARM_SOURCE_ID:?Outer build must provide exact source identity}"
grep -Eq '^Pkg.Revision *= *29\.0\.14206865$' "$ANDROID_NDK_HOME/source.properties"
case $(uname -s) in Linux) HOST=linux-x86_64;; Darwin) HOST=darwin-x86_64;; *) exit 2;; esac
N=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST/bin
export PATH="$N:$PATH" DOTNET_PROCESSOR_COUNT=2
mkdir -p "$BUILD_DIR/managed" "$BUILD_DIR/lib/arm64-v8a"
"$N/aarch64-linux-android34-clang" -std=c11 -O2 -g -fPIC -Wall -Wextra -Werror -Wpedantic \
    -c "$ROOT/android/native/s2a_savecommit.c" -o "$BUILD_DIR/managed/production.o"
# No restore here: preparation is explicit and never runs inside an offline gate.
"$DOTNET" publish "$PROJECT" -c Release -r linux-bionic-arm64 --no-restore \
    -p:BaseIntermediateOutputPath="$OBJ/" -p:BaseOutputPath="$BUILD_DIR/managed/bin/" -p:SelfContained=true \
    -p:PublishAotUsingRuntimePack=true -p:DisableUnsupportedError=true \
    -p:SaveCommitNativeObject="$BUILD_DIR/managed/production.o" \
    -o "$BUILD_DIR/managed/publish" --nologo
cp "$BUILD_DIR/managed/publish/libs2a_savecommit_managed.so" "$BUILD_DIR/lib/arm64-v8a/"
"$N/aarch64-linux-android34-clang" -std=c11 -O2 -g -fPIC -shared -Wall -Wextra -Werror -Wpedantic \
    -DS2ARM_SOURCE_COMMIT=\""$S2ARM_SOURCE_ID"\" \
    -DJNI_ENTRY=Java_org_s2arm_probe_savecommit_moongrant_ManagedInstrumentation_nativeRun \
    "$HERE/../native/runner.c" "$HERE/bridge.c" \
    -L"$BUILD_DIR/lib/arm64-v8a" -ls2a_savecommit_managed \
    -Wl,-z,max-page-size=16384 -Wl,-z,defs -Wl,-soname,libmanaged_bridge.so \
    -o "$BUILD_DIR/lib/arm64-v8a/libmanaged_bridge.so"
python3 "$HERE/check-elf.py" "$N/llvm-readelf" "$BUILD_DIR/lib/arm64-v8a" \
    --report "$BUILD_DIR/managed/elf-contract.txt"
"$N/llvm-readelf" -h -d "$BUILD_DIR/lib/arm64-v8a/libs2a_savecommit_managed.so" > "$BUILD_DIR/managed/elf.txt"
"$N/llvm-nm" -D --defined-only "$BUILD_DIR/lib/arm64-v8a/libs2a_savecommit_managed.so" > "$BUILD_DIR/managed/exports.txt"
grep -q 's2a_savecommit_managed_test' "$BUILD_DIR/managed/exports.txt"
# Ship licenses for the actual restored target runtime, not a guessed version.
python3 - "$OBJ/project.assets.json" "$BUILD_DIR" <<'PY'
import json,pathlib,shutil,sys
j=json.load(open(sys.argv[1]));out=pathlib.Path(sys.argv[2]);pkgs=list(j['packageFolders'])
deps=[d for f in j['project']['frameworks'].values() for d in f.get('downloadDependencies',[]) if d['name']=='Microsoft.NETCore.App.Runtime.NativeAOT.linux-bionic-arm64']
if len(deps)!=1: raise SystemExit('Missing exact NativeAOT target runtime identity')
d=deps[0];version=d['version'].strip('[]').split(',')[0]
roots=[pathlib.Path(p)/d['name'].lower()/version for p in pkgs];root=next((p for p in roots if p.is_dir()),None)
if root is None: raise SystemExit('Restored runtime package absent')
licenses=out/'assets/licenses';licenses.mkdir(parents=True,exist_ok=True)
for name in ('LICENSE.TXT','THIRD-PARTY-NOTICES.TXT'):
 shutil.copyfile(root/name,licenses/f'dotnet-runtime-{name}')
(out/'managed/runtime-package.json').write_text(json.dumps({'name':d['name'],'version':version,'source':'https://api.nuget.org/v3/index.json'},indent=2)+'\n')
PY
printf 'Built managed APP-domain libraries; no device execution.\n'
