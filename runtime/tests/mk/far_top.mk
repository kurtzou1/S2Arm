# native-test-far_top：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += far_top
.PHONY: native-test-far_top
native-test-far_top:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_far_top runtime/tests/t_far_top.c
	$(BUILD)/tests/t_far_top
TEST_TARGETS += native-test-far_top
