# native-test-mac_focus：#279 Mac 游戏窗口焦点判定表 + front_mac.m / textinput_mac.m 接线断言（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += mac_focus
.PHONY: native-test-mac_focus
native-test-mac_focus:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_mac_focus runtime/tests/t_mac_focus.c
	$(BUILD)/tests/t_mac_focus macos/front_mac.m macos/textinput_mac.m
TEST_TARGETS += native-test-mac_focus
