# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""按真实宿主运行显式协议夹具；不替代 native ARM64 / Bionic 验收。"""
import argparse,json,os,pathlib,platform,subprocess,re,sys,threading
from concurrent.futures import ThreadPoolExecutor
from run_pause_wait_host import ROOT,adapt,function
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=pathlib.Path,required=True);a=p.parse_args()
if platform.system()=='Linux':
    # 独立标识的 host protocol，不改原生 ARM64 runner 的准入或证据口径。
    raise SystemExit(subprocess.call([sys.executable,str(pathlib.Path(__file__).with_name('run_pause_wait_linux.py')),'--out',str(a.out)]))
if platform.system()!='Darwin' or platform.machine() not in ('arm64','aarch64'):p.error('Darwin ARM64 adapter only')
if ROOT==a.out.resolve() or ROOT in a.out.resolve().parents:p.error('output must be outside checkout')
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TMPDIR=str(out),TMP=str(out),TEMP=str(out),PYTHONDONTWRITEBYTECODE='1',ASAN_OPTIONS='detect_leaks=0',CLANG_MODULE_CACHE_PATH=str(out/'clang'))
rows=[];lock=threading.Lock()
def run(name,cmd,env):
 # 不设单条墙钟超时：编译与运行都按完成事件判，负载高时编译能超 40 秒（11-21 门禁负载 70/18 核假红）；挂死交门禁分组超时兜底
 c=subprocess.run(list(map(str,cmd)),env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(name+'.log')).write_bytes(c.stdout)
 with lock:
  rows.append(dict(name=name,command=list(map(str,cmd)),exit=c.returncode));print(name,c.returncode,flush=True)
  (out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
 if c.returncode==0 and re.search(rb'\bFAIL\b',c.stdout):raise RuntimeError(name+' exit0 with FAIL in merged output')
 return c

def build(name,mutation=None,asan=False):
 root=out/name;root.mkdir(exist_ok=True);tree=adapt(ROOT,root)
 if mutation:
  file,before,after=mutation;q=tree/file;t=q.read_text();assert t.count(before)==1,(name,t.count(before));q.write_text(t.replace(before,after))
 exe=root/'test';flags=['-fsanitize=address','-fno-omit-frame-pointer'] if asan else []
 c=run(name+'-compile',['/usr/bin/clang','-O1','-g','-Wall','-Wextra','-Wno-unused-parameter','-Wno-unused-function','-I'+str(tree/'runtime/include'),*flags,tree/'test.c','-o',exe],env)
 assert c.returncode==0,c.stdout.decode();return exe,tree
exe,tree=build('actual');disabled=dict(env);disabled.pop('S2A_ANDROID_WAIT_PAUSE',None)
c=run('default-off',[exe],disabled);text=c.stdout.decode()
# 缺省（候选关）：阻塞在系统调用里的目标由暂停方持 G 当场代发 ack（pwait，丝之歌 Unity GC 挂起阻塞线程修复；原先等目标自己 ack，2 秒超时回 0xea01）。
#   5 种无限等待都立即暂停成功；不满足的只有候选实现独有的两条（暂停发条件通知、目标停进原生 park），各 5 次，别的检查全过
values=re.findall(r'^pause-wait mode=\d result=(\S+) elapsed_ns=(\d+)$',text,re.M)
# 只按结果判：旧路径（等目标自己 ack）超时回 0xea01，result==0 已能区分，不再加 0.5 秒墙钟上限
assert len(values)==5 and all(r=='0' for r,ns in values),values
fails=sorted(set(re.findall(r'^FAIL pause-wait (.+)$',text,re.M)))
assert c.returncode==1 and fails==['pause sends actual condition notification','target entered real native park'],fails
assert text.count('FAIL pause-wait pause sends actual condition notification')==5 and text.count('FAIL pause-wait target entered real native park')==5
candidate=dict(env,S2A_ANDROID_WAIT_PAUSE='1')
c=run('candidate',[exe],candidate);assert c.returncode==0 and b'FAIL' not in c.stdout and re.search(r'PASS pause-waits checks=\d+ failures=0',c.stdout.decode())
assert run('deadline-scope',[exe,'scope'],candidate).returncode==0
assert run('watchdog',[exe,'watchdog'],candidate).returncode==0
exe,_=build('asan',asan=True);assert run('asan',[exe],candidate).returncode==0
assert run('asan-deadline-scope',[exe,'scope'],candidate).returncode==0
# 变异反证（下面 8 条链）互相独立：各在自己的 out/<名>/ 下改源、编、跑，只核「必须红」的那一行。并行跑（11-14 门禁提速：原先 40 秒全串行，
#   其中 no-boundary 一条等原生超时就占 20 秒）；上面对时长敏感的正向检查已串行跑完，不和它们抢核。任一条断言失败照样整体失败
def retry_deadline_changed():
 # 同一真实等待重试改 1ns 必须失败，不能靠仅时长。
 retry=('android/native/runtime/fault/tests/pause_wait_test.inc',
        '    pw_wait_probe(cv,d); return pthread_cond_timedwait(cv,mu,d);',
        '    struct timespec changed; if(pw_operation && pw_has_deadline && cv==&pw_operation_thread->cv) { changed=*d;changed.tv_nsec+=1; if(changed.tv_nsec==1000000000){++changed.tv_sec;changed.tv_nsec=0;}d=&changed;}\n'
        '    pw_wait_probe(cv,d); return pthread_cond_timedwait(cv,mu,d);')
 exe,_=build('retry-deadline-changed',retry)
 c=run('retry-deadline-changed',[exe,'scope'],candidate)
 assert c.returncode==1 and c.stdout.count(b'FAIL pause-wait original absolute deadline is unchanged')>=4
def missing_operation_reset():
 exe,_=build('missing-operation-reset',('android/native/runtime/fault/tests/pause_wait_test.inc',
        'pw_operation_thread=NULL;pw_operation=0;pw_has_deadline=0;',
        'pw_operation_thread=NULL;pw_operation=0;'))
 # 删除 begin reset 和 end reset：同 pthread 的新操作必须真实报 deadline 不同。
 q=out/'missing-operation-reset/adapter/android/native/runtime/fault/tests/pause_wait_test.inc'
 q.write_text(q.read_text().replace('    pw_has_deadline=0;','    /* deliberately retain previous operation */',1))
 cc=['/usr/bin/clang','-O1','-g','-Wno-unused-function','-I'+str(q.parents[5]/'runtime/include'),
     str(out/'missing-operation-reset/adapter/test.c'),'-o',str(exe)]
 assert run('missing-operation-reset-recompile',cc,env).returncode==0
 c=run('missing-operation-reset',[exe,'scope'],candidate)
 assert c.returncode==1 and b'FAIL pause-wait original absolute deadline is unchanged' in c.stdout
def verdict_propagation():
 # 实际 C finalizer 聚合相同原模式名；注入活跃探针失败而底层 status=0。
 exe,final_tree=build('verdict-propagation')
 q=final_tree/'test.c';text=q.read_text()
 text=text.replace('int result=pause_wait_suite(); s2a_wait_diag_report(); return pw_finish("pause-waits",result,0);',
     'pw_check(0,"injected active probe");return pw_finish(argc>1?argv[1]:"noarg",0,4096);')
 q.write_text(text)
 assert run('verdict-recompile',['/usr/bin/clang','-O1','-g','-Wno-unused-function','-I'+str(final_tree/'runtime/include'),final_tree/'test.c','-o',exe],env).returncode==0
 for mode in ['noarg','cores','claimed-signal']:
  c=run('verdict-'+mode,[exe,mode],candidate)
  assert c.returncode==1 and b'FAIL pause-wait injected active probe' in c.stdout
  assert b'FAIL thread-mode mode='+mode.encode() in c.stdout
source=(tree/'runtime/src/thread.c').read_text()
mutations={
 'lost-result':('runtime/src/thread.c','    thread->vm_wait_safe=0;\n    atomic_store(&thread->paused_ack,0);','    thread->wres=R_TIMEOUT;\n    thread->vm_wait_safe=0;\n    atomic_store(&thread->paused_ack,0);'),
 'no-boundary':('runtime/src/thread.c',function(source,'static void android_wait_pause_locked('),'static void android_wait_pause_locked(thr_t *thread) { (void)thread; }'),
 'no-barrier':('runtime/src/thread.c','    android_vm_barrier_poll(thread, condition!=&g_pause_cv && android_wait_pause_on()\n                           ? android_wait_pause_poll : NULL);\n    glock();','    /* 故意删除返回 barrier */\n    glock();'),
 'no-wake':('runtime/src/thread.c','if (!already && android_wait_pause_on() && t->vm_wait_safe) pthread_cond_signal(&t->cv);','if (!already && android_wait_pause_on() && t->vm_wait_safe) (void)0;')}
def mutant(name):
 exe,_=build(name,mutations[name]);c=run(name,[exe],candidate)
 expected={'no-boundary':'infinite native wait acknowledges','no-barrier':'resumed waiter cannot escape VM epoch','lost-result':'original wait Result preserved','no-wake':'pause sends actual condition notification'}[name]
 assert c.returncode==1 and expected in c.stdout.decode()
def no_pins():
 # Android pins 分支已由 adapter 显式选择；删 pins 后由 ASan 核真释放对象。
 exe,_=build('no-pins',('runtime/src/thread.c','    if (t->pins) return;','    /* 故意去掉 pins 保留 */'),asan=True)
 c=run('no-pins',[exe],candidate);assert c.returncode!=0 and 'heap-use-after-free' in c.stdout.decode()
# 最长的 no-boundary 先起；4 路足够（其余 7 条合计约 15 秒）
chains=[lambda:mutant('no-boundary'),lambda:mutant('no-wake'),missing_operation_reset,verdict_propagation,no_pins,
        retry_deadline_changed,lambda:mutant('lost-result'),lambda:mutant('no-barrier')]
with ThreadPoolExecutor(max_workers=4) as pool:
 for f in [pool.submit(x) for x in chains]:f.result()
print('PASS expanded real protocol, default-off proxy-ack,ASan,5 rejected mutations; Bionic unexecuted')
