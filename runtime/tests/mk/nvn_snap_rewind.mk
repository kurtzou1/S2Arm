# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_snap_rewind：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_snap_rewind
ifeq ($(S2A_UNAME),Darwin)
# 即时快照恢复把栅栏号 / 出图票号倒回（snap_seq_rewind）：分配器占用号与按栅栏号记的 GPU 写入记录一起清
$(BUILD)/tests/t_nvn_snap_rewind: graphics/nvn/tests/t_nvn_snap_rewind.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_snap_rewind.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_snap_rewind
native-test-nvn_snap_rewind: $(BUILD)/tests/t_nvn_snap_rewind
	$(BUILD)/tests/t_nvn_snap_rewind
TEST_TARGETS += native-test-nvn_snap_rewind
endif
