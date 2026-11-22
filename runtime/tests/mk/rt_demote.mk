# native-test-rt_demote：取图线程实时声明被降级的对策判定（graphics/nvn/gfx/nvn/rt_demote.h；runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += rt_demote
.PHONY: native-test-rt_demote
native-test-rt_demote:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_rt_demote graphics/nvn/tests/t_rt_demote.c
	timeout 30 $(BUILD)/tests/t_rt_demote
TEST_TARGETS += native-test-rt_demote
