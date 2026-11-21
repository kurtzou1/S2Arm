// 通过完整生产 bootstrap / 注册节 / 计数跳板验证 CommandBuffer 回调查询。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks;
static const char *query, *phase;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL %s [%s] %s:%d：%s\n", query, phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name);
    CHECK(entry != NULL);
    return entry;
}
#define API(name) ((NVNT_##name)load(#name))
#define GUARD UINT64_C(0xc53a709df28b146e)
typedef struct { uint64_t pre[2]; NVNcommandBuffer object; uint64_t post[2]; } guarded_command;
typedef struct {
    NVNcommandBuffer *command;
    NVNmemoryPool *pool;
    ptrdiff_t offset;
    size_t size;
    unsigned calls, kind;
} allocation;

static void provide_memory(NVNcommandBuffer *command, NVNcommandBufferMemoryEvent event, size_t size, allocation *a, unsigned kind) {
    CHECK(command == a->command);
    CHECK(event == NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY);
    CHECK(size <= a->size);
    CHECK(kind == a->kind);
    a->calls++;
    API(nvnCommandBufferAddCommandMemory)(command, a->pool, a->offset, a->size);
}
static void callback_a(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent event, size_t size, void *data) { provide_memory(c, event, size, data, 1); }
static void callback_b(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent event, size_t size, void *data) { provide_memory(c, event, size, data, 2); }

static void boundary(const guarded_command *box) {
    CHECK(box->pre[0] == GUARD && box->pre[1] == GUARD);
    CHECK(box->post[0] == GUARD && box->post[1] == GUARD);
}
static void read_query(guarded_command *box, PFNNVNCOMMANDBUFFERMEMORYCALLBACKPROC callback, void *data, const allocation *a, const allocation *b) {
    NVNcommandBuffer before = box->object;
    size_t used = API(nvnCommandBufferGetCommandMemoryUsed)(&box->object);
    unsigned a_calls = a->calls, b_calls = b->calls;
    if (!strcmp(query, "nvnCommandBufferGetMemoryCallback")) CHECK(API(nvnCommandBufferGetMemoryCallback)(&box->object) == callback);
    else CHECK(API(nvnCommandBufferGetMemoryCallbackData)(&box->object) == data);
    CHECK(memcmp(&before, &box->object, sizeof before) == 0);
    CHECK(API(nvnCommandBufferGetCommandMemoryUsed)(&box->object) == used);
    CHECK(a->calls == a_calls && b->calls == b_calls);
    boundary(box);
}
static void exercise(const char *name, NVNdevice *device, NVNmemoryPool *pool, size_t page) {
    query = name; phase = "初始化";
    guarded_command first = { {GUARD, GUARD}, {{0}}, {GUARD, GUARD} };
    guarded_command second = { {GUARD, GUARD}, {{0}}, {GUARD, GUARD} };
    allocation a = { &first.object, pool, 0, page, 0, 1 };
    allocation b = { &second.object, pool, (ptrdiff_t)page, page, 0, 2 };
    CHECK(API(nvnCommandBufferInitialize)(&first.object, device));
    CHECK(API(nvnCommandBufferInitialize)(&second.object, device));
    read_query(&first, NULL, NULL, &a, &b);
    read_query(&second, NULL, NULL, &a, &b);

    phase = "Set/Get 与多对象";
    API(nvnCommandBufferSetMemoryCallback)(&first.object, callback_a);
    API(nvnCommandBufferSetMemoryCallbackData)(&first.object, &a);
    API(nvnCommandBufferSetMemoryCallback)(&second.object, callback_b);
    API(nvnCommandBufferSetMemoryCallbackData)(&second.object, &b);
    read_query(&first, callback_a, &a, &a, &b);
    read_query(&second, callback_b, &b, &a, &b);
    CHECK(a.calls == 0 && b.calls == 0);

    phase = "真实内存回调与 Begin/End 保留";
    // 每条录制录一笔要命令内存的命令（屏障，8 字节）触发回调：EndRecording 按驱动真值不占命令内存（#1904），空录制不再要内存、不回调
    API(nvnCommandBufferBeginRecording)(&first.object);
    read_query(&first, callback_a, &a, &a, &b);
    API(nvnCommandBufferBarrier)(&first.object, 0);
    CHECK(API(nvnCommandBufferEndRecording)(&first.object) != 0);
    CHECK(a.calls == 1 && b.calls == 0);
    read_query(&first, callback_a, &a, &a, &b);
    API(nvnCommandBufferBeginRecording)(&second.object);
    API(nvnCommandBufferBarrier)(&second.object, 0);
    CHECK(API(nvnCommandBufferEndRecording)(&second.object) != 0);
    CHECK(a.calls == 1 && b.calls == 1);
    read_query(&second, callback_b, &b, &a, &b);
    API(nvnCommandBufferBeginRecording)(&first.object);
    read_query(&first, callback_a, &a, &a, &b);
    CHECK(API(nvnCommandBufferEndRecording)(&first.object) != 0);
    CHECK(a.calls == 1 && b.calls == 1);
    read_query(&first, callback_a, &a, &a, &b);

    phase = "独立替换与清空";
    API(nvnCommandBufferSetMemoryCallback)(&first.object, callback_b);
    read_query(&first, callback_b, &a, &a, &b);
    allocation replacement = { &first.object, pool, 0, page, 0, 2 };
    API(nvnCommandBufferSetMemoryCallbackData)(&first.object, &replacement);
    read_query(&first, callback_b, &replacement, &replacement, &b);
    API(nvnCommandBufferSetMemoryCallbackData)(&first.object, NULL);
    read_query(&first, callback_b, NULL, &replacement, &b);
    API(nvnCommandBufferSetMemoryCallbackData)(&first.object, &replacement);
    read_query(&second, callback_b, &b, &a, &b);
    API(nvnCommandBufferSetMemoryCallback)(&first.object, NULL);
    read_query(&first, NULL, &replacement, &a, &b);
    API(nvnCommandBufferSetMemoryCallbackData)(&first.object, NULL);
    read_query(&first, NULL, NULL, &a, &b);

    phase = "Finalize 后重建";
    API(nvnCommandBufferFinalize)(&second.object);
    CHECK(API(nvnCommandBufferInitialize)(&second.object, device));
    read_query(&second, NULL, NULL, &a, &b);
    read_query(&first, NULL, NULL, &a, &b);
    API(nvnCommandBufferFinalize)(&first.object);
    API(nvnCommandBufferFinalize)(&second.object);
    boundary(&first); boundary(&second);
    printf("%s：通过\n", query);
}
int main(int argc, char **argv) {
    const char *names[] = { "nvnCommandBufferGetMemoryCallback", "nvnCommandBufferGetMemoryCallbackData" };
    if (argc > 2 || (argc == 2 && strcmp(argv[1], names[0]) && strcmp(argv[1], names[1]))) {
        fprintf(stderr, "用法：%s [完整查询函数名]\n", argv[0]); return 2;
    }
    query = "准备真实内存池"; phase = "初始化";
    NVNdevice device = {{0}};
    NVNdeviceBuilder device_builder = {{0}};
    NVNmemoryPoolBuilder builder = {{0}};
    NVNmemoryPool pool = {{0}};
    size_t page = (size_t)getpagesize();
    void *storage = NULL;
    CHECK(posix_memalign(&storage, page, page * 2) == 0);
    memset(storage, 0, page * 2);
    API(nvnDeviceBuilderSetDefaults)(&device_builder);
    CHECK(API(nvnDeviceInitialize)(&device, &device_builder));
    API(nvnMemoryPoolBuilderSetDefaults)(&builder);
    API(nvnMemoryPoolBuilderSetDevice)(&builder, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&builder, storage, page * 2);
    API(nvnMemoryPoolBuilderSetFlags)(&builder, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    CHECK(API(nvnMemoryPoolInitialize)(&pool, &builder));
    for (unsigned i = 0; i < 2; i++) if (argc == 1 || !strcmp(argv[1], names[i])) exercise(names[i], &device, &pool, page);
    API(nvnMemoryPoolFinalize)(&pool);
    API(nvnDeviceFinalize)(&device);
    free(storage);
    printf("✓ t_nvn_d：%u 个真实 API 断言\n", checks);
    return 0;
}
