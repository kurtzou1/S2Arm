# native-test-nvn_rt_dup：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rt_dup
ifeq ($(S2A_UNAME),Darwin)
# 同一张贴图挂两个颜色槽：后一个槽经影子画、遍末并回写过的通道（rtdup_attach / rtdup_flush），Metal 4 / Metal 3 各跑一遍
$(BUILD)/tests/t_nvn_rt_dup: graphics/nvn/tests/t_nvn_rt_dup.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -I$(abspath $(NVN_TEST_DIR)/nvn/gen) \
	  -o $@ graphics/nvn/tests/t_nvn_rt_dup.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rt_dup
native-test-nvn_rt_dup: $(BUILD)/tests/t_nvn_rt_dup
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_rt_dup
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_rt_dup
TEST_TARGETS += native-test-nvn_rt_dup
endif
