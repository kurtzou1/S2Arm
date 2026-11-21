# native-test-keyboard_map：iPad 外接键盘（#1869）的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）。
# 被测逻辑是 ios/keyboard_map.h（纯 C 头，无 UIKit / GameController 依赖），链共用的 runtime/src/input_config.c；
#   参数是对照 / 接线断言要读的三份原文（Mac 键码表在 front_mac.m，选源接线在 controller.m，采集在 keyboard.m）。
NATIVE_TEST_OWN += keyboard_map
.PHONY: native-test-keyboard_map
native-test-keyboard_map:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -Iruntime/include -o $(BUILD)/tests/t_keyboard_map runtime/tests/t_keyboard_map.c runtime/src/input_config.c
	$(BUILD)/tests/t_keyboard_map macos/front_mac.m ios/controller.m ios/keyboard.m
TEST_TARGETS += native-test-keyboard_map
