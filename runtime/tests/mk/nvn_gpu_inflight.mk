# GPU error attribution step 1: the in-flight program set of a commit (qf_put / qf_take), its dedup across table growth, and its per-draw cost.
NATIVE_TEST_OWN += nvn_gpu_inflight
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_gpu_inflight: graphics/nvn/tests/t_nvn_gpu_inflight.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_gpu_inflight.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_gpu_inflight
native-test-nvn_gpu_inflight: $(BUILD)/tests/t_nvn_gpu_inflight
	$(BUILD)/tests/t_nvn_gpu_inflight
TEST_TARGETS += native-test-nvn_gpu_inflight
endif
