// Included only by the real runtime/src/thread.c, after its thread roster/locks.
// This is not another thread registry. All lifetime pins belong to thr_t under G.
static _Atomic unsigned android_vm_epoch;
static _Atomic(thr_t *) android_vm_owner;
static _Atomic int android_signal_installed;
static pthread_mutex_t android_vm_serial = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned android_vm_serial_sequence;
static _Thread_local int android_vm_memory_scope;
static pthread_once_t android_signal_once = PTHREAD_ONCE_INIT;
static int android_signal_error;
static unsigned android_vm_sequence;
enum { ANDROID_VM_MAX_THREADS = 1024 };
static thr_t *android_vm_pins[ANDROID_VM_MAX_THREADS];
static size_t android_vm_pin_count;
static _Thread_local int android_vm_active;
static _Thread_local int android_vm_beginning;
static _Thread_local int android_vm_serial_only;          // 本线程持有一个只串行、未停世界的 epoch
static _Thread_local uint64_t android_vm_deadline;        // 本次事务唯一预算截止；升级停世界沿用它
// 「本线程的事务已经在调用栈里被撤销」：quiesce 升级失败会撤销 serial/epoch 并释放事务，
// 外层收尾若再走正常 end() 就是二次收尾（实测 FATAL Android VM writer end 没有同线程 begin → SIGABRT）。
// 状态必须显式传播，不能靠把 end() 改成静默忽略来掩盖。
static _Thread_local int android_vm_revoked;
static _Atomic int android_vm_current_serial_only;        // 当前已发布 epoch 的形态（供收局诊断）
static _Thread_local int android_vm_svc_num = -1;         // 进入内存 SVC 时登记，仅用于到期证据
static _Thread_local uint64_t android_vm_svc_args[3];
static _Atomic uint64_t android_vm_begin_ns;   // 诊断：本次 writer epoch 发布的时刻（0 = 没有进行中的）
static void on_preempt(int, siginfo_t *, void *);
static int android_vm_quiesced(thr_t *, unsigned);
static void core_release(thr_t *);
static void core_acquire(thr_t *);
static void thr_free(thr_t *);
static int thread_keys_init(void);
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && sizeof(unsigned) == 4, "futex epoch must be lock free");

static void android_futex_wake(_Atomic unsigned *word) {
    syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, 0x7fffffff, NULL, NULL, 0);
}
// poll只允许正常上下文传入；信号入口固定NULL，不能在handler里碰宿主锁。
static void android_vm_park_poll(thr_t *thread, void (*poll)(thr_t *)) {
    for (;;) {
        if (poll) poll(thread);
        unsigned epoch = atomic_load_explicit(&android_vm_epoch, memory_order_acquire);
        if (!epoch || atomic_load(&android_vm_owner) == thread) break;
        atomic_store_explicit(&thread->vm_ack, epoch, memory_order_release);
        syscall(SYS_futex, &android_vm_epoch, FUTEX_WAIT_PRIVATE, epoch, NULL, NULL, 0);
    }
    atomic_store_explicit(&thread->vm_ack, 0, memory_order_release);
}
static void android_vm_park(thr_t *thread) { android_vm_park_poll(thread, NULL); }
// Normal-context boundary only, with no G / VM / GPU / scheduler lock held.
static void android_vm_barrier_poll(thr_t *thread, void (*poll)(thr_t *)) {
    if (!thread) return;
    if (poll) poll(thread);
    if (!atomic_load(&android_vm_epoch) || atomic_load(&android_vm_owner) == thread) return;
    int had_core = atomic_load(&thread->held_core);
    if (had_core) core_release(thread);
    android_vm_park_poll(thread, poll);
    if (had_core) core_acquire(thread);
}
static void android_vm_barrier(thr_t *thread) { android_vm_barrier_poll(thread, NULL); }
// 平台及设备验收前，协议候选保持显式启用、默认关闭。
static pthread_once_t android_wait_pause_once=PTHREAD_ONCE_INIT;
static int android_wait_pause_enabled;
static pthread_cond_t g_pause_cv;
static _Atomic int g_frz;
static void android_wait_pause_init(void) {
    const char *value=getenv("S2A_ANDROID_WAIT_PAUSE");
    android_wait_pause_enabled=value && !strcmp(value,"1");
}
static int android_wait_pause_on(void) {
    pthread_once(&android_wait_pause_once,android_wait_pause_init);
    return android_wait_pause_enabled;
}
// 持有 G；只有目标在停止访问客体内存的真实停驻点发布确认。
// 此期间生产者仍可更新原等待谓词。
static void android_wait_pause_locked(thr_t *thread) {
    if (!atomic_load(&thread->pause) && !atomic_load(&g_frz)) return;
    // 可能从启动等非 block 路径进入，停驻时同样不能占住虚拟核。
    core_release(thread);
    thread->pmach=0;
    atomic_store_explicit(&thread->paused_ack,1,memory_order_release);
    pause_diag_boundary_locked(thread,11);
    while (atomic_load(&thread->pause) || atomic_load(&g_frz)) {
        thread->vm_wait_safe=1;
        pthread_cond_wait(&g_pause_cv,&G);
    }
    thread->vm_wait_safe=0;
    atomic_store(&thread->paused_ack,0);
}
// 普通条件等待返回后仍可能停在 VM epoch 内；SIGURG 只打断 futex，
// 由目标在正常上下文复查 pause，不让新请求等到整个 epoch 结束。
static void android_wait_pause_poll(thr_t *thread) {
    if (!atomic_load(&thread->pause) && !atomic_load(&g_frz)) return;
    glock();
    android_wait_pause_locked(thread);
    pthread_mutex_unlock(&G);
}
// Called with G held. Publishing wait-safe and releasing G are atomic to the
// census. A woken/timeout waiter cannot touch guest memory before the barrier.
static int android_condition_wait(thr_t *thread, pthread_cond_t *condition, const struct timespec *deadline) {
    int error=0;
    if (condition!=&g_pause_cv && android_wait_pause_on()
        && (atomic_load(&thread->pause) || atomic_load(&g_frz))) {
        // 停驻后向原循环返回一次伪唤醒：生产者可能已改变 woke，
        // 此处再次睡眠会丢掉那次真实唤醒。
        android_wait_pause_locked(thread);
    } else {
        thread->vm_wait_safe = 1;
        error = deadline ? pthread_cond_timedwait(condition, &G, deadline) : pthread_cond_wait(condition, &G);
        pause_diag_condition_locked(thread,error);
        if (condition!=&g_pause_cv && android_wait_pause_on()) android_wait_pause_locked(thread);
    }
    thread->vm_wait_safe = 0;
    pthread_mutex_unlock(&G);
    // pause_park 的 g_pause_cv 返回期间仍持有原 ack，不能递归停驻。
    // 信号入口仍只调用 poll=NULL 的 android_vm_park。
    android_vm_barrier_poll(thread, condition!=&g_pause_cv && android_wait_pause_on()
                           ? android_wait_pause_poll : NULL);
    glock();
    return error;
}
static void android_install_signal(void) {
    struct sigaction previous;
    if (sigaction(SIGURG, NULL, &previous)) { android_signal_error = errno; return; }
    if ((previous.sa_flags & SA_SIGINFO) || (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN)) {
        android_signal_error = EBUSY; return;
    }
    android_signal_error = plat_fault_install(SIGURG, on_preempt, PLAT_FAULT_ONSTACK);
    if (!android_signal_error) atomic_store_explicit(&android_signal_installed, 1, memory_order_release);
}
int s2a_android_guest_writers_init(void) {
    int error = thread_keys_init();
    if (!error) error = pthread_once(&android_signal_once, android_install_signal);
    return error ? error : android_signal_error;
}
// svc_mem.c 映射表 / 堆改动的不变式：游戏跑起来之后，改表必须在本线程持有的 VM epoch 里（writers_begin 串行化全部改表系统调用并停住其余游戏线程，
//   MapMemory / UnmapMemory / SetHeapSize 才能在拷贝与跟踪时放开 g_mu）。新加改表的系统调用忘了登记进 svc_mem() 的 backing 列表，这里就拦（#619 P1-1 加固）
int s2a_android_vm_writer_held(void) { return android_vm_active; }
// 只回答「本局的停车通道装过没有」：不看当前 SIGURG 处理器是不是我们自己的。
// 收局要把「从未安装」与「装过但被驱动/别的库覆盖」分开——后者 guest 线程还在跑，必须照常报红。
int s2a_android_guest_writers_installed(void) {
    return atomic_load_explicit(&android_signal_installed, memory_order_acquire) != 0;
}
int s2a_android_guest_writers_ready(void) {
    if (!atomic_load_explicit(&android_signal_installed, memory_order_acquire)) return 0;
    struct sigaction current;
    return !sigaction(SIGURG, NULL, &current) && (current.sa_flags & (SA_SIGINFO | SA_ONSTACK)) == (SA_SIGINFO | SA_ONSTACK)
        && current.sa_sigaction == on_preempt;
}
static void android_vm_unpin_locked(void) {
    for (size_t i = 0; i < android_vm_pin_count; ++i) {
        thr_t *thread = android_vm_pins[i];
        --thread->pins;
        if (!thread->pins && thread->exited && thread->closed) thr_free(thread);
    }
    android_vm_pin_count = 0;
}
// gate发布唯一g_park后唤醒准入等待者；不维护第二套停机状态。
int s2a_svc_stopping(void);
void s2a_android_guest_writers_notify_stop(void) {
    atomic_fetch_add_explicit(&android_vm_serial_sequence, 1, memory_order_release);
    android_futex_wake(&android_vm_serial_sequence);
}
static void android_vm_unlock_serial(void) {
    pthread_mutex_unlock(&android_vm_serial);
    atomic_fetch_add_explicit(&android_vm_serial_sequence, 1, memory_order_release);
    android_futex_wake(&android_vm_serial_sequence);
}
static void android_vm_release(void) {
    android_vm_serial_only = 0;
    android_vm_deadline = 0;
    atomic_store(&android_vm_current_serial_only, 0);
    atomic_store(&android_vm_begin_ns, 0);
    atomic_store_explicit(&android_vm_epoch, 0, memory_order_release);
    android_futex_wake(&android_vm_epoch);
    atomic_store(&android_vm_owner, NULL);
    // Cancellation must not block behind an unrelated SVC owning G. The pins
    // remain valid until the next transaction can retire them under G.
    if (!pthread_mutex_trylock(&G)) { android_vm_unpin_locked(); pthread_mutex_unlock(&G); }
    android_vm_unlock_serial();
}
static int android_vm_lock_roster(uint64_t deadline) {
    int error;
    while ((error = pthread_mutex_trylock(&G)) == EBUSY) {
        if (plat_now_ns() >= deadline) return ETIMEDOUT;
        usleep(100);
    }
    return error;
}
// 到期证据：先在名册锁内把真实线程状态拷进线程本地快照，再释放 serial/epoch 并打日志。
// 不为了日志再等 G；拿不到名册锁就明确写 unknown，不读可能已释放的 thread。
extern int pthread_gettid_np(pthread_t) __attribute__((weak));
enum { ANDROID_VM_TIMEOUT_ROWS = 12 };
typedef struct {
    int valid, reason, error, serial_only, have_roster;
    int svc;
    uint64_t args[3];
    unsigned epoch;
    uint64_t owner_handle, owner_id;
    uint64_t started_ns, deadline_ns, expired_ns;
    size_t total, pending, omitted;
    struct {
        uint32_t handle;
        uint64_t id, tid;
        unsigned ack;
        int in_svc, off_guest, wait_safe, admission_wait, wcore, exited, closed;
        int last_svc;
        uint64_t pc, lr;
    } rows[ANDROID_VM_TIMEOUT_ROWS];
} android_vm_timeout_snapshot;
static _Thread_local android_vm_timeout_snapshot android_vm_timeout;
static void android_vm_timeout_common(int reason, int error, unsigned epoch, uint64_t started, uint64_t deadline, int roster) {
    android_vm_timeout_snapshot *snapshot = &android_vm_timeout;
    memset(snapshot, 0, sizeof *snapshot);
    snapshot->valid = 1;
    snapshot->reason = reason;
    snapshot->error = error;
    snapshot->epoch = epoch;
    snapshot->started_ns = started;
    snapshot->deadline_ns = deadline;
    snapshot->expired_ns = plat_now_ns();
    snapshot->svc = android_vm_memory_scope ? android_vm_svc_num : -1;
    if (snapshot->svc >= 0) {
        snapshot->args[0] = android_vm_svc_args[0];
        snapshot->args[1] = android_vm_svc_args[1];
        snapshot->args[2] = android_vm_svc_args[2];
    }
    if (roster) {
        thr_t *owner = atomic_load(&android_vm_owner);
        if (owner) { snapshot->owner_handle = owner->handle; snapshot->owner_id = owner->id; }
    }
    snapshot->serial_only = atomic_load(&android_vm_current_serial_only);
    snapshot->have_roster = roster;
}
static void android_vm_capture_locked(int reason, int error, unsigned epoch, uint64_t started, uint64_t deadline) {
    android_vm_timeout_snapshot *snapshot = &android_vm_timeout;
    android_vm_timeout_common(reason, error, epoch, started, deadline, 1);
    snapshot->total = android_vm_pin_count;
    size_t rows = 0, pending = 0;
    for (size_t i = 0; i < android_vm_pin_count; ++i) {
        thr_t *thread = android_vm_pins[i];
        if (android_vm_quiesced(thread, epoch)) continue;
        ++pending;
        if (rows >= ANDROID_VM_TIMEOUT_ROWS) continue;
        snapshot->rows[rows].handle = thread->handle;
        snapshot->rows[rows].id = thread->id;
        snapshot->rows[rows].tid = (uint64_t)(uintptr_t)(pthread_gettid_np ? pthread_gettid_np(thread->pt) : 0);
        snapshot->rows[rows].ack = atomic_load(&thread->vm_ack);
        snapshot->rows[rows].in_svc = atomic_load(&thread->in_svc);
        snapshot->rows[rows].off_guest = atomic_load(&thread->off_guest);
        snapshot->rows[rows].wait_safe = thread->vm_wait_safe;
        snapshot->rows[rows].admission_wait = thread->vm_admission_wait;
        snapshot->rows[rows].wcore = atomic_load(&thread->wcore);
        snapshot->rows[rows].exited = thread->exited;
        snapshot->rows[rows].closed = thread->closed;
        snapshot->rows[rows].last_svc = thread->last_svc;
        snapshot->rows[rows].pc = thread->svc_pc;
        snapshot->rows[rows].lr = thread->last_lr;
        ++rows;
    }
    snapshot->pending = pending;
    snapshot->omitted = pending - rows;
}
static void android_vm_capture_plain(int reason, int error, unsigned epoch, uint64_t started, uint64_t deadline) {
    android_vm_timeout_common(reason, error, epoch, started, deadline, 0);
}
static const char *android_vm_timeout_reason(int reason) {
    switch (reason) {
    case 1: return "serial-wait";
    case 2: return "roster-before-epoch";
    case 3: return "stop-world";
    case 4: return "roster-before-upgrade";
    case 5: return "stop-world-upgrade";
    default: return "unknown";
    }
}
static const char *android_vm_thread_state(const android_vm_timeout_snapshot *snapshot, size_t i) {
    if (snapshot->rows[i].exited) return "exited";
    if (snapshot->rows[i].off_guest) return "host-callback";
    if (snapshot->rows[i].wait_safe) return "safe-wait";
    if (snapshot->rows[i].admission_wait) return "admission-wait";
    if (snapshot->rows[i].wcore) return "waiting-core";
    if (snapshot->rows[i].in_svc) return "in-svc";
    return "guest-pc";
}
static const char *android_vm_hex_or_unknown(uint64_t value, char *buffer, size_t capacity) {
    if (!value) return "unknown";
    snprintf(buffer, capacity, "%#llx", (unsigned long long)value);
    return buffer;
}
static const char *android_vm_dec_or_unknown(uint64_t value, char *buffer, size_t capacity) {
    if (!value) return "unknown";
    snprintf(buffer, capacity, "%llu", (unsigned long long)value);
    return buffer;
}
static void android_vm_report_timeout(void) {
    android_vm_timeout_snapshot *snapshot = &android_vm_timeout;
    if (!snapshot->valid) return;
    snapshot->valid = 0;
    char svc[16];
    if (snapshot->svc >= 0) snprintf(svc, sizeof svc, "%#x", snapshot->svc);
    else snprintf(svc, sizeof svc, "unknown");
    char owner[40];
    if (snapshot->owner_handle || snapshot->owner_id)
        snprintf(owner, sizeof owner, "%#llx/%llu", (unsigned long long)snapshot->owner_handle, (unsigned long long)snapshot->owner_id);
    else snprintf(owner, sizeof owner, "unknown");
    uint64_t elapsed = snapshot->expired_ns > snapshot->started_ns ? snapshot->expired_ns - snapshot->started_ns : 0;
    uint64_t budget = snapshot->deadline_ns > snapshot->started_ns ? snapshot->deadline_ns - snapshot->started_ns : 0;
    LOG("【红】writer协调到期：svc=%s args=%#llx/%#llx/%#llx 原因=%s errno=%d epoch=%u owner=%s serial_only=%d 开始=%llu 预算=%llu 到期=%llu 现在=%llu 已等=%llu ms 未停稳=%zu/%zu 省略=%zu roster=%s",
        svc, (unsigned long long)snapshot->args[0], (unsigned long long)snapshot->args[1], (unsigned long long)snapshot->args[2],
        android_vm_timeout_reason(snapshot->reason), snapshot->error, snapshot->epoch, owner, snapshot->serial_only,
        (unsigned long long)snapshot->started_ns, (unsigned long long)budget, (unsigned long long)snapshot->deadline_ns,
        (unsigned long long)snapshot->expired_ns, (unsigned long long)(elapsed / 1000000ull), snapshot->pending,
        snapshot->total, snapshot->omitted, snapshot->have_roster ? "ok" : "unknown");
    if (!snapshot->have_roster) {
        LOG("【红】writer未停稳线程明细：unknown（未取得名册锁；不等待、不读可能已释放的 thread） callback=unknown callback_stack=unknown");
        return;
    }
    for (size_t i = 0; i < ANDROID_VM_TIMEOUT_ROWS && i < snapshot->pending; ++i) {
        char handle[24], id[24], tid[24], last_svc[24], pc[24], lr[24];
        LOG("【红】writer未停稳[%zu]：handle=%s id=%s tid=%s state=%s in_svc=%d off_guest=%d wait_safe=%d admission_wait=%d wcore=%d exited=%d closed=%d ack=%u last_svc=%s pc=%s lr=%s callback=unknown callback_stack=unknown",
            i, android_vm_hex_or_unknown(snapshot->rows[i].handle, handle, sizeof handle),
            android_vm_dec_or_unknown(snapshot->rows[i].id, id, sizeof id),
            android_vm_dec_or_unknown(snapshot->rows[i].tid, tid, sizeof tid),
            android_vm_thread_state(snapshot, i), snapshot->rows[i].in_svc, snapshot->rows[i].off_guest,
            snapshot->rows[i].wait_safe, snapshot->rows[i].admission_wait, snapshot->rows[i].wcore,
            snapshot->rows[i].exited, snapshot->rows[i].closed, snapshot->rows[i].ack,
            android_vm_hex_or_unknown((unsigned)snapshot->rows[i].last_svc, last_svc, sizeof last_svc),
            android_vm_hex_or_unknown(snapshot->rows[i].pc, pc, sizeof pc),
            android_vm_hex_or_unknown(snapshot->rows[i].lr, lr, sizeof lr));
    }
    if (!snapshot->pending)
        LOG("【红】writer未停稳线程明细：无（名册内线程均已停稳，失败在名册锁/串行锁/升级路径） callback=unknown callback_stack=unknown");
}
// The lease is the sole deadline authority. Admission keeps no idle/start/lifecycle
// cache; only epoch handoff and the unextended baseline remain local to the gate.
__attribute__((weak)) int s2a_android_host_backing_admission(unsigned writer, uint64_t *deadline);
unsigned s2a_android_guest_writers_epoch(void) { return atomic_load_explicit(&android_vm_epoch, memory_order_acquire); }
enum { ANDROID_VM_WAIT_SLICE_MS = 100 };
typedef struct { unsigned serial_epoch; int extended; } android_vm_renew_state;
static void android_vm_renew(android_vm_renew_state *state, uint64_t now, uint64_t *deadline) {
    unsigned epoch = s2a_android_guest_writers_epoch();
    if (state->serial_epoch != epoch) {
        if (state->extended) *deadline = now + 2000000000ull;
        state->serial_epoch = epoch;
    }
    if (s2a_android_host_backing_admission && s2a_android_host_backing_admission(epoch, deadline)) state->extended = 1;
}
static void android_vm_admitted(android_vm_renew_state *state, uint64_t now, uint64_t *deadline) {
    if (state->extended) *deadline = now + 2000000000ull;
}
// 仅内存SVC的锁外入口允许等待：此期间不访问guest，不调用managed，也不持虚拟核。
// G下发布专用安全态，覆盖serial已被占用但owner尚未发布epoch的窗口。
static int android_vm_wait_serial(thr_t *self, uint64_t *deadline) {
    if (!self || !android_vm_memory_scope) return EBUSY;
    core_release(self);
    android_vm_renew_state renewal = {0};
    int error = android_vm_lock_roster(*deadline);
    if (error) return error;
    self->vm_admission_wait = 1;
    pthread_mutex_unlock(&G);
    for (;;) {
        unsigned sequence = atomic_load_explicit(&android_vm_serial_sequence, memory_order_acquire);
        if (s2a_svc_stopping()) { error = ECANCELED; break; }
        error = pthread_mutex_trylock(&android_vm_serial);
        if (error != EBUSY) {
            // Admission is over. Roster/quiescence belongs to our new writer, not the
            // previous owner's paused/progress budget. False retains its original deadline.
            if (!error) android_vm_admitted(&renewal, plat_now_ns(), deadline);
            break;
        }
        uint64_t now = plat_now_ns();
        android_vm_renew(&renewal, now, deadline);
        if (now >= *deadline) { error = ETIMEDOUT; break; }
        uint64_t remaining = *deadline - now;
        if (remaining > ANDROID_VM_WAIT_SLICE_MS * 1000000ull) remaining = ANDROID_VM_WAIT_SLICE_MS * 1000000ull;   // 按片醒来看推进
        struct timespec wait = {(time_t)(remaining / 1000000000ull), (long)(remaining % 1000000000ull)};
        if (syscall(SYS_futex, &android_vm_serial_sequence, FUTEX_WAIT_PRIVATE, sequence, &wait, NULL, 0)
            && errno != EAGAIN && errno != EINTR && errno != ETIMEDOUT) { error = errno; break; }
    }
    if (error) {
        glock(); self->vm_admission_wait = 0; pthread_mutex_unlock(&G);
        // 撤销安全承诺后不能穿过仍活动的epoch；此处尚未重取虚拟核。
        android_vm_barrier(self);
    }
    return error;
}
static int android_vm_acquire_serial(thr_t *self, uint64_t *deadline) {
    int error = pthread_mutex_trylock(&android_vm_serial);
    if (error == EBUSY) error = android_vm_wait_serial(self, deadline);
    return error;
}
// 持 G 调：该线程已停稳（退出、在登记过的安全等待 / 准入等待里、在等虚拟核、或已在本 epoch 的 guest 指令边界停车）
static int android_vm_quiesced(thr_t *thread, unsigned epoch) {
    return thread->exited || thread->vm_wait_safe || thread->vm_admission_wait
        || atomic_load(&thread->wcore) || atomic_load(&thread->vm_ack) == epoch;
}
// 持 G 调：发布唯一 epoch；pin=1 还是全体停稳事务，pin=0 是 0x2C 空页增页的只串行事务。
static int android_vm_publish_locked(thr_t *self, int pin, uint64_t started, unsigned *epoch_out) {
    android_vm_unpin_locked();
    unsigned epoch = ++android_vm_sequence;
    if (!epoch) epoch = ++android_vm_sequence;
    atomic_store(&android_vm_owner, self);
    atomic_store(&android_vm_begin_ns, started);
    atomic_store_explicit(&android_vm_epoch, epoch, memory_order_release);
    atomic_store(&android_vm_current_serial_only, pin ? 0 : 1);
    *epoch_out = epoch;
    if (!pin) return 0;
    for (thr_t *thread = g_all; thread; thread = thread->all) {
        if (thread == self || thread->exited || !thread->pt) continue;
        if (android_vm_pin_count == ANDROID_VM_MAX_THREADS) return E2BIG;
        ++thread->pins;
        android_vm_pins[android_vm_pin_count++] = thread;
    }
    return 0;
}
// 名册已 pin、G 已放：等到全体停稳或唯一预算到期。到期时在 G 内抓真实线程状态，再交给调用方清 epoch。
static int android_vm_wait_census(unsigned epoch, uint64_t started, uint64_t deadline, int reason) {
    for (;;) {
        int error = android_vm_lock_roster(deadline);
        if (error) {
            android_vm_capture_plain(reason, error, epoch, started, deadline);
            return error;
        }
        if (plat_now_ns() >= deadline) {
            android_vm_capture_locked(reason, ETIMEDOUT, epoch, started, deadline);
            pthread_mutex_unlock(&G);
            return ETIMEDOUT;
        }
        int complete = 1;
        for (size_t i = 0; i < android_vm_pin_count; ++i) {
            thr_t *thread = android_vm_pins[i];
            if (android_vm_quiesced(thread, epoch)) continue;
            complete = 0;
            // No arbitrary suspend: the handler will park only a guest PC,
            // outside SVC / native callbacks. Host lock owners keep progressing.
            int sent = pthread_kill(thread->pt, SIGURG);
            if (sent && sent != ESRCH) { error = sent; break; }
        }
        if (error) {
            android_vm_capture_locked(reason, error, epoch, started, deadline);
            pthread_mutex_unlock(&G);
            return error;
        }
        pthread_mutex_unlock(&G);
        if (complete) return 0;
        usleep(100);
    }
}
int s2a_android_guest_writers_begin(void) {
    if (!s2a_android_guest_writers_ready()) return ENOTSUP;
    if (android_vm_memory_scope && s2a_svc_stopping()) return ECANCELED;
    if (android_vm_active || android_vm_beginning || s2a_android_fault_thread_active()) return EDEADLK;
    android_vm_beginning = 1;
    android_vm_revoked = 0;
    thr_t *self = thread_current_or_null();
    uint64_t started = plat_now_ns(), deadline = started + 2000000000ull;
    int error = android_vm_acquire_serial(self, &deadline);
    if (error) {
        android_vm_beginning = 0;
        if (error == ETIMEDOUT) {
            android_vm_capture_plain(1, error, 0, started, deadline);
            android_vm_report_timeout();
        }
        return error;
    }
    error = android_vm_lock_roster(deadline);
    if (error) {
        if (self && self->vm_admission_wait) {
            glock(); self->vm_admission_wait = 0; pthread_mutex_unlock(&G);
        }
        android_vm_beginning = 0; android_vm_unlock_serial();
        android_vm_capture_plain(2, error, 0, started, deadline);
        android_vm_report_timeout();
        return error;
    }
    if (self) self->vm_admission_wait = 0;
    if (android_vm_memory_scope && s2a_svc_stopping()) {
        pthread_mutex_unlock(&G); android_vm_beginning = 0; android_vm_unlock_serial(); return ECANCELED;
    }
    unsigned epoch = 0;
    error = android_vm_publish_locked(self, 1, started, &epoch);
    pthread_mutex_unlock(&G);
    if (!error) error = android_vm_wait_census(epoch, started, deadline, 3);
    android_vm_beginning = 0;
    if (error) {
        android_vm_release();
        android_vm_report_timeout();
        return error;
    }
    android_vm_deadline = deadline;
    android_vm_serial_only = 0;
    android_vm_active = 1;
    return 0;
}
// 只给已证明是“向全空宿主页增加新零页”的 0x2C 使用。串行锁与 epoch 照旧发布，
// 但不等其他 writer 停稳；随后由 svc_mem.c 在映射表锁内复核，条件不再成立就升级停世界。
int s2a_android_guest_writers_begin_serial(void) {
    if (!s2a_android_guest_writers_ready()) return ENOTSUP;
    if (android_vm_memory_scope && s2a_svc_stopping()) return ECANCELED;
    if (android_vm_active || android_vm_beginning || s2a_android_fault_thread_active()) return EDEADLK;
    android_vm_beginning = 1;
    android_vm_revoked = 0;
    thr_t *self = thread_current_or_null();
    uint64_t started = plat_now_ns(), deadline = started + 2000000000ull;
    int error = android_vm_acquire_serial(self, &deadline);
    if (error) {
        android_vm_beginning = 0;
        if (error == ETIMEDOUT) {
            android_vm_capture_plain(1, error, 0, started, deadline);
            android_vm_report_timeout();
        }
        return error;
    }
    error = android_vm_lock_roster(deadline);
    if (error) {
        if (self && self->vm_admission_wait) {
            glock(); self->vm_admission_wait = 0; pthread_mutex_unlock(&G);
        }
        android_vm_beginning = 0; android_vm_unlock_serial();
        android_vm_capture_plain(2, error, 0, started, deadline);
        android_vm_report_timeout();
        return error;
    }
    if (self) self->vm_admission_wait = 0;
    if (android_vm_memory_scope && s2a_svc_stopping()) {
        pthread_mutex_unlock(&G); android_vm_beginning = 0; android_vm_unlock_serial(); return ECANCELED;
    }
    unsigned epoch = 0;
    error = android_vm_publish_locked(self, 0, started, &epoch);
    pthread_mutex_unlock(&G);
    android_vm_beginning = 0;
    if (error) { android_vm_release(); return error; }
    android_vm_deadline = deadline;
    android_vm_serial_only = 1;
    android_vm_active = 1;
    return 0;
}
int s2a_android_guest_writers_serial_only(void) { return android_vm_serial_only; }
// 只串行事务发现条件不成立（预检后别的改表先把页/邻居占上）时升级。成功保留 serial/epoch，
// 调用方继续原来的映射事务；失败（名册锁或停世界到期）已撤销 serial/epoch，调用方必须终止。
int s2a_android_guest_writers_quiesce(void) {
    if (!android_vm_active || !android_vm_serial_only) return EINVAL;
    thr_t *self = thread_current_or_null();
    unsigned epoch = s2a_android_guest_writers_epoch();
    uint64_t started = atomic_load(&android_vm_begin_ns);
    uint64_t deadline = android_vm_deadline ? android_vm_deadline : plat_now_ns() + 2000000000ull;
    if (!started) started = plat_now_ns();
    if (!epoch) {
        android_vm_active = 0; android_vm_serial_only = 0; android_vm_release();
        return EINVAL;
    }
    int error = android_vm_lock_roster(deadline);
    if (error) {
        android_vm_capture_plain(4, error, epoch, started, deadline);
        android_vm_active = 0; android_vm_serial_only = 0; android_vm_revoked = 1; android_vm_release();
        android_vm_report_timeout();
        return error;
    }
    if (self) self->vm_admission_wait = 0;
    if (android_vm_memory_scope && s2a_svc_stopping()) {
        pthread_mutex_unlock(&G);
        android_vm_active = 0; android_vm_serial_only = 0; android_vm_release();
        return ECANCELED;
    }
    android_vm_unpin_locked();
    int pin_error = 0;
    for (thr_t *thread = g_all; thread; thread = thread->all) {
        if (thread == self || thread->exited || !thread->pt) continue;
        if (android_vm_pin_count == ANDROID_VM_MAX_THREADS) { pin_error = E2BIG; break; }
        ++thread->pins;
        android_vm_pins[android_vm_pin_count++] = thread;
    }
    pthread_mutex_unlock(&G);
    if (pin_error) {
        android_vm_active = 0; android_vm_serial_only = 0; android_vm_revoked = 1; android_vm_release();
        return pin_error;
    }
    error = android_vm_wait_census(epoch, started, deadline, 5);
    if (error) {
        android_vm_active = 0; android_vm_serial_only = 0; android_vm_revoked = 1; android_vm_release();
        android_vm_report_timeout();
        return error;
    }
    android_vm_serial_only = 0;
    atomic_store(&android_vm_current_serial_only, 0);
    return 0;
}
// Terminal shutdown can originate inside ExitProcess/Break's memory SVC.
// That SVC will never return to the guest. The memory-SVC cancellation rule is
// for transactions that may resume, not the terminal owner acquiring the
// shutdown epoch after the SVC gate has closed. Keep all active/fault checks
// in the ordinary writer entry and restore the scope on every return.
int s2a_android_guest_shutdown_writers_begin(void) {
    if (!s2a_svc_stopping()) return EINVAL;
    int scope = android_vm_memory_scope;
    android_vm_memory_scope = 0;
    int error = s2a_android_guest_writers_begin();
    android_vm_memory_scope = scope;
    return error;
}
// 诊断（收局进度线程每 250 ms 调）：正在进行的 writer epoch 里还没停稳的 guest 线程。只 trylock 名册锁 G，拿不到就说拿不到、不等
// （发起方可能正持着它扫名册）；读到的是快照，只用于日志。未停稳 = 不在 guest 指令边界停车、也不在登记过的安全等待里：
// 在系统调用里（还没回到门口）、在宿主侧回调里（写跟踪 / IPC，进了 C#）、或在游戏代码里还没响应停车信号。
void s2a_android_guest_writers_describe(char *out, size_t cap) {
    unsigned epoch = atomic_load_explicit(&android_vm_epoch, memory_order_acquire);
    if (!epoch) { snprintf(out, cap, "没有进行中的 writer epoch"); return; }
    if (pthread_mutex_trylock(&G)) { snprintf(out, cap, "writer epoch %u 进行中，名册锁被占用（这一拍不读）", epoch); return; }
    uint64_t begun = atomic_load(&android_vm_begin_ns);
    if (atomic_load(&android_vm_current_serial_only)) {
        snprintf(out, cap, "writer epoch %u 只串行（0x2C 全空宿主页增页）已 %llu ms；未停世界，无停稳名册",
            epoch, (unsigned long long)(begun ? (plat_now_ns() - begun) / 1000000ull : 0));
        pthread_mutex_unlock(&G);
        return;
    }
    size_t used = 0, pending = 0;
    int n = snprintf(out, cap, "writer epoch %u 已 %llu ms", epoch,
        (unsigned long long)(begun ? (plat_now_ns() - begun) / 1000000ull : 0));
    if (n > 0) used = (size_t)n < cap ? (size_t)n : cap - 1;
    for (size_t i = 0; i < android_vm_pin_count; ++i) {
        thr_t *thread = android_vm_pins[i];
        if (android_vm_quiesced(thread, epoch)) continue;
        if (++pending > 6 || used + 1 >= cap) continue;
        const char *where = atomic_load(&thread->off_guest) ? "在宿主侧回调里（写跟踪 / IPC）"
            : atomic_load(&thread->in_svc) ? "在系统调用里" : "在游戏代码里（停车信号还没响应）";
        n = snprintf(out + used, cap - used, "；句柄 %#x %s（最近系统调用 %#x）", thread->handle, where, (unsigned)thread->last_svc);
        if (n > 0) used += (size_t)n < cap - used ? (size_t)n : cap - used - 1;
    }
    if (used + 1 < cap) snprintf(out + used, cap - used, "；未停稳 %zu / %zu", pending, android_vm_pin_count);
    pthread_mutex_unlock(&G);
}

void s2a_android_guest_writers_end(void) {
    // 收尾必须严格一一对应：被撤销的事务由调用方按 s2a_android_guest_writers_revoked() 判断后
    // 重新准入，绝不在这里静默放行（那会把“撤销了还在改表”掩盖成正常收尾）。
    if (!android_vm_active)
        die("Android VM writer end 没有同线程 begin（已被撤销的事务不能二次收尾，revoked=%d）", android_vm_revoked);
    android_vm_active = 0;
    android_vm_revoked = 0;
    android_vm_release();
}
int s2a_android_guest_writers_revoked(void) { return android_vm_revoked; }

// Shutdown owner only, around a bounded host-state wait (Vulkan admitted drain)
// that precedes any terminal epoch. The owner may itself be a guest thread
// (ExitProcess / Break): while waiting it touches no guest memory, so publish
// census-safe and free its virtual core for the frames being drained. End
// revokes under G and passes the VM barrier before any later guest access.
static _Thread_local int android_host_wait_core;
void s2a_android_guest_host_wait_begin(void) {
    thr_t *thread = pthread_getspecific(g_keythr);
    if (!thread) return;
    android_host_wait_core = atomic_load(&thread->held_core) != 0;
    if (android_host_wait_core) core_release(thread);
    glock(); thread->vm_wait_safe = 1; pthread_mutex_unlock(&G);
}
void s2a_android_guest_host_wait_end(void) {
    thr_t *thread = pthread_getspecific(g_keythr);
    if (!thread) return;
    glock(); thread->vm_wait_safe = 0; pthread_mutex_unlock(&G);
    if (android_host_wait_core) core_acquire(thread); // includes android_vm_barrier
    else android_vm_barrier(thread);
    android_host_wait_core = 0;
}

// 宿主侧长工作里的自愿安全点：客体线程在一次原生调用里连续跑很久（图形回放一次提交可达数秒），
// 这期间它在宿主 PC 上，SIGURG 不应答，停世界只能等到它返回客体，2 秒预算会到期。
// 调用方保证此刻不持 G / VM / tracker 锁，且两次调用之间对客体内存的访问已经成对结束；
// 有 epoch 时在这里按当前 epoch 停驻（同正常返回屏障），没有 epoch 只是一次原子读。非客体线程是空操作。
void s2a_android_guest_host_safepoint(void) {
    if (!atomic_load_explicit(&android_vm_epoch, memory_order_acquire)) return;
    android_vm_barrier(pthread_getspecific(g_keythr));
}

// Called only by gate.c's terminal shutdown park, never by a live native
// callback. Once published this pthread may not access guest memory again.
_Noreturn void s2a_android_guest_park_forever(void) {
    thr_t *thread = thread_current_or_null();
    if (thread) {
        core_release(thread);
        glock(); thread->vm_wait_safe = 1; pthread_mutex_unlock(&G);
    }
    for (;;) pause();
}
