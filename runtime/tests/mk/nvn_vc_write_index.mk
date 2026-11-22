# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += nvn_vc_write_index
ifeq ($(S2A_UNAME),Darwin)

NVN_VCW_BINARY ?= $(BUILD)/tests/t_nvn_vc_write_index
$(NVN_VCW_BINARY): graphics/nvn/tests/t_nvn_vc_write_index.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_vc_write_index.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vc_write_index
native-test-nvn_vc_write_index: $(NVN_VCW_BINARY)
	$(NVN_VCW_BINARY)
TEST_TARGETS += native-test-nvn_vc_write_index
endif
