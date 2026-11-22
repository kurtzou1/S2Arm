# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_session_reset：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_session_reset
ifeq ($(S2A_UNAME),Darwin)
# 会话销毁（进程内重启 / 按快照恢复）后新局不读旧局的表：池访问位与其余按旧局地址 / 序号 / 栅栏号记的表
$(BUILD)/tests/t_nvn_session_reset: graphics/nvn/tests/t_nvn_session_reset.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_session_reset.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_session_reset
native-test-nvn_session_reset: $(BUILD)/tests/t_nvn_session_reset
	$(BUILD)/tests/t_nvn_session_reset
TEST_TARGETS += native-test-nvn_session_reset
endif
