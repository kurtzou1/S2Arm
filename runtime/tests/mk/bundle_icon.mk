# native-test-bundle_icon：包里 AppIcon 文件名（ios/bundle_icon.h，Foundation 层，Mac 上编；Apple TV 包 CFBundlePrimaryIcon 是字符串）
NATIVE_TEST_OWN += bundle_icon
.PHONY: native-test-bundle_icon
native-test-bundle_icon:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_bundle_icon runtime/tests/t_bundle_icon.m
	$(BUILD)/tests/t_bundle_icon
TEST_TARGETS += native-test-bundle_icon
