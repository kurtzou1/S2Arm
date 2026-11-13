# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += play_reflection
.PHONY: native-test-play_reflection
native-test-play_reflection:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_play_reflection runtime/tests/t_play_reflection.m ios/play_layout.m ios/play_reflection.m
	$(BUILD)/tests/t_play_reflection
ifeq ($(shell uname -s),Darwin)
	@$(IOS_CC) -fsyntax-only -fobjc-arc $(NATIVE_INC) -Iruntime/src -Iruntime/ns2pro/include ios/play_reflection.m ios/play_layout.m
endif
TEST_TARGETS += native-test-play_reflection
