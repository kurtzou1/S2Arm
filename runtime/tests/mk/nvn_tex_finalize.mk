# native-test-nvn_tex_finalize：纹理收尾后已录命令按旧编号读回（#778，探针来自报告者的最小复现）
#   期望（手写，按报告者的对照表）：live / early / late / flight 读 255（late / flight 是修前读 0 的两种），remap 读改映射后的 73；
#   new（收尾后同一地址建另一序号）修前修后都读 0，是这次修法覆盖不到的边界，只打出来、不判
NATIVE_TEST_OWN += nvn_tex_finalize
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_tex_finalize: graphics/nvn/tests/nvn_tex_finalize_probe.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/nvn_tex_finalize_probe.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tex_finalize
native-test-nvn_tex_finalize: $(BUILD)/tests/t_nvn_tex_finalize
	bash graphics/nvn/tests/t_nvn_tex_finalize.sh $(BUILD)/tests/t_nvn_tex_finalize
TEST_TARGETS += native-test-nvn_tex_finalize
endif
