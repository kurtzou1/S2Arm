# native-test-dirty_claim：整段解保护时段内每页必须先被本线程认领（等完别人的忙态要重新认领）
NATIVE_TEST_OWN += dirty_claim
.PHONY: native-test-dirty_claim
native-test-dirty_claim:   # 写跟踪认领次序：不需要 GPU / 游戏
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_dirty_claim graphics/nvn/tests/t_dirty_claim.c graphics/nvn/gfx/nvn/nvn_dirty.c -lpthread
	$(BUILD)/tests/t_dirty_claim
TEST_TARGETS += native-test-dirty_claim
