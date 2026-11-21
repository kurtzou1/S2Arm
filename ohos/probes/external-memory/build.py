# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Offline Windows build only. Never invokes hdc or installs/runs on a device."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--sdk',type=Path,required=True,help='OHOS native SDK directory')
p.add_argument('--validator',type=Path,required=True,help='Existing spirv-val executable; no downloads')
p.add_argument('--out',type=Path,required=True)
a=p.parse_args(); src=Path(__file__).resolve().parent; out=a.out.resolve(); out.mkdir(parents=True,exist_ok=True)
commands=[]
def run(args,label):
 result=subprocess.run([str(x) for x in args],capture_output=True,text=True,errors='replace',timeout=60)
 rec={'command':[str(x) for x in args],'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr}
 commands.append(rec); (out/(label+'.json')).write_text(json.dumps(rec,ensure_ascii=False,indent=2),encoding='utf-8')
 print(label+': rc'+str(result.returncode)); print(result.stdout+result.stderr)
 if result.returncode: raise SystemExit(result.returncode)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
compiler=a.sdk/'llvm/bin/clang++.exe'
run([compiler,'--version'],'compiler-version')
run([sys.executable,src/'make_shader.py','--output-dir',out],'generate-shader')
assert sha(src/'transform_spv.h')==sha(out/'transform_spv.h'),'checked-in header differs from generator'
run([a.validator,'--version'],'validator-version')
run([a.validator,'--target-env','vulkan1.1',out/'transform.spv'],'validate-shader')
run([compiler,'--target=aarch64-linux-ohos','--sysroot='+str(a.sdk/'sysroot'),'-D__OHOS_API__=26',
 '-std=c++17','-O2','-fno-exceptions','-fno-rtti','-Wall','-Wextra','-Werror','-Wno-missing-field-initializers',
 '-static-libstdc++',src/'v0_probe.cpp','-lvulkan','-lnative_buffer','-o',out/'s2a_ohos_v0_probe'],'compile-link')
run([a.sdk/'llvm/bin/llvm-readelf.exe','-h','-d',out/'s2a_ohos_v0_probe'],'inspect-elf')
manifest={'scope':'offline-only; no device execution or zero-copy claim','sdk':str(a.sdk),
 'sdkPackage':json.loads((a.sdk/'oh-uni-package.json').read_text(encoding='utf-8')),
 'commands':commands,'sources':[{'name':p.name,'sha256':sha(p)} for p in sorted(src.iterdir()) if p.is_file()],
 'outputs':[{'name':p.name,'sha256':sha(p),'bytes':p.stat().st_size} for p in [out/'s2a_ohos_v0_probe',out/'transform.spv']],
 'runtimeExecuted':False}
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
