# D-92BW 着色器库按活跃集持有：真库容器 + 生产加载 / 预热 / 放库 / 补回入口 + 真 GPU 读回（graphics/nvn/tests/t_nvn_lib_active.m）。
NATIVE_TEST_OWN += nvn_lib_active
ifeq ($(S2A_UNAME),Darwin)
NVN_LIB_ACTIVE_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_LIB_ACTIVE_BINARY ?= $(BUILD)/tests/t_nvn_lib_active
$(NVN_LIB_ACTIVE_BINARY): graphics/nvn/tests/t_nvn_lib_active.m $(NVN_LIB_ACTIVE_SOURCE) $(NVN_MTL_DEPS) $(dir $(NVN_LIB_ACTIVE_SOURCE))nvn_session.inc $(dir $(NVN_LIB_ACTIVE_SOURCE))nvn_hybrid.inc graphics/nvn/lib_pack.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DNVN_LIB_ACTIVE_SOURCE='"$(abspath $(NVN_LIB_ACTIVE_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_lib_active.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_lib_active
native-test-nvn_lib_active: $(NVN_LIB_ACTIVE_BINARY)
	$(NVN_LIB_ACTIVE_BINARY)
TEST_TARGETS += native-test-nvn_lib_active
endif
