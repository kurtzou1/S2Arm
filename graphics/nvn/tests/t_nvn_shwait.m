// 等别的线程在建的着色器时把等待者的急迫度借给建造者（nvn_mtl.m flight_wait_locked，11-02 GTA III：游戏渲染线程在 shader_load_depth 里干等
//   后台预取队列 dm.nvn.sh-pre（QOS_CLASS_BACKGROUND）上一支卡在读库缺页的着色器，超过 10 秒，UE 挂死看门狗故意崩溃；dispatch group 没有属主，系统不做优先级继承）。
// 直接包含生产 nvn_mtl.m，调生产函数 flight_wait_locked。建造者 = BACKGROUND 队列上的线程，在等待开始前、等待中各读一次自己线程的基础调度优先级（THREAD_EXTENDED_INFO pth_priority，含借来的 override；不读随负载衰减的 pth_curpri）。
// 期望（按 Darwin QoS 档位手写，与被测实现无关）：BACKGROUND 基础优先级 4；显式覆盖 pthread_override_qos_class_start_np 在本机实测封顶 DEFAULT（31：要 USER_INITIATED /
//   USER_INTERACTIVE 都得 31，要 UTILITY 得 20，11-02 独立小程序量）。DEFAULT 已出后台档的 CPU 与 I/O 节流（节流 I/O 档只给 BACKGROUND / UTILITY），10 秒卡的正是节流
//   ① 登记了建造者（生产路径 shader_load_depth 建 flight 时记 pthread_self）→ 等待中建造者优先级 ≥ 31（借到了、出了后台档），等待前 ≤ 20（确实是后台档）
//   ② 没登记建造者（= 改前：dispatch_group_wait 干等，没人可借）→ 等待中仍 ≤ 20（反证：夹具真能测出没借到的情形）
#include "../gfx/nvn/nvn_mtl.m"
#include <mach/mach.h>
static unsigned checks, fails;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static int curpri(void) {
    thread_extended_info_data_t i; mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT; mach_port_t t = mach_thread_self();
    kern_return_t r = thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&i, &n); mach_port_deallocate(mach_task_self(), t);
    // 读基础优先级 pth_priority（QoS 档与借来的 override 都落在这上面），不读 pth_curpri：分时线程的当前优先级随占用 CPU 衰减，
    //   负载高时 override 已生效也会读到 31 衰减后的 20（11-21 门禁 ① 假红）；判据要问的是「借到没有」，不是此刻调度器给了几
    return r == KERN_SUCCESS ? i.pth_priority : -1;
}
static void one(int register_builder, int *before, int *during) {
    dispatch_queue_t q = dispatch_queue_create("t.shwait.bg", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0));
    dispatch_semaphore_t ready = dispatch_semaphore_create(0), go = dispatch_semaphore_create(0);
    ShaderFlight *f = [ShaderFlight new]; f->done = dispatch_group_create(); dispatch_group_enter(f->done);
    __block int b0 = -1, b1 = -1;
    dispatch_async(q, ^{
        if (register_builder) f->builder = pthread_self();
        os_unfair_lock_lock(&g_shader_lock); if (!g_shader_flights) g_shader_flights = [NSMutableDictionary dictionary]; g_shader_flights[@"t"] = f; os_unfair_lock_unlock(&g_shader_lock);
        b0 = curpri(); dispatch_semaphore_signal(ready);
        dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
        // 等到等待者真进了 flight_wait_locked 再读：生产函数先借优先级（override）、再解 g_shader_lock，故拿得到锁 = 借这一步已做完（或 ② 根本没借）。
        //   原先固定睡 100 ms 当「已进去」，负载高时等待者还没跑到 → ① 读到后台档、假红（11-19 门禁）。按事件等，外面 alarm(30) 兜底
        while (!os_unfair_lock_trylock(&g_shader_lock)) usleep(1000);
        os_unfair_lock_unlock(&g_shader_lock);
        b1 = curpri();
        os_unfair_lock_lock(&g_shader_lock); [g_shader_flights removeObjectForKey:@"t"]; dispatch_group_leave(f->done); os_unfair_lock_unlock(&g_shader_lock);
    });
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    os_unfair_lock_lock(&g_shader_lock); dispatch_semaphore_signal(go);
    (void)flight_wait_locked(f);   // 生产函数：持锁进入、内部解锁
    *before = b0; *during = b1;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(30);
    int b0, b1; one(1, &b0, &b1);
    VERIFY(b0 >= 0 && b0 <= 20 && b1 >= 31, "① 登记了建造者：建造者优先级 等待前 %d（期望 ≤ 20，后台档）→ 等待中 %d（期望 ≥ 31，借到 DEFAULT、出了节流档）", b0, b1);
    one(0, &b0, &b1);
    VERIFY(b0 >= 0 && b0 <= 20 && b1 >= 0 && b1 <= 20, "② 反证 没登记建造者（改前干等）：等待中 %d（期望 ≤ 20，没借到）", b1);
    printf("%s t_nvn_shwait：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
