#!/usr/bin/env python3
# 门禁手动：只能 Linux ARM64（真 thread/crash/fault 联合），见 android/tests/gate_not_default.tsv
"""Real Linux ARM64 thread/crash/fault integration; all mutations use private copies."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[5]
FAULT = Path('android/native/runtime/fault')
SOURCES = [FAULT/'tests/thread_test.c', FAULT/'tests/thread_guest.S', FAULT/'tests/guest_stack.S',
           FAULT/'fault.c', FAULT/'trampoline.S', Path('android/native/guest_signal.c'),
           Path('android/native/redzone.S'), Path('runtime/src/crash.c'), Path('runtime/src/xstack.c'),
           FAULT/'elf_host.c']
def valid_output(status, text, expected_exit=0, contains=None):
    """Both streams must already be merged; a PASS cannot cancel any FAIL."""
    return (status==expected_exit and (not contains or contains in text)
            and (expected_exit!=0 or not re.search(r"\bFAIL\b",text)))

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--cc',default='cc');args=ap.parse_args()
    out=args.out.resolve()
    if out==ROOT or ROOT in out.parents:ap.error('output must be outside checkout')
    if platform.system()!='Linux' or platform.machine() not in ('aarch64','arm64'):ap.error('native Linux ARM64 execution required')
    out.mkdir(parents=True,exist_ok=True)
    files=set(SOURCES+[Path('runtime/src/thread.c'),Path('runtime/src/thread_wait_diag.inc'),Path('runtime/src/native.h'),Path('platform/plat.h'),Path('graphics/track/s2a_track.h'),Path('android/native/guest_signal.h')])
    files.update(p.relative_to(ROOT) for p in (ROOT/'runtime/include').glob('*.h'))
    files.update(p.relative_to(ROOT) for p in (ROOT/FAULT).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    hashes={str(p):sha(ROOT/p) for p in sorted(files)}
    result={'source_sha256':hashes,'commands':[],'android_executed':False,'managed_callback_executed':False,
            'fixture_boundaries':'module PC range, TSD offset, TLR allocator and tracker callback; actual thread/crash/xstack/fault sources + kernel signals'}
    def run(cmd,name,code=0,contains=None,extra_env=None):
        p=subprocess.run([str(x) for x in cmd],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30,env={**os.environ,'S2A_ANDROID_WAIT_PAUSE':'0',**(extra_env or {})})
        (out/(name+'.log')).write_text(p.stdout);ok=valid_output(p.returncode,p.stdout,code,contains)
        result['commands'].append({'argv':[str(x) for x in cmd],'exit':p.returncode,'expected_exit':code,'pass':ok,'log':name+'.log'})
        (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        if not ok:raise RuntimeError(name)
    run([args.cc,'--version'],'compiler')
    def build(root,name):
        objects=[]
        for i,p in enumerate(SOURCES):
            obj=out/f'{name}-{i}.o';objects.append(obj)
            flags=['-D__ANDROID__','-I'+str(root/'runtime/include'),'-std=gnu11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-unused-function','-Wno-unused-variable','-Wno-missing-field-initializers','-Wno-misleading-indentation','-ffunction-sections','-fdata-sections','-pthread']
            if str(p) in ('runtime/src/crash.c','runtime/src/xstack.c'):flags+=['-D_GNU_SOURCE']
            run([args.cc,*flags,'-c',root/p,'-o',obj],f'{name}-compile-{i}')
        exe=out/name;run([args.cc,'-pthread',*objects,'-Wl,--gc-sections','-o',exe],name+'-link');return exe
    exe=build(ROOT,'thread-test')
    for state in ('0','1'):
        for mode in ('','cores','claimed-signal','deadline-scope'):
            run([exe,*([mode] if mode else [])],(mode or 'positive')+'-switch-'+state,
                contains='PASS ',extra_env={'S2A_ANDROID_WAIT_PAUSE':state})
    for mode in ('pause-waits','pause-vm-orders'):
        run([exe,mode],mode+'-positive',contains='PASS ',extra_env={'S2A_ANDROID_WAIT_PAUSE':'1'})
    run([exe,'diag'],'diagnostic-on',contains='Android-branch diagnostic checks',extra_env={'S2A_WAIT_DIAG':'1'})
    variants=[('pause-context-clobbered',Path('runtime/src/thread.c'),'    if (!already) atomic_store(&t->pause, 1);','    if (!already) { t->pmach = 0; atomic_store(&t->pause, 1); }','FAIL rapid resume/pause keeps async context'),
      ('offguest-false-ack',FAULT/'thread_android.inc','thread->exited || thread->vm_wait_safe','thread->exited || atomic_load(&thread->off_guest) || thread->vm_wait_safe','FAIL off_guest is not quiescence'),
      ('host-safepoint-missing',FAULT/'thread_android.inc','    android_vm_barrier(pthread_getspecific(g_keythr));\n}','    /* deliberately omitted host safepoint park */\n}','FAIL host safepoint quiesces'),
      ('wake-barrier-missing',FAULT/'thread_android.inc','    android_vm_barrier_poll(thread, condition!=&g_pause_cv && android_wait_pause_on()\n                           ? android_wait_pause_poll : NULL);\n    glock();','    /* deliberately omitted wait-return barrier */\n    glock();','FAIL woken waiter cannot escape'),
      ('entry-barrier-missing',Path('runtime/src/thread.c'),'    android_vm_barrier(t);\n#endif\n    { char nm','    /* deliberately omitted entry barrier */\n#endif\n    { char nm','FAIL new entry stopped'),
      ('vm-pause-poll-missing',FAULT/'thread_android.inc','? android_wait_pause_poll : NULL','? NULL : NULL',
       'FAIL pause-wait VM-boundary pause acknowledged by target','pause-vm-orders'),
      ('vm-pause-notification-missing',Path('runtime/src/thread.c'),'if (atomic_load(&t->vm_ack)) android_futex_wake(&android_vm_epoch);',
       '/* deliberately omitted futex notification */','FAIL pause-wait VM-boundary pause acknowledged by target','pause-vm-orders')]
    for name,path,before,after,message,*modes in variants:
        private=out/(name+'-source');private.mkdir(exist_ok=False)
        for p in files:(private/p).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/p,private/p)
        text=(private/path).read_text()
        if text.count(before)!=1:raise RuntimeError('mutation target '+name)
        (private/path).write_text(text.replace(before,after));binary=build(private,name)
        run([binary,*modes],name,1,message,extra_env={'S2A_ANDROID_WAIT_PAUSE':'1' if modes else '0'})
    result['source_unchanged']=hashes=={str(p):sha(ROOT/p) for p in sorted(files)}
    result['pass']=result['source_unchanged'] and all(c['pass'] for c in result['commands'])
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    if not result['pass']:raise RuntimeError('source changed')
    print('PASS real thread-owner integration; '+str(out/'results.json'))
if __name__=='__main__':main()
