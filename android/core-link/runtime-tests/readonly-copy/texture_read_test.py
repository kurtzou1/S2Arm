#!/usr/bin/env python3
"""Offline host gate: real Texture/TextureGroup and DmaClass consumers + tracker/readonly-copy, no GPU/device."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]


def run(out):
    dotnet = os.environ.get('DOTNET', shutil.which('dotnet'))
    assert dotnet, '.NET 10 SDK required'
    config = out/'NuGet.Config'
    config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
    build = [dotnet, 'build', str(HERE/'ReadonlyCopy.Tests.csproj'), '--configfile', str(config),
             '--artifacts-path', str(out/'build'), '-p:NuGetAudit=false', '-v:q']
    result = subprocess.run(build, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    (out/'build.log').write_text(result.stdout)
    if result.returncode:
        print(result.stdout)
    result.check_returncode()
    sources = [HERE/'native_fixture.c', REPO/'android/native/runtime/tracking/readonly_copy.c', REPO/'graphics/track/track.c']
    native = [os.environ.get('CC', 'cc'), '-std=gnu11', '-O2', '-fPIC', '-pthread', '-I'+str(REPO/'runtime/include')]
    system = platform.system()
    if system == 'Darwin':
        library = out/'libreadonly_fixture.dylib'
        native += ['-dynamiclib']
        sources += [HERE/'mac_vm_adapter.c']
    elif system == 'Linux':
        library = out/'libreadonly_fixture.so'
        native += ['-shared', '-D_GNU_SOURCE']
        sources += [REPO/('android/native/'+name) for name in [
            'runtime/tracking/platform.c', 'plat_android.c', 'memory.c', 'guest_signal.c', 'tsd.c',
            'runtime/vm/backing.c']]   # readonly_copy.c 在 Linux 下读 plat_backing_sequence（换页世代）；共享库链接不查缺符号，缺了要到加载时才 127
    else:
        raise RuntimeError('texture read host gate requires macOS or Linux')
    native += [str(path) for path in sources]+['-o', str(library)]
    if system == 'Linux':
        native += ['-ldl']
    subprocess.run(native, check=True, cwd=REPO, timeout=60)
    app = out/'build/bin/ReadonlyCopy.Tests/debug/S2A.SpecTest.dll'
    # App-local resolution also works through Homebrew's shell launcher, which can
    # lose DYLD_LIBRARY_PATH when /bin/bash starts under SIP.
    shutil.copy2(library, app.parent/library.name)
    print('TEXTURE_READ_COMPILED: production GPU and native tracker/copy', flush=True)
    results = []
    dma_modes = ['dma-default', 'dma-red', 'dma-green', 'dma-untracked-fallback',
                 'dma-negative', 'dma-missing-provider']
    writeback_modes = ['writable-copy', 'writable-alias', 'writable-missing', 'writable-fallback',
                       'writable-single-copy', 'writable-single-alias', 'writable-single-missing', 'writable-single-fallback']
    writeback_red = ['writable-red', 'writable-single-red']
    for mode in ['caps', 'red', 'neighbor', 'direct', 'partial', 'borrowed', 'borrowed-multi',
                 'multi', 'hole', 'wrong-thread', 'overflow', 'lifecycle-red', 'lifecycle',
                 'readflush', 'readflush-bypass'] + writeback_modes + writeback_red + dma_modes:
        env = os.environ.copy()
        env.pop('S2A_DMA_BORROWED_READ', None)
        env.pop('S2A_WRITEBACK_BORROWED_READ', None)
        if mode == 'dma-red':
            env['S2A_DMA_BORROWED_READ'] = '1'
        if mode in writeback_red:
            env['S2A_WRITEBACK_BORROWED_READ'] = '1'
        result = subprocess.run([dotnet, str(app), mode], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=30, env=env)
        (out/(mode+'.log')).write_text(result.stdout)
        red = mode in {'red', 'lifecycle-red', 'dma-red', 'writable-red', 'writable-single-red', 'readflush-bypass'}
        if mode == 'readflush-bypass':
            passed = (result.returncode != 0 and 'AccessViolation' in result.stdout
                      and 'ENTER readflush bypass' in result.stdout)
        elif mode == 'dma-red':
            passed = (result.returncode == -6 and 'AccessViolation' in result.stdout
                      and 'DmaClass.DmaCopy' in result.stdout and 'ENTER ' in result.stdout)
        elif mode in writeback_red:
            passed = (result.returncode == -6 and 'AccessViolation' in result.stdout
                      and 'PhysicalMemory.GetWritableRegion' in result.stdout
                      and 'ENTER protected actual PhysicalMemory.GetWritableRegion' in result.stdout)
        else:
            passed = (result.returncode == -6 and 'AccessViolation' in result.stdout
                      and 'LayoutConverter.' in result.stdout and 'Texture.SynchronizeFull' in result.stdout
                      and 'ENTER ' in result.stdout) if red else (
                          result.returncode == 0 and 'PASS '+mode+':' in result.stdout
                          and (not (mode.startswith('writable-') and mode.endswith('-fallback')) or
                               result.stdout.count('【红】GPU 回写没有无跟踪读提供者') == 1))
        results.append(dict(case=mode, passed=passed, expected_red=red, exit=result.returncode))
        print(mode, 'PASS' if passed else 'FAIL', result.returncode, flush=True)
        if not passed:
            print(result.stdout[-3000:])
    (out/'results.json').write_text(json.dumps(dict(build=build, native=native, cases=results), indent=2)+'\n')
    assert all(item['passed'] for item in results), 'texture consumers must preserve protected source bytes'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.out:
        args.out.mkdir(parents=True, exist_ok=False)
        run(args.out.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='s2a-texture-read-') as directory:
            run(Path(directory))
