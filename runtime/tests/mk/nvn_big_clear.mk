# native-test-nvn_big_clear：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_big_clear
ifeq ($(S2A_UNAME),Darwin)
# 附件比这一遍大时清除覆盖整张（size_clears，01007960049A0000 #1330，移植自 nxnative 9c1e4494）；反证：去掉 size_clears → ① ② 红
$(BUILD)/tests/t_nvn_big_clear: graphics/nvn/tests/t_nvn_big_clear.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_big_clear.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_big_clear
native-test-nvn_big_clear: $(BUILD)/tests/t_nvn_big_clear
	$(BUILD)/tests/t_nvn_big_clear
TEST_TARGETS += native-test-nvn_big_clear
endif
