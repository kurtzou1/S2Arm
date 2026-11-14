# 统一缓冲拷贝交接（os_sync_wait_on_address，照 nxnative，MIT）：生产 nvn_mtl.m，只跑 CPU，graphics/nvn/tests/t_nvn_ubc_wait.m
NATIVE_TEST_OWN += nvn_ubc_wait
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_ubc_wait: graphics/nvn/tests/t_nvn_ubc_wait.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_ubc_wait.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ubc_wait
native-test-nvn_ubc_wait: $(BUILD)/tests/t_nvn_ubc_wait
	$(BUILD)/tests/t_nvn_ubc_wait
TEST_TARGETS += native-test-nvn_ubc_wait
endif
