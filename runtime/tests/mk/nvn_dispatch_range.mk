NATIVE_TEST_OWN += nvn_dispatch_range
ifeq ($(shell uname -s),Darwin)
NVN_PRODUCER_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_DRANGE_BINARY ?= $(BUILD)/tests/t_nvn_dispatch_range
$(NVN_DRANGE_BINARY): graphics/nvn/tests/t_nvn_dispatch_range.m $(NVN_PRODUCER_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DNVN_PRODUCER_SOURCE='"$(abspath $(NVN_PRODUCER_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_dispatch_range.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_dispatch_range
native-test-nvn_dispatch_range: $(NVN_DRANGE_BINARY)
	$(NVN_DRANGE_BINARY)
TEST_TARGETS += native-test-nvn_dispatch_range
endif
