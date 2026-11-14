# native-test-guest_file_retry：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_file_retry
ifeq ($(shell uname -s),Darwin)
# 客体内存文件后备的补接（vawin.c s2a_guest_file_retry，#483）：起局时空间不够没接上的，装游戏前再查一次；窗口已有映射时不换
.PHONY: native-test-guest_file_retry
native-test-guest_file_retry: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_file_retry runtime/tests/t_guest_file_retry.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_file_retry
TEST_TARGETS += native-test-guest_file_retry
endif
