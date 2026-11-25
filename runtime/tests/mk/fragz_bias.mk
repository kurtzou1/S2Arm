# 片元深度偏移：读 gl_FragCoord.z 又取样深度贴图的只测不写 LESS / LEQUAL 绘制偏 1 单位，选择表 + 真 Metal 单位换算（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_nvn_fragz_bias.m）
NATIVE_TEST_OWN += fragz_bias
ifeq ($(S2A_UNAME),Darwin)
FRAGZ_BIAS_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
FRAGZ_BIAS_BINARY ?= $(BUILD)/tests/t_nvn_fragz_bias
$(FRAGZ_BIAS_BINARY): graphics/nvn/tests/t_nvn_fragz_bias.m $(FRAGZ_BIAS_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DFRAGZ_BIAS_SOURCE='"$(abspath $(FRAGZ_BIAS_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_fragz_bias.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-fragz_bias
native-test-fragz_bias: $(FRAGZ_BIAS_BINARY)
	$(FRAGZ_BIAS_BINARY)
TEST_TARGETS += native-test-fragz_bias
endif
