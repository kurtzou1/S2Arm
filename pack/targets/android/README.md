# Android 宿主目标

从同一目录中的 NSP/XCI 本体、更新和 DLC 及本机密钥开始：

```sh
bash pack/oneclick/oneclick.sh <源包目录> --target android --keys <prod.keys> --out <私有输出目录>
```

成功后事件 `result` 包含 `apk`、`pack`（独立资源包）和 `artifact`（交付账本）的路径。资源包绑定 APK 的内容与签名证书；账本中的 `inputFrozen` 为 false，表示本次未启用 T04 输入冻结。输出包含玩家数据，不能提交或公开。支持 Apple Silicon Mac 和 Linux x64/arm64；引擎缺少游戏运行时时明确失败。

每个 release（`<私有输出目录>/android-releases/<uuid>/`）的 `resources/` 里，与上一个已发布 release 同路径、同内容的只读文件（RomFS 的绝大部分）是指向它的硬链接，新 release 实际只多占不到 0.5 GiB，不再是整份 RomFS；第一个 release、上一个不可用或不在同一个文件系统时照旧整份复制，日志里有 `reused N of M files` 或 `not reusing …` 一行说明。别原地改 release 里的文件，删哪个 release 都不影响另一个。

出包后端按宿主自动选，两个方向都不自动回退（#1131）：macOS（Apple Silicon）一律走宿主原生构建 `android/host/build.sh`，不需要也不碰 Docker；Linux 一律走 Docker 镜像构建 `android/docker/build.sh`，找不到 docker 或 daemon 不健康直接报红；其它系统报红。宿主原生路径需要 .NET 10 SDK、JDK 17、Android SDK platform 36、build-tools 36.0.0、NDK 29.0.14206865 和 CMake 3.31.6；先跑 `bash android/host/prepare.sh` 在线备料（写回执），构建与 `bash android/host/gate-apk.sh` 离线门禁在 macOS `sandbox-exec` 断网沙盒里跑，缺组件时报红并给出安装命令。可用 `ANDROID_HOME` 指定 SDK，未设时按 local.properties、macOS 默认 `~/Library/Android/sdk`、Linux 默认 `~/Android/Sdk` 顺序解析。Darwin x86_64 的宿主路径未实机验证，出包入口明确报红而不是放行半通状态。所有宿主还需 `xxd`，用于读取游戏模块构建号。Google 的 Linux NDK 工具是 x86-64 程序，Linux arm64 的 docker 镜像里已带兼容运行库；宿主机为 Linux arm64 时无宿主路径（一律 docker）。

没有 S2Arm.app 内置字体的 Linux 用户可传 `--fonts <包含 .bfttf 的目录>`，或先安装 `pack/fonts/requirements.txt`，运行 `python3 pack/fonts/make_open_fonts.py <目录>` 生成开源替代字体后通过 `--fonts` 指定；未提供字体会明确报错。

可加 `--install-serial <序列号>`，通过 `android/tools/deploy_game.py` 安装 APK 并导入绑定资源（不自动启动）；安装或导入失败返回非零，已交付文件保留。设备连接和授权由使用者准备。Mac 界面使用同一入口。此步骤依赖统一部署入口 #953 合入。

此路径使用现有 Android 模块改写、debug 签名及资源导入；正式 release 签名和输入冻结分别属于 T10 和 T04。

默认出包启用 NVN→Vulkan 后端；没有离线程序时描述符记录空文件与空 profile，由设备生成 live profile 并按需编译。描述符的翻译闭包取本源码树直连编译器的构建身份（`cli identity`，由 `android/cs/build.sh --direct-identity` 在与 APK 相同的 .NET 环境里生成到 `build/android-direct/identity.json`），与 APK 里编进的编译器同源同配置；不使用手写常量，设备端编译器拒收别的闭包。

离线 Vulkan 着色器包（#1574，`shaders` 阶段）：给 `S2A_VULKAN_PROFILE=<真机导出的 profile.json>` 后，出包期用共享流水线的抽取器 / 程序表读取器 + `S2A.ShBake bake --vulkan-profile` 烘出 `vulkan/generic/<profileKey>/` 离线包，`attach_shaders.py` 挂进资源包（index 追加 `shaders/vulkan/…` 行，包 manifest 绑定挂前的安装内容根），并经 `game_apk.py --shader-pack` 打成字节可复现的 `assets/game/shaders.zip`——运行时先找已装 `shaders/vulkan/` 树、否则从该资产解压（两条通道内容相同）。profile 是设备真实能力与翻译闭包的快照：先在目标设备上装一版 APK、设 `S2A_SHADER_PROFILE_OUT` 跑一局导出（见 `graphics/vulkan/cache/README.md`）；`S2A_VULKAN_REFS="<参考缓存目录> …"` 可附真机跑出的 Ryujinx 参考缓存提高覆盖率，`PATH` 上有 `spirv-val` 时逐支校验 SPIR-V。未提供 profile 时明示跳过（日志打黄），包里没有离线着色器、设备首遇按现行口径现编——host 不能手写 profile 伪造命中。烘焙证据（抽取、程序表、日志与 `bake.json` 摘要）随交付目录 `shader-pack/` 一并保留；包 manifest 的 `contentRoot` 只对给定安装 revision 有效，换包要重烘。
