# native-test-pso_retry：编译服务失败的管线重试节奏（纯函数，不连宿主 / Metal）
NATIVE_TEST_OWN += pso_retry
$(BUILD)/tests/t_pso_retry: graphics/nvn/tests/t_pso_retry.c graphics/nvn/gfx/nvn/nvn_pso_retry.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Igraphics/nvn/gfx/nvn -o $@ graphics/nvn/tests/t_pso_retry.c
.PHONY: native-test-pso_retry
native-test-pso_retry: $(BUILD)/tests/t_pso_retry
	$(BUILD)/tests/t_pso_retry
TEST_TARGETS += native-test-pso_retry
