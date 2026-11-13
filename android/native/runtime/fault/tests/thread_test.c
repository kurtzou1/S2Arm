// Actual thread owner, census and signal path. Only module/TSD/track providers
// are fixture-specific; this is not a second scheduler or fake quiesce.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef S2A_UNIT_TEST
#define S2A_UNIT_TEST
#endif
#include <pthread.h>
static int pw_pthread_cond_signal(pthread_cond_t *);
static int pw_pthread_mutex_lock(pthread_mutex_t *);
static int pw_pthread_cond_wait(pthread_cond_t *,pthread_mutex_t *);
static int pw_pthread_cond_timedwait(pthread_cond_t *,pthread_mutex_t *,const struct timespec *);
#define pthread_mutex_lock pw_pthread_mutex_lock
#define pthread_cond_signal pw_pthread_cond_signal
#define pthread_cond_wait pw_pthread_cond_wait
#define pthread_cond_timedwait pw_pthread_cond_timedwait
#include "../../../../../runtime/src/thread.c"
#undef pthread_mutex_lock
#undef pthread_cond_signal
#undef pthread_cond_wait
#undef pthread_cond_timedwait

#include "../../../guest_signal.h"
#include <sys/mman.h>

// 仅本隔离夹具的宿主端点；真实线程/诊断/条件等待/信号实现不替换。
// 本夹具不执行 CreateThread 的游戏入口，不把这些桩编入生产宿主。
int s2a_android_runtime_enter_guest_thread(void){return 0;}
void sw_thread_enter(uint64_t entry,uint64_t arg,uint64_t sp){(void)entry;(void)arg;(void)sp;abort();}
void s2a_cs_handle_closed(uint32_t kind,uint64_t cookie){(void)kind;(void)cookie;}
void s2a_host_write_hook(uint64_t address,uint64_t length){(void)address;(void)length;}
void s2a_low_holes(uint64_t *total,uint64_t *largest){*total=0;*largest=0;}
void *s2a_tail_map(uint64_t len,int user,int prot){(void)len;(void)user;(void)prot;return NULL;}
void s2a_tail_unmap(void *address,uint64_t len,int user){(void)address;(void)len;(void)user;}
void (*s2a_test_cv_after_release)(void);

void s2a_crash_install(void);
extern void s2a_fault_test_guest_stack(void (*)(void),void *), s2a_thread_test_loop(void *);
extern void s2a_thread_test_fault(void *);
extern char s2a_thread_test_guest_start[],s2a_thread_test_guest_end[];
static int checks;
__attribute__((weak)) void s2a_android_redlog_write(const char *line, size_t n) { (void)line; (void)n; }   // guest_signal.c 的红行落盘出口：run_thread.py 的构建不链 redlog.c，这里给桩；暂停等待那套构建（build_pause_wait_android.py）链 redlog.c，弱符号让位给真的
static void check(int yes,const char *name){++checks;if(!yes){fprintf(stderr,"FAIL %s\n",name);exit(1);}}
uint64_t plat_now_ns(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return(uint64_t)ts.tv_sec*1000000000ull+ts.tv_nsec;}
uint64_t now_ns(void){return plat_now_ns();}
int plat_fault_install(int signal,void(*handler)(int,siginfo_t*,void*),unsigned flags){struct sigaction a={0};a.sa_sigaction=handler;a.sa_flags=SA_SIGINFO|(flags&PLAT_FAULT_ONSTACK?SA_ONSTACK:0);sigemptyset(&a.sa_mask);return sigaction(signal,&a,NULL)?errno:0;}
pthread_key_t g_key18,g_keytls,g_keytlr,g_keygate;
void sw_gate(void){abort();}
uint64_t plat_tsd_base(void){return 0;}
void *s2a_tlr_alloc(void){return calloc(1,4096);}
void s2a_tlr_free(void *p){free(p);}
uint32_t s2a_mem_tmem_borrow(uint64_t a,uint64_t n,uint32_t p){(void)a;(void)n;(void)p;return 0;}
void s2a_mem_tmem_unborrow(uint64_t a,uint64_t n){(void)a;(void)n;}
void s2a_mem_tmem_close(uint64_t a,uint64_t n){(void)a;(void)n;}
void s2a_mem_codemem_free(void *o){free(o);}
void s2a_cs_thread_exit(uint32_t t){(void)t;}
int s2a_svc_stopping(void){return 0;}
int plat_tsd_init(void){return 0;}
int plat_tsd_offset(uint32_t key,uint64_t *offset){*offset=(uint64_t)key*8;return 0;}
int plat_thread_stack_bounds(uintptr_t *lo,uintptr_t *hi){pthread_attr_t a;void*p;size_t n;int e=pthread_getattr_np(pthread_self(),&a);if(e)return e;e=pthread_attr_getstack(&a,&p,&n);pthread_attr_destroy(&a);*lo=(uintptr_t)p;*hi=*lo+n;return e;}
module_t *module_of(const void *pc){static module_t m; m.base=(void*)s2a_thread_test_guest_start; m.patch_off=s2a_thread_test_guest_end-s2a_thread_test_guest_start; uintptr_t p=(uintptr_t)pc;return p>=(uintptr_t)s2a_thread_test_guest_start&&p<(uintptr_t)s2a_thread_test_guest_end?&m:NULL;}
int s2a_direct_fault(void*a,int w,void*c){(void)a;(void)w;(void)c;return 0;}
struct job{_Atomic uint64_t count,stop;_Atomic int phase,release,touch_active;int mode;thr_t*thread;void *page;size_t page_size;};
static _Thread_local struct job *job;
int s2a_track_fault_guest(void*a,int w,uint64_t skip){return job&&a==job->page&&w&&!skip?2:0;}
int s2a_track_fault(void*a,int w){(void)a;(void)w;return 0;}
void s2a_track_touch(uint64_t a){
    if(!job||a!=(uintptr_t)job->page)_exit(120);
    stack_t ss;sigaltstack(NULL,&ss);if(ss.ss_flags&SS_ONSTACK)_exit(121);
    if(s2a_android_guest_writers_begin()!=EDEADLK)_exit(122);
    atomic_store(&job->touch_active,1);atomic_store(&job->phase,2);
    while(!atomic_load(&job->release))usleep(100);
    if(mprotect(job->page,job->page_size,PROT_READ|PROT_WRITE))_exit(123);
    atomic_store(&job->touch_active,0);
}
static void guest_body(void){if(job->mode==4){s2a_thread_test_fault(job->page);atomic_store(&job->phase,3);}s2a_thread_test_loop(job);}
static void *worker(void *arg){job=arg;thr_t*t=calloc(1,sizeof*t);job->thread=t;t->pt=pthread_self();t->started=1;atomic_store(&t->in_svc,1);t->prio=44;t->mask=7;pthread_cond_init(&t->cv,NULL);glock();t->all=g_all;g_all=t;pthread_mutex_unlock(&G);
    thread_bind_host(t); // real entry barrier, TSD + guest TLS initialization
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0)-0x400)&~15ull,0);if(s2a_android_fault_probe())_exit(111);atomic_store(&job->phase,1);
    if(job->mode==1){atomic_store(&t->off_guest,1);while(!atomic_load(&job->release))usleep(100);s2a_core_enter();}
    else if(job->mode==2){glock();while(!atomic_load(&job->release))thread_condition_wait(t,&t->cv,NULL);pthread_mutex_unlock(&G);atomic_store(&job->phase,3);}
    else if(job->mode==6){while(!atomic_load(&job->release)){s2a_android_guest_host_safepoint();atomic_fetch_add(&job->count,1);}} // 宿主侧长工作：每圈过一次自愿安全点
    else if(job->mode==5){while(!atomic_load(&job->release))usleep(100);glock();t->closed=1;pthread_mutex_unlock(&G);thread_exit(t);}
    else if(job->mode==3){glock();atomic_store(&job->phase,2);while(!atomic_load(&job->release))usleep(100);pthread_mutex_unlock(&G);android_vm_barrier(t);}
    if(job->mode==4){job->page_size=(size_t)sysconf(_SC_PAGESIZE);job->page=mmap(NULL,job->page_size,PROT_READ,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);}
    svc_exit(t);atomic_store(&job->phase,3);size_t n=1<<20;void*stack=mmap(NULL,n,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);s2a_fault_test_guest_stack(guest_body,(char*)stack+n);munmap(stack,n);if(job->page)munmap(job->page,job->page_size);
    core_release(t);s2a_tlr_free(t->tlr);t->tlr=NULL;s2a_android_fault_thread_fini();sw_xstack_thread_fini();s2a_android_altstack_free();glock();t->exited=1;t->closed=1;pthread_setspecific(g_keythr,NULL);thr_free(t);pthread_mutex_unlock(&G);atomic_store(&job->phase,4);return NULL;}
static void until(_Atomic int*s,int want){uint64_t end=plat_now_ns()+3000000000ull;while(atomic_load(s)!=want){if(plat_now_ns()>end){fprintf(stderr,"timeout phase %d expected %d\n",atomic_load(s),want);exit(1);}usleep(100);}}
static pthread_t start(struct job*j,int mode){memset(j,0,sizeof*j);j->mode=mode;pthread_t p;check(!pthread_create(&p,NULL,worker,j),"create worker");until(&j->phase,mode==3||mode==4?2:mode?1:3);return p;}
static void stop(struct job*j,pthread_t p){atomic_store(&j->stop,1);check(!pthread_join(p,NULL),"worker joins");}
static void *release_later(void*a){struct job*j=a;usleep(50000);atomic_store(&j->release,1);return NULL;}
// 收局进度的名册快照：epoch 进行中、名册锁空出来的那一拍读到（最多重试 30 ms）
static char described[512];
static void *describe_later(void*a){(void)a;usleep(15000);for(int i=0;i<150;i++){s2a_android_guest_writers_describe(described,sizeof described);if(!strstr(described,"名册锁被占用"))break;usleep(200);}return NULL;}
static void claimed_handler(int s){(void)s;}
static int pw_epoch_parked(thr_t *t) {unsigned e=atomic_load(&android_vm_epoch);return e && atomic_load(&t->vm_ack)==e;}
static int pw_epoch_begin(void) { return s2a_android_guest_writers_begin(); }
static void pw_epoch_end(void) { s2a_android_guest_writers_end(); }
#include "pause_wait_test.inc"
// 通过真实 SVC32 和原生条件等待观察请求生命周期；不带暂停修复。
struct diag_job {
    _Atomic int ready, run, stop, ordinary;
    thr_t *thread;
    uint32_t event;
};
static void diag_until(_Atomic int *state, int value) {
    uint64_t end=plat_now_ns()+3000000000ull;
    while(atomic_load(state)!=value && plat_now_ns()<end) usleep(100);
    check(atomic_load(state)==value,"diagnostic worker bounded handshake");
}
static void *diag_worker(void *arg) {
    struct diag_job *d=arg;
    s2a_thread_main_init();
    d->thread=cur();
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0)-0x400)&~15ull,0);
    check(!s2a_android_fault_probe(),"diagnostic worker fault probe");
    atomic_store(&d->ready,1);
    uint64_t r[31]={0,(uintptr_t)&d->event,1,(uint64_t)-1};
    svc_thread(0x18,r);
    check(!r[0],"diagnostic infinite waiter released by event");
    atomic_store(&d->run,1);
    while(!atomic_load(&d->stop)) {
        if(atomic_load(&d->ordinary)==1) {
            atomic_store(&d->ordinary,0);
            glock();
            for(int i=0;i<4;i++) {
                struct timespec dl;
                clock_gettime(CLOCK_REALTIME,&dl);
                dl.tv_nsec+=1000000;
                if(dl.tv_nsec>=1000000000){dl.tv_sec++;dl.tv_nsec-=1000000000;}
                check(thread_condition_wait(d->thread,&d->thread->cv,&dl)==ETIMEDOUT,
                      "ordinary diagnostic wait actually times out");
            }
            pthread_mutex_unlock(&G);
            atomic_store(&d->ordinary,2);
        }
        uint64_t sleep[31]={0};
        svc_thread(0x0b,sleep);
    }
    core_release(d->thread);
    s2a_tlr_free(d->thread->tlr);d->thread->tlr=NULL;
    s2a_android_fault_thread_fini();sw_xstack_thread_fini();s2a_android_altstack_free();
    glock();
    thr_t *t=d->thread;
    for(thr_t **q=&g_all;*q;q=&(*q)->all) if(*q==t){*q=t->all;break;}
    h_free(h_idx(t->handle));
    pthread_setspecific(g_keythr,NULL);
    pthread_mutex_unlock(&G);
    pthread_cond_destroy(&t->cv);free(t);
    return NULL;
}
static void diag_no_old_request(size_t from,uint64_t request) {
    glock();
    for(size_t i=from;i<g_wd_used;i++)
        check(!((g_wd[i].event==11||g_wd[i].event==14)&&g_wd[i].request==request),
              "completed request cannot own later park or condition");
    pthread_mutex_unlock(&G);
}
static int diag_mode(void) {
    check(wait_diag_on(),"diagnostic mode explicitly enabled");
    s2a_thread_main_init();thr_t *caller=cur();
    uint32_t read,write;uint64_t event=s2a_event_create(&read,&write);
    struct diag_job d={.event=read};pthread_t worker_thread;
    check(!pthread_create(&worker_thread,NULL,diag_worker,&d),"diagnostic worker create");
    diag_until(&d.ready,1);
    uint64_t end=plat_now_ns()+3000000000ull;
    int blocked=0;
    do {glock();blocked=d.thread->wkind==4&&d.thread->vm_wait_safe;pthread_mutex_unlock(&G);
        if(!blocked)usleep(100);
    } while(!blocked&&plat_now_ns()<end);
    check(blocked,"diagnostic target really blocked in infinite SVC18");
    uint64_t caller_id=caller->id,target_id=d.thread->id;
    uint64_t r[31]={d.thread->handle,1};uint64_t begin=plat_now_ns();
    svc_thread(0x32,r);
    check(r[0]==R_TIMEOUT&&plat_now_ns()-begin>=1900000000ull,
          "diagnostic observes original two-second EA01");
    glock();
    uint64_t request=g_pd_request;
    check(!d.thread->trace_pause&&!d.thread->trace_pause_conditions,
          "timeout invalidates diagnostic request");
    int ev9=0,ev10=0,ev12=0,ev13=0;unsigned seen=0,native=0;
    for(size_t i=0;i<g_wd_used;i++) {
        wait_diag_record_t *v=&g_wd[i];
        if(v->request!=request)continue;
        if(v->event==9){ev9++;check(v->source_tid==caller_id&&v->object==target_id,
                                  "SVC32 begin caller and target pair");}
        if(v->event==10){ev10++;check(v->deadline_mono>v->mono,"pause has actual deadline");
            seen=v->signal_seen;native=v->signal_native;}
        if(v->event==12){ev12++;check(v->result==R_TIMEOUT,"pause end retains R_TIMEOUT");
            check(v->signal_seen>=seen&&v->signal_native>=native,"signal counters monotonic");}
        if(v->event==13){ev13++;check(v->source_tid==caller_id&&v->object==target_id&&v->result==R_TIMEOUT,
                                    "SVC32 final request caller target EA01 pair");}
    }
    check(ev9==1&&ev10==1&&ev12==1&&ev13==1,"SVC32 diagnostic records complete");
    size_t after_timeout=g_wd_used;
    uint64_t suppressed=g_wd_pause_cond_suppressed;
    pthread_mutex_unlock(&G);
    s2a_event_signal(event);diag_until(&d.run,1);
    atomic_store(&d.ordinary,1);diag_until(&d.ordinary,2);
    diag_no_old_request(after_timeout,request);
    glock();check(g_wd_pause_cond_suppressed==suppressed,"suppressed stable after timeout");
    pthread_mutex_unlock(&G);
    r[0]=d.thread->handle;r[1]=1;svc_thread(0x32,r);
    check(!r[0],"diagnostic second pause acknowledges at actual SVC boundary");
    glock();uint64_t second=d.thread->trace_pause;
    check(second>request,"new pause has new request");
    pthread_mutex_unlock(&G);
    // 唤醒真实 pause_park 的 pthread 等待，目标仍在有效 pause 内重新等待。
    for(int i=0;i<4;i++) {
        glock();unsigned previous=d.thread->trace_pause_conditions;
        pthread_cond_broadcast(&g_pause_cv);pthread_mutex_unlock(&G);
        end=plat_now_ns()+3000000000ull;int returned=0;
        do {glock();returned=d.thread->trace_pause_conditions>previous;pthread_mutex_unlock(&G);
            if(!returned)usleep(100);
        } while(!returned&&plat_now_ns()<end);
        check(returned,"actual pause condition return observed");
    }
    glock();check(g_wd_pause_cond_suppressed>suppressed,"suppressed grows during valid request");
    pthread_mutex_unlock(&G);
    r[0]=d.thread->handle;r[1]=0;svc_thread(0x32,r);check(!r[0],"diagnostic unpause succeeds");
    glock();check(!d.thread->trace_pause&&!d.thread->trace_pause_conditions,
                  "unpause invalidates diagnostic request");
    size_t after_unpause=g_wd_used;suppressed=g_wd_pause_cond_suppressed;
    pthread_mutex_unlock(&G);
    atomic_store(&d.ordinary,1);diag_until(&d.ordinary,2);
    s2a_guest_freeze(1);
    end=plat_now_ns()+3000000000ull;
    while(!atomic_load_explicit(&d.thread->paused_ack,memory_order_acquire)&&plat_now_ns()<end)usleep(100);
    check(atomic_load_explicit(&d.thread->paused_ack,memory_order_acquire),"actual later g_frz boundary reached");
    s2a_guest_freeze(0);
    diag_no_old_request(after_unpause,second);
    glock();check(g_wd_pause_cond_suppressed==suppressed,"suppressed stable after unpause");
    pthread_mutex_unlock(&G);
    atomic_store(&d.stop,1);check(!pthread_join(worker_thread,NULL),"diagnostic worker joins");
    s2a_wait_diag_report();
    uint64_t c[31]={read};svc_thread(0x16,c);c[0]=write;svc_thread(0x16,c);s2a_event_release(event);
    printf("PASS %d Android-branch diagnostic checks; original EA01 retained\n",checks);
    return 0;
}

static int thread_modes(int argc,char**argv){setenv("S2A_CORES",argc>1&&!strcmp(argv[1],"cores")?"1":"0",1);
    if(argc>1&&!strcmp(argv[1],"claimed-signal")){signal(SIGURG,claimed_handler);check(s2a_android_guest_writers_init()==EBUSY,"claimed SIGURG rejected");check(!s2a_android_guest_writers_ready(),"claimed not ready");return 0;}
    check(!pthread_key_create(&g_key18,NULL)&&!pthread_key_create(&g_keytls,NULL)&&!pthread_key_create(&g_keytlr,NULL)&&!pthread_key_create(&g_keygate,NULL),"fixture guest TLS keys");
    check(!s2a_android_guest_writers_ready(),"not ready before install");check(!s2a_android_guest_writers_init(),"real install");check(s2a_android_guest_writers_ready(),"installed ready");s2a_crash_install();
    if(argc>1&&!strcmp(argv[1],"diag"))return diag_mode();
    if(argc>1&&!strcmp(argv[1],"pause-waits")) {s2a_thread_main_init();return pause_wait_suite();}
    if(argc>1&&!strcmp(argv[1],"deadline-scope")) {s2a_thread_main_init();return pw_scope_suite();}
    if(argc>1&&!strcmp(argv[1],"pause-vm-orders")) {s2a_thread_main_init();return pw_vm_orders_suite();}
    struct job spinning;pthread_t spin=start(&spinning,0);uint64_t before;
    for(int i=0;i<16;i++){check(!s2a_android_guest_writers_begin(),"guest PC quiesces");before=atomic_load(&spinning.count);usleep(2000);check(before==atomic_load(&spinning.count),"guest writes stopped");check(s2a_android_guest_writers_begin()==EDEADLK,"nested rejected");s2a_android_guest_writers_end();}
    before=atomic_load(&spinning.count);usleep(10000);check(atomic_load(&spinning.count)>before,"guest resumes");
    check(!thr_pause(spinning.thread),"actual SetThreadActivity pause");before=atomic_load(&spinning.count);usleep(2000);check(before==atomic_load(&spinning.count),"paused guest stopped");
    uint8_t context[0x320];thr_context3(spinning.thread,context);uint64_t pc;memcpy(&pc,context+0x100,8);check(pc>=(uintptr_t)s2a_thread_test_guest_start&&pc<(uintptr_t)s2a_thread_test_guest_end,"actual paused context PC");for(int repeat=0;repeat<1000;repeat++){check(!thr_unpause(spinning.thread),"rapid resume");check(!thr_pause(spinning.thread),"rapid pause");check(spinning.thread->pmach==1,"rapid resume/pause keeps async context");thr_context3(spinning.thread,context);memcpy(&pc,context+0x100,8);check(pc>=(uintptr_t)s2a_thread_test_guest_start&&pc<(uintptr_t)s2a_thread_test_guest_end,"rapid pause exports actual guest PC");}check(!thr_unpause(spinning.thread),"resume activity");
    s2a_android_guest_writers_describe(described,sizeof described);check(!strcmp(described,"没有进行中的 writer epoch"),"describe without epoch");
    struct job callback;pthread_t cb=start(&callback,1),releaser,describer;check(!pthread_create(&releaser,NULL,release_later,&callback),"release helper");check(!pthread_create(&describer,NULL,describe_later,NULL),"describe helper");uint64_t begin=plat_now_ns();check(!s2a_android_guest_writers_begin(),"drain native callback");check(plat_now_ns()-begin>=30000000,"off_guest is not quiescence");pthread_join(describer,NULL);check(strstr(described,"在宿主侧回调里")&&strstr(described,"未停稳 1 /"),"describe names the callback writer");check(atomic_load(&callback.phase)==1,"callback return parks");s2a_android_guest_writers_end();pthread_join(releaser,NULL);until(&callback.phase,3);stop(&callback,cb);
    struct job touching;pthread_t touch=start(&touching,4);check(atomic_load(&touching.touch_active),"real Touch began");check(!pthread_create(&releaser,NULL,release_later,&touching),"touch release helper");begin=plat_now_ns();check(!s2a_android_guest_writers_begin(),"actual fault Touch drains");check(plat_now_ns()-begin>=30000000&&!atomic_load(&touching.touch_active),"no active Touch at quiescence");check(atomic_load(&touching.phase)==2,"Touch retry cannot escape epoch");s2a_android_guest_writers_end();pthread_join(releaser,NULL);until(&touching.phase,3);stop(&touching,touch);
    struct job waiter;pthread_t wait=start(&waiter,2);usleep(10000);check(!s2a_android_guest_writers_begin(),"condition wait safe");atomic_store(&waiter.release,1);glock();pthread_cond_signal(&waiter.thread->cv);pthread_mutex_unlock(&G);usleep(5000);check(atomic_load(&waiter.phase)==1,"woken waiter cannot escape");s2a_android_guest_writers_end();until(&waiter.phase,3);stop(&waiter,wait);
    // 宿主侧长工作（图形回放一次提交）不回客体也能被停世界越过：安全点停驻 → 事务期间不前进 → 结束后继续
    struct job hostloop;pthread_t host=start(&hostloop,6);usleep(2000);check(!s2a_android_guest_writers_begin(),"host safepoint quiesces");before=atomic_load(&hostloop.count);usleep(5000);check(before==atomic_load(&hostloop.count),"host loop parked in epoch");s2a_android_guest_writers_end();usleep(5000);check(atomic_load(&hostloop.count)>before,"host loop resumes after epoch");atomic_store(&hostloop.release,1);until(&hostloop.phase,3);stop(&hostloop,host);
    check(!s2a_android_guest_writers_begin(),"epoch before entry");struct job newborn={0};pthread_t child;check(!pthread_create(&child,NULL,worker,&newborn),"spawn during epoch");usleep(10000);check(!atomic_load(&newborn.phase),"new entry stopped");s2a_android_guest_writers_end();until(&newborn.phase,3);stop(&newborn,child);
    struct job exiting;pthread_t exiting_thread=start(&exiting,5);check(!pthread_create(&releaser,NULL,release_later,&exiting),"exit release helper");check(!s2a_android_guest_writers_begin(),"exit drains pinned roster");check(exiting.thread->exited&&exiting.thread->closed&&exiting.thread->pins==1,"exit metadata pinned until epoch end");s2a_android_guest_writers_end();pthread_join(releaser,NULL);check(!pthread_join(exiting_thread,NULL),"actual ExitThread joins");
    struct job locked;pthread_t lock=start(&locked,3);begin=plat_now_ns();check(s2a_android_guest_writers_begin()==ETIMEDOUT,"native G holder cancels");check(plat_now_ns()-begin<2500000000ull,"lock timeout bounded");atomic_store(&locked.release,1);until(&locked.phase,3);stop(&locked,lock);
    struct job inflight;pthread_t flight=start(&inflight,1);check(s2a_android_guest_writers_begin()==ETIMEDOUT,"inflight callback cancels");check(!atomic_load(&android_vm_epoch),"cancel clears epoch");before=atomic_load(&spinning.count);usleep(10000);check(atomic_load(&spinning.count)>before,"cancel resumes guest");atomic_store(&inflight.release,1);until(&inflight.phase,3);stop(&inflight,flight);
    check(!s2a_android_guest_writers_begin(),"later epoch succeeds");s2a_android_guest_writers_end();stop(&spinning,spin);check(!s2a_android_guest_writers_begin(),"zero guest admission");s2a_android_guest_writers_end();printf("PASS %d real thread-owner checks\n",checks);return 0;}

int main(int argc,char **argv) {
    alarm(30);
    int result=thread_modes(argc,argv);
    return pw_finish(argc>1?argv[1]:"noarg",result,checks);
}
