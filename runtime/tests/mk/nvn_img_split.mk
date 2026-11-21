# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += nvn_img_split
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_img_split: graphics/nvn/tests/t_nvn_img_split.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_img_split.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_img_split
native-test-nvn_img_split: $(BUILD)/tests/t_nvn_img_split
	@status=0; for backend in mtl3 mtl4; do NXGAL_BE=$$backend $(BUILD)/tests/t_nvn_img_split || status=1; done; exit $$status
TEST_TARGETS += native-test-nvn_img_split
endif
