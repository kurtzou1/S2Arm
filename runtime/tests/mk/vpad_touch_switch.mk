# native-test-vpad_touch_switch：切「仅触屏 / 按键」的三种来源（自动 / 手动保存 / 提示条只这一局；ios/vpad_layout.m，Foundation 层，Mac 上编）
NATIVE_TEST_OWN += vpad_touch_switch
.PHONY: native-test-vpad_touch_switch
native-test-vpad_touch_switch:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_touch_switch runtime/tests/t_vpad_touch_switch.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_touch_switch
TEST_TARGETS += native-test-vpad_touch_switch
