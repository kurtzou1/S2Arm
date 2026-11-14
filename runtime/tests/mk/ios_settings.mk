# native-test-ios_settings：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 「关于本包」等文字经 S2AL 取字符串表（#316）：命令行程序的主 bundle 是可执行文件所在目录，所以可执行文件放本组自己的子目录、zh-Hans.lproj 拷在旁边。
#   原先放共用的 $(BUILD)/tests/ 又不拷字符串表，只有 cpatch_settings 组拷：整套门禁里它先跑才借到，单跑本组或并行时排到前面就红 5 项
NATIVE_TEST_OWN += ios_settings
.PHONY: native-test-ios_settings
native-test-ios_settings:
	@mkdir -p $(BUILD)/tests/ios_settings
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -framework Foundation -o $(BUILD)/tests/ios_settings/t_ios_settings runtime/tests/t_ios_settings.m ios/settings.m ios/cpatch_model.m runtime/src/caps.c runtime/src/patch.c runtime/src/launchctx.c
	@rm -rf $(BUILD)/tests/ios_settings/zh-Hans.lproj && cp -R ios/l10n/zh-Hans.lproj $(BUILD)/tests/ios_settings/
	$(BUILD)/tests/ios_settings/t_ios_settings ios/Settings.bundle/Root.plist
TEST_TARGETS += native-test-ios_settings
