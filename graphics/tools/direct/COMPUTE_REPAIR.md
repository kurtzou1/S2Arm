# 大型计算着色器的 Metal 编译兼容性

`DshFlat.GiantFix` 在原有深层阶梯压平之后调用 `DshOutline.Compute`。同一实现用于离线出库与设备缺键现编。新增源码自动进入 `S2A.Dsh.csproj` 的 `DshXfpInput`；翻译器指纹变化会使翻译缓存失效，MSL 内容变化会使 Metal 编译缓存失效，不需要另加游戏配置或更换宿主 ABI 链号。

拆分只处理 SPIRV-Cross 生成的、函数体至少 8192 行的 `kernel void main0`：选择互不重叠的封闭 `if` 函数体，提取为内部链接的 `noinline` 辅助函数。辅助函数体限定为 128–6000 行；条件仍在原位置执行。捕获的私有值、缓冲指针和共享存储通过保留地址空间的引用传递。含跨函数出口、同步或 SIMD 收敛操作的候选不拆；不能确定声明、作用域或版式时保持原文。小着色器、其他阶段不变。

这是针对巨大入口导致的 Metal 优化器长时间不返回的兼容性改形，不是对任意编译器卡住的超时恢复，也不跳过 GPU 工作。未覆盖的语法或其他编译器缺陷仍可能需要后续修复。

## 已出包的 Mac 游戏

只更新 S2Arm.app 不会重写已经生成的 metallib。使用带修复的版本重新准备着色器库，或在本机对现有库运行 `repair_compute.py`；不需要重新提取游戏原件，也不需要重新改写游戏主程序。

准备工具需要 Xcode / Metal 工具链、Python、.NET 10 运行时，以及用本次源码构建的 `dsh_batch.dll`。开发者可用 .NET 10 SDK 构建：

```sh
dotnet build graphics/tools/direct/dsh/batch/dsh_batch.csproj -c Release -o build/compute-batch
python3 graphics/tools/direct/repair_compute.py \
  --library '<Mac 镜像>/shaders/direct/b-<链号>' \
  --manifest '<Mac 镜像>/manifest.json' \
  --cache '<出包缓存>/store/dshb' \
  --work '<私有修复目录>' \
  --dotnet '<dotnet 可执行文件>' \
  --outliner build/compute-batch/dsh_batch.dll
```

准备阶段不修改已安装游戏。工具枚举当前库中的计算着色器，校验翻译缓存的内容摘要和键，再用已安装 `fn_prefix` 与 MSL 内容摘要匹配源版本。只替换能安全拆分的源码；每份替换库都必须通过 Metal 编译和无自建归档的计算管线创建。找不到准确源版本或有编译失败就停止，不发布部分结果。

退出 S2Arm 和运行中的游戏后应用：

```sh
python3 graphics/tools/direct/repair_compute.py \
  --library '<Mac 镜像>/shaders/direct/b-<链号>' --work '<私有修复目录>' --apply
```

工具新增一个分片，切换 `lib.idx`，同步更新清单中的真实大小和摘要，并记下本地修复来源。原分片、存档和缓存均保留。之后从 S2Arm 正常启动游戏。

回滚使用同一命令，把 `--apply` 换成 `--rollback`。原索引和原清单从修复目录恢复；未使用的新分片保留。若切换中断，重新执行应用或回滚可完成索引与清单的切换；若游戏已重新出包、文件身份不符，工具拒绝覆盖。修复目录是回滚依据，不要提前删除。

## 验证

- `python3 graphics/tools/direct/tests/t_compute_outline.py`：通过生产 `GiantFix` 边界验证拆分与拒绝条件，编译 Mac / iOS 合成着色器，并把 Mac GPU 结果与独立的 uint32 CPU 判据对照。
- `python3 graphics/tools/direct/tests/t_repair_compute.py`：验证索引读取、应用、重复应用、回滚、切换中断恢复、拒绝覆盖已变化的游戏、缓存完整性。测试只使用原创合成数据。
- `python3 graphics/tools/direct/tests/t_repair_loader.py`：通过生产 `shader_build`、库容器与 `ulibs` 缓存，分别验证同批兄弟先加载、替换函数先加载的真实 GPU 结果；恢复旧 `fn_lib` 后两种顺序都必须失败。此测试直接提供 Metal device，不验证完整宿主初始化或 NVN 命令回放。
- 原有 `t_dmsh_giant.py` 继续验证深层控制流改形及 GPU 差分。

管线创建成功不能替代 GPU 结果验证，合成计算核也不能证明全游戏正确。日志的 `still compiling after 5000 ms` 是告警，不是编译取消或 GPU 算力预算。无自建管线归档的测试仍可能命中系统编译缓存，因此不能把单次耗时当作冷编译性能数据。
