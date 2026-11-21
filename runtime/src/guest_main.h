// 原生层内部组合接口，不属于托管 s2a_native ABI。
#pragma once
#include <stdint.h>
#include <stdatomic.h>
struct s2a_guest_main_args {
    uint64_t stack_top;
    int argc;
    char **argv;
#if defined(__APPLE__) && (!defined(__ANDROID__) && !defined(__OHOS__))
    _Atomic int entered;
#endif
};
// 在独立宿主 pthread 上运行。args / argv 由调用方保有到线程退出。
// 使用真实 thread / xstack / det 实现与共享 SDK 初始化顺序。
void *s2a_guest_main(void *args);
