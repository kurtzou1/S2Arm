# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_initfill_stale3d：本单测的构建规则（runtime/build.mk 按 runtime/tests/mk/*.mk 自动收入）
NATIVE_TEST_OWN += nvn_initfill_stale3d
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_initfill_stale3d: graphics/nvn/tests/t_nvn_initfill_stale3d.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_initfill_stale3d.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_initfill_stale3d
native-test-nvn_initfill_stale3d: $(BUILD)/tests/t_nvn_initfill_stale3d
	$(BUILD)/tests/t_nvn_initfill_stale3d
TEST_TARGETS += native-test-nvn_initfill_stale3d
endif
