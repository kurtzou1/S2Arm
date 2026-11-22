# native-test-os_notice：iOS / iPadOS 18.0.x 开局一次性提示升级系统（ios/os_notice.h 纯判断 + ios/app.m 接线断言）
NATIVE_TEST_OWN += os_notice
.PHONY: native-test-os_notice
native-test-os_notice:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_os_notice runtime/tests/t_os_notice.c
	$(BUILD)/tests/t_os_notice ios/app.m
TEST_TARGETS += native-test-os_notice
