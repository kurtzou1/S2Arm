#!/usr/bin/env bash
# 门禁手动：辅助脚本（构建辅助），按显式 NDK / SDK / JDK / BUILD_DIR 打 savecommit 探针 APK，给 apk/run.sh 真机测试用，本身不是单测
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
: "${ANDROID_NDK_HOME:?Set explicit NDK r29 directory}"
: "${ANDROID_SDK_ROOT:?Set explicit SDK directory with API 36 and build-tools 36.0.0}"
: "${JAVA_HOME:?Set explicit JDK 17 directory}"
: "${BUILD_DIR:?Set a dedicated absolute build directory outside the repository}"
case "$BUILD_DIR" in /*) ;; *) echo 'BUILD_DIR must be absolute' >&2; exit 2;; esac
mkdir -p "$BUILD_DIR"; BUILD_DIR=$(cd "$BUILD_DIR" && pwd -P)
case "$BUILD_DIR/" in "$ROOT/"*) echo 'Build artifacts and signing keys must stay outside the repository' >&2; exit 2;; esac
INCLUDE_MANAGED=${INCLUDE_MANAGED:-0}
case "$INCLUDE_MANAGED" in 0|1) ;; *) echo 'INCLUDE_MANAGED must be 0 or 1' >&2; exit 2;; esac
FD_DIAGNOSTICS=${FD_DIAGNOSTICS:-0}
case "$FD_DIAGNOSTICS" in 0|1) ;; *) echo 'FD_DIAGNOSTICS must be 0 or 1' >&2; exit 2;; esac
grep -Eq '^Pkg.Revision *= *29\.0\.14206865$' "$ANDROID_NDK_HOME/source.properties"
case $(uname -s) in Linux) HOST=linux-x86_64;; Darwin) HOST=darwin-x86_64;; *) echo 'Unsupported NDK host' >&2; exit 2;; esac
N=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST/bin
B=$ANDROID_SDK_ROOT/build-tools/36.0.0
A=$ANDROID_SDK_ROOT/platforms/android-36/android.jar
export PATH="$JAVA_HOME/bin:$PATH"
"$JAVA_HOME/bin/java" -version 2> "$BUILD_DIR/java-version.txt"
grep -Eq 'version "17\.' "$BUILD_DIR/java-version.txt"
for tool in aapt2 d8 apksigner zipalign; do test -x "$B/$tool"; done
test -f "$A"; test -x "$N/aarch64-linux-android34-clang"
"$N/aarch64-linux-android34-clang" --version > "$BUILD_DIR/clang-version.txt"
HEAD=$(git -C "$ROOT" rev-parse HEAD)
DIRTY=$(git -C "$ROOT" status --porcelain -- android/native/s2a_savecommit.c android/native/s2a_savecommit.h android/cs/savecommit android/cs/aot/AndroidSaveCommit.cs android/cs/aot/S2A.Android.Aot.csproj compat/tree/src/Ryujinx.HLE/FileSystem/S2AHostFileSystem.cs)
IDENTITY=$HEAD; if [ -n "$DIRTY" ]; then IDENTITY=$HEAD+dirty; fi
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$BUILD_DIR/lib/arm64-v8a" "$BUILD_DIR/obj"
# Classes live in a fixed allowlist; no stale Activity classes enter the jar.
flags=(-std=c11 -O2 -g -Wall -Wextra -Werror -Wpedantic -fPIC -fvisibility=hidden)
for name in native openread; do
    if [ "$name" = native ]; then
        source=$HERE/../native_host_test.c; entry=Native
        wraps=(fsetxattr fgetxattr mkdirat fsync ioctl write syscall s2a_savecommit_exchange)
    else
        source=$HERE/../open_read_host_test.c; entry=OpenRead
        wraps=(open fstat s2a_savecommit_open_read)
    fi
    "$N/aarch64-linux-android34-clang" "${flags[@]}" -pthread -Dmain=suite_main -c "$source" -o "$BUILD_DIR/obj/$name-test.o"
    "$N/aarch64-linux-android34-clang" "${flags[@]}" -pthread -c "$ROOT/android/native/s2a_savecommit.c" -o "$BUILD_DIR/obj/$name-production.o"
    "$N/aarch64-linux-android34-clang" "${flags[@]}" -DS2ARM_SOURCE_COMMIT=\""$IDENTITY"\" -DJNI_ENTRY=Java_org_s2arm_probe_savecommit_moongrant_${entry}Instrumentation_nativeRun -c "$HERE/native/runner.c" -o "$BUILD_DIR/obj/$name-runner.o"
    objects=("$BUILD_DIR/obj/$name-test.o" "$BUILD_DIR/obj/$name-production.o" "$BUILD_DIR/obj/$name-runner.o")
    if [ "$FD_DIAGNOSTICS" = 1 ]; then
        "$N/aarch64-linux-android34-clang" "${flags[@]}" -pthread -c "$HERE/native/fd_observer.c" -o "$BUILD_DIR/obj/$name-observer.o"
        objects+=("$BUILD_DIR/obj/$name-observer.o"); wraps+=(opendir readdir closedir)
    fi
    links=(); for wrap in "${wraps[@]}"; do links+=("-Wl,--wrap=$wrap"); done
    "$N/aarch64-linux-android34-clang" -shared -pthread -Wl,-Bsymbolic-functions "${links[@]}" "${objects[@]}" -o "$BUILD_DIR/lib/arm64-v8a/lib${name}_suite.so"
done
if [ "$INCLUDE_MANAGED" = 1 ]; then
    S2ARM_SOURCE_ID="$IDENTITY" BUILD_DIR="$BUILD_DIR" bash "$HERE/managed/build-library.sh"
fi
"$JAVA_HOME/bin/javac" -source 8 -target 8 -Xlint:-options -classpath "$A" -d "$BUILD_DIR/classes" "$HERE"/java/org/s2arm/probe/savecommit/moongrant/*.java
classes=(); for name in Probe Native OpenRead; do classes+=(-C "$BUILD_DIR/classes" "org/s2arm/probe/savecommit/moongrant/${name}Instrumentation.class"); done
if [ "$INCLUDE_MANAGED" = 1 ]; then classes+=(-C "$BUILD_DIR/classes" org/s2arm/probe/savecommit/moongrant/ManagedInstrumentation.class); fi
"$JAVA_HOME/bin/jar" cf "$BUILD_DIR/classes.jar" "${classes[@]}"
"$B/d8" --lib "$A" --min-api 34 --output "$BUILD_DIR/dex" "$BUILD_DIR/classes.jar"
MANIFEST=$HERE/AndroidManifest.xml
if [ "$INCLUDE_MANAGED" = 1 ]; then MANIFEST=$HERE/managed/AndroidManifest.xml; fi
"$B/aapt2" link -I "$A" --manifest "$MANIFEST" -o "$BUILD_DIR/resources.apk"
python3 - "$BUILD_DIR" "$INCLUDE_MANAGED" <<'PY'
import pathlib,sys,zipfile,shutil
p=pathlib.Path(sys.argv[1]);shutil.copyfile(p/'resources.apk',p/'unsigned.apk')
with zipfile.ZipFile(p/'unsigned.apk','a') as z:
    z.write(p/'dex/classes.dex','classes.dex',compress_type=zipfile.ZIP_DEFLATED)
    libraries=['libnative_suite.so','libopenread_suite.so']
    if sys.argv[2]=='1': libraries+=['libs2a_savecommit_managed.so','libmanaged_bridge.so']
    for name in libraries:
        z.write(p/f'lib/arm64-v8a/{name}',f'lib/arm64-v8a/{name}',compress_type=zipfile.ZIP_STORED)
    if sys.argv[2]=='1':
        for f in sorted((p/'assets/licenses').glob('dotnet-runtime-*.TXT')):
            z.write(f,str(f.relative_to(p)),compress_type=zipfile.ZIP_DEFLATED)
PY
"$B/zipalign" -P 16 -f 4 "$BUILD_DIR/unsigned.apk" "$BUILD_DIR/aligned.apk"
mkdir -p "$BUILD_DIR/private"; chmod 700 "$BUILD_DIR/private"
KEY=$BUILD_DIR/private/debug.jks
if [ ! -f "$KEY" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEY" -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 36500 -dname 'CN=S2Arm synthetic test, O=S2Arm contributors, C=US' -noprompt
fi
chmod 600 "$KEY"
"$B/apksigner" sign --ks "$KEY" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out "$BUILD_DIR/savecommit-tests.apk" "$BUILD_DIR/aligned.apk"
"$B/apksigner" verify --verbose --print-certs "$BUILD_DIR/savecommit-tests.apk" > "$BUILD_DIR/signature.txt"
"$B/zipalign" -c -P 16 4 "$BUILD_DIR/savecommit-tests.apk"
python3 - "$ROOT" "$HERE" "$BUILD_DIR" "$IDENTITY" "$FD_DIAGNOSTICS" "$INCLUDE_MANAGED" <<'PY'
import hashlib,json,pathlib,sys
root,here,out=map(pathlib.Path,sys.argv[1:4])
paths=[p for p in here.rglob('*') if p.is_file() and p.suffix in ('.c','.h','.cs','.csproj','.java','.xml','.sh','.py') and not {'bin','obj'}.intersection(p.relative_to(here).parts)]
paths += [here.parent/'native_host_test.c',here.parent/'open_read_host_test.c',root/'android/native/s2a_savecommit.c',root/'android/native/s2a_savecommit.h',root/'android/cs/savecommit/AndroidDirectoryTransaction.cs',root/'android/cs/aot/AndroidSaveCommit.cs',root/'compat/tree/src/Ryujinx.HLE/FileSystem/S2AHostFileSystem.cs']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
data={'source_identity':sys.argv[4],'fd_diagnostics':int(sys.argv[5]),'include_managed':int(sys.argv[6]),'apk_sha256':sha(out/'savecommit-tests.apk'),'sources':{str(p.relative_to(root)):sha(p) for p in paths},'status':'BUILT; NOT DEVICE EXECUTED','ndk':'29.0.14206865','jdk':(out/'java-version.txt').read_text(),'clang':(out/'clang-version.txt').read_text()}
if sys.argv[6]=='1': data['managed_runtime']=json.loads((out/'managed/runtime-package.json').read_text())
(out/'build-evidence.json').write_text(json.dumps(data,indent=2)+'\n')
print('APK SHA256',data['apk_sha256'])
PY
printf 'Built %s\nNo installation or device test performed.\n' "$BUILD_DIR/savecommit-tests.apk"
