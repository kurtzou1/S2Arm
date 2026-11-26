# native-test-slot_motion：手柄传感器跟手柄在槽的时间走（#2142，ios/slot_feedback.m：分到槽即开、离开才关、回前台补开，游戏要不要六轴不再开关传感器）
ifeq ($(S2A_UNAME),Darwin)
NATIVE_TEST_OWN += slot_motion
.PHONY: native-test-slot_motion
native-test-slot_motion:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -Iios -Iruntime/src -Iruntime/include -o $(BUILD)/tests/t_slot_motion runtime/tests/t_slot_motion.m runtime/src/motion_pick.c \
	  -framework Foundation -framework GameController -framework CoreHaptics
	$(BUILD)/tests/t_slot_motion
TEST_TARGETS += native-test-slot_motion
endif
