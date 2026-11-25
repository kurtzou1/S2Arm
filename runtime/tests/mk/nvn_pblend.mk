# #674 programmable blending through the production host (pso_pb_eff / fs_pb_fn / pso_desc / enc_r_slot27), on a real GPU attachment.
NATIVE_TEST_OWN += nvn_pblend
ifeq ($(S2A_UNAME),Darwin)
NVN_PBLEND_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_PBLEND_BINARY ?= $(BUILD)/tests/t_nvn_pblend
$(NVN_PBLEND_BINARY): graphics/nvn/tests/t_nvn_pblend.m graphics/dsx/gal_colorround.c $(NVN_PBLEND_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include -Igraphics/dsx \
	  -I$(abspath $(NVN_TEST_DIR)/nvn/gen) -DNVN_PBLEND_SOURCE='"$(abspath $(NVN_PBLEND_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_pblend.m graphics/dsx/gal_colorround.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pblend
native-test-nvn_pblend: $(NVN_PBLEND_BINARY)
	$(NVN_PBLEND_BINARY)
TEST_TARGETS += native-test-nvn_pblend
endif
