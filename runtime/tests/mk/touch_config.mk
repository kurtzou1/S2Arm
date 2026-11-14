# native-test-touch_config：游戏声明触屏配置 → 自动切仅触屏（ios/touch_config.m，Foundation 层，Mac 上编；vpad.m 切方案入口由单测桩掉）
#   提示文案按 App 界面语言取（S2APICK：玩家选的 S2AUILanguage，没选跟系统）：启动参数 -S2AUILanguage zh-Hans 只进参数域、不写偏好文件，按中文期望核；
#   旁边仍放 zh-Hans.lproj（字符串表按主 bundle 查；不和别的组共用 $(BUILD)/tests 下的 .lproj：门禁组并行，别组 rm -rf 重拷时这边会看到没有本地化）
NATIVE_TEST_OWN += touch_config
.PHONY: native-test-touch_config
native-test-touch_config:
	@rm -rf $(BUILD)/tests/touch_config && mkdir -p $(BUILD)/tests/touch_config && cp -R ios/l10n/zh-Hans.lproj $(BUILD)/tests/touch_config/
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -fobjc-arc -framework Foundation -o $(BUILD)/tests/touch_config/t_touch_config runtime/tests/t_touch_config.m
	$(BUILD)/tests/touch_config/t_touch_config -S2AUILanguage zh-Hans
TEST_TARGETS += native-test-touch_config
