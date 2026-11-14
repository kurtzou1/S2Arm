# native-test-tdump_stress：全线程现场挂起期间不调要锁的函数，不会被持锁的被挂起线程卡死（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += tdump_stress
.PHONY: native-test-tdump_stress
native-test-tdump_stress:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_tdump_stress runtime/tests/t_tdump_stress.c runtime/src/tdump.c
	$(BUILD)/tests/t_tdump_stress
TEST_TARGETS += native-test-tdump_stress
