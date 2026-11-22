# 直连图形层（NVN→Metal，graphics/nvn/gfx 原样搬入 + host/ 替身头 + host_adapt.m）→ 静态库，被宿主 / iOS App 链进去（graphics/build.mk）。
# 编译参数照上游：Mac 用 -O2（原先照上游早期的 -O1；11-11 帧回放测速 tools/frame_bench.sh 同一帧对照：提交线程指令 -6.8%、周期约 -5%），iOS 同它的 Xcode Release（-Os，ARC，gnu11）。
# 直连层用 Metal 4 不加可用性判断：编译下限照 S2Arm，屏蔽 unguarded-availability；只在支持 Metal 4 的系统上走直连（gfxmode.c 就绪判定）
# ROOT 可由调用方在命令行给无空格别名（tools/nospace.sh）：下面的绝对路径都从 ROOT 拼，不用 CURDIR / abspath（会解析回带空格的真路径）
ROOT  := $(abspath ../..)
.DELETE_ON_ERROR:   # 配方中途失败时删掉已写出的目标，同树重跑不会把失败当成已编好跳过（10-25：graphics/metal 因此漏过一个真失败）
# Xcode 按用户机器（10-25，不写死版本）：指定 S2A_DEVELOPER_DIR > 环境里的 DEVELOPER_DIR（tools/toolchain.sh 解析后导出）> xcode-select；
#   先在 include 之前记下环境值——toolchain.env 里那行不当缺省（make 里文件内赋值会盖过环境变量）。赋值行不带行尾注释：注释前的空格会进值
_S2A_ENV_DD := $(DEVELOPER_DIR)
include $(ROOT)/tools/toolchain.env
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR
OUT   := $(ROOT)/build/nvn
AA_NAMES := edge blend neighbour
AA_MSLH := $(addprefix $(OUT)/gen/nvn_aa_,$(addsuffix .h,$(AA_NAMES)))
AA_LUT := $(ROOT)/compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures
AA_LUTH := $(OUT)/gen/nvn_aa_lut.h
# S2Arm tessellation: CHWTessellator（graphics/metal/gal_tess_d3d.h）嵌成头文件 $(OUT)/gen/gal_tess_msl.h（k_nvn_tess_core），被 nvn_builtin.h include
GENH  := $(OUT)/gen/gal_tess_msl.h
SRCS  := $(sort $(wildcard gfx/nvn/*.c gfx/nvn/*.m gfx/nvn/*.S gfx/tex/*.c gfx/tex/*.m gfx/vk/*.m gfx/gl/*.m)) host_adapt.m graphics_session.c   # gfx/vk：Vulkan 款（直连层 hle_vk.m，10-24 搬入）
HDRS  := $(wildcard gfx/nvn/*.h gfx/nvn/*.inc gfx/nvn/include/*.h gfx/tex/*.h gfx/vk/*.h gfx/vk/*.inc gfx/gl/*.h host/*.h host/*.inc) graphics_session.h ../track/s2a_track.h texture_extent.inc widen_glue.inc widen_fallback.inc fe_stat.h lib_pack.inc lib_pack_core.inc $(ROOT)/graphics/widen/export/s2a_widen.h $(ROOT)/graphics/metal/fit_judge.h $(ROOT)/runtime/src/native.h $(ROOT)/runtime/include/s2a_gfx_mode.h $(AA_MSLH) $(AA_LUTH) $(GENH)
# 本库源码 include 的运行时头文件也要进依赖：漏了改头文件不重编库，各编译单元对共用结构的理解前后不一（11-18 改 snapfmt.h 的结构，库里还是旧目标文件）
HDRS  += $(ROOT)/runtime/src/snapfmt.h $(wildcard $(ROOT)/runtime/include/*.h)
# 源 / 头清单戳（11-05 合入运维线：门禁常驻工作树跨批增量编，某批分支删 / 改名一个源文件后，余下源都比库旧、库不重建，
#   旧库里留着已删文件的目标文件，引用的宿主符号已不在 → 偶发「Undefined symbols」（nvn_rec_cover 构建失败 12 次，干净重跑就绿）。
#   清单变了就改写戳（内容不变不改写，不触发重编），各库依赖它
SRCSTAMP := $(OUT)/.srclist
$(shell mkdir -p $(OUT); [ "$$(cat $(SRCSTAMP) 2>/dev/null)" = '$(sort $(SRCS) $(HDRS))' ] || printf '%s' '$(sort $(SRCS) $(HDRS))' > $(SRCSTAMP))
PFX   := -ffile-prefix-map=$(ROOT)=.
# 按剖析数据优化编译（PGO，graphics/nvn/pgo/README.md）：pgo/nvn.prof.txt（文本格式，只有函数名 + 分支计数）由本机工具链转成二进制剖析数据再 -fprofile-instr-use；
#   文本入仓不入二进制：.profdata 的格式版本跟 clang 走，玩家机器的旧 Xcode 读不了新版本会编译报错，文本格式各版本都认。
#   源码改了对不上的函数 clang 只告警（下面三个 -Wno 关掉）、按无剖析编，不影响正确性。S2A_PGO_GEN=1 = 编插桩版（tools/pgo_record.sh 用），不读剖析数据。
#   取值记进 $(OUT)/.pgo_cfg：插桩 / 剖析数据换了库要重编
PGO_TXT := $(ROOT)/graphics/nvn/pgo/nvn.prof.txt
PGO_BIN := $(OUT)/pgo/nvn.profdata
ifeq ($(S2A_PGO_GEN),1)
PGO_CF := -fprofile-instr-generate
PGO_DEP :=
else ifneq ($(wildcard $(PGO_TXT)),)
PGO_CF := -fprofile-instr-use=$(PGO_BIN) -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled -Wno-profile-instr-missing
PGO_DEP := $(PGO_BIN)
endif
PGO_STAMP := $(OUT)/.pgo_cfg
$(shell mkdir -p $(OUT); [ "$$(cat $(PGO_STAMP) 2>/dev/null)" = '$(PGO_CF)' ] || printf '%s' '$(PGO_CF)' > $(PGO_STAMP))
# 二进制剖析数据在解析时按需转好（同上面两个戳）：库依赖它，要是只在建库时才转，换输出目录 / 只问 make -q 都会判「依赖缺失要重建」
#   （tests/nvn_lib_srclist_test.sh ① ③），门禁常驻树白编一遍。解析时转不出（没有 xcrun 的机器）就留给下面这条规则在建库时转
ifneq ($(PGO_DEP),)
$(shell [ $(PGO_BIN) -nt $(PGO_TXT) ] || { mkdir -p $(OUT)/pgo && DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun llvm-profdata merge -o $(PGO_BIN).$$$$ $(PGO_TXT) 2>/dev/null && mv -f $(PGO_BIN).$$$$ $(PGO_BIN); })
endif
$(PGO_BIN): $(PGO_TXT)
	@mkdir -p $(OUT)/pgo
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun llvm-profdata merge -o $@.$$$$ $< && mv -f $@.$$$$ $@
INC   := -I$(ROOT)/graphics/nvn/gfx/nvn/include -I$(ROOT)/graphics/nvn/host -I$(ROOT)/runtime/include -I$(ROOT)/graphics/nvn/third_party/vulkan-headers/include -I$(OUT)/gen
WARN  := -Wall -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability -Werror=incompatible-pointer-types   # 指针类型不符按错误编（11-21：对 os_unfair_lock 调 pthread_mutex_lock 只是警告，没上锁、提交线程缺页闪退）

# S2Arm tessellation: 嵌入 CHWTessellator（tools/embed_msl.py 把源文件转成 C 字符串常量）
$(OUT)/gen/gal_tess_msl.h: $(ROOT)/graphics/metal/gal_tess_d3d.h $(ROOT)/graphics/metal/tools/embed_msl.py
	@mkdir -p $(OUT)/gen
	python3 $(ROOT)/graphics/metal/tools/embed_msl.py $(ROOT)/graphics/metal/gal_tess_d3d.h k_nvn_tess_core $@
IOS_SDK := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_FLAGS := -arch arm64 -isysroot $(IOS_SDK) -mios-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
# glslang 的平台标识（Apple TV 由顶层 graphics/build.mk 从命令行换成 tvos-arm64）
GLSLANG_RID ?= ios-arm64

mac: $(OUT)/mac/libnvn.a
ios: $(OUT)/ios/libnvn.a

$(OUT)/gen/nvn_aa_%.h: $(ROOT)/graphics/metal/shaders/aa_%.metal $(ROOT)/graphics/metal/tools/embed_msl.py
	@mkdir -p $(OUT)/gen
	python3 $(ROOT)/graphics/metal/tools/embed_msl.py $< k_aa_$* $@
$(AA_LUTH): $(AA_LUT)/SmaaAreaTexture.bin $(AA_LUT)/SmaaSearchTexture.bin $(ROOT)/graphics/metal/tools/embed_aa_lut.py
	@mkdir -p $(OUT)/gen
	python3 $(ROOT)/graphics/metal/tools/embed_aa_lut.py $(AA_LUT) $@

# 可用性棘轮（tools/avail_count.sh）：按系统下限（iOS 18 / macOS 15）只打开「未守卫的新系统 API」告警做语法检查，每条打「平台 文件 符号」。
#   WARN 关着这两条告警，10-28 实测：建采样器处的 setReductionMode（26 起）没守卫，Metal 3 设备上一建 min / max 采样器即崩，编译时无声
avail: $(AA_MSLH) $(AA_LUTH) $(GENH)
	@for f in $(addprefix $(ROOT)/graphics/nvn/,$(filter-out %.S,$(SRCS))); do \
	  clang $(PFX) -std=gnu11 -fobjc-arc $(IOS_FLAGS) $(INC) -Wno-everything -Wunguarded-availability-new -Wunguarded-availability -fsyntax-only $$f 2>&1 | sed "s/^/ios /"; \
	  clang $(PFX) -std=gnu11 -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) $(INC) -Wno-everything -Wunguarded-availability-new -Wunguarded-availability -fsyntax-only $$f 2>&1 | sed "s/^/mac /"; \
	done | sed -nE -e "s#^(ios|mac) .*/gfx/nvn/([^:]+):[0-9]+:[0-9]+: warning: '([^']+)' is only available on.*#\1 \2 \3#p" \
	  -e "s#^(ios|mac) .*/gfx/nvn/([^:]+):[0-9]+:[0-9]+: (fatal )?error: .*#\1 \2 编译出错#p"

# 静态库原子出（10-31 银河2 正式包红：同树并行 make host，graphics/metal/Makefile 同一处说明）：目标文件编进本次私有目录，库先出到临时名、
#   核成员数不少于本次编出的目标文件数再原子改名到位；并行的另一份各编各的，谁后改名都是完整的库
LIBCHK = [ $$(ar t $@.$$$$ | grep -c '\.o$$') -ge $$(ls "$$d"/*.o | wc -l) ] || { echo "【红】$@：建出的库成员数少于目标文件数"; exit 1; }
$(OUT)/mac/libnvn.a: $(SRCS) $(HDRS) Makefile $(SRCSTAMP) $(PGO_STAMP) $(PGO_DEP)
	@mkdir -p $(OUT)/mac
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(addprefix $(ROOT)/graphics/nvn/,$(SRCS)); do clang $(PFX) -std=gnu11 -O2 -g $(PGO_CF) -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) $(WARN) $(INC) -c $$f -o $$(echo $$f | sed 's|.*/gfx/nvn/||; s|/|_|g').o || exit 1; done) \
	  && ar rcs $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@

$(OUT)/ios/libnvn.a: $(SRCS) $(HDRS) Makefile $(SRCSTAMP) $(PGO_STAMP) $(PGO_DEP)
	@mkdir -p $(OUT)/ios
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(addprefix $(ROOT)/graphics/nvn/,$(SRCS)); do clang $(PFX) -std=gnu11 -Os -g $(PGO_CF) -fobjc-arc $(IOS_FLAGS) $(WARN) $(INC) -c $$f -o $$(echo $$f | sed 's|.*/gfx/nvn/||; s|/|_|g').o || exit 1; done) \
	  && ar rcs $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@

# GL 层运行时兜底的 GLSL 翻译（gfx/gl/gl_xlate.c，含改写层 gl_glsl_es.c）+ glslang 静态库 → libglx.a：只链进宿主与 iOS App（graphics/build.mk）。
#   不进 libnvn（只链 libnvn 的单测不带 glslang / SPIRV-Cross，GL 层弱引用 s2a_gl_xlate）；spvc_* 在最终链接时取直连翻译库 libdsx 那份 SPIRV-Cross（graphics/build.mk 链 build/dsx/{mac,ios}/libdsx.a）。
#   glslang 官方 tag 原样构建、按脚本内容缓存（graphics/third_party/glslang/build.sh，要 cmake / ninja）
GLX_DEP := gfx/gl/gl_xlate.c gfx/gl/gl_glsl_es.c gfx/gl/gl_glsl_es.h $(ROOT)/graphics/third_party/glslang/build.sh $(ROOT)/graphics/third_party/spirv_cross/spirv_cross_c.h Makefile
GLX_CF := -std=gnu11 -Wall -Wextra -Wno-unused-parameter -I$(ROOT)/graphics/third_party/spirv_cross
glx-mac: $(OUT)/mac/libglx.a
glx-ios: $(OUT)/ios/libglx.a
$(OUT)/mac/libglx.a: $(GLX_DEP) $(SRCSTAMP)
	@mkdir -p $(OUT)/mac
	L=$$(bash $(ROOT)/graphics/third_party/glslang/build.sh osx-arm64 | tail -1) && [ -s "$$L" ] && d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && clang $(PFX) $(GLX_CF) -O2 -g -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -I"$$(dirname "$$L")/include" -c $(ROOT)/graphics/nvn/gfx/gl/gl_xlate.c -o "$$d/gl_xlate.o" \
	  && libtool -static -o $@.$$$$ "$$d/gl_xlate.o" "$$L" 2> /dev/null && mv -f $@.$$$$ $@
$(OUT)/ios/libglx.a: $(GLX_DEP) $(SRCSTAMP)
	@mkdir -p $(OUT)/ios
	L=$$(bash $(ROOT)/graphics/third_party/glslang/build.sh $(GLSLANG_RID) | tail -1) && [ -s "$$L" ] && d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && clang $(PFX) $(GLX_CF) -Os -g $(IOS_FLAGS) -I"$$(dirname "$$L")/include" -c $(ROOT)/graphics/nvn/gfx/gl/gl_xlate.c -o "$$d/gl_xlate.o" \
	  && libtool -static -o $@.$$$$ "$$d/gl_xlate.o" "$$L" 2> /dev/null && mv -f $@.$$$$ $@

# 两路后端冒烟（tests/t_nvn_m3.m，#277）：链本库、宿主符号在单测里打桩；要 Metal 4 设备（26 起），Metal 3 一路用 NXGAL_BE=mtl3 强制
# 宽屏核心入口的桩按头文件逐个生成（s2a_widen_init 与返回 float 的三个入口在 tests/host_stubs.h 里手写）：库里新用到一个入口不用再手补桩表
# 生成规则写在本 Makefile 里，规则一改（如 c59151647 把返回 float 的三个入口挪去手写）旧 inc 必须重生成：依赖本文件（11-02 合入线：gate-host 持久构建目录
#   留着 14:21 生成的旧 inc，头文件没变不重生，与 host_stubs.h 手写的 s2a_widen_k / ky / frag_scale_y 类型冲突，graphics/gate 直连冒烟编译红）
$(OUT)/tests/widen_stubs.inc: $(ROOT)/graphics/widen/export/s2a_widen.h Makefile
	@mkdir -p $(OUT)/tests
	sed -n 's/^[a-z0-9_]*[ *]*\(s2a_widen_[a-z0-9_]*\)(.*/WSTUB(\1)/p' $< | grep -v -e '(s2a_widen_init)' -e '(s2a_widen_k)' -e '(s2a_widen_ky)' -e '(s2a_widen_frag_scale_y)' > $@
widen-stubs: $(OUT)/tests/widen_stubs.inc
# 直连层单测链 libnvn.a 不链原生层：libnvn 引用的宿主符号放行参数只从源码「// 弱链接[nvntest]：<符号>」登记生成（同 runtime/build.mk NVN_TEST_WEAK，
#   tools/weak_link_decl.py 一处口径；11-01 合入线：这里原先手抄 -U，帧录放加 3 个符号漏了一处，graphics/gate 直连两路冒烟链接红）。不要在链接行手写放行参数
# 直连层要链的系统框架 / 库也在用到它的源文件里登记「// 系统库[nvntest]：-framework Xxx」（同一工具一起输出）：这一行不再随功能增减改动
# 延迟求值（=）：只有链 t_nvn_m3 时才起 python3 扫登记；make mac 只编库不该读全部宿主源码（它算进只链库的单测的实读输入）
NVN_TEST_WEAK = $(shell python3 $(ROOT)/tools/weak_link_decl.py flags nvntest)
$(OUT)/tests/t_nvn_m3: $(OUT)/mac/libnvn.a tests/t_nvn_m3.m tests/host_stubs.h $(OUT)/tests/widen_stubs.inc $(ROOT)/tools/weak_link_decl.py
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall $(INC) -I$(OUT)/tests -Itests -o $@ tests/t_nvn_m3.m $(OUT)/mac/libnvn.a \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++ $(NVN_TEST_WEAK)
test: $(OUT)/tests/t_nvn_m3
	timeout 120 $(OUT)/tests/t_nvn_m3
	# 几何着色器变换反馈三个核（nvn_geometry.h k_nvn_geo_tf_msl）：手造记录 / 列表 / 计数
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall -o $(OUT)/tests/t_geo_tf tests/t_geo_tf.m -framework Metal -framework Foundation
	timeout 60 $(OUT)/tests/t_geo_tf
	# 几何着色器输出的有序压缩核（nvn_geometry.h k_nvn_geo_pack_msl）：一个线程组分块并行，与逐个走完同顺序、同字、同截断
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall -o $(OUT)/tests/t_geo_pack tests/t_geo_pack.m -framework Metal -framework Foundation
	timeout 60 $(OUT)/tests/t_geo_pack
	# 存储缓冲大小表（nvn_refl.h nvn_sbsz_fill）：几何辅助缓冲按本笔临时区段长进表（11-06 鬼灭 #37 脸空白 / 手缺失）
	clang $(PFX) -std=gnu11 -O1 -Wall -o $(OUT)/tests/t_sbsz tests/t_sbsz.c
	timeout 30 $(OUT)/tests/t_sbsz
	# 取图线程实时声明被降级的对策（gfx/nvn/rt_demote.h，D-7YPC / D-5JYW：降级后回落优先级 0、整进程搬能效核）
	clang $(PFX) -std=gnu11 -O1 -Wall -o $(OUT)/tests/t_rt_demote tests/t_rt_demote.c
	timeout 30 $(OUT)/tests/t_rt_demote
	# 直连库打包容器的读法（lib_pack.inc）：两个小 metallib 现编，测试按格式手造容器；客体输入（种类 56）用 zlib 库压块、读端用 Foundation 解
	xcrun -sdk macosx metal tests/t_lib_pack_a.metal -o $(OUT)/tests/t_lib_pack_a.metallib && xcrun -sdk macosx metal tests/t_lib_pack_b.metal -o $(OUT)/tests/t_lib_pack_b.metallib
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall -o $(OUT)/tests/t_lib_pack tests/t_lib_pack.m -framework Metal -framework Foundation -lz
	timeout 60 $(OUT)/tests/t_lib_pack $(OUT)/tests/t_lib_pack_a.metallib $(OUT)/tests/t_lib_pack_b.metallib
	# 曲面细分固定核单测（tests/t_tess_triangle.m）：三角patch已知因子 → 已知点数/索引数
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall $(INC) -o $(OUT)/tests/t_tess_triangle tests/t_tess_triangle.m -framework Metal -framework Foundation
	timeout 60 $(OUT)/tests/t_tess_triangle
	# 曲面细分 VS 前置段单测（tests/t_tess_vsfront.m）：手造 VS 的捕获记录 → 搬运核按映射 / 规范布局搬成 TCS 输入；非索引与 8 位乱序重复索引两例；缺省（Metal 4 接口）与 NXGAL_BE=mtl3（老接口）各跑一遍
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall $(INC) -o $(OUT)/tests/t_tess_vsfront tests/t_tess_vsfront.m -framework Metal -framework Foundation
	timeout 60 $(OUT)/tests/t_tess_vsfront
	NXGAL_BE=mtl3 timeout 60 $(OUT)/tests/t_tess_vsfront
	# 直连曲面细分越界与派发（tests/t_nvn_tess_bounds.m，审计 1101 P0-5 / P0-6、18:00 P1-42）：前缀和 32 位折返的片要丢弃；TCS 按线程数派发、不越过 Pt × N；计数 / 写出按片数派发
	clang $(PFX) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Wall $(INC) -o $(OUT)/tests/t_nvn_tess_bounds tests/t_nvn_tess_bounds.m -framework Metal -framework Foundation
	timeout 120 $(OUT)/tests/t_nvn_tess_bounds

test-color-round:
	$(MAKE) -s -C $(ROOT)/graphics/dsx $(ROOT)/build/dsx/libdsx.dylib
	python3 $(ROOT)/graphics/tools/direct/tests/t_color_round_fetch.py $(ROOT)/build/dsx/libdsx.dylib
	$(MAKE) -C $(ROOT) native-test-nvn_color_round

.PHONY: mac ios glx-mac glx-ios test widen-stubs avail test-color-round
