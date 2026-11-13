# native-test-nvn_pool_index：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pool_index
ifeq ($(shell uname -s),Darwin)
# 内存池地址索引在登记 / 注销时就地维护（不整表重排）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_pool_index: graphics/nvn/tests/t_nvn_pool_index.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pool_index.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pool_index
native-test-nvn_pool_index: $(BUILD)/tests/t_nvn_pool_index
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_pool_index
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_pool_index
TEST_TARGETS += native-test-nvn_pool_index
endif
