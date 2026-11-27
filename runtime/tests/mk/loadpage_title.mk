# native-test-loadpage_title：加载页游戏名的取法（ios/loadpage_title.h，#502）。纯 Foundation，Mac 上编
NATIVE_TEST_OWN += loadpage_title
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-loadpage_title
native-test-loadpage_title:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_loadpage_title runtime/tests/t_loadpage_title.m
	$(BUILD)/tests/t_loadpage_title
TEST_TARGETS += native-test-loadpage_title
endif
