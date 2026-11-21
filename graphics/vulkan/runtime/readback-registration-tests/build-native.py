#!/usr/bin/env python3
# 门禁手动：辅助脚本（构建辅助），用 NDK 与 linux-bionic-arm64 NativeAOT 编出真机联合夹具（--dotnet / --toolchain / --out），产物给真机跑，本身不是单测；Host.csproj 宿主部分已由 tests/vulkan_backend_test.sh 门禁跑
"""Build the standalone Bionic joint fixture locally; never connect to a device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dotnet', type=Path, required=True)
p.add_argument('--toolchain', type=Path, required=True, help='NDK prebuilt bin directory')
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
here = Path(__file__).resolve().parent
repo = here.parents[3]
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
clang = a.toolchain.resolve() / 'aarch64-linux-android34-clang'
commands = [
    [clang, '-O2', '-fPIC', '-fvisibility=hidden', '-ffunction-sections', '-fdata-sections',
     '-shared', '-Wl,--gc-sections,--no-undefined', here/'native_fixture.c', '-ldl', '-o', out/'libepoch_native.so'],
    [clang, '-O2', here/'runner.c', '-ldl', '-o', out/'runner'],
    [a.dotnet.resolve(), 'publish', here/'Native.csproj', '-c', 'Release', '-r', 'linux-bionic-arm64',
     '--configfile', here/'NuGet.Config', '--artifacts-path', out/'managed-artifacts',
     '-p:CppCompilerAndLinker='+str(a.toolchain.resolve()/'clang'),
     '-p:CppLibCreator='+str(a.toolchain.resolve()/'llvm-ar'), '-o', out/'managed'],
]
environment = dict(os.environ, PATH=str(a.toolchain.resolve())+os.pathsep+os.environ.get('PATH',''),
                   DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1')
sources = [here/n for n in ['build-native.py','NuGet.Config','native_fixture.c','runner.c','Native.cs','Native.csproj','Host.csproj','Program.cs']]
sources += [repo/n for n in ['graphics/track/track.c','android/native/runtime/tracking/platform.c',
    'android/native/plat_android.c','compat/tree/src/Ryujinx.Memory/Tracking/MemoryTracking.cs',
    'compat/tree/src/Ryujinx.Memory/Tracking/RegionHandle.cs','compat/tree/src/Ryujinx.Memory/Tracking/VirtualRegion.cs']]
record = {'sources':{str(f.relative_to(repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources}, 'commands':[]}
status = 0
try:
    for i, command in enumerate(commands):
        with (out/f'build-{i}.log').open('w') as log:
            r = subprocess.run([str(x) for x in command], cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        record['commands'].append({'args':[str(x) for x in command], 'exit':r.returncode})
        if r.returncode:
            status=1; break
    if not status:
        record['outputs'] = {str(f.relative_to(out)):hashlib.sha256(f.read_bytes()).hexdigest()
                             for f in [out/'runner',out/'libepoch_native.so',out/'managed/libepoch_managed.so']}
except (OSError, subprocess.TimeoutExpired) as error:
    status = 1
    record['error'] = str(error)
finally:
    record['exit']=status
    (out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'output':str(out),'exit':status,'deviceRun':False}))
raise SystemExit(status)
