# native-test-nvn_bcd_prewarm：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_bcd_prewarm
ifeq ($(shell uname -s),Darwin)
# 无 BC 时解压管线在设备初始化时交后台去建（#582）：有 / 无 BC 两种、Metal 4 / Metal 3 两路
$(BUILD)/tests/t_nvn_bcd_prewarm: graphics/nvn/tests/t_nvn_bcd_prewarm.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_bcd_prewarm.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_bcd_prewarm
native-test-nvn_bcd_prewarm: $(BUILD)/tests/t_nvn_bcd_prewarm
	DM_TEST_NO_BC=1 NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_bcd_prewarm
	DM_TEST_NO_BC=1 NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_bcd_prewarm
	DM_TEST_NO_BC=0 NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_bcd_prewarm
TEST_TARGETS += native-test-nvn_bcd_prewarm
endif
