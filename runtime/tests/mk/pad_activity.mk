# native-test-pad_activity：Mac 手柄输入算用户活动的判据（macos/pad_activity.h，纯 C 头、不引系统头，#2159），所以不走 runtime/src/<名>.c 的通用规则。
NATIVE_TEST_OWN += pad_activity
.PHONY: native-test-pad_activity
native-test-pad_activity:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Imacos -o $(BUILD)/tests/t_pad_activity runtime/tests/t_pad_activity.c
	$(BUILD)/tests/t_pad_activity
TEST_TARGETS += native-test-pad_activity
