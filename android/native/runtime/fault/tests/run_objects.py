#!/usr/bin/env python3
"""Compile the real Android/Bionic owner objects without linking or running an APK."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[5]
FAULT=Path('android/native/runtime/fault')
SOURCES=[Path('runtime/src')/p for p in ('thread.c','crash.c','xstack.c','entry.S','gate.c')]+[FAULT/p for p in ('fault.c','trampoline.S','elf_host.c')]+[Path('android/native')/p for p in ('guest_signal.c','redzone.S')]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def ndk_cc():
    # 与 core-link 同一固定版本解析；门禁不依赖调用者手工传路径。
    sys.path.insert(0,str(ROOT/'android/core-link'));import link_symbols
    ndk=link_symbols.find_ndk();host={'darwin':'darwin-x86_64','linux':'linux-x86_64'}.get(sys.platform.split('-')[0])
    if ndk is None or host is None:raise SystemExit('【红】找不到固定 NDK 29.0.14206865；设 ANDROID_NDK_HOME 或传 --cc')
    cc=ndk/'toolchains/llvm/prebuilt'/host/'bin/aarch64-linux-android34-clang'
    if not cc.is_file():raise SystemExit(f'【红】缺少 {cc}；设 ANDROID_NDK_HOME 或传 --cc')
    return cc
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--cc',type=Path);a=ap.parse_args();out=a.out.resolve();cc=a.cc or ndk_cc()
    if out==ROOT or ROOT in out.parents:ap.error('output must be outside source')
    out.mkdir(parents=True,exist_ok=True)
    inputs=SOURCES+[FAULT/'fault.h',FAULT/'thread_android.inc',Path('runtime/src/native.h'),Path('platform/plat.h'),Path('platform/plat_asm.h')]
    inputs+=sorted(p.relative_to(ROOT) for p in (ROOT/'runtime/include').glob('*.h'))
    hashes={str(p):sha(ROOT/p) for p in inputs};receipt={'kind':'NDK29 Bionic API34 objects only','source_sha256':hashes,'commands':[],'android_executed':False,'baseline_warning_exception':'gate.c has six existing137fa uint64_t/%llx warnings; only format stays warning for this object'}
    def run(command,name):
        p=subprocess.run([str(x) for x in command],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45);(out/(name+'.log')).write_text(p.stdout)
        receipt['commands'].append({'argv':[str(x) for x in command],'exit':p.returncode,'log':name+'.log'});(out/'results.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if p.returncode:raise RuntimeError(name)
    run([cc,'--version'],'compiler')
    for i,p in enumerate(SOURCES):run([cc,*(['-D_GNU_SOURCE'] if p.name in ('crash.c','thread.c') else []),'-I'+str(ROOT/'runtime/include'),'-std=gnu11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-unused-function','-Wno-missing-field-initializers',*(['-Wno-error=format'] if p.name=='gate.c' else []),'-c',ROOT/p,'-o',out/f'{i}-{p.name}.o'],f'compile-{i}')
    receipt['source_unchanged']=hashes=={str(p):sha(ROOT/p) for p in inputs};receipt['pass']=receipt['source_unchanged'];(out/'results.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if not receipt['pass']:raise RuntimeError('source changed')
    print('PASS 10 Bionic owner objects; '+str(out/'results.json'))
if __name__=='__main__':main()
