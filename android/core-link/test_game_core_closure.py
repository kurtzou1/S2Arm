#!/usr/bin/env python3
"""Exercise the production game source list and cpatch provider without a device.

The NDK link is a narrow real-object regression; it does not replace the full
NativeAOT shared-library/APK build or establish Android runtime correctness.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import link_symbols

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'android'


def run(args):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args[0]}\n{result.stderr}")
    return result.stdout


def ndk_bin():
    system = 'darwin-x86_64' if sys.platform == 'darwin' else 'linux-x86_64' if sys.platform.startswith('linux') else None
    if not system:
        raise RuntimeError('NDK host is unsupported; use macOS or Linux with NDK 29.0.14206865')
    # Use the same ordered, version-checked search as Q19: stale direct NDK
    # overrides must not hide a valid SDK or the other direct override.
    ndk = link_symbols.find_ndk()
    if ndk is None:
        names = ('ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'HOME')
        env = ', '.join(f'{name}={os.environ.get(name)!r}' for name in names)
        searched = ', '.join(repr(str(path.absolute())) for path in link_symbols.ndk_candidates())
        sdk = (os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or
               str(Path.home() / ('Library/Android/sdk' if system == 'darwin-x86_64' else 'Android/Sdk')))
        manager = str(Path(sdk) / 'cmdline-tools/latest/bin/sdkmanager')
        command = f'{shlex.quote(manager)} --sdk_root={shlex.quote(sdk)} {shlex.quote("ndk;29.0.14206865")}'
        raise RuntimeError(f'expected Android NDK 29.0.14206865; searched [{searched}]; env [{env}]; install: {command}')
    binary = ndk / 'toolchains/llvm/prebuilt' / system / 'bin'
    for tool in ('aarch64-linux-android29-clang', 'aarch64-linux-android29-clang++', 'ld.lld', 'llvm-nm'):
        if not (binary / tool).is_file():
            raise RuntimeError(f'missing {binary / tool}; install NDK 29.0.14206865 or set ANDROID_NDK_HOME')
    return binary


def main():
    ndk = ndk_bin()
    host_cc = shlex.split(os.environ['CC']) if os.environ.get('CC') else [shutil.which('clang') or shutil.which('cc')]
    if not host_cc or not host_cc[0]:
        raise RuntimeError('missing host C compiler for cpatch default behavior')
    with tempfile.TemporaryDirectory(prefix='s2a-game-link-') as temp:
        temp = Path(temp)
        # Both real bridge modes must compile, including game-only paths.
        # This catches declarations hidden behind the diagnostic preprocessor guard.
        run([sys.executable, ANDROID / 'native/jni_abi.py', '--header', temp / 's2a_jni_abi.h',
             ANDROID / 'app/src/main/java/org/s2arm/android/NativeBridge.java',
             ANDROID / 'app/src/main/java/org/s2arm/android/TouchInputBridge.java'])
        bridge_flags = ['-std=gnu++17', '-DS2A_CS_STATIC=1', '-DVK_USE_PLATFORM_ANDROID_KHR',
                        '-I', temp, '-I', ROOT, '-I', ROOT / 'runtime/src',
                        '-I', ROOT / 'runtime/include', '-I', ANDROID / 'native',
                        # #868：bridge.cpp 引 nvn/nvn_vk_first_draw.h → direct/vk_device.h、vk_record.h → nvn_obj.h …：正式编译里这些目录由
                        #   直连目标（core-link/NvnDirect.cmake s2a_android_direct_core 的 includes）给，这里照抄同一份
                        '-I', ROOT / 'graphics/nvn/gfx/nvn', '-I', ROOT / 'graphics/nvn/gfx/nvn/include', '-I', ROOT / 'graphics/nvn',
                        '-I', ROOT / 'graphics/nvn/host', '-I', ROOT / 'graphics/nvn/gfx/tex', '-I', ANDROID / 'native/nvn',
                        '-I', ANDROID / 'native/nvn/compat', '-I', ANDROID / 'native/direct',
                        '-I', ROOT / 'graphics/track']
        for mode, extra in (('diagnostic', []), ('game', ['-DS2A_ANDROID_GAME_RUNTIME=1'])):
            run([ndk / 'aarch64-linux-android29-clang++', *bridge_flags, *extra, '-c',
                 ANDROID / 'native/bridge.cpp', '-o', temp / (mode + '-bridge.o')])
        print('diagnostic and game bridge: NDK real C++ compilation passed')
        listing = temp / 'sources.txt'
        cmake = temp / 'sources.cmake'
        cmake.write_text(f'include("{ANDROID / "core-link/Runtime.cmake"}")\n'
                         's2a_android_game_sources(SOURCES)\n'
                         f'file(WRITE "{listing}" "${{SOURCES}}")\n')
        run([os.environ.get('CMAKE', 'cmake'), '-P', cmake])
        sources = {Path(x).resolve() for x in listing.read_text().split(';') if x}
        loader = (ROOT / 'runtime/src/loader.c').resolve()
        provider = (ROOT / 'runtime/src/cpatch.c').resolve()
        if loader not in sources:
            raise RuntimeError('production game CMake list lacks runtime/src/loader.c')
        flags = ['-std=gnu11', '-D_GNU_SOURCE', '-DS2A_ANDROID_GAME_RUNTIME=1',
                 '-I', ROOT / 'runtime/include', '-I', ROOT / 'runtime/src',
                 '-I', ROOT, '-I', ANDROID / 'native', '-I', ROOT / 'graphics/track']
        objects = []
        for source in (loader, provider):
            if source not in sources:
                continue
            obj = temp / (source.stem + '.o')
            run([ndk / 'aarch64-linux-android29-clang', *flags, '-c', source, '-o', obj])
            objects.append(obj)
        linked = temp / 'core.o'
        run([ndk / 'ld.lld', '-r', *objects, '-o', linked])
        symbols = run([ndk / 'llvm-nm', '--format=posix', linked]).splitlines()
        # s2a_cpatch_load：目录装载；s2a_cpatch_load_source：APK 起局（#48 D2，loader.c load_modules_from_source 调）
        for name in ('s2a_cpatch_load', 's2a_cpatch_load_source'):
            rows = [x.split() for x in symbols if x.split() and x.split()[0] == name]
            if len(rows) != 1 or rows[0][1] not in ('T', 't'):
                raise RuntimeError(f'game core link has no unique strong {name}: {rows}')
            print(f'game core loader/cpatch: NDK real objects resolve one strong {name}')
        # 开关口径 Apple / Android 相同（#48 D2：不设 S2A_CPATCH_ON 按表缺省开），一份宿主单测覆盖目录与 APK 内存表两条装载路
        exe = temp / 't_cpatch'
        run([*host_cc, '-std=gnu11', '-I', ROOT / 'runtime/include',
             ROOT / 'runtime/tests/t_cpatch.c', ROOT / 'runtime/src/cpatch.c', '-o', exe])
        print(run([exe]).strip())
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f'game core link regression failed: {error}', file=sys.stderr)
        sys.exit(1)
