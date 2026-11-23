# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_win_restore_clock：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_win_restore_clock
ifeq ($(S2A_UNAME),Darwin)
# 即时存档恢复后窗口里的节拍时刻（存档进程的单调钟读数）不再照旧用：设备重启后读档不再睡在取图里。
$(BUILD)/tests/t_nvn_win_restore_clock: graphics/nvn/tests/t_nvn_win_restore_clock.c $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_win_restore_clock.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_win_restore_clock
native-test-nvn_win_restore_clock: $(BUILD)/tests/t_nvn_win_restore_clock
	timeout 60 $(BUILD)/tests/t_nvn_win_restore_clock
TEST_TARGETS += native-test-nvn_win_restore_clock
endif
