// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 由真实线程夹具引入，使用原生 SVC、pthread、G/句柄表/pins，
// 由目标发布 ack；原本无限等待的线程无需执行客体指令。
static uint32_t pw_read, pw_write;
static uint64_t pw_event;
static _Atomic uint32_t pw_mutex, pw_key;
static _Atomic int pw_done;
static uint64_t pw_result;
static _Atomic int pw_checks, pw_failures;
static int pw_epoch_begin(void);
static void pw_epoch_end(void);
static int pw_epoch_parked(thr_t *);
static void pw_check(int ok, const char *name) {
    ++pw_checks;
    if (!ok) { ++pw_failures; fprintf(stderr,"FAIL pause-wait %s\n",name); }
}
// 夹具包装真实 pthread 调用记录通知/停驻，不替代内核等待。
// SIGURG 可引起平台伪唤醒，删通知的反例还必须核实际通知计数。
static _Thread_local int pw_requesting;
static pthread_cond_t *pw_notify_cv;
static _Atomic int pw_notifications, pw_native_parks, pw_writer_active;
static _Atomic uintptr_t pw_barrier_target;
static _Atomic int pw_boundary_violation;
// 每个 fixture SVC 是一项逻辑操作，覆盖其全部真实 pthread 重试。
// watchdog / scheduler 独立 CV 不共享客体操作的首 deadline。
static _Thread_local thr_t *pw_operation_thread;
static _Thread_local unsigned pw_operation;
static _Thread_local int pw_has_deadline;
static _Atomic unsigned pw_operation_sequence, pw_guest_retries, pw_guest_firsts;
static _Atomic unsigned pw_watchdog_calls, pw_watchdog_changes;
static _Thread_local struct timespec pw_watchdog_previous;
static _Thread_local int pw_watchdog_seen;
static _Thread_local _Atomic int *pw_timed_calls;
static _Thread_local struct timespec *pw_first_output;
static void pw_operation_begin(thr_t *t) {
    pw_operation_thread=t;pw_operation=atomic_fetch_add(&pw_operation_sequence,1)+1;
    pw_has_deadline=0;
}
static void pw_operation_end(void) {
    pw_check(pw_operation_thread==pthread_getspecific(g_keythr),"operation belongs to actual calling thread");
    pw_operation_thread=NULL;pw_operation=0;pw_has_deadline=0;
}
static _Thread_local struct timespec pw_deadline;
// 真 Android 的 svc_exit/core_acquire 还有后置屏障；只看 guest 返回会掩盖
// 更早的条件返回缺口。记录实际 glock 重取，核验 writer 已准入期间未越界。
static int pw_pthread_mutex_lock(pthread_mutex_t *mu) {
    thr_t *t=pthread_getspecific(g_keythr);
    if (mu==&G && atomic_load(&pw_writer_active) && t
        && (uintptr_t)t==atomic_load(&pw_barrier_target) && !t->vm_wait_safe)
        {atomic_store(&pw_boundary_violation,1);pw_check(0,"resumed waiter cannot escape VM epoch before G");}
    return pthread_mutex_lock(mu);
}
static int pw_pthread_cond_signal(pthread_cond_t *cv) {
    if (pw_requesting && cv==pw_notify_cv) ++pw_notifications;
    return pthread_cond_signal(cv);
}
static void pw_wait_probe(pthread_cond_t *cv,const struct timespec *deadline) {
    thr_t *t=pthread_getspecific(g_keythr);
    if (cv==&g_pause_cv && t && t->wkind) {
        stack_t ss; int e=sigaltstack(NULL,&ss);
        pw_check(!e && !(ss.ss_flags&SS_ONSTACK),"ack park is target normal context");
        pw_check(atomic_load(&t->paused_ack) && !t->pmach && atomic_load(&t->in_svc),"ack published before real park");
        pw_check(!atomic_load(&t->held_core),"park releases scheduler core");
        ++pw_native_parks;
    }
    if (deadline && cv==&g_wd_cv) {
        // 真实 watchdog 每次调用是新一轮 CLOCK_REALTIME+20ms，不是客体重试。
        ++pw_watchdog_calls;
        if (pw_watchdog_seen && (deadline->tv_sec!=pw_watchdog_previous.tv_sec
                                || deadline->tv_nsec!=pw_watchdog_previous.tv_nsec))
            ++pw_watchdog_changes;
        pw_watchdog_previous=*deadline;pw_watchdog_seen=1;
    }
    if (deadline && pw_operation && t==pw_operation_thread && cv==&t->cv) {
        pw_check(t->wkind==2 || t->wkind==4,"deadline belongs to real CV/event SVC wait");
        if (!pw_has_deadline) {pw_deadline=*deadline;pw_has_deadline=1;++pw_guest_firsts;
            if(pw_first_output)*pw_first_output=*deadline;}
        else ++pw_guest_retries;
        pw_check(pw_deadline.tv_sec==deadline->tv_sec && pw_deadline.tv_nsec==deadline->tv_nsec,
                 "original absolute deadline is unchanged");
        if (pw_timed_calls) atomic_fetch_add(pw_timed_calls,1);
    }
}
static int pw_pthread_cond_wait(pthread_cond_t *cv,pthread_mutex_t *mu) {
    pw_wait_probe(cv,NULL); return pthread_cond_wait(cv,mu);
}
static int pw_pthread_cond_timedwait(pthread_cond_t *cv,pthread_mutex_t *mu,const struct timespec *d) {
    pw_wait_probe(cv,d); return pthread_cond_timedwait(cv,mu,d);
}
struct pw_job { int cv, mask_signal, operations; int64_t ns; thr_t *thread; _Atomic int ready, completed, timed_calls; struct timespec deadlines[2]; };
static void *pw_worker(void *arg) {
    struct pw_job *j=arg; thr_t *t=calloc(1,sizeof *t);
    if (j->mask_signal) {sigset_t set;sigemptyset(&set);sigaddset(&set,SIGURG);pthread_sigmask(SIG_BLOCK,&set,NULL);}
    t->started=1; t->pt=pthread_self(); t->prio=44; t->mask=7;
    pthread_cond_init(&t->cv,NULL); atomic_store(&t->in_svc,1);
    glock(); t->id=g_next_id++; t->handle=h_new(S2A_OBJ_THREAD,t,0);
    t->all=g_all; g_all=t; j->thread=t; pthread_mutex_unlock(&G);
    thread_bind_host(t);
    for (int op=0;op<(j->operations?j->operations:1);++op) {
        uint64_t regs[31]={0,(uintptr_t)&pw_read,1,(uint64_t)j->ns};
        if (j->cv) {
            atomic_store(&pw_mutex,t->handle);
            regs[0]=(uintptr_t)&pw_mutex;regs[1]=(uintptr_t)&pw_key;regs[2]=t->handle;
        }
        atomic_store(&j->timed_calls,0);pw_timed_calls=&j->timed_calls;
        pw_first_output=j->operations?&j->deadlines[op]:NULL;
        pw_operation_begin(t);atomic_store(&j->ready,op+1);
        svc_thread(j->cv?0x1c:0x18,regs);pw_result=regs[0];
        pw_operation_end();pw_timed_calls=NULL;pw_first_output=NULL;
        if (j->cv && !pw_result) pw_check(atomic_load(&pw_mutex)==t->handle,"CV reacquires original mutex");
        if (j->operations) {
            pw_check(!pw_result,"independent operation keeps real Result");
            s2a_event_clear(pw_event);
        }
        atomic_store(&j->completed,op+1);
    }
    atomic_store(&pw_done,1); thread_exit(t); return NULL;
}
static uint32_t pw_start(struct pw_job *j, pthread_t *pt, int cv, int64_t ns) {
    *j=(struct pw_job){.cv=cv&1,.mask_signal=(cv&2)!=0,.ns=ns};
    cv=cv&1; atomic_store(&pw_done,0);
    pw_check(!pthread_create(pt,NULL,pw_worker,j),"real pthread created");
    uint32_t handle=0;   /* 按事件等目标进入等待，不设墙钟上限；挂死交门禁分组超时 */
    for (;;) {
        glock();
        if (j->thread && j->thread->vm_wait_safe && j->thread->wkind==(cv?2:4))
            handle=j->thread->handle;
        pthread_mutex_unlock(&G); if (handle) break; usleep(100);
    }
    pw_check(handle!=0,"actual native SVC is blocked and wait-safe"); return handle;
}
static uint32_t pw_activity(uint32_t h, int activity) {
    uint64_t r[31]={h,(uint32_t)activity}; pw_requesting=activity==1;
    svc_thread(0x32,r); pw_requesting=0; return (uint32_t)r[0];
}
static void pw_produce(int cv, int cancel, uint32_t h) {
    uint64_t r[31]={cv?(uintptr_t)&pw_key:cancel?h:pw_write,1};
    svc_thread(cv?0x1d:cancel?0x19:0x11,r);
    pw_check(!r[0],"original wake/cancel producer accepted");
}
static void pw_join(pthread_t pt, uint32_t h, uint64_t want) {
    pw_check(!pthread_join(pt,NULL),"real ExitThread joined");
    pw_check(atomic_load(&pw_done) && pw_result==want,"original wait Result preserved");
    uint64_t r[31]={h}; svc_thread(0x16,r);
    pw_check(!r[0],"closed original handle after exit"); s2a_event_clear(pw_event);
}
static int pause_wait_suite(void) {
    pw_event=s2a_event_create(&pw_read,&pw_write);
    for (int mode=0;mode<5;++mode) {
        struct pw_job j; pthread_t pt; int cv=mode==1 || mode==4,cancel=mode==2;
        uint32_t h=pw_start(&j,&pt,mode>=3?(mode==3?2:3):cv,-1); if (!h) return 1;
        if (mode<2) {
            pw_check(!pthread_kill(pt,SIGURG),"real native SIGURG delivered");
            while (!atomic_load(&j.thread->preempt_req)) usleep(100);
            pw_check(atomic_load(&j.thread->preempt_req),"native handler reached without guest trampoline");
            glock();pw_check(!j.thread->woke && !atomic_load(&j.thread->paused_ack),
                "real signal does not forge wake or ack");pthread_mutex_unlock(&G);
        }
        pw_notify_cv=&j.thread->cv; int notices=atomic_load(&pw_notifications);
        int parks=atomic_load(&pw_native_parks);
        uint64_t begin=now_ns(); uint32_t result=pw_activity(h,1);
        printf("pause-wait mode=%d result=%#x elapsed_ns=%llu\n",mode,result,(unsigned long long)(now_ns()-begin));
        pw_check(result==0,"infinite native wait acknowledges pause within original 2s");
        if (!result) {
            pw_check(atomic_load(&pw_notifications)>notices,"pause sends actual condition notification");
            // release ack 可能早于探针；G 栅栏后目标已进入真实等待。
            glock();
            pw_check(atomic_load(&pw_native_parks)>parks,"target entered real native park"); thr_t *t=h_obj(h,S2A_OBJ_THREAD);
            pw_check(t && atomic_load(&t->paused_ack) && !t->pmach && atomic_load(&t->in_svc),"target publishes SVC-safe ack");
            pthread_mutex_unlock(&G);
            for (int repeat=0;repeat<8;++repeat) {
                pw_check(!pw_activity(h,0),"rapid resume");
                pw_check(!pw_activity(h,1),"rapid re-pause");
            }
        }
        if (!result) {
            glock();pw_check(!j.thread->woke && j.thread->wkind==(cv?2:4),"pause does not forge original predicate");
            pthread_mutex_unlock(&G);
            pw_check(pw_activity(h,1)==R_BAD_STATE,"duplicate pause rejected");
        }
        pw_produce(cv,cancel,h); usleep(20000);
        if (!result) {
            pw_check(!atomic_load(&pw_done),"producer cannot return guest while paused");
            atomic_store(&pw_barrier_target,(uintptr_t)j.thread);
            pw_check(!pw_epoch_begin(),"VM writer accepts parked native waiter");
            atomic_store(&pw_boundary_violation,0);
            atomic_store(&pw_writer_active,1);
            pw_check(!pw_activity(h,0),"resume accepted");
            while (!pw_epoch_parked(j.thread) && !atomic_load(&pw_boundary_violation)) usleep(100);
            pw_check(pw_epoch_parked(j.thread) && !atomic_load(&pw_boundary_violation),
                     "resumed waiter reaches actual VM return barrier");
            pw_check(!atomic_load(&pw_done),"resumed waiter cannot escape VM epoch");
            atomic_store(&pw_writer_active,0);
            pw_epoch_end();
        }
        pw_join(pt,h,cancel?R_CANCELLED:0);
    }
    for (int cv=0;cv<2;++cv) for (int expires=0;expires<2;++expires) {
        struct pw_job finite; pthread_t pt;
        uint32_t h=pw_start(&finite,&pt,cv,expires?50000000:1000000000);
        if (!h) return 1;pw_notify_cv=&finite.thread->cv;
        uint32_t result=pw_activity(h,1); pw_check(!result,"finite wait pauses");
        if (!result) {
            if (expires) usleep(80000);
            pw_check(!atomic_load(&pw_done),"finite wait cannot return while paused");
            pw_check(!pw_activity(h,0),"finite resume");
            if (!expires) pw_produce(cv,0,h);
        } else if (!expires) pw_produce(cv,0,h);
        pw_join(pt,h,expires?R_TIMEOUT:0);
        // 「暂停不重启有限 deadline」按事件判：每次真实 timedwait 的绝对 deadline 都要等于首次（pw_wait_probe），不再量墙钟
    }
    // CloseHandle 不释放仍存活且有 pin 的目标；旧 handle 不可继续控制它。
    struct pw_job closed;pthread_t closed_pt;uint32_t closed_h=pw_start(&closed,&closed_pt,0,-1);
    if (!closed_h)return 1;pw_notify_cv=&closed.thread->cv;
    pw_check(!pw_activity(closed_h,1),"close race target pauses");
    glock();thr_t *pinned=h_obj(closed_h,S2A_OBJ_THREAD);++pinned->pins;
    uint64_t pinned_id=pinned->id;pthread_mutex_unlock(&G);
    uint64_t close_regs[31]={closed_h};svc_thread(0x16,close_regs);
    pw_check(!close_regs[0],"close active paused handle");
    pw_check(pw_activity(closed_h,0)==R_BAD_HANDLE,"closed handle cannot resume target");
    pw_produce(0,0,closed_h);pw_check(!thr_unpause(pinned),"pinned target resumes after close");
    pw_check(!pthread_join(closed_pt,NULL),"closed target actually exits");
    glock();pw_check(pinned->id==pinned_id && pinned->exited && pinned->closed && pinned->pins==1,
        "exited closed target retained by actual pin");
    --pinned->pins;thr_free(pinned);pthread_mutex_unlock(&G);s2a_event_clear(pw_event);
    uint64_t r[31]={pw_read};svc_thread(0x16,r);r[0]=pw_write;svc_thread(0x16,r);s2a_event_release(pw_event);
    printf("%s pause-waits checks=%d failures=%d\n",pw_failures?"FAIL":"PASS",pw_checks,pw_failures);
    return pw_failures?1:0;
}

// 握手制造真实伪唤醒，不改生产 deadline、wake 谓词、Result 或 ack。
// 同一 pthread 连续执行两次独立 SVC；每项都至少进入两次真实 timedwait。
static int pw_scope_suite(void) {
    pw_event=s2a_event_create(&pw_read,&pw_write);
    unsigned firsts=atomic_load(&pw_guest_firsts),retries=atomic_load(&pw_guest_retries);
    for (int cv=0;cv<2;++cv) {
        struct pw_job j={.cv=cv,.ns=1000000000,.operations=2};pthread_t pt;
        pw_check(!pthread_create(&pt,NULL,pw_worker,&j),"scope real worker created");
        for (int op=1;op<=2;++op) {
            uint32_t h=0;
            for (;;) {
                glock();
                if (j.thread && atomic_load(&j.ready)==op && atomic_load(&j.timed_calls)>=1
                    && j.thread->vm_wait_safe && j.thread->wkind==(cv?2:4)) {
                    h=j.thread->handle;
                    pw_check(!j.thread->woke,"spurious notification starts with pending predicate");
                    pthread_cond_signal(&j.thread->cv);
                }
                pthread_mutex_unlock(&G);if(h)break;usleep(100);
            }
            pw_check(h!=0,"scope real operation entered timedwait");if(!h)return 1;
            while (atomic_load(&j.timed_calls)<2) usleep(100);
            pw_check(atomic_load(&j.timed_calls)>=2,"same operation actually retries timedwait");
            glock();pw_check(!j.thread->woke && atomic_load(&j.completed)<op,
                            "real retry leaves original predicate and operation pending");
            pthread_mutex_unlock(&G);pw_produce(cv,0,h);
        }
        pw_join(pt,j.thread->handle,0);
        pw_check(j.deadlines[0].tv_sec!=j.deadlines[1].tv_sec || j.deadlines[0].tv_nsec!=j.deadlines[1].tv_nsec,
                 "independent same-thread operations have distinct real deadlines");
        pw_check(atomic_load(&j.completed)==2,"same pthread finishes two independent operations");
    }
    pw_check(atomic_load(&pw_guest_firsts)-firsts==4,"four independently reset finite deadlines");
    pw_check(atomic_load(&pw_guest_retries)-retries>=4,"four real same-operation deadline retries");
    uint64_t r[31]={pw_read};svc_thread(0x16,r);r[0]=pw_write;svc_thread(0x16,r);s2a_event_release(pw_event);
    printf("%s deadline-scope checks=%d failures=%d firsts=%u retries=%u\n",
           pw_failures?"FAIL":"PASS",pw_checks,pw_failures,
           atomic_load(&pw_guest_firsts)-firsts,atomic_load(&pw_guest_retries)-retries);
    return pw_failures?1:0;
}
// 两种顺序均让目标真正离开原 CV、停到 VM futex，再清掉旧 pause ack
// 后发新请求。不能只测试原 CV 上的 wait-safe 或借上次 ack 通过。
static int pw_vm_orders_suite(void) {
    pw_event=s2a_event_create(&pw_read,&pw_write);
    for (int masked=0;masked<2;++masked) for (int cv=0;cv<2;++cv) for (int first=0;first<2;++first) {
        struct pw_job j;pthread_t pt;
        uint32_t h=pw_start(&j,&pt,cv+2*masked,-1);if(!h)return 1;
        if (first) pw_check(!pw_activity(h,1),"pause before VM epoch");
        pw_check(!pw_epoch_begin(),"VM writer accepts original safe wait");
        pw_produce(cv,0,h);
        if (first) pw_check(!pw_activity(h,0),"resume first pause into VM");
        for (int repeat=0;repeat<4;++repeat) {
            while (!pw_epoch_parked(j.thread)||atomic_load(&j.thread->paused_ack)) usleep(100);
            pw_check(pw_epoch_parked(j.thread)&&!atomic_load(&j.thread->paused_ack),
                     "VM barrier reached with previous pause ack cleared");
            uint32_t result=pw_activity(h,1);
            pw_check(!result,"VM-boundary pause acknowledged by target");
            pw_check(!atomic_load(&pw_done),"VM-boundary target has not returned to guest");
            if (result) {pw_epoch_end();pw_join(pt,h,0);return 1;}
            if (repeat!=3) pw_check(!pw_activity(h,0),"repeated resume inside same VM epoch");
        }
        // 两种释放顺序都不能让 pause 或 VM 的其中一个被当成另一个的完成。
        if (first) {
            pw_epoch_end();usleep(1000);
            pw_check(!atomic_load(&pw_done),"VM release retains independent pause");
            pw_check(!pw_activity(h,0),"resume after VM release");
        } else {
            pw_check(!pw_activity(h,0),"resume before VM release");usleep(1000);
            pw_check(!atomic_load(&pw_done),"pause release retains independent VM barrier");
            pw_epoch_end();
        }
        pw_join(pt,h,0);
    }
    uint64_t r[31]={pw_read};svc_thread(0x16,r);r[0]=pw_write;svc_thread(0x16,r);s2a_event_release(pw_event);
    printf("%s pause-vm-orders checks=%d failures=%d\n",pw_failures?"FAIL":"PASS",pw_checks,pw_failures);
    return pw_failures?1:0;
}
static int pw_finish(const char *mode,int status,int original_checks) {
    int bad=status || atomic_load(&pw_failures);
    printf("%s thread-mode mode=%s original_checks=%d pause_checks=%d failures=%d guest_firsts=%u guest_retries=%u watchdog_calls=%u watchdog_changes=%u\n",
           bad?"FAIL":"PASS",mode,original_checks,pw_checks,pw_failures,
           pw_guest_firsts,pw_guest_retries,pw_watchdog_calls,pw_watchdog_changes);
    return bad?1:0;
}
