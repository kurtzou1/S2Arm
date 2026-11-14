# native-test-ui_lang：iOS 宿主界面语言取法（runtime/include/s2a_ui_lang.h：首次跟随系统 / 选过就记住 / 选跟随系统恢复；简 → 简、繁 → 繁、其余 → 英）
NATIVE_TEST_OWN += ui_lang
.PHONY: native-test-ui_lang
native-test-ui_lang:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_ui_lang runtime/tests/t_ui_lang.c
	$(BUILD)/tests/t_ui_lang
TEST_TARGETS += native-test-ui_lang
