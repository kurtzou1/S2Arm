# GAL Metal 后端：libnxgal.dylib（Mac 宿主 / 单测用；iOS 上同一组源码静态链进主程序）+ 单测。
# 产物进 <仓库根>/build/gal/（不进仓）。用法：make -C graphics/metal test
# 源码 = 本目录全部 gal_*.m（新块加文件即自动纳入）；单测 = tests/t_*.c|m 各自一个可执行，直接连源码（可调内部接口）。
# tests/<名>_stubs.m 存在时一并链入该单测（块合入前的临时桩，强定义盖过 gal_weak.m 的弱缺省）。
# ROOT 可由调用方在命令行给无空格别名（tools/nospace.sh；10-25 路径带空格）：下面所有绝对路径都从 ROOT 拼，不再用 abspath / CURDIR（会解析回带空格的真路径）
ROOT  := $(abspath ../..)
# Xcode 按用户机器（10-25，不写死版本）：指定 S2A_DEVELOPER_DIR > 环境里的 DEVELOPER_DIR（tools/toolchain.sh 解析后导出）> tools/toolchain.sh 当场解析（缺省装着的最新 Xcode，同根 Makefile）> xcode-select；
#   11-14：原先单独 make -C graphics/metal 时跳过 toolchain.sh 直接退到 xcode-select（本机指 Xcode 26.6），metal-tt 出的 Metal 3 归档 macOS 27 运行时认不得（test-m3 / test-m3archive 全未命中）
#   先在 include 之前记下环境值——toolchain.env 里那行不当缺省（make 里文件内赋值会盖过环境变量）。赋值行不带行尾注释：注释前的空格会进值
_S2A_ENV_DD := $(DEVELOPER_DIR)
include $(ROOT)/tools/toolchain.env
# 前端 / 玩家机器用 S2A_DEVELOPER_DIR 指自己的 Xcode（同 tools/toolchain.sh，#49）：不设 = toolchain.env 那套（10-23 Spare-host 全新机器实测：Makefile 不认，没装 27.1 的机器着色器键算不出）
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell S2A_TC_QUIET=1 bash -c '. "$$1" > /dev/null && printf %s "$$DEVELOPER_DIR"' _ $(ROOT)/tools/toolchain.sh 2>/dev/null),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET   # iOS 下限只在 IOS_FLAGS 里显式用（见 tools/toolchain.sh）
OUT   := $(ROOT)/build/gal
# 配方失败就删掉它已写出的目标（10-25 门禁「首跑红、重跑绿」：t_fbrp_lib.sh 先写出 fbr.tsv、后面的合编核对才失败，
#   目标留着比依赖新，重跑时 make 直接跳过、门禁转绿，真失败被盖住）
.DELETE_ON_ERROR:
SRCS  := $(sort $(wildcard gal_*.m))
# 头文件依赖覆盖本目录全部 *.h（10-29：只列 gal_*.h 漏了 fit_judge.h，改它的分支在增量树里不重编、渲染器单测假绿，合入 main 后干净树才红）。
#   不用 -MMD：这里各规则是多个源码一条 clang 一次编链，-MMD 只记下最后一个源码的依赖（实测 prog: b.c，前面源码的头全丢），反而假绿
HDRS  := $(wildcard *.h)
# 源码绝对路径（__FILE__ / 调试信息目录）映射成仓库相对路径：发布出去的库与工具不带出包机的用户目录（10-23 beta.2 前）
# 单独加在各编译行、不进 OBJCFLAGS：翻译键（graphics/tools/shbake/xc_key.sh）哈希 OBJCFLAGS，进去就带上仓库绝对路径、换目录键就变
PFX   := -ffile-prefix-map=$(ROOT)=.
# macOS 宿主编译固定用所选 Xcode 的 macOS SDK（10-26 22:4x：不给 -isysroot 时 clang 按各机默认挑 SDK——本机落到 CommandLineTools 的 MacOSX26.4、gate-host 落到
#   Xcode-27.1 的 MacOSX.sdk，同一提交编出的 gal_xc 不同，远端出包的着色器产物不能复用）。和 PFX 一样单独加在编译行、不进 OBJCFLAGS（不让 SDK 路径进翻译键）
MAC_SDK := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk macosx --show-sdk-path 2>/dev/null)
#   SDK 路径本身也映射成固定名：同一份 SDK 在各机的安装路径不同（gate-host 解析到 Xcode-27.app、本机 Xcode-27.1.app），路径字符串会进目标文件
#   clang 自带头文件（Xcode 里的 lib/clang/<版本>/include）的路径同理：所选 Xcode 的应用根（软链路径与真实路径各一条）都映射成 Xcode.app
XC_APP := $(if $(DEVELOPER_DIR),$(abspath $(DEVELOPER_DIR)/../..))
XC_APP_REAL := $(if $(XC_APP),$(shell cd $(XC_APP) 2>/dev/null && pwd -P))
MACSYS := $(if $(MAC_SDK),-isysroot $(MAC_SDK) -ffile-prefix-map=$(MAC_SDK)=MacOSX.sdk) $(if $(XC_APP),-ffile-prefix-map=$(XC_APP)=Xcode.app) $(if $(XC_APP_REAL),-ffile-prefix-map=$(XC_APP_REAL)=Xcode.app)
OBJCFLAGS := -O2 -g -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -I$(OUT)/gen
# ABI 指纹（gal_abi.h 内容生成，C / C# 两端各编一份、初始化比对）：所有编源码的目标都依赖它
ABIH  := $(OUT)/gen/gal_abi_hash.h
# 曲面细分器 MSL（gal_tess_d3d.h 原文嵌成字符串，gal_tess.m 用）：与 ABIH 一样是编源码的生成依赖
TESSH := $(OUT)/gen/gal_tess_msl.h
AA_NAMES := edge blend neighbour
AA_MSLH := $(addprefix $(OUT)/gen/gal_aa_,$(addsuffix .h,$(AA_NAMES)))
AA_LUT := $(ROOT)/compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures
AA_LUTH := $(OUT)/gen/gal_aa_lut.h
GENH  := $(ABIH) $(TESSH) $(AA_MSLH) $(AA_LUTH)
T_TESS := $(OUT)/t_tess/vs.spv $(OUT)/t_tess/tcs.spv $(OUT)/t_tess/tes.spv $(OUT)/t_tess/fs.spv $(OUT)/t_tess/tesatom.spv
# t_draw 原始位顶点输入段（Ryujinx 补丁 vattr-raw 的形态）：手写 SPIR-V，运行时现翻
T_VRAW := $(OUT)/t_vraw/vs.spv $(OUT)/t_vraw/fs.spv
LIBS  := -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics
# 直连着色器翻译段（颜色出口 / 加固 / 溢出 / 曲面翻译 / 顶点自取纯 C 部分 / 直连 XC）与 SPIRV-Cross 在直连翻译库 libdsx（graphics/dsx/Makefile，11-08 拆出）：
#   本目录不再编它们。渲染器自己也要用（gal_spill_msl / gal_tessxc_* / spvc_* 等）：libnxgal.dylib 以 -hidden-l 静态链入 libdsx（符号全隐藏，不导出 nxgal_dmsh_* / nxgal_spv_* / spvc_*）；
#   mac / ios 静态库不再合并 libdsx，链接方（graphics/build.mk、单测）另链 build/dsx/{mac,ios}/libdsx.a。直连消费方（S2A.Dsh 等）只认 libdsx
SPVC_DIR := $(ROOT)/graphics/third_party/spirv_cross
DSX_OUT := $(ROOT)/build/dsx
DSX_MAC_A := $(DSX_OUT)/mac/libdsx.a
DSX_IOS_A := $(DSX_OUT)/ios/libdsx.a
SPVC  := -I$(SPVC_DIR) $(DSX_MAC_A) -lc++
HDRS  += $(wildcard ../dsx/*.h)
# t_prog 要输入目录（手写 SPIR-V 及其离线库），单列在下面
# t_gpuwd（T10 / #635 GPU 挂死看门狗）单列：它不碰 Metal、不碰 gal_core，走通用规则要白搭 35 秒把整套源码再链一遍。
#   从自动收集里摘出来，在 all 与 test 里各显式挂一次（test 里带 timeout 60，同 t_buf / t_draw 的写法）
TESTS := $(filter-out t_prog t_gpuwd,$(sort $(basename $(notdir $(filter-out %_stubs.m,$(wildcard tests/t_*.c tests/t_*.m))))))
J     ?= 8

all: $(OUT)/libnxgal.dylib $(addprefix $(OUT)/,$(TESTS)) $(OUT)/t_prog $(OUT)/t_gpuwd $(OUT)/gal_xc $(OUT)/xc_bench $(T_TESS) $(T_VRAW) $(HELPERS)

# 静态库原子出（10-31 银河2 正式包红：抓着色器的 make host 与宽屏探针的 make host 同树同时跑，旧写法先清共享 o/ 再原地 ar，
#   macOS ar 遇到被对方清掉 / 写坏的成员仍退 0、只留 96 字节空库，两边链接 nxgal_* 全缺）：目标文件编进本次私有目录，库先出到临时名、
#   核成员数不少于本次编出的目标文件数再原子改名到位；并行的另一份各编各的，谁后改名都是完整的库
LIBCHK = [ $$(ar t $@.$$$$ | grep -c '\.o$$') -ge $$(ls "$$d"/*.o | wc -l) ] || { echo "【红】$@：建出的库成员数少于目标文件数"; exit 1; }
# libdsx 静态库由它自己的 Makefile 判新旧（真实文件目标 + FORCE，同 graphics/build.mk：库没变就不重链）
# OUT= 显式给回 dsx 自己的产物目录：本目录常被 make OUT=<临时目录> 调（tests/visual/gate.sh 等），不给会随 MAKEFLAGS 传进 dsx，目标路径对不上（No rule to make target）
$(DSX_MAC_A): FORCE
	$(MAKE) -C $(ROOT)/graphics/dsx OUT=$(DSX_OUT) $@
$(DSX_IOS_A): FORCE
	$(MAKE) -C $(ROOT)/graphics/dsx OUT=$(DSX_OUT) $@
FORCE:

# iOS 版：全部 gal_*.m 编成静态库（出包线链进 NativeAOT 主程序；iOS 首遇现编要的 SPIRV-Cross 与翻译段在 build/dsx/ios/libdsx.a，链接方另链）
IOS_SDK := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_FLAGS := -arch arm64 -isysroot $(IOS_SDK) -mios-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
# 离线辅助库的 Metal 编译 SDK 与系统下限（Apple TV 由顶层 graphics/build.mk 从命令行换成 appletvos / -mtvos-version-min；Metal 3 那份 iOS 固定 18.0）
METAL_SDK ?= iphoneos
METAL_MIN ?= -mios-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
METAL_MIN3 = $(if $(filter iphoneos,$(METAL_SDK)),-mios-version-min=18.0,$(METAL_MIN))
ios: $(OUT)/ios/libnxgal.a $(OUT)/ios/gal_helpers/.stamp
# iOS 版离线辅助库（10-23）：源码与平台无关（Mac 版 gal_xc 导出，源码哈希两边相同），用 iOS SDK 编；pack/ipa.sh 签名前拷进 App 的 gal_helpers/
$(OUT)/ios/gal_helpers/.stamp: $(OUT)/gal_xc
	rm -rf $(OUT)/ios/gal_helpers && mkdir -p $(OUT)/ios/gal_helpers/src && $(OUT)/gal_xc --helpers $(OUT)/ios/gal_helpers/src
	for f in $(OUT)/ios/gal_helpers/src/*.metal; do xcrun -sdk $(METAL_SDK) metal -std=metal4.0 $(METAL_MIN) -o $(OUT)/ios/gal_helpers/$$(basename $$f .metal).metallib $$f || exit 1; done
	mkdir -p $(OUT)/ios/gal_helpers/m3 && for f in $(OUT)/ios/gal_helpers/src/*.metal; do xcrun -sdk $(METAL_SDK) metal -std=metal3.2 $(METAL_MIN3) -o $(OUT)/ios/gal_helpers/m3/$$(basename $$f .metal).metallib $$f || exit 1; done
	touch $@
$(OUT)/ios/libnxgal.a: $(SRCS) $(HDRS) $(GENH)
	@mkdir -p $(OUT)/ios
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(addprefix $(ROOT)/graphics/metal/,$(SRCS)); do clang $(PFX) -O2 -fobjc-arc -fvisibility=hidden $(IOS_FLAGS) -I$(SPVC_DIR) -I$(OUT)/gen -Wno-unguarded-availability-new -c $$f || exit 1; done) \
	  && libtool -static -o $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@

# Mac 宿主静态库（S2A_CS=1 make host 链进 build/s2arm-host，graphics/build.mk 用）：全部 gal_*.m 目标文件（libdsx 由 graphics/build.mk 另链）
mac: $(OUT)/mac/libnxgal.a
$(OUT)/mac/libnxgal.a: $(SRCS) $(HDRS) $(GENH)
	@mkdir -p $(OUT)/mac
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(addprefix $(ROOT)/graphics/metal/,$(SRCS)); do clang $(PFX) $(MACSYS) $(OBJCFLAGS) -fvisibility=hidden -I$(SPVC_DIR) -c $$f || exit 1; done) \
	  && libtool -static -o $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@

$(ABIH): gal_abi.h tools/abi_hash.py
	@mkdir -p $(OUT)/gen
	python3 tools/abi_hash.py gal_abi.h --c $@
$(TESSH): gal_tess_d3d.h tools/embed_msl.py
	@mkdir -p $(OUT)/gen
	python3 tools/embed_msl.py gal_tess_d3d.h k_tess_ts_src $@
$(OUT)/gen/gal_aa_%.h: shaders/aa_%.metal tools/embed_msl.py
	@mkdir -p $(OUT)/gen
	python3 tools/embed_msl.py $< k_aa_$* $@
$(AA_LUTH): $(AA_LUT)/SmaaAreaTexture.bin $(AA_LUT)/SmaaSearchTexture.bin tools/embed_aa_lut.py
	@mkdir -p $(OUT)/gen
	python3 tools/embed_aa_lut.py $(AA_LUT) $@

$(OUT)/libnxgal.dylib: $(SRCS) $(HDRS) $(DSX_MAC_A) $(GENH)
	@mkdir -p $(OUT)
	clang $(PFX) $(MACSYS) $(OBJCFLAGS) -fvisibility=hidden -dynamiclib -install_name @rpath/libnxgal.dylib -o $@ $(SRCS) $(LIBS) -I$(SPVC_DIR) -L$(DSX_OUT)/mac -Wl,-hidden-ldsx -lc++   # libdsx 按需链入、符号全隐藏：直连入口只由 libdsx 导出

# 内部辅助库离线化（10-23）：gal_xc --helpers 导出辅助库 MSL → xcrun metal -std=metal4.0（运行时缺省同为 metal4.0 + 快速数学）编成
#   $(OUT)/gal_helpers/gal_helper_<键>.<源码哈希>.metallib；渲染器在可执行文件 / libnxgal 旁的 gal_helpers/ 按源码哈希找，找到就不现编（gal_core.m helper_offline）
# Metal 3 兼容版（M3-2 / #109）：同一份 MSL 另出一份 -std=metal3.2（iOS 18 / macOS 15 起）放进 m3/ 子目录，文件名与源码哈希同 Metal 4 版；
#   7 个库实测没有 MSL 4 专有语法，MSL 源不用分两版。运行时选库逻辑不在本卡（M3-4 再接），这里只出产物 + 单测 t_helper_m3 用老接口验能载、能按名取函数
HELPERS := $(OUT)/gal_helpers/.stamp
$(HELPERS): $(OUT)/gal_xc
	rm -rf $(OUT)/gal_helpers && mkdir -p $(OUT)/gal_helpers/src && $(OUT)/gal_xc --helpers $(OUT)/gal_helpers/src
	for f in $(OUT)/gal_helpers/src/*.metal; do xcrun -sdk macosx metal -std=metal4.0 -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -o $(OUT)/gal_helpers/$$(basename $$f .metal).metallib $$f || exit 1; done
	mkdir -p $(OUT)/gal_helpers/m3 && for f in $(OUT)/gal_helpers/src/*.metal; do xcrun -sdk macosx metal -std=metal3.2 -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -o $(OUT)/gal_helpers/m3/$$(basename $$f .metal).metallib $$f || exit 1; done
	touch $@
# 单测：.c 按 C 编，.m 按 Objective-C（ARC）编；都直接连源码。都依赖离线辅助库（单测断言渲染器启动到首帧不现编）
#   EXTRA_FLAGS / EXTRA_SRCS：目标各自的追加旗标 / 追加源码（缺省空——其余单测命令行一字不变）
$(OUT)/t_%: tests/t_%.* $(SRCS) $(HDRS) $(wildcard tests/*.h) $(DSX_MAC_A) $(GENH) | $(HELPERS)
	@mkdir -p $(OUT)
	clang $(PFX) $(MACSYS) $(EXTRA_FLAGS) $(OBJCFLAGS) -o $@ $(firstword $(wildcard tests/t_$*.c tests/t_$*.m)) $(wildcard tests/t_$*_stubs.m) $(EXTRA_SRCS) $(SRCS) $(LIBS) $(SPVC)

# t_present_hdr（PR7 gal HDR 闭环，评审稿 v3 §4 PR7）：链生产策略存储 graphics/nvn/gfx/nvn/nvn2.c（纯 C）——
#   gal 经 dlsym 接缝（RTLD_DEFAULT，同 gal_present.m ap_direct 先例）消费策略入口：宿主里由直连图形层给，
#   本单测里命中可执行文件自身的生产强定义。nvn2.c 的 dm_opmode 由测试文件替身给（同 graphics/nvn/tests/t_nvn2.c 文案）；
#   其 dm.h（替身头）引 native.h 的生成头按 -Iruntime/include 取（同 runtime/build.mk NATIVE_INC）
$(OUT)/t_present_hdr: EXTRA_SRCS := ../nvn/gfx/nvn/nvn2.c
$(OUT)/t_present_hdr: EXTRA_FLAGS := -I$(ROOT)/runtime/include
$(OUT)/t_present_hdr: ../nvn/gfx/nvn/nvn2.c

# GPU 挂死看门狗单测（T10 / #635）：只链 gal_gpuwd.m + 自己，不链整套源码 —— 它不碰 Metal、不碰 gal_core，
#   全程不提交任何命令缓冲（用「登记了栅栏但从不推进完成号」造挂死，主线程用 read 空管道冒充 waitUntilCompleted）
$(OUT)/t_gpuwd: tests/t_gpuwd.c gal_gpuwd.h gal_gpuwd.m
	@mkdir -p $(OUT)
	clang $(PFX) $(MACSYS) $(OBJCFLAGS) -o $@ tests/t_gpuwd.c gal_gpuwd.m -framework Foundation

# t_pso_registry 的着色器离线编成 metallib 放在可执行文件旁（10-23：单测不再现场编 MSL / 建归档，归档夹具按工具链指纹缓存，见 tests/fixture.h）
$(OUT)/t_pso_registry_in/registry.metallib: tests/t_pso_registry.metal
	@mkdir -p $(OUT)/t_pso_registry_in
	xcrun -sdk macosx metal -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -o $@ $<
$(OUT)/t_pso_registry: $(OUT)/t_pso_registry_in/registry.metallib tests/fixture.h
$(OUT)/t_fixture $(OUT)/t_cnt $(OUT)/t_draw $(OUT)/t_merge $(OUT)/t_tex $(OUT)/t_psowait: tests/fixture.h
# t_m3pso（#115 / M3-8 Metal 3 管线编译）：TESTS 由 tests/t_*.m 自动收；库走 fixture.h 的离线夹具
$(OUT)/t_m3pso: tests/fixture.h
$(OUT)/t_m3archive: tests/fixture.h
# t_m3probe（#108 / M3-1 Metal 3 探针）：独立单测，只用老接口（MTLBinaryArchive / MTLDynamicLibrary），
#   不经过渲染器、不依赖 NXGAL_BE=mtl3；归档在临时目录现建，不需要离线辅助库
$(OUT)/t_m3probe: tests/fixture.h
# t_helper_select（#117）：生产辅助库按后端选目录，真实计算读回与缺失/损坏反例。
# 同由 TESTS 自动收进 test-deps / test，graphics/gate.sh 经这两个入口执行，不重复登记。

# 首遇现编耗时测量（Mac 版；iOS 版由出包线的测试 App 调 xc_bench_main）
$(OUT)/xc_bench: tools/xc_bench.m $(SRCS) $(HDRS) $(DSX_MAC_A) $(GENH)
	clang $(PFX) $(MACSYS) $(OBJCFLAGS) -I$(SPVC_DIR) -o $@ tools/xc_bench.m $(SRCS) $(LIBS) $(SPVC)
# 第 4 块：离线库工具（SPIR-V 目录 → MSL + 索引；tools/gal_offline.py 调它再并行 xcrun metal → metallib）
$(OUT)/gal_xc: tools/gal_xc.c gal_abi.h $(OUT)/libnxgal.dylib Makefile
	clang $(PFX) $(MACSYS) -O1 -g -Wall -Wextra -o $@ tools/gal_xc.c -L$(OUT) -lnxgal -Wl,-rpath,@executable_path   # 与 libnxgal.dylib 同目录：rpath 不写编它那棵树的绝对路径（临时合入工作树删掉后共享产物根的 gal_xc 就找不到库，10-18 出包线踩到）
# t_draw 曲面细分段输入：手写四段 SPIR-V（与 t_draw 同目录的 t_tess/，运行时现翻）
$(OUT)/t_tess/%.spv: tests/t_tess_%.spvasm
	@mkdir -p $(OUT)/t_tess
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_vraw/%.spv: tests/t_vraw_%.spvasm
	@mkdir -p $(OUT)/t_vraw
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
# t_prog 输入：手写 SPIR-V（spirv-as）+ 它们的离线库（验 load_binary / 离线路径）
$(OUT)/t_prog_in/%.spv: tests/t_prog_%.spvasm
	@mkdir -p $(OUT)/t_prog_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_session_resources: $(OUT)/t_prog_in/vs.spv $(OUT)/t_prog_in/fs.spv
# t_fbr / t_fbfetch 输入：片元帧缓冲读取证明的正反例手写 SPIR-V（tests/t_fbr_*.spvasm），放在可执行文件旁的 t_fbr_in/
$(OUT)/t_fbr_in/%.spv: tests/t_fbr_%.spvasm
	@mkdir -p $(OUT)/t_fbr_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
T_FBR := $(patsubst tests/t_fbr_%.spvasm,$(OUT)/t_fbr_in/%.spv,$(wildcard tests/t_fbr_*.spvasm))
$(OUT)/t_fbr $(OUT)/t_fbrp $(OUT)/t_fbfetch $(OUT)/t_texbards $(OUT)/t_firstskip $(OUT)/t_xcstall $(OUT)/t_xcqos $(OUT)/t_nofrag $(OUT)/t_psoasync $(OUT)/t_speccombo $(OUT)/t_psodev $(OUT)/t_psopf: $(T_FBR)
# t_fbrp 输入：出包那条路造的离线库（gal_xc --fbr 证明 + 改写 → gal_offline.py），见 tests/t_fbrp_lib.sh
T_FBRP := $(OUT)/t_fbrp_in/fbr.tsv
$(T_FBRP): $(T_FBR) $(OUT)/gal_xc tools/gal_offline.py tools/unity_check.py tests/t_fbrp_lib.sh
	bash tests/t_fbrp_lib.sh $(OUT)
# t_border 输入：自定义边框色端到端的手写 SPIR-V（tests/t_border_*.spvasm），放在可执行文件旁的 t_border_in/
$(OUT)/t_border_in/%.spv: tests/t_border_%.spvasm
	@mkdir -p $(OUT)/t_border_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_border: $(OUT)/t_border_in/vs.spv $(OUT)/t_border_in/fs.spv
# t_lodbias 输入：采样器 LOD 偏置原生 / 着色器模拟端到端的 SPIR-V（tests/t_lodbias_*.spvasm，GLSL 经 glslangValidator 生成后反汇编），放在可执行文件旁的 t_lodbias_in/
$(OUT)/t_lodbias_in/%.spv: tests/t_lodbias_%.spvasm
	@mkdir -p $(OUT)/t_lodbias_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_lodbias: $(OUT)/t_lodbias_in/vs.spv $(OUT)/t_lodbias_in/fs.spv
# t_drawid 输入：绘制号（gl_DrawID / BuiltIn DrawIndex）端到端的 SPIR-V（tests/t_drawid_*.spvasm，GLSL 经 glslangValidator 生成后反汇编），DrawParameters 自 Vulkan 1.1 进核心
$(OUT)/t_drawid_in/%.spv: tests/t_drawid_%.spvasm
	@mkdir -p $(OUT)/t_drawid_in
	spirv-as --target-env vulkan1.2 $< -o $@ && spirv-val --target-env vulkan1.2 $@
$(OUT)/t_drawid: $(OUT)/t_drawid_in/vs.spv $(OUT)/t_drawid_in/fs.spv
# t_wline 输入：宽线展开端到端的手写 SPIR-V（tests/t_wline_*.spvasm）
# t_iblend 输入：整数输出片元（tests/t_iblend_fs.spvasm），顶点用宽线那份（位置直通）
$(OUT)/t_iblend_in/fs.spv: tests/t_iblend_fs.spvasm
	@mkdir -p $(OUT)/t_iblend_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_iblend: $(OUT)/t_wline_in/vs.spv $(OUT)/t_iblend_in/fs.spv
$(OUT)/t_wline_in/%.spv: tests/t_wline_%.spvasm
	@mkdir -p $(OUT)/t_wline_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_wline $(OUT)/t_rdiscard $(OUT)/t_logicop: $(OUT)/t_wline_in/vs.spv $(OUT)/t_wline_in/fs.spv
# t_logicop 整数输出片元：手写 SPIR-V（tests/t_lop_*.spvasm：uint 输出、int 输出、带丢弃）
$(OUT)/t_lop_in/%.spv: tests/t_lop_%.spvasm
	@mkdir -p $(OUT)/t_lop_in
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
$(OUT)/t_logicop: $(OUT)/t_lop_in/fsu.spv $(OUT)/t_lop_in/fsi.spv $(OUT)/t_lop_in/fsd.spv
# 片元输入上限用例另放 t_prog_fin（全读那支故意翻译失败，不进离线库）
$(OUT)/t_prog_fin/%.spv: tests/t_prog_%.spvasm
	@mkdir -p $(OUT)/t_prog_fin
	spirv-as --target-env vulkan1.0 $< -o $@ && spirv-val --target-env vulkan1.0 $@
T_FIN := $(OUT)/t_prog_fin/fs32r4.spv $(OUT)/t_prog_fin/fs32r32.spv
T_SPV := $(OUT)/t_prog_in/vs.spv $(OUT)/t_prog_in/fs.spv $(OUT)/t_prog_in/cs.spv $(OUT)/t_prog_in/vsl.spv $(OUT)/t_prog_in/cso.spv $(OUT)/t_prog_in/csspill.spv $(OUT)/t_prog_in/csl.spv $(OUT)/t_prog_in/csw.spv
$(OUT)/t_prog_in/lib/gal.shards: $(T_SPV) $(OUT)/gal_xc tools/gal_offline.py
	GAL_SHARD_MB=0.001 python3 tools/gal_offline.py $(OUT)/t_prog_in $(OUT)/t_prog_in/lib macos   # 每片约 1 KB：每支各一片，单测走多片按键取片
# 语料（acnh 467 支着色器，约 2 分钟）：只在 make test-corpus 时生成；CORPUS_SRC 缺省取旧库只读产物，新库出包产物到位后改指新根
CORPUS_SRC ?= $(HOME)/.s2arm/out/acnh/shaders
$(OUT)/corpus/failed.txt:
	cd tools/gal_spvgen && dotnet publish gal_spvgen.csproj -c Release -nodeReuse:false -p:UseSharedCompilation=false -o $(OUT)/gal_spvgen -v quiet > $(OUT)/gal_spvgen.log 2>&1
	$(OUT)/gal_spvgen/gal_spvgen $(CORPUS_SRC) $(OUT)/corpus 200 200
$(OUT)/corpus/lib/gal.shards: $(OUT)/corpus/failed.txt $(OUT)/gal_xc tools/gal_offline.py
	J=$(J) python3 tools/gal_offline.py $(OUT)/corpus $(OUT)/corpus/lib macos

# test-deps：单测要的全部产物（门禁先单独 make -j 并行编它、只把跑单测计进 300 秒；10-23 本机冷编顺序 362 秒 / -j18 并行 60 秒 / 只跑单测 33 秒）
test-deps: all $(OUT)/t_prog_in/lib/gal.shards $(T_FIN) $(T_FBRP)

test: test-deps
	@set -e; for t in $(TESTS); do echo "== $$t"; s=$$(date +%s); $(OUT)/$$t; echo "·· $$t $$(( $$(date +%s) - s )) 秒"; done; echo "== t_prog（出包口径：计数关）"; $(OUT)/t_prog $(OUT)/t_prog_in; echo "== t_prog --count（计数开：现翻 + 计数，离线库不开）"; $(OUT)/t_prog --count $(OUT)/t_prog_in; echo "== t_prog --arch-lazy（管线归档按需开片：仿 iPhone 低区上限 + 低区账本）"; $(OUT)/t_prog --arch-lazy $(OUT)/t_prog_in; echo "== t_prog --arch-lru（管线归档腾退：只容 1 片的上限、按最近最少使用放片）"; $(OUT)/t_prog --arch-lru $(OUT)/t_prog_in; echo "== t_buf（Metal 校验层：宿主映射缓冲删除不碰驻留集）"; MTL_DEBUG_LAYER=1 $(OUT)/t_buf; echo "== t_draw（顶点自取 NXGAL_VPULL=1）"; NXGAL_VPULL=1 $(OUT)/t_draw; echo "== t_gpuwd（GPU 挂死看门狗：独立线程 + 提交时刻登记，缺省关）"; timeout 60 $(OUT)/t_gpuwd

test-corpus: all $(OUT)/t_prog_in/lib/gal.shards $(OUT)/corpus/lib/gal.shards
	$(OUT)/t_prog $(OUT)/t_prog_in $(OUT)/corpus

# Metal 3 归档（#116 / M3-9 第二批）：一条命令跑「出包路径 → 运行时命中」——合成 MSL / 离线索引 → PSO_M3=1 pso_gen.py 出 .mtlp-json
#   → pso_chunk.sh（metal-tt）出归档 → 老接口按描述 + FailOnBinaryArchiveMiss 查；另跑设备归档（写盘 → 重开 → 命中 / 反证）。
#   不经渲染器、不需要 NXGAL_BE=mtl3；iOS 目标上的命中留给 #91。退出码 0 = 绿
test-m3:
	bash tests/t_m3pack.sh

# 正式离线工具生成自有 GLSL 包，经运行时生产入口核对命中及实际像素。
test-m3archive: $(OUT)/t_m3archive $(OUT)/gal_xc
	@set -e; d=$$(mktemp -d /tmp/m3archive-pack.XXXXXX); trap 'rm -rf "$$d"' EXIT; python3 tests/m3archive_pack.py --gal-xc $(OUT)/gal_xc --output "$$d/input"; $(OUT)/t_m3archive --pack "$$d/input/pack" "$$d/input/manifest.tsv"

clean:
	rm -rf $(OUT)

.PHONY: all test test-deps test-corpus test-m3 test-m3archive clean ios mac FORCE
