# native-test-nvn_gpw_untouched：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_gpw_untouched
ifeq ($(shell uname -s),Darwin)
# GPU 写记账打哈希、核对不读游戏没碰过的页（11-13 0400486024DEC000 Mac：渲染目标存储逐 GOB 读，缺页在提交线程上，零页进足迹）
$(BUILD)/tests/t_nvn_gpw_untouched: graphics/nvn/tests/t_nvn_gpw_untouched.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_gpw_untouched.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_gpw_untouched
native-test-nvn_gpw_untouched: $(BUILD)/tests/t_nvn_gpw_untouched
	$(BUILD)/tests/t_nvn_gpw_untouched
TEST_TARGETS += native-test-nvn_gpw_untouched
endif
