# native-test-mouse_map：iPad 触控板 / 鼠标（#1869 PR 2）的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）。
# 被测逻辑是 ios/mouse_map.h（纯 C 头，无 UIKit / GameController 依赖），链共用的 runtime/src/input_config.c；
#   参数是对照 / 接线断言要读的原文（Mac 鼠标规则在 front_mac.m，采集在 mouse.m，并进键盘在 keyboard.m，位移消费在 vpad.m，触点分流在 controller.m，锁定声明在 app.m，电视版空实现在 tv_host.m、不编 mouse.m 在 build.mk）。
NATIVE_TEST_OWN += mouse_map
.PHONY: native-test-mouse_map
native-test-mouse_map:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -Iruntime/include -o $(BUILD)/tests/t_mouse_map runtime/tests/t_mouse_map.c runtime/src/input_config.c
	$(BUILD)/tests/t_mouse_map macos/front_mac.m ios/mouse.m ios/keyboard.m ios/vpad.m ios/controller.m ios/app.m ios/tv_host.m runtime/build.mk
TEST_TARGETS += native-test-mouse_map
