# Android AArch64 缺页改道与 guest writer 暂停

这里复用 `thread.c` 的真实线程表、`crash.c` 的唯一 dispatcher 和 `xstack.c` 的宿主栈。新增代码不另建线程调度器，也不在信号中调用 C#。源码、隔离 host 验证、Android 链接、NativeAOT/设备与游戏验收是不同状态。

## 启动和回调合同

1. loader/内存初始化后、Services Start 前调用 `s2a_android_guest_writers_init`。它初始化真实 thread TSD keys，并检查 SIGURG 未被其他 handler 占用才安装 ONSTACK handler；失败必须阻止进入 guest。`writers_ready` 还检查当前实际 handler，没有用符号存在代替安装。
2. 唯一 crash owner 安装实际 SEG/BUS/TRAP 等 handler 后才发布 `dispatch_installed`。每个 guest pthread 在正常上下文预分配完整保存区/备用栈，登记真实宿主 pthread xstack。main 必须先进入同一线程表；child 的入口屏障在写 guest TLS 之前。
3. 同一 guest pthread 经统一 runtime hook 实际附着托管运行时，再调用 `fault_probe`。探针通过当前真实 handler 链，以明确探针 PC/私有受保护页触发 SEG→宿主栈正常上下文→BRK→原指令；同时核验当前备用栈，允许 NativeAOT 合法链式 handler 和附着时更换备用栈。只有成功才发布最终 `dispatch_ready`。探针不冒充 GPU/managed readback。
4. 正常缺页只按真实模块 PC 和 ESR data-abort WnR 判断。tracker 0 未处理、1 重试、2 必须改道；负值/无法保存完整上下文必须失败，不能回退解保护。
5. 复制全部 GPR/SP/PC/PSTATE、信号 mask、内联扩展区；同 pthread 真实宿主 xstack 上执行 `core_leave → track_touch → core_enter`，精确 BRK 经同 dispatcher 恢复原指令和 cursor。SIGURG 正常调度也复用此完整保存/恢复机制。回调期间不持 adapter 锁。
6. Android full-readback 始终传 `skip=0`。tracker/managed owner 必须完成读回与保护转换；错误同步终止，不能用旧地址 skip 忽略新的 GPU 脏世代。缺少/重复/越界 FPSIMD、未知记录、外置 `extra_context`、阻塞 SIGTRAP 均拒绝。内联 SVE 随完整帧复制；SME/外置 SVE 尚不支持。

## VM 和关停暂停

`writers_begin()` 成功返回 0，失败返回 errno；调用者不得持有线程表、VM、tracker 或 GPU 锁。当前正常上下文 owner 可为 guest SVC 或普通 host pthread；fault/trampoline 回调内调用返回 EDEADLK。并发 owner 返回 EBUSY，调用者必须取消该次改映射；不允许继续写。

真实线程表 under-G census 持有 metadata pins。只接受：已退出、明确的条件等待/终止等待、实际等虚拟核，或当前 epoch 的 guest-PC SIGURG ack。`in_svc` / `off_guest` 本身不是安全证明：持宿主锁的线程继续运行，直到正常返回屏障。条件等待醒来、核等待结束、新线程初始化、SVC/读回返回均检查 epoch，不能在 owner 改页期间恢复 guest 写。

2 秒的 census/线程表锁预算到期时撤销 epoch、唤醒已停 guest 并返回失败；没有后台等待线程。取消/结束不在 G 后无限阻塞：若 G 此刻忙，metadata pins 留到下一次成功取得 G 时回收，最多保留上一批线程 metadata，不保留活动 guest 执行权。owner 需成对 `writers_end()`；不得跨 pthread 或嵌套。

关停消费者必须先取消等待、排空托管 SVC，再成功 begin，并保持 epoch 到进程退出，不调用 end 后再 Dispose。`gate.c` 的 Android terminal park 显式声明永不再访问 guest 内存；不能把任意 off_guest 回调这样处理。未停稳/仍在 Touch/超时不允许 Dispose，交给实际关停 watchdog 非零退出。零 guest 也发布 epoch，从而挡住后来的入口。

Apple 原 dispatcher/touch 路径保持；Android 不链接 Mach 的 touch/alias/emul/diag_brk 优化对象。`elf_host.c` 只查询实际加载 ELF 的可执行 PT_LOAD 区间用于已有 host-entry 判断，不是另一个 loader。

## 隔离验证入口

```sh
python3 android/native/runtime/fault/tests/run.py --out /tmp/fault-host
python3 android/native/runtime/fault/tests/run_thread.py --out /tmp/thread-host
python3 android/native/runtime/fault/tests/run_objects.py --out /tmp/fault-ndk --cc /path/to/aarch64-linux-android34-clang
```

前两个需要原生 Linux ARM64；输出必须在 checkout 外。runner 保存 SHA、实际命令和原始输出，变异仅写私有副本。`run.py` 检查真实 SEG/TRAP/rt_sigreturn、32 SIMD、FPCR/FPSR、GPR、112B redzone、cursor 和 final probe；缺失 q0/cursor/probe 路由必须报红。

`run_thread.py` 直接编译生产 thread/crash/xstack/fault，使用真实 pthread、保护页、信号与不同 guest 栈，虚拟核开/关分别验证。包括真实 Touch 阻塞排空、owner 重入拒绝、guest 写循环停止/恢复、SetThreadActivity/context、条件醒来、新入口、ExitThread pin 退休、持 G/回调超时和撤销后继续；错误 off_guest ack、删等待返回屏障、删真实 thread_bind_host 入口屏障均须报红。

该 fixture 的模块 PC 范围、TSD offset、TLR 分配器及 tracker callback 是明确提供者，不验证 Bionic 的 TSD 快速汇编、真实 managed/GPU 读回。NDK runner 只编译真实 Bionic API34 对象，不运行 Android；gate.c 的既有六处 uint64_t/%llx 警告单独记录，未放宽其余对象。仍需总装 `-z defs`、真正 NativeAOT 附着/handler 链、设备 self-probe 和首游戏验证，不能据 host 测试宣称 game_ready。
