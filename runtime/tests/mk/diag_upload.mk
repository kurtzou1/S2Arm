# native-test-diag_upload：诊断一键上传的纯判断（ios/diag_upload.h）+ ios/diag.m 接线断言（同 pad_liveness.mk 的做法）
NATIVE_TEST_OWN += diag_upload
.PHONY: native-test-diag_upload
native-test-diag_upload:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -o $(BUILD)/tests/t_diag_upload runtime/tests/t_diag_upload.c
	$(BUILD)/tests/t_diag_upload ios/diag.m .github/ISSUE_TEMPLATE/问题回报.yml
TEST_TARGETS += native-test-diag_upload
