# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors

# native-test-nvn_ind_binst：GPU 间接绘制与多绘制的 baseInstance 经计算拷贝进 c0+0x644（Metal 4 / Metal 3）
NATIVE_TEST_OWN += nvn_ind_binst
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_ind_binst: graphics/nvn/tests/t_nvn_ind_binst.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_ind_binst.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ind_binst
native-test-nvn_ind_binst: $(BUILD)/tests/t_nvn_ind_binst
	timeout 120 $(BUILD)/tests/t_nvn_ind_binst
TEST_TARGETS += native-test-nvn_ind_binst
endif
