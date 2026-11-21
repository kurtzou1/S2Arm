# #1783 vertex fetch limit: a stream the draw reads past its bound range reads zeros there (production bind_vbufs on a real GPU, Metal 4 and Metal 3).
NATIVE_TEST_OWN += nvn_vbuf_limit
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_vbuf_limit: graphics/nvn/tests/t_nvn_vbuf_limit.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_vbuf_limit.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vbuf_limit
native-test-nvn_vbuf_limit: $(BUILD)/tests/t_nvn_vbuf_limit
	$(BUILD)/tests/t_nvn_vbuf_limit
TEST_TARGETS += native-test-nvn_vbuf_limit
endif
