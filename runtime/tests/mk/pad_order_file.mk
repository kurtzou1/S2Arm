# native-test-pad_order_file：分配玩家顺序表的 JSON 解析（ios/pad_order_file.h，Mac / iOS 宿主共用；Foundation 只有 macOS 上有）
ifeq ($(S2A_UNAME),Darwin)
NATIVE_TEST_OWN += pad_order_file
.PHONY: native-test-pad_order_file
native-test-pad_order_file:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -Iios -o $(BUILD)/tests/t_pad_order_file runtime/tests/t_pad_order_file.m -framework Foundation
	$(BUILD)/tests/t_pad_order_file macos/front_mac.m ios/controller.m
TEST_TARGETS += native-test-pad_order_file
endif
