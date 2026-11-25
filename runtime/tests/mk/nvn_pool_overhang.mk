# native-test-nvn_pool_overhang：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pool_overhang
ifeq ($(S2A_UNAME),Darwin)
# 池上伸出池尾的缓冲对象（D-6VG6）：池 0x195000 上建 0x1b0000 的缓冲对象，GPU 读写尾部（池尾之后）落在存储同一偏移，Switch 1 / Switch 2 各一遍
$(BUILD)/tests/t_nvn_pool_overhang: graphics/nvn/tests/t_nvn_pool_overhang.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_pool_overhang.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pool_overhang
native-test-nvn_pool_overhang: $(BUILD)/tests/t_nvn_pool_overhang
	$(BUILD)/tests/t_nvn_pool_overhang
TEST_TARGETS += native-test-nvn_pool_overhang
endif
