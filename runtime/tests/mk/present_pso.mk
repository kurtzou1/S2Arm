# native-test-present_pso：PR3c 出图 PSO 多槽纯逻辑单测（graphics/nvn/tests/t_present_pso.c → graphics/nvn/gfx/nvn/nvn_present_pso.h；评审稿 v3 §2.2 PSO 缓存 / §3 B3·B4·B5 / §4 PR3c）——
#   槽命中 / 交替不重建 / 失败回退（HDR 槽死负缓存、基线槽不受牵连）/ 四槽上限（gal_present.m g_pr_pso[4] 同数）/ 预热命中断言；
#   纯 C，不要 GPU / 游戏（t_present_fit 同族口径：测的就是生产代码 include 的同一份纯逻辑）。
#   三态流：基线（无 PR3c 实现）上 nvn_present_pso.h 不存在 → 编译期报 file not found（红）。
NATIVE_TEST_OWN += present_pso
.PHONY: native-test-present_pso
native-test-present_pso:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_present_pso graphics/nvn/tests/t_present_pso.c
	$(BUILD)/tests/t_present_pso
TEST_TARGETS += native-test-present_pso
