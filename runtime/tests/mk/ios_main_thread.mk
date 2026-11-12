# native-test-ios_main_thread：iOS 前后台与 UIKit 主线程的接线断言（11-11 v0.3.0 局中失焦崩溃；runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += ios_main_thread
.PHONY: native-test-ios_main_thread
native-test-ios_main_thread:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_ios_main_thread runtime/tests/t_ios_main_thread.c
	$(BUILD)/tests/t_ios_main_thread ios/app.m ios/controller.m ios/vpad.m
TEST_TARGETS += native-test-ios_main_thread
