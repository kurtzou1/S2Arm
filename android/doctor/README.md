# Android APK 环境检查与准备指引（#107）

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 合并分析 §13。

入口：在任意工作目录执行 `bash <仓库>/android/doctor.sh`。
只需要 Python 标准库。检查不安装、不下载、不还原、不运行 Gradle/构建脚本，不启动 Docker/ADB 服务，不修改全局环境。

```sh
# 人读摘要 / 机器 JSON；输出只写 stdout，由调用方重定向到自己的报告目录
bash android/doctor.sh
bash android/doctor.sh --format json
# 打印缺项、准备步骤、需要用户授权后才能执行的命令；仍然不执行
bash android/doctor.sh --plan
```

退出码：0=全部检查已确认；1=源码布局变化、要求冲突或读取失败；2=缺项、版本不匹配、不支持或尚未验证。参数错误由 argparse 返回 2。JSON 的 `version=1`、`scope=android-apk`；每项包含稳定 `id/status/expected/actual/path/action`。人读输出与 JSON 使用同一份检查结果。公共 `tools/doctor.sh` 的调用方可直接调用本入口、解析 JSON 并保留非零状态；本 PR 不修改共用入口或现有构建/门禁，接线交由测试出包线审查。

`stages` 分开记录环境、编译、APK 校验、签名、安装、游戏与性能。本工具不执行这些验收，后六项始终 `not_tested`。不能用 doctor 报告替代 APK 或真机验收。

## 复用已有工具与缓存

```sh
bash android/doctor.sh --format json --plan \
  --jdk '<JDK 根>' --sdk '<Android SDK 根>' \
  --gradle-home '<解压的 Gradle 根>' --dotnet '<dotnet 可执行文件>' \
  --cache-root '<原容器 /cache 的可读副本或当前挂载目录>' \
  --gradle-cache '<GRADLE_USER_HOME>' --nuget-cache '<NUGET_PACKAGES>' \
  --assets '<probe 的 project.assets.json>' \
  --space-path '<本次构建输出所在卷>' --min-free-bytes '<本次需要的字节数>'
```

参数接受中文、空格路径。JDK、SDK、Gradle home 默认读对应环境变量。Gradle home 两样都没给时，像找 `javac` 一样从 PATH 上的 `gradle` 解软链，解到 `<home>/bin/gradle` 才取 `<home>`；只看路径和 launcher JAR 名，不运行 Gradle。官方构建镜像只放 `/usr/local/bin/gradle` 软链、不设 `GRADLE_HOME`，靠的就是这一条（#1568 定）。其余缓存默认按现有构建的 `/cache` 布局检查。`--dotnet`、`--docker` 可显式指定已有可执行文件；Docker image 默认跟随现有 `S2ARM_ANDROID_IMAGE` 或 `docker/build.sh`。

这些参数**仅选择检查路径**，不改构建脚本的缓存路由。#176 后 cs/OpenSSL/codecs 使用 `S2A_BUILD_CACHE`（缺省 `/cache`），Docker volume 另由 `S2ARM_ANDROID_CACHE` 选择；检查宿主缓存时显式传同一目录给 `--cache-root`。在 Mac 上检查另一目录，不会使其自动进入构建容器。`--plan` 会打印显式指定的进程环境和带 Shell 引用的命令，不执行/不自动 `eval`。不能通过改 PATH/全局 shell 配置“修复”检查。

剩余空间报告实际字节数；源码没有通用构建磁盘预算，必须由调用者提供 `--min-free-bytes`，否则标为 `unverified`，不猜固定容量。多卷输出分别检查相应路径。

## 版本与缓存正本

不另建版本 JSON。`requirements.sources` 记录本次读取的源码 SHA256；每次从以下文件提取并交叉验证，未知/重复声明、消费方不一致时退出 1：

- Dockerfile：JDK、SDK / Build Tools、NDK、CMake、Gradle、固定基础镜像；
- app/build.gradle、settings.gradle：compileSdk、Java、NDK、CMake、minSdk、AGP；
- host/hostenv.sh 与其调用的 tools/jdk17.sh：严格 JDK 主版本，helper 也记录源码 SHA256；cs/build.sh 与 global.json：普通 SDK 滚动策略和容器**精确** SDK、目标/宿主架构；
- openssl/build.sh、codecs/build.sh：API、NDK、缓存表达式与脚本哈希；
- services/opus/build.sh、services/vpx/build.sh：沿用跨平台版本/源码 SHA256 正本。

检查 SDK package.xml 标识及必需载荷；报告同时列出已有版本目录，不能用“目录存在”替代载荷。Gradle 从已解压 launcher JAR 的版本名读取，不调用可能首次初始化/写缓存的 `gradle --version`，不运行 Wrapper。AGP 逐项检查 POM/JAR。

NativeAOT 的 SDK 按所选缓存根下的 `dotnet/<精确版本>` 检查，不能用 Mac 上另一个可运行的 .NET 版本代替。检查缓存的 Linux x64 ELF SDK、SDK DLL。runtime 版本必须来自 probe 的真实 `project.assets.json` 精确 downloadDependencies。编译器版本优先取同一文件的 libraries；libraries 没有时，只认 downloadDependencies 里的精确钉版本 `[v, v]`，并且本地 NuGet 缓存里要按包名 + 版本找得到这个包（`.nupkg` 或解开的 `tools/`），再按下面的 x64 ilc 判；只有其一仍是 unverified。这是因为 `PublishAotUsingRuntimePack` 的真实还原只把宿主编译器记成 PackageDownload，libraries 里只有目标侧编译器（#107 情形 E，#1568 定）。不猜 SDK 对应的 runtime，也不选缓存里的最新版本。检查运行包 archive、LICENSE/THIRD-PARTY-NOTICES、精确 Linux x64 ilc。

OpenSSL 检查两个 ELF64/AArch64 库和许可证；Opus / VP8 按原脚本生成相同脚本 key、shim key，检查 archive、shim、头文件和许可证/专利声明。库检查是**格式与存在性检查**，不是二进制完整性/链接/解码正确性证明。源码 SHA 是构建正本的 pin，不冒充已缓存二进制的校验结果。

**离线闭包始终 `unverified`**：AGP 和 NativeAOT 缓存齐全仍不能证明全部 Maven/NuGet 传递依赖可离线解析，所以不会报全绿（当前 doctor 正常退出 2）。闭包须在授权构建环境独立执行离线构建验证；doctor 故意不触发这一步，也不把在线构建成功记成离线通过。离线缺项照常枚举，不联网补齐。

唯一执行的外部命令是限定参数且 8 秒超时的 `javac -version` / `java -version`、`dotnet --list-sdks`、`docker version --format`、`docker image inspect --format`；后两者只查询已配置的 daemon，不执行 build/run/pull/start。只输出允许的 Docker 版本/架构/镜像 ID 字段，不回显其 stderr、环境变量、登录信息或容器配置。报告路径含用户指定目录，分享前自行脱敏。

## Apple Silicon 与 Linux x64 支持矩阵

下表里 Apple Silicon 两行和「#133 交付时验证」保留原作者当时的环境与未验状态；它们不是 2026-10-26 后续证据的全集。原脚本适配判定与新阶段实证分开，见下方“后续阶段实证”。Linux x86_64 行的「本次实证」列在 2026-10-28 改为本分片的主机实测摘要；#133 当时「没有该主机」的原句保留在历史节。

| 执行位置 | 当前脚本是否能直接使用 | 本次实证 / 下一步 |
|---|---|---|
| Linux x86_64 / WSL2 x64 | 脚本 SDK `linux-x64` 和 NDK `linux-x86_64` 匹配；仍须依赖齐备 | 2026-10-28 Ubuntu 24.04.5 x86_64 实跑：`nativeaot_host=ok`。只读检查不下载、不安装；缺项时退出 2，总状态不报绿。10-28 那次 WSL2 未跑。APK 构建 / 签名未完成，安装「未测」。详见下方「Linux x64 主机实证」。2026-11-06 WSL2 x64 + Docker（情形 E）：官方 `docker/build.sh` 全流程退出 0，APK 校验与 v2 签名验证通过；`test.sh` CTest 52/54；同日用测试包名 `org.s2arm.android.w2` 在 Redmi 真机安装通过（E4）。详见「WSL2 x64 + Docker 实证」 |
| Linux arm64 原生容器 | 不匹配，原脚本下载 x64 SDK、使用 x86_64 NDK | doctor 报 unsupported；不能仅换成 arm64 基础镜像 |
| Apple Silicon macOS 原生 | 不能直接执行当前 Linux x64 NativeAOT 脚本 | Server M4/macOS 26.2 实查：主机架构不符、无 Docker、缺精确 Linux x64 SDK/runtime；普通 Mac .NET 可运行并不能消除这些缺项 |
| Apple Silicon + Linux amd64 仿真容器 | 候选路径，必须显式 `--platform linux/amd64`，需要已有可用仿真 | 本次未安装 Docker/未启动服务，**未验证**仿真或 APK 构建。镜像 metadata=amd64 不证明容器可执行/链接成功。优先转交已验证 Linux x64 构建机 |

`--plan` 输出显式 amd64 的 image build 命令与 `DOCKER_DEFAULT_PLATFORM=linux/amd64` 调用原 build.sh 的命令。它们可能联网、安装、写缓存，必须用户另行授权后手动执行。原 build.sh 不固定 Docker 平台，本 PR 不改它；同名镜像的 OS/arch 不符会明确报告。doctor 读取的主机/挂载目录与 Docker 镜像是分开的信息，不将主机缓存当作容器已验证缓存，不启动容器来制造通过结论。

## Linux x64 主机实证（2026-10-28，#107 分片）

主机：Linux 6.12.94+ x86_64，Ubuntu 24.04.5 LTS，Python 3.12.3。源码 `e6e6befdd`。本机是原生 Linux x86_64；WSL2 未跑。预装 OpenJDK 21.0.12.1（`/usr/bin/javac` 指向 `/usr/lib/jvm/java-21-openjdk-amd64/bin/javac`）。本分片额外只安装了 OpenJDK 17.0.20.1（`/usr/lib/jvm/java-17-openjdk-amd64`）和取证用的 strace 6.8。当时没有 Docker、Android SDK、NDK、.NET。doctor 判定口径未改，版本仍从现有源码读取。本次读到的正本：JDK 17、SDK 36、Build Tools 36.0.0、NDK 29.0.14206865、CMake 3.31.6、Gradle 9.8.1、AGP 9.4.1、容器 SDK 10.0.301、宿主 `linux-x64`、NDK 预编译目录 `linux-x86_64`、默认镜像名 `s2arm-android-build:1`。

| 问题 | 这台 Linux x64 主机上的结论 |
|---|---|
| 能否直接跑已合入的 doctor | 能。Python 标准库即可。`nativeaot_host` 为 ok（`os=Linux`，`arch=x86_64`） |
| 脚本要求的 SDK / NDK 宿主是否对得上 | 对得上 `linux-x64` / `linux-x86_64`。架构匹配不等于 SDK、NDK、.NET 或编解码缓存已经齐备 |
| 能否在本机完成当前 APK 构建、签名、安装 | 本分片没有完成构建和签名。无 Docker，无 SDK/NDK/.NET 缓存。安装无真机，记「未测」 |
| Apple Silicon 行 | 保持原记录。本分片的 Linux 结果不写入那两行 |

doctor 的 `stages` 始终把编译、APK 校验、签名、安装、游戏、性能记为 `not_tested`。下表的「安装」按本分片要求写成「未测」。doctor 退出 0 才表示检查项全部为 ok；下面各次都是退出码 2、`status=incomplete`，没有把缺项报成通过。

### 情形 A：只准备 JDK 17 和 Python

命令（干净环境，不继承调用方的 `JAVA_HOME` / `ANDROID_HOME`）：

```sh
env -i PATH=/usr/bin:/bin HOME=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR=/tmp \
  bash android/doctor.sh --jdk /usr/lib/jvm/java-17-openjdk-amd64 --format json
```

期望：JDK 17 的实际路径和版本记为 ok；#106 §4 那类其余差异（SDK / Build Tools、NDK、CMake、Gradle / AGP、Docker、NativeAOT 与编解码缓存）逐项列出；不下载、不安装；总状态不报绿；安装记「未测」。

真结果：退出码 2。`status=incomplete`。`stages`：`environment=incomplete`，`compile` / `apk_validation` / `signature` / `installation` / `device_game` / `performance` 均为 `not_tested`。安装记「未测」。27 项里 ok 只有 `jdk`、`jdk_runtime`、`nativeaot_host`。

| 检查 | 期望 | 真结果 |
|---|---|---|
| jdk / jdk_runtime | 17 | ok。实际 `17.0.20.1`。路径分别是该 JDK 的 `bin/javac`、`bin/java` |
| sdk_files / sdk_package | android-36，且有 `android.jar` 与 package 元数据 | missing。路径 `/opt/android-sdk/platforms/android-36`。`available_versions=[]` |
| build_tools_files / build_tools_package | 36.0.0，含 aapt2、apksigner、zipalign | missing。路径 `/opt/android-sdk/build-tools/36.0.0` |
| ndk_files / ndk_package / ndk_linux_compiler | 29.0.14206865，且有 linux-x86_64 clang | missing。路径 `/opt/android-sdk/ndk/29.0.14206865` 及其 `toolchains/llvm/prebuilt/linux-x86_64` |
| cmake_files / cmake_package | 3.31.6，含 cmake 与 ninja | missing。路径 `/opt/android-sdk/cmake/3.31.6` |
| gradle | 9.8.1 | missing。未传 `--gradle-home` |
| agp_pom / agp_jar | 9.4.1 | missing。路径 `/cache/gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/9.4.1` |
| dotnet_inventory | 10.0.301，`rollForward=latestFeature` | missing。PATH 中无 `dotnet` |
| nativeaot_sdk / nativeaot_sdk_host | 缓存内 Linux x64 SDK 10.0.301 | missing。路径 `/cache/dotnet/10.0.301` |
| nativeaot_restore / nativeaot_runtime | 精确 `linux-bionic-arm64` 还原及运行包 | restore missing（`/workspace/build/android-cs/probe/obj/project.assets.json` 不存在）；runtime unverified |
| openssl / opus / vpx | 缓存内 ELF / archive 与许可证 | missing。路径 `/cache/openssl/3.5.9-ndk29-api29`、`/cache/codecs/opus-1.6.1-ndk29-api29-3248d806e947`、`/cache/codecs/vpx-1.17.0-ndk29-api29-3248d806e947` |
| nativeaot_host | `linux-x64 / linux-x86_64` | ok。`{'os':'Linux','arch':'x86_64'}` |
| docker / docker_image | 已在跑的 daemon；镜像 `linux/amd64` | docker missing（无 CLI）。镜像 unverified，名为 `s2arm-android-build:1` |
| offline_resolution | 完整依赖闭包 | unverified |
| disk_space | 未传 `--min-free-bytes` 时不猜预算 | unverified。`free_bytes=263909896192`，路径 `/`（默认 `/cache` 不存在，检查落到现存父目录） |

同一命令不加 `--jdk`（默认 `javac` 仍是预装的 21）时：`jdk` 与 `jdk_runtime` 为 mismatch，实际 `21.0.12.1`，路径是 `/usr/lib/jvm/java-21-openjdk-amd64/bin/javac` 与同目录的 `java`。其余检查与上表同类。退出码 2。这对应 #106 §4 的 Java 行：机器上已有 JDK 21，要求仍是 17。

无下载 / 无安装：对 `--format json` 的上述 JDK 17 命令做 `strace -f -e trace=network,execve`。成功的 `execve` 只有 `env`、`bash`、`dirname`、`python3`、`javac -version`、`java -version`。没有 `curl`、`wget`、`apt`、`sdkmanager`、`docker`、`gradle`。没有 `AF_INET` / `AF_INET6`。仅有的 `connect` 是 libc 对 `/var/run/nscd/socket` 的 `AF_UNIX` 尝试，返回 `ENOENT`。strace 里 `javac` / `java` 出现 `SIGSEGV` 后进程仍退出 0，doctor 读到的版本是 `17.0.20.1`（HotSpot 用信号做空指针检查的常见痕迹）。

### 情形 B：指定复用目录

复用目录是本次在 `/tmp` 准备的，不在仓库里：

- `--jdk`：上面的 JDK 17。
- `--gradle-home`：官方 `gradle-9.8.1-bin.zip`，SHA-256 `dce76f55f8e251a3a1f130eb120f30b3d271de2b76c9b0729d316b5a1b6dc01f`，与 `android/docker/Dockerfile` 的 `GRADLE_SHA256` 一致。doctor 只读 `lib/gradle-launcher-9.8.1.jar` 的文件名和 `bin/gradle` 的脚本头，strace 确认没有执行 `bin/gradle`。
- `--sdk`：只建了空目录 `platforms/android-36`、`build-tools/36.0.0`、`ndk/28.2.13676358`、`cmake/3.22.1`。没有 SDK 载荷，也没有 `package.xml`。目录名用来对照 #106 §4 的「NDK 28.2 / CMake 3.22.1 与要求不符」。
- `--cache-root /tmp/s2arm-107/reuse-cache`，`--min-free-bytes 1048576`。

```sh
env -i PATH=/usr/bin:/bin HOME=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR=/tmp \
  bash android/doctor.sh \
  --jdk /usr/lib/jvm/java-17-openjdk-amd64 \
  --gradle-home /tmp/s2arm-107/dl/gradle-9.8.1 \
  --sdk /tmp/s2arm-107/reuse-sdk \
  --cache-root /tmp/s2arm-107/reuse-cache \
  --min-free-bytes 1048576 --format json
```

期望：报告列出实际 JDK / Gradle / SDK / 缓存路径和读到的版本；空目录和错误版本目录不因为「目录存在」而通过；指定预算后磁盘按实际剩余字节判断。

真结果：退出码 2，`status=incomplete`。安装仍是 `stages.installation=not_tested`（「未测」）。

| 检查 | 期望 | 真结果 |
|---|---|---|
| jdk / jdk_runtime | 指定 JDK 的路径与 17 | ok。`17.0.20.1`，路径同上 |
| gradle | 9.8.1，且不运行 Gradle | ok。实际 `['9.8.1']`，路径 `/tmp/s2arm-107/dl/gradle-9.8.1`。strace 无 `bin/gradle` |
| sdk_files | 有 `android.jar` 才算有载荷 | missing。路径 `.../reuse-sdk/platforms/android-36`。`available_versions=['android-36']`，`android.jar` 缺失 |
| ndk_files / ndk_package | 29.0.14206865 | missing。检查路径是 `.../ndk/29.0.14206865`（该目录不存在）。同级已有目录记为 `available_versions=['28.2.13676358']` |
| cmake_files / cmake_package | 3.31.6 | missing。检查路径 `.../cmake/3.31.6`。`available_versions=['3.22.1']` |
| build_tools_files | 36.0.0 且有 aapt2 / apksigner / zipalign | missing。版本目录名是 `36.0.0`，三个可执行文件都不存在 |
| agp_pom / agp_jar、dotnet、NativeAOT、OpenSSL / Opus / VP8 | 随 `--cache-root` 改到指定缓存 | 仍 missing / unverified。路径前缀变为 `/tmp/s2arm-107/reuse-cache/...`，不再是默认 `/cache` |
| disk_space | 剩余 ≥ 1048576 | ok。`free_bytes=263585046528`，路径 `/tmp/s2arm-107/reuse-cache` |
| nativeaot_host | Linux x64 | ok |

`--plan`（同一 JDK / SDK / 缓存，不传磁盘预算）退出码同样是 2。stdout 含「准备计划（未执行）」和「获准后手动执行（本次未执行）」，并打印 `docker build --platform linux/amd64 ...` 与 `DOCKER_DEFAULT_PLATFORM=linux/amd64 ... docker/build.sh`。strace 的 `execve` 仍只有 shell、python3、`javac -version`、`java -version`，没有执行这两条准备命令。

### 情形 C：离线

普通用户的 `unshare -n` 返回 `Operation not permitted`。改用 `sudo unshare -n`。命名空间内 `curl -fsS --max-time 3 https://example.com` 的真结果是 `Could not resolve host: example.com`，curl 退出码 6。

```sh
sudo unshare -n -- sudo -u ubuntu -H env -i PATH=/usr/bin:/bin HOME=/tmp \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR=/tmp \
  bash android/doctor.sh --jdk /usr/lib/jvm/java-17-openjdk-amd64 --offline --format json
```

期望：缺项照常逐条列出；不联网补齐；总状态不报绿；安装「未测」。

真结果：退出码 2。`offline=true`，`network` 为 `no network probes`，`status=incomplete`。`jdk` / `jdk_runtime` 仍为 ok（`17.0.20.1`），`nativeaot_host` 仍为 ok，SDK / NDK / CMake / Gradle / AGP / .NET / 编解码缓存 / Docker 与情形 A 一样是 missing 或 unverified。`stages.installation=not_tested`（「未测」）。同一命名空间里不加 `--offline` 的人读输出，27 项状态与情形 A 的在线人读输出逐项相同，退出码也是 2。离线没有把任何缺项改成 ok。

### 情形 D：完整准备

按 Dockerfile 的版本尝试后续构建。本机没有 Docker CLI，也没有已运行的 daemon，因此没有走 `docker/build.sh`。没有 SDK / NDK / .NET / OpenSSL / Opus / VP8 缓存，`verify-apk.py` 没有 APK 可校验。签名未做。安装「未测」（无真机，也没有可安装的 APK）。

`android/test.sh` 先单独跑了一次，JDK 17 放在 PATH 最前，`JAVA_HOME` 指向该 JDK，`PY=/usr/bin/python3`：

| 项 | 期望 | 真结果 |
|---|---|---|
| 环境 | doctor 把缺项与未验证项分开 | 见情形 A–C。总状态 incomplete，退出码 2 |
| 编译 | `android/test.sh` 退出 0 | 未通过，见下面两次命令。没有 APK |
| 签名 | APK 签名验证分开记 | 未做。没有 APK，没有跑 `apksigner` |
| 安装 | 真机安装 | 未测 |

第一次 `test.sh`：`PATH` 以 JDK 17 的 `bin` 开头，`JAVA_HOME` 指向该 JDK，`PY=/usr/bin/python3`。退出码 1。默认 `/usr/bin/cc` 是 Clang 18.1.3，`/usr/bin/c++` 链接试编译失败：`cannot find -lstdc++`。CMake 停在 Configuring incomplete，没有进入 ctest 或 Java 契约。同机 `g++`（g++-13）可以链接一个空 `main`；`libstdc++.so` 在 `/usr/lib/gcc/x86_64-linux-gnu/13/`。

第二次：同一 JDK / `PY`，并设 `CC=gcc`、`CXX=g++`。CMake 识别 GNU 13.3.0，配置完成。编译 `guest_page_test` 时失败：`runtime/src/det.c:384` 在 `__ANDROID__` 分支使用 `((ucontext_t *)ctx)->uc_mcontext.pc`，x86_64 宿主的 `mcontext_t` 没有成员 `pc`。`android/CMakeLists.txt` 在 Linux 上把 `det.c` 的编译定义设为 `__ANDROID__`。`cmake --build` 失败，`test.sh` 退出码 2。没有 ctest 结果，也没有进入后面的 Java 步骤。本分片不改 `CMakeLists.txt` 或 `native/`。

另一次只为看 Java 契约能走到哪：`S2A_TEST_NO_NATIVE=1`，JDK 17 与 `PY=/usr/bin/python3`。这不是完整 `test.sh` 的通过记录。真结果退出码 1。在停之前打印了 `Android gamepad: ... passed`、`BootContract: ok`、`BootSpec: ok`、`BootSpec schema: ok`、`GamePack: ok`、`GameInstall: ok`、`App 纯 Java 类编译：ok`。使用的 `javac` 是 `/usr/lib/jvm/java-17-openjdk-amd64/bin/javac`，版本 `17.0.20.1`。随后 `native_rewriter_test.py` 报红退出：Capstone/LZ4 固定依赖在 `S2A_REWRITER_DEPS`、`build/rewriter-deps` 和默认运行目录都不存在，脚本声明不自动下载。

系统 CMake 是 3.28.3，满足 `test.sh` 注释里的 3.18+。APK 正本仍要求 SDK 里的 CMake 3.31.6；doctor 没有把系统 CMake 当成那一项通过。完整 NativeAOT 与 APK 还要 SDK、NDK、.NET 与编解码缓存。本机没有 Docker，这些下载没有开始。`verify-apk.py` 未运行。

准备获准并完成后，使用原有入口验证，不重写流水线：

1. 对应环境执行 `android/test.sh`；Mac 仅 Java/契约可按现有 `S2A_TEST_NO_NATIVE=1`，严格 JDK gate 单列。
2. `docker/build.sh` 默认构建路径含 probe/crypto、assemble、lint、`verify-apk.py` 与 `apksigner verify`；编解码静态模式按原 `S2ARM_ANDROID_CS_SERVICES=static`。
3. 把实际命令、commit、APK SHA、工具报告和每一阶段退出状态绑定保存。构建/签名成功不能填写“安装成功”“游戏可玩”。

## WSL2 x64 + Docker 实证（2026-11-06，#107 情形 E）

本节补验收 ④：完整准备后，`android/test.sh` 和 APK 校验能走到哪；环境、编译、APK 校验、签名、安装分开记。源码 `85f95b81a`。doctor 判定口径没改，下面只记读数。

主机是 Windows 上的 WSL2：内核 `6.18.54.1-microsoft-standard-WSL2`，发行版 Ubuntu 18.04.6，x86_64。宿主机本身没装 JDK / SDK / .NET，工具都在构建镜像里：

- **Docker**：28.1.1，`linux/amd64`。
- **构建镜像**：`s2arm-android-build:1`，镜像 ID `12a38c0c3fcd`，2026-10-31 构建。`android/docker/Dockerfile` 本身最后一次改动是 `79c713497`（10-28），早于镜像；之后 `docker/` 目录里改的都是准备 / 门禁脚本，不是 Dockerfile。
- **缓存卷**：`s2arm-android-build-cache`。**不是空卷**：之前的构建已经留下了 .NET、NuGet 和 Gradle 缓存。下面的耗时是热缓存下的读数，不代表首次准备要多久。

### E1 环境：doctor

**期望**：缺项和未验证项分开列；构建前后的差别只出在构建产物带来的那几项；离线闭包始终 unverified；总状态不报绿（退出 2）。

**容器内，构建前**：

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  --mount type=bind,source=<仓库>,target=/src \
  --mount type=volume,source=s2arm-android-build-cache,target=/cache \
  -e HOME=/cache/home -e S2A_BUILD_CACHE=/cache -e GRADLE_USER_HOME=/cache/gradle \
  --workdir /src --entrypoint bash s2arm-android-build:1 \
  -c 'bash android/doctor.sh --format json'
```

- **退出码**：2，`status=incomplete`。27 项：18 ok、5 missing、4 unverified。
- **missing**：
  - `gradle`：镜像没设 `GRADLE_HOME`，Gradle 在 `/opt/gradle-9.8.1`，经 `/usr/local/bin/gradle` 软链在 PATH 上。
  - `dotnet_inventory`：PATH 里没有 `dotnet`。构建用的是缓存里的 `/cache/dotnet/10.0.301/dotnet`。
  - `nativeaot_restore`：探针还没还原。
  - `openssl`：当前缓存键下还没有库。
  - `docker`：容器里没有 Docker CLI。
- **unverified**：`nativeaot_runtime`、`docker_image`、`offline_resolution`、`disk_space`（没传预算）。

**容器内，构建后**：同一命令，加 `--gradle-home /opt/gradle-9.8.1 --dotnet /cache/dotnet/10.0.301/dotnet --min-free-bytes 10737418240`。

- **退出码**：2，`status=incomplete`。27 项：24 ok、1 missing、3 unverified。
- **新变 ok 的**：`gradle`（`9.8.1`）、`dotnet_inventory`（`10.0.301`）、`nativeaot_restore`（`linux-bionic-arm64`，runtime `10.0.9`）、`nativeaot_runtime`、`openssl`、`disk_space`（剩余 `868435673088` 字节 ≥ 预算）。
- **missing**：只剩 `docker`（容器内）。
- **unverified**：
  - `docker_image`：容器内查不了，见下面的宿主机读数。
  - `offline_resolution`：按设计始终 unverified。
  - `nativeaot_compiler`：见下面的「口径问题 1」。

**宿主机**（`bash android/doctor.sh --format json`，Python 3.12）：

- `docker` ok：`28.1.1`，`linux/amd64`。
- `docker_image` ok：`sha256:12a38c0c3fcd…`，`linux/amd64`。
- `nativeaot_host` ok：Linux x86_64。
- 其余 SDK / JDK 等是 missing（工具在镜像里，不在宿主机上）。总状态 incomplete，退出 2。

### E2 编译 + APK 校验 + 签名：`docker/build.sh`

**命令**：在仓库根执行 `bash android/docker/build.sh`，不带参数。这是默认全流程：`cs/build.sh` → `openssl/build.sh` → Gradle `:app:assembleDebug :app:lintDebug` → `verify-apk.py` → `apksigner verify`。

**期望**：每一步都退出 0；APK 只有 arm64-v8a，ELF 段和 APK 按 16 KB 对齐；签名验证通过。

**真结果**：退出 0，123 秒（热缓存）。

- **NativeAOT 探针**：`build/android-cs/jniLibs/arm64-v8a/libs2a_cs_probe.so`。
- **OpenSSL**：
  - 当前缓存键下没有现成的库，所以联网下载了源码 `openssl-3.5.9.tar.gz`，在镜像里编出 `libssl.so` 和 `libcrypto.so`。
  - 这次完整准备是**在线**的，不能当离线可复现的证据。
- **Gradle**：`BUILD SUCCESSFUL in 1m 5s`，48 个任务全部执行，lint 报告写到 `app/build/reports/lint-results-debug.*`。
- **APK 校验**（`verify-apk.py`）：`APK verified: arm64-v8a, 16 KB ELF segments and APK alignment, JNI ABI 083f4b8f84de`。
- **签名**：`apksigner verify` 退出 0。`--verbose --print-certs` 的读数：
  - v2 签名 true，v1 / v3 / v3.1 / v4 都是 false；
  - 1 个签名者，`CN=Android Debug`，证书 SHA-256 `c152fd195a71dc200337bf68694d4797e0c92250bcd89cf62d0b50a8da776aba`。
  - 这是 debug 签名，不是发布签名。
- **产物**：`android/app/build/outputs/apk/debug/app-debug.apk`，12152793 字节，SHA-256 `27d5e9f67557b33873f66f09f9f8610bd009e8413b793bd8a9765639968f9fae`。

### E3 编译（宿主测试）：`android/test.sh`

**环境**：本机自建的检查镜像 `s2arm-contrib-check:2`（ID `ffdf07827a4e`，不在仓库里），在 `s2arm-android-build:1` 上加了 git 和 Python 3.12 虚拟环境。

- 虚拟环境里装了 `tools/rewriter-requirements.txt` 的钉版包。
- `S2A_REWRITER_DEPS` 指向 `runtime/rewriter/prepare_deps.py` 事先准备好的目录。
- `S2A_PY` 指向该虚拟环境。
- JDK 17 用镜像自带的。

**期望**：`test.sh` 退出 0。

**第一次**：PATH 照镜像原样。

- **退出码**：127。
- `cs/video`、buffer-scratch、provider、vk_membuf、vk_resid 等前面各步都过。
- 到原生 CMake 那一步时报 `cmake: command not found`：镜像只在 `/opt/android-sdk/cmake/3.31.6/bin` 里有 CMake，PATH 上没有。`test.sh` 默认用 PATH 里的 `cmake`，也可以用 `CMAKE` 指定。

**第二次**：PATH 前加 `/opt/android-sdk/cmake/3.31.6/bin`。

- **退出码**：8。CTest 54 例过 52 例，两例红：
  1. **`android_nativeaot_startup_roots`**：调 `/usr/bin/ld -shared --gc-sections … -z start-stop-gc` 时 ld 自己崩了（退出 -11），报 `BFD (GNU Binutils for Ubuntu) 2.42 assertion fail ../../bfd/elfxx-x86.c:546`。
     - 这是宿主 x86_64 上 Ubuntu 的 GNU ld 2.42 本身的问题，与本仓库代码无关。
     - 10-30 维护方在本卡记过同一处：`android_nativeaot_startup_roots`，GNU ld 2.42 自身断言。
  2. **`android_crash_android_fatal`**：60 项里 3 项不符，都是 ⑪「掩码替身」：`sa_mask∪本信号都阻塞`、`处理器返回后掩码还原`、`重放续走后退出码 45`（真结果 -1）。
     - **原因**：⑪ 按注释「macOS 上 PROT_NONE 页访问给 SIGBUS」，用 `SIGBUS` 装替身、拿空指针触发。Linux 上空指针访问给的是 `SIGSEGV`，替身根本没被调到。
     - **核对**：本机把 ⑪ 在非 Apple 平台改用 `SIGSEGV` 重编，`t_crash_android_fatal` 60 项全符。这个改动没有进本 PR。
     - ⑪ 是 `ddeab0e24`（11-06）新加的，Mac 上的门禁看不到这一例红。
- 这次没有拿到 `test.sh` 退出 0 的读数。

**后续（同日）**：
- ⑪ 已由维护方在 main 修掉（`7820b6a60`，按平台取信号：Apple 上 SIGBUS、其余 SIGSEGV）。
- `test.sh` 找 CMake 已按 #1571 改：按 `$CMAKE` → PATH → SDK 最高版本取，`ctest` 取同一份。镜像里 PATH 上没有 cmake 也能跑到 CTest，读数仍是 52/54（剩 GNU ld 2.42 那一例，加上修好之前的 ⑪）。

### E4 安装

同日下午在真机上补测，只装、不启动、不触屏。设备窗口经协调方批准。

- **设备**：Redmi 22081212G（Android，arm64）。
- **包**：从 main `7e16121d7` 用 `docker/build.sh -Ps2arm.testAppIdSuffix=.w2 :app:assembleDebug` 出的 debug APK，包名 `org.s2arm.android.w2`（固定测试后缀）。
  - SHA-256 `9a9e251c6f04f3ebd9bf9ea2896c9493dc0a84d3109c333e30fb13d39fa8a262`，12169185 字节。
  - `verify-apk.py` 通过；`apksigner` 是 v2，debug 证书。
- **为什么用测试包名**：机上已有的 `org.s2arm.android` 是另一把 debug 密钥签的（证书 SHA-256 `0977d882…`，本次构建是 `c152fd19…`）。`install -r` 会被拒，要装就得先卸载、丢它的数据，所以没动它。
- **期望**：装上、机上文件与构建产物逐字节一致、包管理器读得到；收尾卸掉，原有包不变。
- **真结果**：
  - `adb install` 回 Success；
  - 机上 `base.apk` 的 sha256 与上面一致；
  - `dumpsys package` 读到 versionCode 1、`0.1.0-dev`、DEBUGGABLE、v2 签名；
  - `adb uninstall org.s2arm.android.w2` 回 Success，`pm path` 为空；
  - 原有 `org.s2arm.android` 的 `base.apk` sha256 前后一致，包数前后都是 397，最后回到桌面。

这只证明安装这一步。构建、签名或安装成功，都不能记成「游戏可玩」。

### 小结

| 阶段 | 期望 | 真结果 |
|---|---|---|
| 环境 | 缺项与未验证项分开，不报绿 | doctor 退出 2；容器内构建后 24/27 ok，余下是容器内无 Docker CLI、`docker_image`、`offline_resolution` 与 `nativeaot_compiler`；宿主机 Docker 与镜像 ok |
| 编译 | `docker/build.sh` 与 `test.sh` 都退出 0 | `docker/build.sh` 退出 0；`test.sh` 退出 8（CTest 52/54，两例红原因见 E3） |
| APK 校验 | arm64-v8a、16 KB 对齐 | 通过（`verify-apk.py`） |
| 签名 | `apksigner verify` 通过 | 通过（v2，debug 证书） |
| 安装 | 真机安装 | 通过（测试包名 `org.s2arm.android.w2`，见 E4） |

### 口径问题（#1568 已定，#1570 / #1571 已按定的改）

1. **`nativeaot_compiler` 在真实还原下始终 unverified。** 探针用 `PublishAotUsingRuntimePack`，真实的 `project.assets.json` 是这样记的：
   - 宿主编译器 `runtime.linux-x64.Microsoft.DotNet.ILCompiler` 只出现在 `project.frameworks.net10.0.downloadDependencies`，精确版本 `[10.0.9, 10.0.9]`；
   - `libraries` 里只有目标侧的 `runtime.linux-arm64.Microsoft.DotNet.ILCompiler/10.0.9`。

   doctor 只从 `libraries` 取编译器，所以这项永远到不了 ok。缓存里 `nuget/runtime.linux-x64.microsoft.dotnet.ilcompiler/10.0.9` 是在的。现有单测 `test_review_foreign_compiler_metadata_remains_unverified` 有意把这个形态判成 unverified，所以本分片不改，请定是否改口径：例如接受 `downloadDependencies` 里的精确版本，再加上缓存里对应的 x64 ELF `ilc`。
   **已改（#1570）**：`libraries` 没有时，认 `downloadDependencies` 里的精确钉版本，并且本地 NuGet 缓存里按包名 + 版本找得到这个包，再按 x64 `ilc` 判；只有其一仍 unverified。官方镜像里对真实还原实跑，这项是 ok。
2. **在官方构建镜像里，gradle 报 missing。** 镜像没设 `GRADLE_HOME`，doctor 也不从 PATH 上的软链反查。可以在镜像里设 `GRADLE_HOME`，也可以让 doctor 像找 JDK 那样从 PATH 解析（只读 launcher JAR 文件名，不运行 Gradle）。
   **已改（#1570）**：从 PATH 解析，不改镜像。
3. **`test.sh` 在镜像里找不到 CMake**（见 E3 第一次）。**已改（#1571）**：按 `$CMAKE` → PATH → SDK 最高版本取，`ctest` 取同一份；PATH 只对 CMake 三步、只多 cmake / ctest 两个名字。

## #133 交付时验证（历史）

`TMPDIR=<本任务外置缓存> bash android/doctor/test.sh`：纯标准库合成测试，含版本冲突、载荷缺失、错误架构/损坏库、精确 AOT 版本、shim key 变化、Docker 不可用/arm64、错误 JSON、超时、磁盘预算、中文空格/Shell 引用及文件树内容/mtime/权限无变化。没有运行安装器或真实 Docker。

Server 的实际只读报告复现部分环境缺项；JDK 21 下现有 Android Java/契约测试通过，**严格 JDK 17 gate、Linux 原生部分、完整 APK/签名未测**。#133 交付时的 integration 尚无 `tools/contrib_check.sh`，当时实际调用退出 127；未复制 main 另一套门禁冒称通过。这是原阶段记录，不表示后续 integration 仍无该入口。最终完整环境准备和 APK 验收依赖获准补齐工具或维护者构建环境，#107 暂不宣称全部验收完成。

## 后续阶段实证（2026-10-26，#467）

以下是已合入 [PR #467](https://github.com/jhaizhou-ops/S2Arm/pull/467) 的后续来源记录，不是本次文档更新在本 Server 上重新构建、运行容器或核验二进制的结果。它补充上表的历史实证，**不改变 doctor 对现有整条脚本、精确工具及离线闭包的判定**。

固定来源：[`58c1f959` 的分段记录](https://github.com/jhaizhou-ops/S2Arm/blob/58c1f9591f1f34afbf4be5229912bbee5e090ef8/docs/%E6%80%A7%E8%83%BD%E4%B8%8E%E5%BC%80%E5%8F%91%E6%B5%8B%E8%AF%95%E7%BB%8F%E9%AA%8C.md)与[同提交的归档／剥离及 Rosetta 限制](https://github.com/jhaizhou-ops/S2Arm/blob/58c1f9591f1f34afbf4be5229912bbee5e090ef8/docs/%E5%9D%91%E8%AE%B0%E5%BD%95.md)。该记录限定为 M2 Max、OrbStack 12 CPU、源码 `b114df2f`；正式镜像 `4cbb20d3` 为经 Rosetta 执行的 `linux/amd64`。这些源码／镜像短标识沿用原作者记录，不冒充本次独立完整身份核验。

| 路线与阶段 | 来源实际记录 | 仍不能推出的结论 |
|---|---|---|
| 正式 Linux x64 镜像经 Rosetta 执行整链 | AOT 回执134.0秒、APK 回执90.1秒；Gradle 带 lint、47/47任务全执行 | 这是限定来源的构建分段回执，不是本 Server 或所有 Apple Silicon 主机已通过，也不补齐本次 APK 校验／签名／安装和 #107 验收④ |
| 开发路线：Linux arm64 容器执行 AOT | 官方 Ubuntu 24.04 与 .NET SDK 10.0.301 linux-arm64；记录了冷 publish 与三次单行增量 publish | 证明所述 AOT 阶段可行，不等于原 x64 SDK／NDK 整链可直接在 arm64 容器使用；不能仅换基础镜像或把 doctor 的 unsupported 改绿 |
| 开发路线：x64 镜像后处理和后续工具 | arm64 ILC 原始 `.o` 按原命令在 x64 镜像用 `ar -crs` 与 NDK `llvm-objcopy` 处理后，作者报告 `libs2a_cs.a` 与正式构建相同；剥离后 `libs2arm_android.so` 也相同。objcopy、ninja、Gradle 仍在 x64 镜像执行 | 不是随便换宿主／归档／剥离工具都字节相同；原 `.o`、归档 `.a`、剥离 `.so` 是不同阶段。本文没有取得并独立校验这些二进制或完整哈希 |

归档差异的来源解释是：两边 ILC 原始 `.o` 相同，但 PATH 选择的 binutils `objcopy` 与 NDK `llvm-objcopy` 处理归档不同；LinkNative 跳过时还可能复用先前 StripSymbols 属性的旧 `.a`。源文档用 `cb25b7d7…`、`3003d04f…` 等短哈希记结果，不能把这些前缀当作本次完整字节校验。Rosetta 增量 publish 卡住的根因仍未确认，源文档只记录关闭共享编译后的有限结果；这些记录不是安装工具、起常驻容器或清理缓存的执行授权。

### 开发局与正式验收分开

[开发替换库通道](../README.md#development-runtime-library-debuggable-builds-only)每次起局须显式选择与基包身份绑定的库；正式 APK 也可 debuggable，不能仅凭这个标志判断局的性质。`dev-override` 会在 BootSpec、局目录记录与日志中标识；[`f5bcb5ec` 套件说明](https://github.com/jhaizhou-ops/S2Arm/blob/f5bcb5ec232dc749faaeb3eb56bdd166d1196793/docs/%E8%B4%A1%E7%8C%AE%E8%80%85%E5%BC%80%E5%8F%91%E6%B5%8B%E8%AF%95%E5%A5%97%E4%BB%B6.md)明确 metrics 拒绝开发局导出，frame gate／score 判局无效。开发循环耗时不作玩家帧率、能耗或首遇读数；正式包仍遵循原全量出包与独立验收纪律。

#467 的9000／Mali-G710验证是原作者指定设备的有限证据：8E加载尚未验证，早期手动开发局两次进程消失未定位；其他读数入口未逐一检查的边界见该 PR 与通道文档。文档或局标记不等于所有入口都已覆盖，不把未复现问题写成已修复。

本次只对齐文档来源、阶段与身份边界；未运行 Android doctor、容器、构建、APK／签名／安装或设备验收。#107 的完整准备与验收④仍须在对应环境按前述入口分别记录，不能由本节补齐为通过。

## 保存路径配置与严格离线检查

`--config <文件.json>` 读取 version=1 路径配置，示例见 [configuration.example.json](configuration.example.json)。
键名与 CLI 参数相同，用下划线连接（例如 `gradle_home`）。支持前文的路径、`image`、`offline` 和 `min_free_bytes`；不支持版本 pin、任意环境变量或命令。
未知/重复键、错误类型、负预算、空路径或损坏 JSON 返回错误（JSON 模式仍输出可解析 JSON）。
优先级为 **CLI > 配置 > 进程环境 > 默认值**；配置中的相对路径以配置文件所在目录为基准。

```sh
bash android/doctor.sh --config '<路径配置.json>' --offline --format json
```

`--offline` 不联系任何 Docker daemon，包括配置的远程 daemon；Docker/镜像能力标为 unverified。
不改变本地 javac/dotnet 版本检查。缓存 JAR 必须能读取 ZIP 目录且有 class 成员，POM 必须为正确 artifact/version；
静态库逐成员检查 ar 边界与 ELF64/AArch64 架构，截断、空 archive、宿主 x64 库和未知/bitcode 成员不当作有效目标库。
这些格式检查仍不替代 CRC/链接或完整离线解析验收。

## 评审修正（PR #133）

- NativeAOT downloadDependencies 只接受精确闭合范围：[v]、[v,v]、[v, v]。两端空白会去掉；真正区间、开区间、空值与表示最低版本的裸版本被拒绝。编译器仍须来自 libraries 的精确 Linux x64 身份；linux-arm64 libraries 与 linux-x64 downloadDependency 并存不构成通过证据。
- NDK 逐个读取 cs 的 ndk_bin、OpenSSL/编解码的 ndk 实际赋值，核对版本与宿主路径；同值重复、export/inline 重赋值或未知表达式都失败，不执行 shell、不靠脚本中出现版本字符串判断一致。
- aapt2/zipalign、CMake/Ninja 按当前宿主格式/ISA检查；NDK clang、缓存 dotnet/ilc 按构建脚本要求的 Linux x64检查，并要求执行权限。Linux ELF64、macOS 64位 Mach-O/通用二进制的匹配切片可识别；其他格式保留 unverified。
- apksigner/Gradle/NDK clang 包装器允许受支持的 sh/bash shebang，并检查解释器可用性；不执行它们。普通 CMake 数据/许可证不要求执行权限。各文件诊断记录在 actual.files，包元数据与载荷分别报告，元数据正确不会提升未知可执行文件为 ok。
- 这些是静态格式及权限证据，不证明动态链接、脚本完整执行或 APK构建。离线闭包仍 unverified；缺平台环境继续保留 Draft。
- 测试临时根先 resolve，避免 macOS 路径别名（如 /tmp 与 /private/tmp）导致字符串断言误报；不改变生产相对路径语义。

## #176 合流兼容

版本解析入口支持原 `/cache/...` 字面量和 `cache` / `cache_root=${S2A_BUILD_CACHE:-/cache}` 的已发布布局，
各生产者可分别使用新旧布局。只展开已知版本变量的 `$name` / `${name}` 引用，允许路径整体双引号。
缺失/重复赋值、未知根或表达式、路径越级、SDK 路径/版本矛盾和 JDK 来源矛盾均退出 1；从不 source/eval 生产脚本。
`--cache-root` 是库存的检查/重定位目录；不自动解释 host/build.sh 的宿主缓存默认值，也不选择构建分支。
`--dotnet` 仍只查询普通 SDK 清单；#176 的 `S2A_ANDROID_DOTNET` 宿主覆盖不代替此工具对容器精确 SDK 的载荷检查。
宿主 SDK RID 与 Android 目标编译器 RID 分开；缺最终工具选择证据仍保持 unverified。

新增组合回归通过真实 `requirements(repo)` 读取生产源码及合成变体，覆盖 16 种缓存根/JDK 来源组合；
原有精确 NuGet、NDK 消费路径、载荷架构和执行权限检查继续保留。测试不运行构建生产者，不安装或还原依赖。
