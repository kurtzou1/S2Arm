# native-test-pblend_rewrite：#674 可编程混合改写的文本面（graphics/dsx/gal_colorround.c，纯 C、各平台同编）；runtime/build.mk 按 runtime/tests/mk/*.mk 收进来
NATIVE_TEST_OWN += pblend_rewrite
.PHONY: native-test-pblend_rewrite
native-test-pblend_rewrite:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Igraphics/dsx -o $(BUILD)/tests/t_pblend_rewrite graphics/nvn/tests/t_pblend_rewrite.c graphics/dsx/gal_colorround.c
	$(BUILD)/tests/t_pblend_rewrite
TEST_TARGETS += native-test-pblend_rewrite
