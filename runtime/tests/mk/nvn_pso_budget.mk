# native-test-nvn_pso_budget：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pso_budget
ifeq ($(S2A_UNAME),Darwin)
# 管线额度：超额按最后用到的帧放掉久没用的、预热按额度停（AGX 编译变体额度）
$(BUILD)/tests/t_nvn_pso_budget: graphics/nvn/tests/t_nvn_pso_budget.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_pso_budget.inc graphics/nvn/gfx/nvn/nvn_geometry.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pso_budget.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pso_budget
native-test-nvn_pso_budget: $(BUILD)/tests/t_nvn_pso_budget
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_pso_budget
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_pso_budget
TEST_TARGETS += native-test-nvn_pso_budget
endif
