# native-test-nvn_vppack：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_vppack
ifeq ($(S2A_UNAME),Darwin)
# 包内顶点补齐变体 <键>_vp（nvn_mtl.m vp_pack）：批库（Build.cs VarBatches，函数 s<键>_main0、掩码 s<键>_main0_vpmask_<十六进制>）与逐键库（main0、dm_vp_mask_<十六进制>）都载得上、掩码各自
$(BUILD)/tests/t_nvn_vppack: graphics/nvn/tests/t_nvn_vppack.m $(NVN_MTL_DEPS) graphics/nvn/host/dsh_miss.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_vppack.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vppack
native-test-nvn_vppack: $(BUILD)/tests/t_nvn_vppack
	$(BUILD)/tests/t_nvn_vppack
TEST_TARGETS += native-test-nvn_vppack
endif
