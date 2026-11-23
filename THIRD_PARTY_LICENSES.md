# 第三方许可

S2Arm 本身以 Apache License 2.0 授权（仓库根目录 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。版权人写 **S2Arm contributors**。下表按当前树重新核对，不是只抄旧清单。

「进 .app」表示 Mac 启动器 `S2Arm.app` 会带上（Runtime、引擎树或链进宿主）。「进 IPA」表示装到 iPhone 的游戏包进程里会带上。构建机才用、玩家包里没有的，两列都写否。安卓 APK 单列在后面一节。本清单是唯一来源，[docs/第三方依赖.md](docs/第三方依赖.md) 只指向这里。

| 组件 | 版本 | 许可 | 来源 | 进 .app | 进 IPA |
| --- | --- | --- | --- | --- | --- |
| Ryujinx 树 | 目录 `compat/tree`（旧文档记 1.3.2） | MIT | https://github.com/Ryujinx/Ryujinx ，许可 `compat/tree/LICENSE.txt` | 是（编进 Mac 宿主 / 出包工具） | 是（编进 iOS 宿主） |
| Ryujinx WSI | 派生自 Ryujinx | MIT | `graphics/vulkan/wsi`，`LICENSE.Ryujinx.txt` | 安卓/Vulkan 构建用 | 否（不进 iOS IPA） |
| 直连图形层部分代码 | 提交 `86d9ba12` | MIT | 许可全文 `graphics/nvn/LICENSE`，版权 © 2026 seedds | 是 | 是 |
| 着色器清单数据（管线预建种子） | 定期同步各上游最新提交，每份种子文件首行记来源库与提交 | MIT | nxnative、MacNativeGames、hermit、AetherNX、ffr-on-mac、OunceNative，以及 nxnative 的分叉 / 派生 18 个（plumber-racer-2、nxnative-easy、kartnative、nxnative-oot-framegen、Jhoisaac、no-lag-kart、UserDerezzed、nxnative-ultimate、Aeonitis、AmateurWizrd、Mighty-Green-Kokiri-Kid、kid-with-sword-remake ×2、iDams、mizukico、yubismartlabs、BorisChubiryaev、forbesfields）；来源表 `tools/ext_pso_sources.tsv`，版权声明与许可全文见 NOTICE「着色器清单数据」、`graphics/nvn/LICENSE`、`graphics/nvn/third_party/macnativegames/LICENSE`、`graphics/nvn/third_party/pso_lists/` | 否（经社区补丁统一包下载） | 是（出包时并进游戏包的 pso_manifest.tsv；只有着色器键与管线描述） |
| HDR 上屏 present_mode 数学（`graphics/nvn/gfx/nvn/nvn_hdr_policy.h` 的六态模式与 PQ/肩部纯函数、`nvn_mtl.m` present_pipeline 模式化着色器、`nvn2.c` 出图侧读数；单测 `graphics/nvn/tests/t_present_hdr.m`） | 提交 `3e120874062b`（PR #1176） | MIT | https://github.com/seedds/nxnative PR #1176（co-author：beecrepaldi-afk 的 PQ 层、b1tdr3amer24 的 present-after-GPU、Amost- 的纸白/peak 处理），版权 © 2026 seedds，许可全文同 `graphics/nvn/LICENSE`；适配式移植融入本仓结构（不建 vendored 子树） | 是 | 是 |
| SDR 转 HDR 扩张数学（BT.2446-1 §4.2 逆映射：`nvn_hdr_policy.h` 扩张参数式、`nvn_mtl.m`/`gal_present.m` 的 `present_itm`；单测对拍） | ITU-R BT.2446-1（免费标准文本，数学不受版权约束） | 无新增第三方代码（手写 MSL；对照 gamescope〔BSD-2-Clause，https://github.com/ValveSoftware/gamescope 〕/ libplacebo〔LGPL-2.1+，https://github.com/haasn/libplacebo 〕交叉验证，未复制两者任何代码文本） | https://www.itu.int/rec/R-REC-BT.2446/en | —（无第三方文件） | —（无第三方文件） |
| 放置式稀疏贴图块管理（`graphics/nvn/gfx/nvn/nvn_stex.inc`、单测 `runtime/tests/t_nvn_stex.m`） | kartnative 提交 `47f2d1d5` | MIT | https://github.com/pahorema/kartnative （nxnative 的分支）`dm/gfx/tex/nvn_sparse_tex.m`，版权 © 2026 seedds，许可全文同 `graphics/nvn/LICENSE` | 是 | 是 |
| APK v2 签名 / RSA / 自签证书（`android/tools/apk_sign.py`） | nx2android 仓库 `nxnative/dm/android/apk/apksign.py` | MIT | 版权 © 2026 seedds，许可全文同 `graphics/nvn/LICENSE`；改动：签名钥按机器存 `~/.s2arm/android/signing-key.json`、签磁盘上的 ZIP（文件头写明出处与改动）。启动器出安卓包时给组装好的 APK 签名 | 发版带安卓预编引擎时是（引擎树） | 否 |
| ns2pro-bridge | 基线 `4d7ce092` | MIT | https://github.com/DanielZhangyc/ns2pro-bridge ，`runtime/ns2pro/LICENSE` | 按需编进 framework 时是 | 按需编进 framework 时是 |
| Vulkan-Headers | 1.4.363 | Apache-2.0 OR MIT | https://github.com/KhronosGroup/Vulkan-Headers ，`graphics/nvn/third_party/vulkan-headers` | 否（只是编译用头） | 否 |
| SPIRV-Cross | vulkan-sdk-1.4.363.0 | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Cross ，源码在 `graphics/third_party/spirv_cross`（旧文档写「不进仓库」是错的）。命令行另从 Homebrew 打进 .app | 是（源码在引擎树；`spirv-cross` 在 Runtime/bin） | 是（`graphics/build.mk` 把源码编进 iOS 渲染器静态库 `libnxgal.a`，首遇着色器在机上现编用） |
| SPIRV-Tools | Homebrew 构建时的版本，写入 Runtime `versions.json` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Tools | 是（`spirv-as` / `spirv-val`） | 否 |
| glslang | Homebrew 构建时的版本 | 以该包 `LICENSE.txt` 为准（BSD-3-Clause 等，与 Apache-2.0 兼容） | https://github.com/KhronosGroup/glslang | 是（`glslangValidator`） | 否 |
| Arm ASTC Encoder | 5.7.0（库源码原样） | Apache-2.0 | https://github.com/ARM-software/astc-encoder ，`graphics/third_party/astc-encoder`（许可 `LICENSE.txt`）；出包时 `pack/astc_pack.py` 把 BC 贴图预转成 ASTC（Apple TV），机制参考 brad-n/TVPort（MIT） | 否（只在出包机上编成出包工具） | 否（运行时只读预转好的包） |
| bcdec | 提交 80859ed（经 MacNativeGames） | MIT 或 Unlicense | https://github.com/iOrange/bcdec ，`graphics/nvn/third_party/bcdec` | 是（链进图形层） | 是 |
| nvn_bcdec | MacNativeGames `84eebcd0985c` | MIT | https://github.com/ly05010419/MacNativeGames ，`graphics/nvn/gfx/tex/nvn_bcdec.c`；同源移植还有 `nvn_mtl.m` 几处；许可全文 `graphics/nvn/third_party/macnativegames/LICENSE` | 是 | 是 |
| nvn.h | h1k421，自公开 DWARF 重建 | MIT | `graphics/nvn/gfx/nvn/include/nvn.h` | 是（当头文件编译） | 是 |
| D3D11 细分参照 | Mesa main，2026-10-21 取 | MIT | Microsoft，经 Mesa `src/gallium/auxiliary/tessellator`；`graphics/metal/gal_tess_d3d.h` | 是 | 是 |
| SMAA | 经 Ryujinx 着色器转出（不带 FXAA：NVIDIA FXAA 3.11 没有授权条款） | MIT | `graphics/metal/shaders/AA-LICENSE.txt` | 是 | 是 |
| AMD FidelityFX Super Resolution 1（EASU + RCAS） | Ryujinx `FsrScaling.glsl` / `FsrSharpening.glsl` 内嵌的 `ffx_a.h` / `ffx_fsr1.h`（2021 版）手工移植成 Metal 着色器 | MIT（© 2021 Advanced Micro Devices, Inc.；浮点近似部分 © 2014 Michal Drobot） | `graphics/nvn/gfx/nvn/nvn_present_fsr.inc`（直连上屏的 `Fsr` 滤镜）；许可全文 `graphics/nvn/third_party/ffx_fsr1/LICENSE.txt`，两段声明另嵌在着色器源码字符串里随二进制带走（`native-test-present_fsr` 核） | 是（链进图形层） | 是 |
| LumaDock 移植 | `238c1dd` | MIT | https://github.com/Xc1Ym/LumaDock ，全文 `launchers/macos/LICENSE.LumaDock.txt` | 是（启动器） | 否 |
| LibHac | 0.21.0-alpha.133 | MIT（© 2018 Alex Barney）+ ISC（hactool，© 2018 SciresM）+ XTSSharp 声明，以包内 `LICENSE` 为准 | nupkg：`compat/packages/ryujinx.libhac.0.21.0-alpha.133.nupkg` | 是（编进 NSP/XCI 读取器） | 否 |
| Ryujinx 引用的 NuGet 包 | MsgPack.Cli 1.0.1、Humanizer 3.0.10、Gommon 2.8.1.2、Microsoft.IO.RecyclableMemoryStream 3.0.1、Microsoft.IdentityModel.JsonWebTokens 8.19.1、SkiaSharp 3.119.4、NetCoreServer 8.0.7、Open.Nat.V2 3.2.1、System.IO.Hashing 10.0.9（版本见 `compat/tree/Directory.Packages.props`） | MsgPack.Cli 为 Apache-2.0，其余 MIT（按各包 nuspec 与包内 LICENSE 核过） | NuGet，经 Ryujinx.Common / HLE / Horizon / Input 进入产品引用闭包 | 是（随 Ryujinx 工具链） | 在引用闭包里；NativeAOT 裁剪后各自是否保留未逐一核 |
| ZstdSharp.Port | 0.8.8 | MIT | nupkg：`compat/packages/zstdsharp.port.0.8.8.nupkg` | 是（随 Ryujinx 工具链） | 视宿主构建是否引用 |
| deko3d 算法移植 | — | zlib（© 2018-2020 fincs） | https://github.com/devkitPro/deko3d `source/dk_image.cpp`；移植在 `graphics/nvn/gfx/nvn/nvn_tex.c`，声明在文件第 2 行（zlib 要求改过的版本标明改过、不删声明） | 是 | 是 |
| IANA tzdata / tzcode | 2026f（`services/systemdata/tzdata-pins.sh` 钉版） | 公有领域，个别文件 BSD-3-Clause | https://www.iana.org/time-zones ；`services/systemdata/make_tzdata.sh` 生成进系统数据 | 否 | 是（资源包的系统数据） |
| Runtime 自动带上的 Homebrew 动态库 | Homebrew 构建时的版本 | OpenSSL：Apache-2.0；liblzma（xz）：0BSD；lz4：BSD-2-Clause；SQLite：公有领域；mpdecimal：BSD-2-Clause；ncurses：X11 风格 | `launchers/macos/bundle_runtime.py` 按 `otool -L` 拷进 Runtime/lib（被 Python、zstd、bash 链接）。许可拷贝目前靠 `brew deps --installed`，会漏 openssl@3，修法归出包线 | 是 | 否 |
| libarmeilleure-jitsupport | 随 Ryujinx 树的预编译库 | MIT | `compat/tree/src/ARMeilleure/Native/libs/` | 仅 Mac 宿主构建链到时 | 否 |
| Capstone（Python） | 5.0.7 | BSD-3-Clause | https://www.capstone-engine.org ，钉在 `launchers/macos/requirements-runtime.txt`；许可副本 `runtime/rewriter/LICENSES/capstone.txt`，LLVM 派生部分 `runtime/rewriter/LICENSES/capstone-llvm.txt` | 是 | 否 |
| Capstone / LZ4（C 改写器） | 由 `runtime/rewriter/prepare_deps.py` 按钉版下载，不入库 | BSD-3-Clause（另含 LLVM 派生部分，LLVM Release License）/ BSD-2-Clause | 许可副本在 `runtime/rewriter/LICENSES/` | 是（编进 `s2a-rewrite`） | 否 |
| python-lz4 | 4.4.5 | BSD-3-Clause | https://github.com/python-lz4/python-lz4 | 是 | 否 |
| NumPy | 2.4.2（.app 钉版） | BSD-3-Clause | https://numpy.org 。开发机文档里出现过 2.5.4，那是另一套环境，不打进 .app | 是 | 否 |
| Pillow | 12.3.0（与出包机钉版一致） | MIT-CMU | https://github.com/python-pillow/Pillow/blob/12.3.0/LICENSE 。已核许可原文允许使用、修改和分发，要求保留版权及许可声明、不得未经许可使用作者名作宣传，可与本项目 Apache-2.0 自有代码共存；随 Runtime 保留包的 dist-info/licenses（含 wheel 所带库的各自许可）。只用于出包图标缩放 | 是（Runtime Python 包） | 否 |
| Microsoft Visual C++ 运行库（Windows，Runtime/vcrt） | 14.44.35112，钉 SHA-256 | Visual Studio 可再发行文件条款 | https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files | 是 | 否 |
| Python | 3.12（python-build-standalone 官方构建） | PSF License | https://www.python.org | 是 | 否 |
| dmgbuild | 1.6.7 | MIT | https://github.com/dmgbuild/dmgbuild ，仅维护者 DMG 打包用，钉在 `launchers/macos/requirements-dmg.txt`；不修改上游文件，许可随安装包保存在 `dmgbuild-1.6.7.dist-info/licenses/LICENSE` | 否 | 否 |
| ds-store | 1.3.3 | MIT | https://github.com/dmgbuild/ds_store ，DMG 的 Finder 布局元数据；不修改上游文件，许可随安装包保存在 `ds_store-1.3.3.dist-info/licenses/LICENSE` | 否 | 否 |
| mac-alias | 2.2.3 | MIT | https://github.com/dmgbuild/mac_alias ，DMG 背景文件引用；不修改上游文件，许可随安装包保存在 `mac_alias-2.2.3.dist-info/licenses/LICENSE` | 否 | 否 |
| .NET 运行时 | 10.x（构建机已装的 10.* 最新补丁） | MIT | https://github.com/dotnet/runtime | 是（NativeAOT 把运行时代码静态编进 Mac 宿主与出包工具：Engine/Binaries 里的读取器 / RomFS 索引 / 着色器烘焙器 / 直连批量进程全为单文件；不带共享运行时目录） | 是（NativeAOT 把运行时代码静态编进 iOS 宿主；不带共享运行时目录） |
| zstd 命令行与 libzstd | Homebrew 构建时的版本 | BSD-3-Clause | https://github.com/facebook/zstd | 是 | 否 |
| zstd 单文件解码器（zstddeclib.c） | 1.5.7（官方发行包 `zstd-1.5.7.tar.gz`，sha256 `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`，用包内 `build/single_file_libs/combine.py` 生成，未改） | BSD-3-Clause（上游 BSD / GPLv2 二选一，本项目选 BSD） | https://github.com/facebook/zstd ，源码与许可全文在 `runtime/third_party/zstd/`；`runtime/src/pack_apply.c` 整份编入，只解压传输压缩的 game.img 块 | 是（编进 Mac 宿主） | 是（编进 iOS 宿主；安卓同链 pack_apply.c） |
| libvpx | 1.17.0 | BSD-3-Clause（附专利授权） | https://chromium.googlesource.com/webm/libvpx ，由 `services/vpx/build.sh` 按 sha256 取，不入库，构建时打 S2Arm 补丁 `services/vpx/patches/`（Nvdec VP9 作业接口，不改未调用时的解码结果）；VP9 重打包压缩头的写出顺序与默认概率表镜像其 BSD 实现（`Vp9CompressedHeader.cs`、`android/codecs/vpxbench/hdr.c`，出处 `vp9_decodeframe.c::read_compressed_header`/`vp9_entropymode.h`）；发版时 iOS arm64 / macOS arm64 静态库预编进 App（`Engine/Binaries/Prepare/libs/vpx/`），玩家出包只链接 | 是（静态链进 Mac 宿主；预编库随 App） | 是（静态链进 iOS 宿主） |
| libopus | 1.6.1 | BSD-3-Clause（附专利授权） | https://opus-codec.org ，由 `services/opus/build.sh` 按 sha256 取，不入库 | 是 | 是 |
| dav1d | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d ，由 `services/dav1d/build.sh` 按 sha256（与 downloads.videolan.org 同目录 .sha256 一致）取、在开发 / 发版机构建，不入库；发版时 iOS arm64 / macOS arm64 静态库预编进 App（`Engine/Binaries/Prepare/libs/dav1d/`，带许可原文 COPYING），玩家出包只链接。AV1 软件解码（VideoToolbox 不支持 AV1 的机器上 Switch 2 片头用） | 是（静态链进 Mac 宿主；预编库随 App） | 是（静态链进 iOS 宿主） |
| Noto Sans 字体 | 见 `pack/fonts/LICENSES.md`（Noto Sans 2.015，CJK 2.004） | OFL-1.1 | google/fonts 提交 `45e3d5269e4a17d823f6d84470bc084dc5ae46f6` | 是（生成后放进 Fonts；ttf 本身不入库） | 玩家包若带开源字体则是 |
| Unihan | Unicode 17.0.0 | Unicode License v3 | https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip | 否（只参与生成字体） | 否 |
| Gradle Wrapper | 9.8.1 | Apache-2.0 | `android/gradle/wrapper/gradle-wrapper.jar` | 否 | 否 |
| H.264 测试向量 | 自生成 | CC0-1.0 | `android/codecs/tests/vectors` | 否 | 否 |
| shader_split 夹具 | 自写 | 0BSD | `tests/fixtures/shader_split_reuse` | 否 | 否 |
| timeout（perl 实现） | 本仓库源码 | Apache-2.0 | `tools/bin/timeout`，构建 Runtime 时拷成 `Runtime/bin/timeout`；开发机经 `tools/toolchain.sh` 用同一份 | 是 | 否 |
| nxfmt / yaz0dec | 本仓库源码 | Apache-2.0 | `graphics/tools/nxfmt.py`、`graphics/tools/yaz0dec.c`。出包机有 C 编译器时现编共享库，失败则纯 Python。不预装进 .app | 否（源码在玩家选的源码树里；.app 不另塞一份 .so） | 否 |
| dmsh_xlate_bin | 见该目录 NOTICE | MIT / Apache-2.0（各包） | `translator/dmsh_xlate_bin/NOTICE.md` | 引擎树打进 .app 时会带上这些 DLL | 否 |
| AssetStudio 布局说明 | Perfare/AssetStudio 固定提交 `d158e864`；交叉核对用 aelurum/AssetStudio（AssetStudioMod）`35b24990` | MIT（只作格式依据） | Unity Shader 按版本生成布局，依据是 `Classes/Shader.cs` 的版本分支规则（逐条行号与许可全文见 `translator/THIRD_PARTY.md`）。读取器是按公开布局重写的，没有搬 AssetStudio 源码或数据 | 否 | 否 |

## 10-30 维护者 拍板的许可事项

| 事项 | 定论 | 落实方 |
| --- | --- | --- |
| 社区补丁 | 一律学成我方通用能力；公开发布的包不带上游补丁字节 | 泛化线 |
| 存档 | 存档不随包分发；玩家出包时可以导入自己的存档 | 出包线 |
| 字体 | 出包缺省改用开源替代字体（Noto Sans 等）；任天堂原版字体只用玩家从自己机器里导出的，不随包分发 | 出包线 |
| d2r_vulkan_engine 的 Harmony 来源 | 维护者 自写，MIT，已结案 | 已写入本清单；`SOURCE.json` 随目录于 2026-10-30 删除，来源/许可记录移到 `android/docs/direct-mode-d2r-study.md` §9 |
| FXAA 3.11 | 换成 SMAA，FXAA 从清单删除 | 画面线：已落地（wire-c/aa-smaa-only 删 FXAA 着色器与开关，Ryujinx 补丁 20261030-1756-no-fxaa） |

## 安卓 APK

| 组件 | 版本 | 许可 | 来源 | 进 APK |
| --- | --- | --- | --- | --- |
| libavc（H.264 解码） | AOSP `android-16.0.0_r4`，提交 `d380d04a` | Apache-2.0（源码包内 LICENSE） | `android/codecs/build.sh` 按内容 SHA 取固定源码，不入库 | 是（静态链进单库） |
| OpenSSL | 3.5.9 | Apache-2.0 | `android/openssl/build.sh` 构建，供 .NET 加密，不入库 | 是 |
| Capstone / LZ4（安卓改写器） | 同上表 5.0.7 / 1.9.4 | BSD-3-Clause（另含 LLVM 派生部分）/ BSD-2-Clause | `android/rewriter/CMakeLists.txt`，许可副本 `runtime/rewriter/LICENSES/` | 是 |
| d2r_vulkan_engine（已删除） | d2r-mobile 导入 | MIT（© 2026 jhaizhou）。原始来源「Harmony NVN-to-Vulkan implementation」为 维护者 自写，MIT（维护者 10-30 确认，原记在 `SOURCE.json` 的 `author` 字段） | 原 `graphics/third_party/d2r_vulkan_engine/`，2026-10-30 整目录删除（PR #1108）；来源/许可记录移到 `android/docs/direct-mode-d2r-study.md` §9 | 否（已删除，本仓不再分发逐字文件） |
| .NET 运行时（linux-bionic） | 10.x | MIT | https://github.com/dotnet/runtime | 是（NativeAOT 静态编进单库） |
| libopus / libvpx | 同上表 1.6.1 / 1.17.0 | BSD-3-Clause（附专利授权） | 按 sha256 取固定源码，不入库 | 是 |
| Ryujinx 树、Ryujinx 子集、直连图形层等共用组件 | 同上表 | 同上表 | 同上表 | 是（安卓单库共用同一份托管代码与原生层） |
| libadrenotools / liblinkernsbypass | Eden 分支 `8ba23b42d7` / liblinkernsbypass `aa3975893d`，经 BananaNative `3d43275` vendored | BSD-2-Clause（© 2021 Billy Laws）；`adreno_binder_compat.c` 来自 BananaNative（MIT） | https://github.com/bylaws/libadrenotools 、https://github.com/bylaws/liblinkernsbypass ；源码 `android/third_party/libadrenotools`，许可全文该目录 `LICENSE` 与 `lib/linkernsbypass/LICENSE` | 是（编成 `libadrenotools.so` / `libhook_impl.so` / `libmain_hook.so`；只在选择外挂驱动时加载。驱动二进制本身不进 APK、不入库） |

## 已经从出包路径拿掉的 GPL

| 原组件 | 许可 | 原来怎么进包 | 现在 |
| --- | --- | --- | --- |
| oead 1.3.0 | GPL-2.0-or-later | `requirements-runtime.txt`，`bundle_runtime.py` 拷进 .app 的 Python | 删除。Yaz0 解压和 SARC 读写改由 `graphics/tools/nxfmt.py`（Apache-2.0）。`shader_pack.sh` 的抽取缓存键不再含 oead 版本，并纳入 `nxfmt.py` / `yaz0dec.c`，旧抽取缓存作废。`pack/stage_extract.sh` 的阶段键同样不再含 oead 版本，抽取阶段缓存也会失效 |
| GNU coreutils 的 `timeout` | GPL-3.0 | Homebrew `coreutils` 的 `timeout` 拷进 Runtime/bin | 改为拷贝仓库自带的 perl 版 `tools/bin/timeout`（全仓唯一实现，macOS 自带 perl）。支持本仓库实际用到的 `timeout 秒 命令…`、`-k`、`-s` / `--signal`、`--foreground`，超时退出 124，到点杀整棵子孙进程树 |

## 仍随 .app 分发、但是独立程序的 GPL

GNU bash 5 继续放在 `Runtime/bin/bash`，并且排在作业 PATH 最前。换掉它风险高：引擎脚本按 bash 5 写，macOS 自带 `/bin/bash` 是 3.2，没有 `BASHPID` 等；2026-10-25 启动器在 Hades 一局里因为 `BASHPID: unbound variable` 让 EXIT 陷阱失败。`/bin/zsh` 也跑不了这些 bash 脚本。

因此 bash 保持为单独拉起的程序，不与 S2Arm 静态或动态链接。许可全文在构建时从 Homebrew bash 的 `COPYING` 拷到 `Runtime/licenses/bash-COPYING.txt`。对应源码的位置和书面提供方式写在 `launchers/macos/runtime_source_offer.txt`，并拷进同一 licenses 目录。这不把 S2Arm 其余代码变成 GPL。

## 不在仓库里、也不打进包的 copyleft

| 组件 | 许可 | 情况 |
| --- | --- | --- |
| ooz（Oodle 解码） | GPL-3.0 | 不入库。用户把自备动态库路径放在 `NXSH_OODLE`。没有就报「Oodle 插件缺」，不当作成功 |
| BymlLibrary | AGPL-3.0 | 只在研究笔记里作为本机工具被调用过（`docs/研究/直连泛化普查_DanielZhangyc.md`）。仓库没有它的源码或二进制 |
| FFmpeg | LGPL | 安卓文档写明 H.264 链接方式未定，当前没有链进，也没有放源码。若以后要链进 IPA，得单独决定动态链接或换实现 |

## 调研过、不带的

| 来源 | 许可 | 处理 |
| --- | --- | --- |
| AssetRipper/TypeTreeDumps | 没有许可证（根目录无 LICENSE） | 没有许可证等同不能用：不带、不抄。仓库原有两份取自它的布局（2018.3 Shader、2022.3 ComputeShader）已在 10-29 删除，前者改由上表 AssetStudio 规则生成，后者改走免树扫描 |
| AssetRipper/Tpk、K0lb3/UnityPy、K0lb3/tpk_ar | 代码 MIT | 它们用的 `.tpk` 数据来自 TypeTreeDumps，代码许可不覆盖数据，数据不带，也不加依赖 |
| AssetRipper/AssetRipper | GPL-3.0 | 与本仓库许可不兼容，没有读它的代码 |

## 只认磁盘格式、没有搬 GPL 源码

`graphics/tools/shbake/guest_cache.py` 和 `refpso.py` 按 yuzu / Eden 缓存的公开字段宽度解析字节（文件头 `yuzucach`、管线状态定长）。实现是本仓库自己的结构体读取，没有逐行复制 yuzu 或 Eden 的源码。两边能对上，是因为磁盘格式要互通。

`graphics/tools/shbake/nxdecomp.py` 里的 Yay0 / LZ10 / LZ11 等是按公开算法写的。文件头提到的 ooz 只是可选的用户插件，见上表。

## 维护

加或升级第三方组件时，补上版本或提交、来源 URL、用途、改了哪些文件、许可文件在哪，并写明进不进 .app / IPA。保留原作者的版权和许可文本。只在开发机用的依赖不要写成玩家运行时依赖。

本清单不代替根目录 LICENSE。返回 [README](README.md) 或[贡献指南](CONTRIBUTING.md)。
