# native-test-game_export：手机上导出这一款（ios/game_export.m，0.6.3）往返单测：导出 → s2a_s2arm_import + s2a_img_scan 导回另一个容器。要 Foundation / python3，只 Mac
NATIVE_TEST_OWN += game_export
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-game_export
native-test-game_export:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -Iios -DS2A_UNIT_TEST -o $(BUILD)/tests/t_game_export -fobjc-arc runtime/tests/t_game_export.m ios/game_export.m -fno-objc-arc runtime/src/pack_apply.c \
	  -framework Foundation $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_game_export
TEST_TARGETS += native-test-game_export
endif
