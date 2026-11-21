// 真实 thread.c 配合既有夹具端点，不另写一套等待实现。
// 等事件的上限只当兜底（11-19：原先 1～5 秒，负载高时线程没跑到就判红 → 一律 30 秒，正常时一到就返回）
#define main base_thread_suite_main
#include "t_thread.c"
#undef main
#if defined(__APPLE__)
#define WD_OPTIONAL __attribute__((weak_import))
#else
#define WD_OPTIONAL __attribute__((weak))
#endif
WD_OPTIONAL int s2a_test_wait_ring_probe(uint64_t *, uint64_t *, size_t *, uint64_t *);
WD_OPTIONAL size_t s2a_test_wait_records(void);
WD_OPTIONAL int s2a_test_wait_enabled(void);
WD_OPTIONAL int s2a_test_wait_source_svc(void);
WD_OPTIONAL uint64_t s2a_test_wait_dropped(void);
WD_OPTIONAL void s2a_wait_diag_report(void);
static uint32_t wd_handle, wd_write;
static uint64_t wd_event;
static _Atomic int wd_done;
static uint64_t wd_result;
static _Atomic uint32_t wd_mutex, wd_key;
static void wd_waiter(uint64_t cv) {
    uint64_t r[31]={0, (uintptr_t)&wd_handle, 1, (uint64_t)-1};
    if (cv) { uint64_t id[31]={0,S2A_H_CUR_THREAD}; svc_thread(0x25,id);
        uint32_t tag=s2a_thread_current();
        atomic_store(&wd_mutex,tag);
        r[0]=(uintptr_t)&wd_mutex; r[1]=(uintptr_t)&wd_key; r[2]=tag;
    }
    svc_thread(cv ? 0x1c : 0x18,r); wd_result=r[0]; atomic_store(&wd_done,1);
    uint64_t exit_regs[31]={0}; svc_thread(0x0a,exit_regs);
}
static void wd_waiter1a(uint64_t owner) {
    uint64_t r[31]={owner,(uintptr_t)&wd_mutex,s2a_thread_current()};
    svc_thread(0x1a,r); wd_result=r[0]; atomic_store(&wd_done,1);
    uint64_t e[31]={0}; svc_thread(0x0a,e);
}
static void wd_until(int kind, uint64_t address) {
    while (!s2a_test_waiters(kind,address)) usleep(100);   /* 按事件等，不设墙钟上限；挂死交门禁分组超时 */
    CHECK(s2a_test_waiters(kind,address)>0,"waiter actually registered kind %d",kind);
}
static void wd_join(uint32_t h) {
    uint64_t r[31]={0,(uintptr_t)&h,1,(uint64_t)-1}; svc_thread(0x18,r);   /* 无限等退出事件 */
    CHECK(!r[0] && atomic_load(&wd_done),"real ExitThread observable before CloseHandle");
    uint64_t close_regs[31]={h}; svc_thread(0x16,close_regs);
}
uint32_t s2a_test_wait_first(int kind, uint64_t a);
int s2a_test_wait_fields(uint32_t h, int *type, int32_t *val, int64_t *tmo, unsigned *nsig);
static _Atomic int32_t wd_addr;
static _Atomic int wd_a34_done[2];
static void wd_waiter34(uint64_t i) {   // 0x34 类型 2（相等则等）、比较值 1、无限超时
    uint64_t r[31]={(uintptr_t)&wd_addr,2,1,(uint64_t)-1};
    svc_thread(0x34,r); atomic_store(&wd_a34_done[i],1);
    uint64_t e[31]={0}; svc_thread(0x0a,e);
}
static void *wd_host_signal(void *unused) { (void)unused; usleep(10000); s2a_event_signal(wd_event); return NULL; }
int main(int argc,char **argv) {
    setenv("S2A_WAIT_TRACE","1",1);   // 逐线程「被发信号」计数缺省关；本单测要查它，必须在第一次等待前开
    int ring=argc>1 && !strcmp(argv[1],"ring");
    int enabled=ring || (argc>1 && !strcmp(argv[1],"on"));
    if(enabled) setenv("S2A_WAIT_DIAG","1",1); else unsetenv("S2A_WAIT_DIAG");
    if(argc>1 && !strcmp(argv[1],"zero")) setenv("S2A_WAIT_DIAG","0",1);
    if(argc>1 && !strcmp(argv[1],"invalid")) setenv("S2A_WAIT_DIAG","invalid",1);
    if(argc>1 && !strcmp(argv[1],"stamp-only")) setenv("S2A_DIAG_STAMP","fixture+0x4,fixture+0x8",1);
    setenv("S2A_CORES","0",1);
    pthread_key_create(&g_key18,NULL); pthread_key_create(&g_keytls,NULL);
    pthread_key_create(&g_keytlr,NULL); pthread_key_create(&g_keygate,NULL);
    g_wtag=s2a_thread_main_init();   // 不设整测墙钟上限：各处等待都按事件判，挂死交门禁分组超时
    CHECK((s2a_test_wait_enabled?s2a_test_wait_enabled():0)==enabled,"诊断开关在第一次等待前已初始化");
    if (ring) {
        uint64_t first=0,last=0,dropped=0; size_t pending=0;
        CHECK(s2a_test_wait_ring_probe && s2a_test_wait_ring_probe(&first,&last,&pending,&dropped), "ring probe available");
        CHECK(first==4 && last==1027 && pending==1024 && dropped==3,
              "unprinted ring retains seq 4..1027, pending 1024 dropped 3: got %llu..%llu %zu/%llu",
              (unsigned long long)first,(unsigned long long)last,pending,(unsigned long long)dropped);
        s2a_wait_diag_report();
        CHECK(s2a_test_wait_records()==0 && s2a_test_wait_dropped()==3,"ring drained with three drops");
        return bad?1:0;
    }
    wd_event=s2a_event_create(&wd_handle,&wd_write);
    uint64_t early_signal[31]={wd_write}; svc_thread(0x11,early_signal);
    CHECK(!early_signal[0],"首 wait 前的真实 SignalEvent 成功");
    CHECK((s2a_test_wait_source_svc?s2a_test_wait_source_svc():0)==(enabled?0x11:0),"首 wait 前 signal 的真实 source_svc 已记录");
    s2a_event_clear(wd_event);

    strcpy(g_fake_mod.name,"fixture");
    void s2a_svc_frame(uint64_t);
    s2a_svc_frame((uintptr_t)guest_spin+4);
    uint64_t r[31]={0,(uintptr_t)&wd_handle,1,0};r[30]=(uintptr_t)guest_spin+8;svc_thread(0x18,r);
    s2a_svc_frame(0);r[30]=0;
    CHECK(r[0]==0xea01,"zero poll preserves timeout");
    r[0]=0;r[1]=(uintptr_t)&wd_handle;r[2]=1;r[3]=5000000;
    uint64_t start=now_ns(); svc_thread(0x18,r);
    CHECK(r[0]==0xea01 && now_ns()-start>=4000000,"finite actual pthread timeout, no fake success");
    s2a_event_signal(wd_event); r[1]=(uintptr_t)&wd_handle;r[2]=1;r[3]=1000000000;
    svc_thread(0x18,r); CHECK(!r[0] && !r[1],"already-signaled index0"); s2a_event_clear(wd_event);
    pthread_t host; pthread_create(&host,NULL,wd_host_signal,NULL);
    r[1]=(uintptr_t)&wd_handle;r[2]=1;r[3]=(uint64_t)-1;
    svc_thread(0x18,r); CHECK(!r[0],"negative infinite wait wakes via host event"); pthread_join(host,NULL);s2a_event_clear(wd_event);
    uint32_t invalid=0x1234; r[1]=(uintptr_t)&invalid;r[2]=1;r[3]=0;
    svc_thread(0x18,r);CHECK(r[0]==0xe401,"invalid handle preserved");
    r[1]=1;r[2]=65;r[3]=0;svc_thread(0x18,r);CHECK(r[0]==0xee01,"count65 rejects without pointer read");
    for(int mode=0;mode<2;++mode) {
        atomic_store(&wd_done,0);uint32_t h;spawn(wd_waiter,0,&h);wd_until(4,0);
        if(mode) {uint64_t signal_regs[31]={wd_write};svc_thread(0x11,signal_regs);} else {uint64_t c[31]={h};svc_thread(0x19,c);CHECK(!c[0],"CancelSynchronization accepted");}
        wd_join(h);CHECK(wd_result==(mode?0:0xec01),"cancel/event result unchanged");s2a_event_clear(wd_event);
    }
    atomic_store(&wd_done,0);uint32_t h;spawn(wd_waiter,1,&h);wd_until(2,(uintptr_t)&wd_key);
    uint64_t signal_regs[31]={(uintptr_t)&wd_key,1};svc_thread(0x1d,signal_regs);wd_join(h);
    CHECK(wd_result==0,"condition signal and mutex reacquire");
    for(int mode=0;mode<2;++mode) {
        atomic_store(&wd_mutex,g_wtag);atomic_store(&wd_key,0);
        uint64_t c[31]={(uintptr_t)&wd_mutex,(uintptr_t)&wd_key,g_wtag,mode?5000000:0};
        svc_thread(0x1c,c);CHECK(c[0]==0xea01,"CV zero/finite timeout unchanged");
    }
    // 真正进入 0x1A 等待，再由持有者解锁；以及不阻塞、无效句柄早退。
    atomic_store(&wd_mutex,g_wtag|WAITER); atomic_store(&wd_done,0);
    uint32_t lock_h; spawn(wd_waiter1a,g_wtag,&lock_h); wd_until(1,(uintptr_t)&wd_mutex);
    uint64_t unlock[31]={(uintptr_t)&wd_mutex}; svc_thread(0x1b,unlock); wd_join(lock_h);
    CHECK(wd_result==0,"arbitrate lock blocked and unlocked");
    const uint32_t bogus=0x7ff0u<<15|0x1fffu;
    atomic_store(&wd_mutex,0);
    uint64_t lock_early[31]={bogus,(uintptr_t)&wd_mutex,g_wtag}; svc_thread(0x1a,lock_early);
    CHECK(lock_early[0]==0,"arbitrate lock no wait");
    atomic_store(&wd_mutex,bogus|WAITER); lock_early[0]=bogus; svc_thread(0x1a,lock_early);
    CHECK(lock_early[0]==0xe401,"arbitrate lock invalid owner");
    atomic_store(&wd_addr,1);
    for (int mode=0;mode<3;++mode) {
        uint64_t ar[31]={(uintptr_t)&wd_addr,2,mode?1:2,mode==2?5000000:0};
        svc_thread(0x34,ar); CHECK(ar[0]==(mode?0xea01:0xfa01),"address early/timeout result %d: %#llx",mode,(unsigned long long)ar[0]);
    }
    // ㉓ 等地址的现场字段：两个等待者、只发一条信号 → 醒一个，剩下那个仍在等，且它的「等待期间被发信号」必须是 1。
    //   只看键表（1024 格直映）分不出「没人发」和「发了没轮到我」——「从没被发过信号」可能就是撞掉的记录
    atomic_store(&wd_addr,1);
    { uint32_t h0,h1; spawn(wd_waiter34,0,&h0); spawn(wd_waiter34,1,&h1);
      while(s2a_test_waiters(3,(uintptr_t)&wd_addr)<2) usleep(100);   // 按事件等，挂死交门禁分组超时
      CHECK(s2a_test_waiters(3,(uintptr_t)&wd_addr)==2,"two address waiters registered");
      uint64_t s1[31]={(uintptr_t)&wd_addr,0,0,1}; svc_thread(0x35,s1);
      CHECK(!s1[0]&&s2a_test_waiters(3,(uintptr_t)&wd_addr)==1,"one signal wakes exactly one address waiter");
      uint32_t left=s2a_test_wait_first(3,(uintptr_t)&wd_addr);
      int ty,ty0=-1; int32_t val=0; int64_t tmo=0; unsigned nsig=0;
      int ok=s2a_test_wait_fields(left,&ty,&val,&tmo,&nsig);
      CHECK(ok&&ty==2&&val==1&&tmo<0,"address wait keeps its condition (type %d, compare %d, timeout %lld)",ty,(int)val,(long long)tmo);
      CHECK(ok&&nsig==1,"per-waiter signal count ignores who was picked (got %u)",nsig);
      { void s2a_thread_dump(void); s2a_thread_dump(); }   // 现场导出走一遍「等地址」分支（条件原样写出）
      uint64_t s2[31]={(uintptr_t)&wd_addr,0,0,(uint64_t)-1}; svc_thread(0x35,s2);
      while(s2a_test_waiters(3,(uintptr_t)&wd_addr)) usleep(100);
      while(!atomic_load(&wd_a34_done[0])||!atomic_load(&wd_a34_done[1])) usleep(100);
      CHECK(atomic_load(&wd_a34_done[0])&&atomic_load(&wd_a34_done[1]),"both address waiters returned");
      ty0=ty; (void)ty0;
      uint64_t cl[31]={h0}; svc_thread(0x16,cl); cl[0]=h1; svc_thread(0x16,cl); }
    // 耗尽精确的生命周期预算后，真实等待仍应照常工作。
    for(int i=0;i<400;++i){r[1]=(uintptr_t)&wd_handle;r[2]=1;r[3]=0;svc_thread(0x18,r);CHECK(r[0]==0xea01,"budget does not change Result");}
    size_t count=s2a_test_wait_records?s2a_test_wait_records():0;
    uint64_t dropped=s2a_test_wait_dropped?s2a_test_wait_dropped():0;
    CHECK(enabled ? count<=1024 : count==0 && dropped==0,"diagnostic pending bounded and disabled has no records (got %zu/%llu)",count,(unsigned long long)dropped);
    if(s2a_wait_diag_report)s2a_wait_diag_report();
    uint64_t close_regs[31]={wd_handle};svc_thread(0x16,close_regs);close_regs[0]=wd_write;svc_thread(0x16,close_regs);s2a_event_release(wd_event);
    printf("%s t_thread_wait_diag enabled=%d records=%zu dropped=%llu\n",bad?"FAIL":"PASS",enabled,count,(unsigned long long)dropped);
    return bad?1:0;
}
