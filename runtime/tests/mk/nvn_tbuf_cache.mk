# native-test-nvn_tbuf_cache：缓冲纹理原子视图不循环升级、视图池缓存及释放失效、不对齐池表副本同步
NATIVE_TEST_OWN += nvn_tbuf_cache
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_tbuf_cache: graphics/nvn/tests/t_nvn_tbuf_cache.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tbuf_cache.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tbuf_cache
native-test-nvn_tbuf_cache: $(BUILD)/tests/t_nvn_tbuf_cache
	$(BUILD)/tests/t_nvn_tbuf_cache
	$(BUILD)/tests/t_nvn_tbuf_cache neg
TEST_TARGETS += native-test-nvn_tbuf_cache
endif
