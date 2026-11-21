# native-test-guest_need_file：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_need_file
ifeq ($(S2A_UNAME),Darwin)
# 文件后备局记需求的客体那份（vawin.c s2a_guest_file_live，#1842）：文件块里在内存或已落块的页都算、匿名块不算
.PHONY: native-test-guest_need_file
native-test-guest_need_file: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_need_file runtime/tests/t_guest_need_file.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_need_file
TEST_TARGETS += native-test-guest_need_file
endif
