# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-vp_prog_pick：#674 补齐变体选 program 的纯 C 逻辑（graphics/nvn/gfx/nvn/vp_prog_pick.h）
#   runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk
NATIVE_TEST_OWN += vp_prog_pick
.PHONY: native-test-vp_prog_pick
native-test-vp_prog_pick:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -Igraphics/nvn/gfx/nvn -o $(BUILD)/tests/t_vp_prog_pick graphics/nvn/tests/t_vp_prog_pick.c
	timeout 30 $(BUILD)/tests/t_vp_prog_pick
TEST_TARGETS += native-test-vp_prog_pick
