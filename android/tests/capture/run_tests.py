#!/usr/bin/env python3
# 门禁手动：要传参数：显式 JDK17 / SDK36 / NDK29 / .NET10 / 匹配宿主的 Skia 托管与原生库路径，见 android/tests/gate_not_default.tsv；纯像素部分已在 test.sh 门禁
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Existing-tools-only capture regression. Explicit output; no downloads/restores/devices."""
import argparse
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('jdk', 'android-sdk', 'ndk', 'dotnet-root', 'skia-managed', 'skia-native', 'output'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--cxx', default='clang++')
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    android = here.parents[1]
    java = android/'app/src/main/java/org/s2arm/android'
    native = android/'native'
    hle = android.parents[0]/'compat/tree/src/Ryujinx.HLE'
    system = platform.system()
    if system not in ('Darwin', 'Linux'):
        raise RuntimeError('Host JNI regression requires an existing macOS or Linux JDK/C++ toolchain')
    include_os = 'darwin' if system == 'Darwin' else 'linux'
    ndk_host = 'darwin-x86_64' if system == 'Darwin' else 'linux-x86_64'
    ndk_bin = args.ndk/'toolchains/llvm/prebuilt'/ndk_host/'bin'
    candidates = list((args.dotnet_root/'sdk').glob('10.*/Roslyn/bincore/csc.dll'))
    refs = list((args.dotnet_root/'packs/Microsoft.NETCore.App.Ref').glob('10.*/ref/net10.0'))
    if not candidates or not refs:
        raise RuntimeError('Existing .NET10 compiler/reference pack required; not installed by this script')
    key = lambda p: tuple(int(x) for x in p.parts[-4].split('-')[0].split('.'))
    csc = sorted(candidates, key=key)[-1]
    ref = sorted(refs, key=lambda p: tuple(int(x) for x in p.parts[-3].split('-')[0].split('.')))[-1]
    runtime_version = ref.parts[-3]
    commands = []
    def run(name, argv):
        p = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
        commands.append(dict(name=name, args=[str(x) for x in argv], exit=p.returncode,
                             stdout=p.stdout, stderr=p.stderr))
        (out/'commands.json').write_text(json.dumps(commands, indent=2))
        (out/(name+'.log')).write_text(p.stdout+p.stderr)
        print(name, p.returncode, (p.stdout+p.stderr)[-1000:] if p.returncode else p.stdout.strip(), flush=True)
        if p.returncode:
            raise RuntimeError(name+' failed; see '+str(out/(name+'.log')))
    scratch = out/'tmp'
    scratch.mkdir(exist_ok=True)
    os.environ.update(TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch),
        DOTNET_CLI_HOME=str(out/"cli"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1",
        DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE="true")
    run('java-host-compile', [args.jdk/'bin/javac', '--release', '17', '-d', out,
        java/'CapturePixels.java', here/'CapturePixelsTest.java', here/'JvmCaptureCodec.java'])
    run('pixel-contract', [args.jdk/'bin/java', '-XX:-UsePerfData', '-Djava.io.tmpdir='+str(scratch),
        '-cp', out, 'org.s2arm.android.CapturePixelsTest'])
    jar = args.android_sdk/'platforms/android-36/android.jar'
    run('java-android-compile', [args.jdk/'bin/javac', '--release', '17', '-cp', jar, '-d', out/'android',
        java/'CapturePixels.java', java/'CaptureEncoder.java'])
    run('native-android-compile', [ndk_bin/'clang++', '--target=aarch64-linux-android34', '-std=c++17',
        '-Wall', '-Wextra', '-Werror', '-fPIC', '-c', native/'capture_jpeg.cpp', '-o', out/'capture-arm64.o'])
    run('jni-host-build', [args.cxx, '-std=c++17', '-Wall', '-Wextra', '-Werror',
        '-I'+str(args.jdk/'include'), '-I'+str(args.jdk/'include'/include_os), '-I'+str(native),
        native/'capture_jpeg.cpp', here/'capture_jni_test.cpp', '-L'+str(args.jdk/'lib/server'), '-ljvm',
        '-Wl,-rpath,'+str(args.jdk/'lib/server'), '-o', out/'capture-jni-test'])
    run('jni-real-jpeg', [out/'capture-jni-test', out, scratch])
    common = [args.dotnet_root/'dotnet', 'exec', csc, '-noconfig', '-nostdlib+', '-unsafe+', '-target:exe',
        '-langversion:preview', '-nullable:disable', *['-r:'+str(p) for p in sorted(ref.glob('*.dll'))],
        hle/'UI/ScreenshotJpegEncoder.cs', hle/'HOS/Services/Caps/ScreenshotEncoding.cs', here/'ScreenshotEncodingTest.cs']
    for mode in ('default', 'android'):
        app = out/mode
        app.mkdir(exist_ok=True)
        compile_args = [*common, '-out:'+str(app/'test.dll')]
        if mode == 'default':
            shutil.copyfile(args.skia_managed, app/'SkiaSharp.dll')
            compile_args += ['-r:'+str(args.skia_managed), hle/'HOS/Services/Caps/SkiaScreenshotEncoder.cs']
        else:
            compile_args += ['-define:S2A_ANDROID_HOST']
        run('managed-compile-'+mode, compile_args)
        (app/'test.runtimeconfig.json').write_text(json.dumps({'runtimeOptions': {'tfm':'net10.0',
            'framework': {'name':'Microsoft.NETCore.App','version':runtime_version}}}))
        run('managed-run-'+mode, [args.dotnet_root/'dotnet', app/'test.dll', scratch/'capture-reference.jpg', args.skia_native])
    print('Capture host contract regressions passed. Android Bitmap device execution is still untested.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
