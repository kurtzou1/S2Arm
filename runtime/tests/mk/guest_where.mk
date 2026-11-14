# native-test-guest_where：客体地址翻导出名（native.h module_func_at / s2a_guest_where，#806）。只用头文件内联，不链运行时源
NATIVE_TEST_OWN += guest_where
.PHONY: native-test-guest_where
native-test-guest_where:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_where runtime/tests/t_guest_where.c
	$(BUILD)/tests/t_guest_where
TEST_TARGETS += native-test-guest_where
