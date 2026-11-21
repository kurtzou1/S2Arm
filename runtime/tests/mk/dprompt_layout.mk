# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += dprompt_layout
ifeq ($(S2A_UNAME),Darwin)
# iOS 触屏提示条按安全区宽度排版（#1926）：纯函数 S2APromptLayoutMake，要 Foundation / CoreGraphics，只在苹果主机上编
.PHONY: native-test-dprompt_layout
native-test-dprompt_layout:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_dprompt_layout runtime/tests/t_dprompt_layout.m
	$(BUILD)/tests/t_dprompt_layout
TEST_TARGETS += native-test-dprompt_layout
endif
