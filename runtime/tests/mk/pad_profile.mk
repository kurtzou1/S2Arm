# native-test-pad_profile：只有通用物理描述的系统手柄（#2244 单只一代 Joy-Con；ios/pad_profile.h：认单只、按标准键名采样，位序同扩展手柄）
ifeq ($(S2A_UNAME),Darwin)
NATIVE_TEST_OWN += pad_profile
.PHONY: native-test-pad_profile
native-test-pad_profile:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -Iios -Iruntime/src -Iruntime/include -o $(BUILD)/tests/t_pad_profile runtime/tests/t_pad_profile.m runtime/src/pad.c \
	  -framework Foundation -framework GameController
	$(BUILD)/tests/t_pad_profile
TEST_TARGETS += native-test-pad_profile
endif
