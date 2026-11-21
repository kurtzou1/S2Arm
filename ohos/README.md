# 鸿蒙运行时协作源码（Draft）

共用上游 NVN 前端、回放核心和 Vulkan 后端；本目录提供鸿蒙宿主、musl 线程槽、程序加载、服务/输入/音频/视频接缝及构建工具。新层是唯一构建后端。没有游戏、游戏派生程序、缓存、签名证书或可安装二进制。

## 配套与构建

- 外壳见 PR #1297（ohos/app）；音频见 PR #1298（ohos/audio 与 ohos/cs/audio）。本运行时分支依赖音频片。
- 原生工具：官方 OHOS API26 native SDK，CMake/Ninja/Clang；不需要 Android NDK 运行库。
- 托管项目：ohos/cs/S2A.Ohos.csproj，.NET10 NativeAOT linux-musl-arm64；引用仓库现有服务/兼容层/直连编译器。
- Opus/VPX：ohos/codecs/build.py --help；版本与摘要引用 services 下固定依赖。工具需要显式传入，不附第三方源码或二进制。

```sh
cmake -S ohos/native -B <native-build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=<native-sdk>/build/cmake/ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release
cmake --build <native-build> --parallel 2
cmake -S ohos/audio -B <audio-build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=<native-sdk>/build/cmake/ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a
cmake --build <audio-build>
```

产物为 libs2arm_ohos_native.a、libs2arm_ohos_direct.a、libs2arm_ohaudio.a。
完整链接入口 `python ohos/link_engine.py --help`，要求显式提供上述归档、Opus/VPX、NativeAOT对象和运行库输入表。`--hms-include` 可选；不带 HMS 头时记录能力缺失并保留公开 QoS/帧计数，带头时保留 HMS 提示。两种性能对象交叉编译已通过；本轮最终引擎链接未验。没有隐式读取仓库外 PGO 文件，没有 ABI 成功桩。

OpenSSL 必须随引擎部署：见 [构建入口](openssl/README.md)。复用安卓版本/摘要，输出 OHOS `libssl.so.3` / `libcrypto.so.3` 与许可证，不提交生成库。

2026-11-16 接收协作者修复：codec 工具按平台选后缀；VPX 在构建副本打共享补丁并验证整份补丁状态；native 引用共享帧周期控制，补齐图形选择就绪钩子；TSD 排除本线程栈里的旧指针副本。没有带入模拟器的 VA39 空洞预占或 Dummy 音频开关。
离线回归：`python ohos/codecs/test_patch.py`；`CC=<宿主编译器> python ohos/native/test_tsd_probe.py`。后者使用合成地址和 API 替身，不替代真实 musl/设备 ABI 验证。

`ohos/build_signed_modules.py` 只公开生成器源码。它读取用户本机改写输出，生成的载体含游戏派生代码，必须留在本地；不附证书、密钥或任何载体结果。原本地工作树未提交的载体变更没有覆盖或混入此片。

## 责任与入口

| 目录 | 职责 |
|---|---|
| host | 窗口租约、HostApi、会话启动、性能提示、触觉反馈 |
| native | musl/VM/信号/线程槽、签名模块装载、硬件解码边界 |
| native/gfx_plat | 已合入的鸿蒙图形平台件；会话三件套仍引用安卓源码 |
| cs | 服务装配、直连/视频/软键盘接入；audio 在配套片 |
| probes / tests | 原创合成夹具与诊断源码，非游戏资产；不是应用默认入口 |

## 本次实际验证与未完成项

- Windows + 官方API26/Clang15：两个 native 静态库编译通过；host/feedback/performance/NUMA四个对象编译通过。最初因苹果平台条件/安卓surface宏失败，补齐OHOS选择后通过；这不是首帧证明。
- 签名生成器4项纯合成契约测试通过：`python -B ohos/tests/test_signed_generator.py`。
- 键盘回归已按共用 HostUi 口径更新（出错报红一次、回 null，不抛）：编真 OhosKeyboard / OhosHostUi / Red.cs，HostUi 只留软键盘挂点；接进 `ohos/gate.sh`。
- 历史 test_nro_container.py 依赖尚未公开的 nro_container.py，标「门禁手动」。改写器两支（test_rewrite_ohos.py、test_rewrite_sp_add.py）改调 C 改写器（Python patch_nso.py 上游已删），接进 `ohos/gate.sh`，要固定 venv 的 unicorn / capstone 与 S2A_REWRITER_DEPS；图形描述符 C 夹具未接。
- 全量 NativeAOT、最终 libS2AEngine.so 链接、模拟器首帧、真机画面/帧率未验；不请求把本 Draft 当成可玩版本合入。
- 完整贡献门禁在 Windows 前置环境检查退出，Python3入口、固定改写依赖、Xcode缺失；不把编译静态库称为完整门禁通过。
- 共享源码改动主要为 OHOS 选择 Linux 路径、musl TLS、签名装载、动态库内反馈导出及 OHOS surface；苹果/安卓门禁仍待各宿主验证。没有复制图形后端，也没有移入旧层性能实验。

## 后续交付清单

外壳公开SDK入口/文案资源、NativeAOT完整闭合、模拟器首帧是当前优先项。旧版出包适配器与自拼离线库不作为公共协议；改接上游目标适配器和LibPack后单独交付。旧层修复/性能经验逐项对照共用新层，不能直接沿用旧设备FPS。
