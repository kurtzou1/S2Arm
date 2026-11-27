# native-test-keyboard_store：iPad 外接键盘键位两层存取（ios/keyboard_store.m，#1987 第 2 条「设为所有游戏的默认」）的构建规则。
# 被测逻辑只依赖 Foundation，在 Mac 上直接编；⑨ 接 ios/settings.m 的真分层，链接依赖同 ios_settings.mk（settings.m 要 cpatch_model / caps / patch / launchctx）。
#   可执行文件放本组子目录、字符串表拷在旁边（同 ios_settings.mk：settings.m 里有经 S2AL 取的文字）
NATIVE_TEST_OWN += keyboard_store
.PHONY: native-test-keyboard_store
native-test-keyboard_store:
	@mkdir -p $(BUILD)/tests/keyboard_store
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iios -fobjc-arc -framework Foundation -o $(BUILD)/tests/keyboard_store/t_keyboard_store runtime/tests/t_keyboard_store.m ios/keyboard_store.m ios/settings.m ios/cpatch_model.m runtime/src/input_config.c runtime/src/caps.c runtime/src/gdefaults.c runtime/src/patch.c runtime/src/launchctx.c
	@rm -rf $(BUILD)/tests/keyboard_store/zh-Hans.lproj && cp -R ios/l10n/zh-Hans.lproj $(BUILD)/tests/keyboard_store/
	$(BUILD)/tests/keyboard_store/t_keyboard_store
TEST_TARGETS += native-test-keyboard_store
