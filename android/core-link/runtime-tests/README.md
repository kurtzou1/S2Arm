# Android runtime 组合层 host 验证

运行 `python3 android/core-link/runtime-tests/run.py --out <独立产物目录>`。

直接编译生产 `native/runtime/runtime.c` 和共享 `runtime/src/guest_main.c`，测试端仅提供显式合成的 core/SDK/服务端点。25 个独立进程验证同一真实消费者的启动顺序、错误服务状态/身份/版本、停止请求、未解析导入、错 NPDM 身份和缺 SDK 导出等边界；额外变异负控删除生产 Ready 检查，应被 `false-ready` 用例拒绝。独立 argv 用例验证 Apple 调用方仍能传显式参数；Android 不覆盖 SDK 的默认 argv。

这些用例不执行改写 guest、不切真实 guest 栈，也不验证 VM、Bionic TLS/信号、Vulkan 或退出清场。合成 provider 仅存在于本测试程序，不能链接 APK。`runtime/src/host_main.c` 已调用同一 `s2a_guest_main` 入口；没有第二份 Android SDK 初始化序列。

## root 集成接点

`core-link/Runtime.cmake` 的 `s2a_add_android_runtime_objects(target)` 生成组合层与共享 guest 入口的实际对象。`s2a_add_android_native_core_objects(target)` 列出当前真实 native core 源码（排除 Apple `main`）；它是明确的编译输入，不是成功能力清单。Android 宿主还须链接自己的 `plat_android` / Bionic TSD / signal / HostApi 与真正 managed services。任何缺符号应由最终 `-z defs` 拒绝，不能添加 diagnostic stub 或假 Mach 头补链接。

Shell 的单一 boot worker 调 `s2a_android_runtime_run`，并把已有冻结 BootSpec 对应的 只读 APK module_source/已验 npdm_path（目录模式用于 host）、有序模块列表、NPDM program_id、game/state 路径、同 DSO owner、HostApi、W6 lease 提供给它。所有宿主对象须保活到进程退出。状态查询及 stop 只针对同 session；单进程不支持二次启动。服务 start 的 `0 + Ready + 同 session + error=0` 只证明服务/GPU准备完毕。每条真实guest pthread仍须在host xstack就绪后，由同一个runtime入口强引用真实managed attach、同线程fault self-probe和final tracking ready；未达到不能执行SDK。对导入、SDK 和可返回的初始化错误，组合层通过既有 HostApi 请求退出；旧 native `die()` 仍会终止进程，不是可恢复失败。

`StopRequested` 只表示请求被接受；runtime 不 Dispose 仍在使用的服务、guest RAM 或 WSI lease，不宣称 quiesced。`pthread_join` 失败也不会让 guest 参数落成已返回栈上的悬空指针。真正的停止与 WSI 债务结算仍属 shell/native/GPU 实际 owner。

当前 `CoreLink.cmake` game 模式拒绝保持不变。当前真实 core 仍有 Android 平台缺口（loader TARGET/RX、thread Mach context、svc_mem alias、window/fault/lifecycle），完整 Android 生产链接与运行尚未通过。只有这些真实 owner 接通并通过最终链接/设备验收，root 才能把此对象组合接到 game 入口；不能把 host fixture 通过作为删除阻断的理由。


## HostApi 停止与 guest 准入

在 Linux host 上运行 `python3 android/core-link/runtime-tests/run_stop_admission.py --out /tmp/s2a-stop-test`。
这条测试直接编译生产 `host_android.c`、HostApi 注册表、input/WSI、`runtime.c` 和共享 `guest_main.c`。
只有 core/SDK/services 端点是合成夹具；`--wrap=pthread_create` 仅把新 guest 的调度停在入口前。
`late-host-stop` 在 services 已 Ready 后、UI 尚未消费 eventfd 时，真实 HostApi 接受 GPU 错误停止，随后放行线程：必须零 SDK 入口。
`runtime-stop` 检查外部停止也先进入同一 HostApi 锁存，`admitted-first` 检查反向顺序明确属于已准入会话，`latch` 检查一次领取不清停止锁存。

`--baseline-runtime /path/to/old/runtime.c` 可运行修复前生产源码负控：旧独立 `g_stop` 看不到 HostApi 已接受的停止，夹具会观测一次 SDK 入口并拒绝。
线性化点是 `g.stop_lock` 内一次性设置 `guest_entered`，不是下一条 CPU guest 指令。准入前停止保证拒绝；准入后停止仍由真实退出 owner 处理，不表示所有 guest 线程已静止。
运行时锁和 HostApi 停止锁不嵌套；锁内不调用 guest/C#，测试也不预先消费 eventfd。本测试不证明 Android/Bionic、实际 guest 或 GPU 运行。

## 线程与 VM 续片

`run_thread_gate.py` 编译真实 Android 条件分支的 runtime/guest_main，6 个独立进程覆盖真实入口消费顺序及错误session、attach失败/停止、probe失败、仅prepared未final-ready。provider为明确合成，不能代替Bionic/NativeAOT设备验证。`run_guest_entry.py`另验3个主线程fault状态入口。真实 managed attach、fault、writer停车机制由各自生产owner提供，runtime没有成功替身。

私有runtime status仍24字节，offset20的`last_phase`只记录Loading/MemoryReady/ServicesReady/GuestRunning；错误或停止不覆盖。它让外壳避免与loader并发清场，不表示quiesced。runtime在loader前消费真实selfcheck；mem_init后依次消费真实writers_init、tracker_prepare和VM hooks准备，任何失败不启动服务。

Linux ARM64的`vm/run.py`链接真实shared svc_mem、tracker、registry与plat_vm_alias，13个进程覆盖真实别名、部分宿主页、ControlCodeMemory/TransferMemory、内核失败回滚、poison终止、hook冲突和栈复制的GPU回写重入VM锁。仅handle/NPDM及writers端点为合成；测试明确断言VM ready仍为0，不把fixture当完整线程安全点验收。Android的MapMemory/UnmapMemory在实际writers安全点内解锁g_mu后同步GPU/复制；源页沿既有跟踪写预备通道保守报脏，不用untracked读绕过GPU最新值。

## 主 guest 运行态发布（#961）

`run_save_running.py --out <新目录> --ndk-include <NDK 29 sysroot/usr/include>`（只能 Linux：GNU ld `--wrap`、`host_android.c` 的 eventfd）。真实 HostApi / stop owner、Android `runtime.c`、共用 `guest_main.c` / `session.c` / `direct_prompt.c` 一起编链；managed 服务、fault、tracking、SDK 与 `S2A_SaveAtomicState` 是合成端点。9 个独立进程覆盖：正常启动进 SDK 时已 RUNNING 且首次轮询拿到服务层原因位、安全值 0、子线程准入不发布、状态已不是 STARTING 时报红照常进、发布后停止、发布前停止 / 会话已失败 / attach 或 tracking 失败都不进 SDK。致命退出经 `--wrap=_exit` 在退出那一刻判定。不带 `--source-root` 时另跑 5 个回退负对照；`--source-root <修前树>` 用那棵树的生产源配本树夹具，得修前红。夹具只经既有接口观测，不引用新接缝。不证明设备、NativeAOT、存储故障或 Java 提示。
