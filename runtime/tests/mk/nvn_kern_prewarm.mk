# native-test-nvn_kern_prewarm：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_kern_prewarm
ifeq ($(shell uname -s),Darwin)
# Switch 2 的两个源码现编计算核在设备初始化时交后台去建（#674）：Switch 2 / 非 Switch 2 两种、Metal 4 / Metal 3 两路
$(BUILD)/tests/t_nvn_kern_prewarm: graphics/nvn/tests/t_nvn_kern_prewarm.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_kern_prewarm.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_kern_prewarm
native-test-nvn_kern_prewarm: $(BUILD)/tests/t_nvn_kern_prewarm
	DM_TEST_OUNCE=1 NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_kern_prewarm
	DM_TEST_OUNCE=1 NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_kern_prewarm
	DM_TEST_OUNCE=0 NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_kern_prewarm
TEST_TARGETS += native-test-nvn_kern_prewarm
endif
