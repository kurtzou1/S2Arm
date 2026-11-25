# 快照恢复建贴图前判内存池还在不在（D-S68N，生产 nvn_mtl.m 源码，graphics/nvn/tests/t_snap_tex_live.m）
NATIVE_TEST_OWN += snap_tex_live
ifeq ($(S2A_UNAME),Darwin)
SNAP_TEX_LIVE_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
SNAP_TEX_LIVE_BINARY ?= $(BUILD)/tests/t_nvn_snap_tex_live
$(SNAP_TEX_LIVE_BINARY): graphics/nvn/tests/t_snap_tex_live.m $(SNAP_TEX_LIVE_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DSNAP_TEX_LIVE_SOURCE='"$(abspath $(SNAP_TEX_LIVE_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_snap_tex_live.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-snap_tex_live
native-test-snap_tex_live: $(SNAP_TEX_LIVE_BINARY)
	$(SNAP_TEX_LIVE_BINARY)
TEST_TARGETS += native-test-snap_tex_live
endif
