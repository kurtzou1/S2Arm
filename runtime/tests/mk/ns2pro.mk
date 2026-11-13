# native-test-ns2pro：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ns2pro
native-test-ns2pro:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include runtime/ns2pro/tests/test_captured_reports.c $(NS2_CODECS) -o $(BUILD)/tests/ns2_captured_reports
	$(BUILD)/tests/ns2_captured_reports
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include runtime/ns2pro/tests/test_rumble_codec.c runtime/ns2pro/NS2Rumble.c -o $(BUILD)/tests/ns2_rumble_codec
	$(BUILD)/tests/ns2_rumble_codec
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include runtime/ns2pro/tests/test_joycon.c $(NS2_CODECS) -o $(BUILD)/tests/ns2_joycon
	$(BUILD)/tests/ns2_joycon
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include runtime/ns2pro/tests/test_keep.c $(NS2_CODECS) -o $(BUILD)/tests/ns2_keep
	$(BUILD)/tests/ns2_keep
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include runtime/ns2pro/tests/test_bond.c $(NS2_CODECS) -o $(BUILD)/tests/ns2_bond
	$(BUILD)/tests/ns2_bond
TEST_TARGETS += native-test-ns2pro
