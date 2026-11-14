# native-test-nvn_thunk_count：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_thunk_count
ifeq ($(shell uname -s),Darwin)
# NVN 跳板缺省不计数、DM_NVN_COUNT=1 才计数（11-13，照 nxnative e250bb8b）
$(BUILD)/tests/t_nvn_thunk_count: graphics/nvn/tests/t_nvn_thunk_count.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/nvn_thunks.S graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_thunk_count.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_thunk_count
native-test-nvn_thunk_count: $(BUILD)/tests/t_nvn_thunk_count
	$(BUILD)/tests/t_nvn_thunk_count
TEST_TARGETS += native-test-nvn_thunk_count
endif
