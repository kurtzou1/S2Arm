# native-test-nvn_pkg_gpu_alias：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pkg_gpu_alias
ifeq ($(S2A_UNAME),Darwin)
# #674 随包贴图被 GPU 写过后登记进共享表 + alias_key_of 块线性布局归一化；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_pkg_gpu_alias: graphics/nvn/tests/t_nvn_pkg_gpu_alias.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pkg_gpu_alias.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pkg_gpu_alias
native-test-nvn_pkg_gpu_alias: $(BUILD)/tests/t_nvn_pkg_gpu_alias
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_pkg_gpu_alias
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_pkg_gpu_alias
TEST_TARGETS += native-test-nvn_pkg_gpu_alias
endif
