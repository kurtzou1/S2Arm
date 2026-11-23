# native-test-far_slow：Mac「地址空间不够这款」提示条的触发判据（far_slow.h，纯函数）
NATIVE_TEST_OWN += far_slow
.PHONY: native-test-far_slow
native-test-far_slow:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_far_slow runtime/tests/t_far_slow.c
	$(BUILD)/tests/t_far_slow
TEST_TARGETS += native-test-far_slow
