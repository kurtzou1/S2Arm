#!/usr/bin/env python3
"""共享guest入口的真实消费者顺序与拒绝测试，不替代fault实现或NativeAOT验收。"""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--cc',default='cc');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[3];out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
exe=out/'guest-entry'
# -D_GNU_SOURCE：模拟安卓时 native.h 走 bionic 那支，无条件调 pthread_setname_np；宿主 glibc 只在 _GNU_SOURCE 下才声明它（Linux 门禁上缺它 -Werror 红）
command=[a.cc,'-D__ANDROID__','-D_GNU_SOURCE','-std=gnu11','-Wall','-Wextra','-Werror','-I'+str(root/'runtime/include'),'-I'+str(root/'runtime/src'),str(root/'runtime/src/guest_main.c'),str(pathlib.Path(__file__).with_name('guest_entry_test.c')),'-o',str(exe)]
subprocess.run(command,check=True)
results=[]
for case in ['ready','init-fail','ready-fail']:
    r=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=10)
    expected='初始化失败' if case=='init-fail' else '尚未就绪'
    passed=(r.returncode==0 and 'SDK_ENTRY' in r.stdout) if case=='ready' else (r.returncode==-6 and 'SDK_ENTRY' not in r.stdout and expected in r.stderr)
    results.append(dict(case=case,passed=passed,returncode=r.returncode,stdout=r.stdout,stderr=r.stderr));print(case,'PASS' if passed else 'FAIL')
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
if not all(x['passed'] for x in results):raise SystemExit(1)
