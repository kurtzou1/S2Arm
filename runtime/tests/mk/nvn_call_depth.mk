# native-test-nvn_call_depth：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_call_depth
ifeq ($(shell uname -s),Darwin)
# 命令列表嵌套调用不吃宿主栈（显式返回栈）：200 层与自己调自己，跑在 256 KB 栈的线程上
$(BUILD)/tests/t_nvn_call_depth: graphics/nvn/tests/t_nvn_call_depth.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_call_depth.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_call_depth
native-test-nvn_call_depth: $(BUILD)/tests/t_nvn_call_depth
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_call_depth
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_call_depth
TEST_TARGETS += native-test-nvn_call_depth
endif
