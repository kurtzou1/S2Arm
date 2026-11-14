NATIVE_TEST_OWN += nvn_texdump
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_texdump: graphics/nvn/tests/t_nvn_texdump.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_texdump.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_texdump
native-test-nvn_texdump: $(BUILD)/tests/t_nvn_texdump
	@for mode in off single size multi replace classes; do $(BUILD)/tests/t_nvn_texdump $$mode $(abspath $(BUILD)/tests) || exit $$?; done
TEST_TARGETS += native-test-nvn_texdump
endif
