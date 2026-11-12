# native-test-nvn_dbl_keep：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_dbl_keep
ifeq ($(shell uname -s),Darwin)
# 诊断双画的临时纹理 / 缓冲进驻留集、持有到提交回调（11-12 Mac 开片上读检查两局 GPU 缺页）
$(BUILD)/tests/t_nvn_dbl_keep: graphics/nvn/tests/t_nvn_dbl_keep.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_dbl_keep.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_dbl_keep
native-test-nvn_dbl_keep: $(BUILD)/tests/t_nvn_dbl_keep
	$(BUILD)/tests/t_nvn_dbl_keep
TEST_TARGETS += native-test-nvn_dbl_keep
endif
