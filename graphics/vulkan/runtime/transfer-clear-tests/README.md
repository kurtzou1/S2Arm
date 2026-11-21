# 完整颜色清除的保守快速路径

生产代码在 `PipelineFull.TryClearColorByTransfer`。Android 冷启动时显式放置
`<state>/vulkan-transfer-clears.enable` 才开启；缺省关闭，其他前端不设置此策略。
仅原高通辅助清屏分支中，全通道、单层、基准 mip、非 MSAA 的完整 2D
图像可以走 `vkCmdClearColorImage`。当前格式集合为 RGBA8/BGRA8 UNORM、RGBA8
SRGB、RGBA16 SFLOAT、B10G11R11 UFLOAT、R8 UNORM/UINT、RG16 SNORM，均有
独立真机探针。要求视图与存储格式、
尺寸完全相同，裁剪覆盖全图，实际格式与 image usage 都允许 transfer-dst。
其余输入保留原实现，不删除高通 `CmdClearAttachments` 兼容处理。

先结束渲染遍、落实待处理屏障，使用同一主命令缓冲持有 image 的 Auto 引用，
清除前后插入 all-commands ↔ transfer 依赖。图像保持 GENERAL 布局；不建新
helper pipeline、临时 UBO 或独立提交。待处理查询结果仍触发原提交，连续
transfer 清除到64次会提交。条件渲染保留旧路径；遮挡查询不计 transfer 操作。
规范：[vkCmdClearColorImage](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdClearColorImage.html)。

## 主机控制流检查

```sh
python3 graphics/vulkan/runtime/transfer-clear-tests/run.py \
  --dotnet /absolute/path/dotnet --deps /absolute/matched/runtime/dlls \
  --out /absolute/new-output
```

编译未改写的生产 dispatch/eligibility 方法，只有硬件与资源端点为记录器。
77项覆盖格式、样本数、层级、裁剪、掩码、usage、实际格式能力、条件渲染、
有待处理查询时先提交、64次上限及重置、引用保持和屏障顺序（清图后先记写入、再插屏障），
以及因写掩码为 0 没进帧缓冲的目标（#468，`PipelineBase.ZeroMaskFilteredColorView`）：
部分掩码清除走清除着色器、用该视图自己的尺寸和分量类型；全掩码清除交给
`PipelineBase.ClearRenderTargetColor`（放回帧缓冲的那一段在 `../zero-mask-attachment-tests` 里测）；
已在帧缓冲里的目标不受影响。它不验证GPU像素。
`--source-root` 可指旧源码，旧实现应在缺少 transfer 路径断言失败；不是编译失败。
`--mutation` 支持 mask/conditional/format/extent/scissor/usage/capability/pending/
bound/reset/barrier/clear/color-bits/filtered（去掉留在外面的视图，#468）；这些负控应编译成功、运行失败，失败不伪装成退出0。
UINT清除必须保留ColorF的原始位模式，不能把浮点数数值强转整数；原helper也是
`floatBitsToUint`。此项另有原始位模式断言和driver_probe的整数fragment路径。

## 真机独立驱动探针

使用本机NDK的`glslc --target-env=vulkan1.1`分别编译`probe.vert`、`probe.frag`、
`probe_uint.frag`，
用NDK的`aarch64-linux-android34-clang -O2 -Wall -Wextra driver_probe.c -lvulkan`
生成可执行文件。部署到授权设备的测试目录，执行：

```text
driver_probe probe.vert.spv probe.frag.spv probe_uint.frag.spv
driver_probe probe.vert.spv probe.frag.spv probe_uint.frag.spv omit
```

第一条应退出0；第二条故意遗漏清除，应退出1。探针不读取游戏内存。
每种格式128组、图像96×80：绘制红底→完整transfer清除→带变化裁剪的绿块绘制→读回。
遮挡查询跨两遍及中间清除；设备支持精确查询时逐项要求7744个样本。
8个格式共7864320像素。0.5线性色分别核sRGB编码、半浮点/packed-float位模式，
SNORM含负值；UINT用17/123等原始整数。UNORM/SRGB/SNORM允许1 LSB量化误差，
半浮点、packed-float和UINT按精确位模式核对。
原厂Adreno840实测0超容差像素、0查询差；遗漏清除负控每格式974848像素错误，
精确查询保持正确。它验证驱动原语/顺序，不能代替
生产C#接线、所有格式/驱动、游戏场景或能耗验收；没有开启Vulkan验证层。

首次尝试的“无活动查询时借用主CB辅助绘制”没有纳入生产代码：持续查询使
该路径适用性不足，两个v12局18.37/20.37次present每秒还有缓存/分配量差异，
不能称性能改善。该实验资料只在本地保留。

真机同包性能对照结果另记于`android/docs/transfer-clear-optimization.md`。
