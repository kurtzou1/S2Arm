# 共享 Linux Vulkan 测试环境

`tests/shader_cases_test.sh` 与 `android/tests/vk/run.sh` 共用这一份镜像。
Linux 仍直接使用本机工具（`android/tests/vk/run.sh` 缺原生工具时同 macOS 进容器，见下）；
macOS 两入口都通过已运行的 Docker `colima` context 进入同一环境。不安装、不启动虚拟机，不在门禁里下载、构建或拉镜像。

## 显式准备（联网，门禁之外）

先自行准备 Docker（Mac 为 colima context），然后在仓库根运行：

```sh
bash tests/vulkan/prepare.sh
```

底镜像是微软官方 `.NET SDK 10.0.403-noble`，固定的是包含 Linux amd64/arm64
的 manifest-list SHA-256 `de4fe90a98845d75910b9769662465c84de1a934665c431279d1382b2bddc02b`。
2026-10-31 从 `https://mcr.microsoft.com/v2/dotnet/sdk/manifests/10.0.403-noble`
取得列表并核对响应 `Docker-Content-Digest` 与实际 JSON SHA-256 一致。
FROM、build、run 均显式固定 `linux/amd64`，从该固定清单选择 amd64；Mac ARM 宿主通过 Rosetta / QEMU 模拟 Linux amd64，不声明原生 ARM 验证。维护方实测 arm64 Ubuntu ports 无法使用该快照；因此不能按宿主架构默认选择。Ubuntu apt 使用固定快照
`20261030T000000Z`，签名校验保持默认；安装 Mesa lavapipe、Khronos validation、
glslc、spirv-val、C/C++ 编译器、Python、Vulkan headers/loader。SDK 来自上述
微软镜像，不另行运行未固定版本的 dotnet-install。

基础摘要不是最终测试镜像摘要。prepare 输出本地构建后 image ID；本地 tag 由
Dockerfile、entrypoint 与结果处理脚本内容摘要派生，并保存同一来源标签。运行先核标签，再使用
`image inspect` 得到的不可变 image ID（不使用可能在检查后改变的 tag）。两客户端
只有一个镜像定义。此处不发布镜像、不申请 registry 凭据，也不把 Dockerfile
存在视为镜像已经构建成功。

## 离线运行与结果

```sh
bash tests/shader_cases_test.sh
bash android/tests/vk/run.sh
# Linux 上显式验证同一容器，供准备环境的维护者使用：
bash tests/vulkan/run.sh tests/shader_cases_test.sh
bash tests/vulkan/run.sh android/tests/vk/run.sh
```

`android/tests/vk/run.sh` 默认档先在**宿主**上跑真编译器链（`android/tests/gs_compiler_chain_test.py`，产物
`build/696-real-compiler`），再跑后端用例。链的前置条件：`dotnet`（.NET 10 SDK）在 PATH 上；固定的
NDK 29.0.14206865（设 `ANDROID_NDK_HOME`，或放在 `$ANDROID_HOME/ndk/`、`~/Android/Sdk/ndk/` 下，其他版本不认）；
首次要联网还原 NuGet 包。容器是离线的，链在容器里跑不了：macOS 每次先在宿主出链再进容器；Linux 宿主缺原生
lavapipe / validation / glslc 时同 macOS，宿主出链后自动进容器（容器也没准备好才退出码 2）；直接运行
`bash tests/vulkan/run.sh android/tests/vk/run.sh` 而 `build/696-real-compiler` 不在时，容器内明报缺什么并返回 2，
先在宿主出链即可。

容器采用 `--pull=never --network=none`、宿主 UID/GID，只挂载本仓库，不传
Docker socket、不用 privileged、不读取用户登录配置。linked worktree 的 HEAD 由宿主 git 读取并作为专用标量传入，manifest 注明该来源；不挂仓外 gitdir，仍逐文件散列测试源码。临时 HOME 和缓存留在
一次性容器里。使用真实 lavapipe ICD，启用 Khronos validation；原 Android
`--tsan` 档继续按原约定关闭 validation，不能把它当 validation 验收。

Docker/context 未运行、镜像未准备或来源不匹配、容器启动失败返回 **75**。
容器内缺工具明报工具名并返回 **2**，真实测试失败保留非零码，不能转换成跳过。测试自身的125/126/127先在容器内映射为失败1，避免与Docker保留启动码混淆。
测试日志发现 `Validation Error` 或 `VUID-` 亦返回 1。

`container_test.py` 是 fake Docker 的进程路由/退出码合同（由 `tests/vulkan_routing_test.sh` 在宿主原生跑，不进模拟容器），不是 Docker、Mac、
Vulkan 或设备实测。8 个合成着色器的真实执行及两个负控由现有 `run.py` 保持，
不改指令、翻译器、GPU 语义或期望值。翻译器 ShaderCases.dll 按编译输入摘要（注入后源码、工程、dotnet 版本、镜像 ID）缓存在 `S2A_VULKAN_CACHE`（Mac 缺省 `~/Library/Caches/s2a_vulkan`，挂进容器 `/cache`；`off` 关），命中不编；CLI build 卡死兜底 900 秒，其他子进程/每例执行 55 秒；入口整步预算 1200 秒，不含显式首次准备镜像。总墙钟只报告，不作 60 秒性能断言；
Mac 容器实跑及其墙钟必须由有该环境的维护者另给实测，不从 Linux 结果外推。

第三方许可沿原项目：Microsoft .NET SDK、Ubuntu 打包组件各保留镜像/包内
版权及许可证；Mesa 为 MIT 等、Khronos validation 为 Apache-2.0、shaderc 与
SPIRV-Tools 为 Apache-2.0。未复制这些项目源码到本仓库。
