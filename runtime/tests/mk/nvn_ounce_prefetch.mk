# native-test-nvn_ounce_prefetch：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_ounce_prefetch
ifeq ($(shell uname -s),Darwin)
# Switch 2 程序在 ProgramSetShaders 时交后台预取（#674）：NVN2 阶段正式键首次绘制时才算，预取不能跟着跳过；Metal 4 / Metal 3 两路
$(BUILD)/tests/t_nvn_ounce_prefetch: graphics/nvn/tests/t_nvn_ounce_prefetch.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_ounce_prefetch.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ounce_prefetch
native-test-nvn_ounce_prefetch: $(BUILD)/tests/t_nvn_ounce_prefetch
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_ounce_prefetch
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_ounce_prefetch
TEST_TARGETS += native-test-nvn_ounce_prefetch
endif
