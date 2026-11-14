# native-test-cpatch_levels：帧率补丁按档（cpatch.c fps_pick），与 t_cpatch 同样链 cpatch.c；runtime/build.mk 按 runtime/tests/mk/*.mk 收进来
NATIVE_TEST_OWN += cpatch_levels
.PHONY: native-test-cpatch_levels
native-test-cpatch_levels:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -DS2A_UNIT_TEST -o $(BUILD)/tests/t_cpatch_levels runtime/tests/t_cpatch_levels.c runtime/src/cpatch.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_cpatch_levels
TEST_TARGETS += native-test-cpatch_levels
