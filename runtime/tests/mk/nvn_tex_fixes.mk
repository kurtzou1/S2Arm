# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_tex_fixes：本单测的构建规则（runtime/build.mk 按 runtime/tests/mk/*.mk 自动收入）
NATIVE_TEST_OWN += nvn_tex_fixes
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_tex_fixes: graphics/nvn/tests/t_nvn_tex_fixes.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tex_fixes.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tex_fixes
native-test-nvn_tex_fixes: $(BUILD)/tests/t_nvn_tex_fixes
	$(BUILD)/tests/t_nvn_tex_fixes
TEST_TARGETS += native-test-nvn_tex_fixes
endif
