# native-test-vawin_extend：Mac 上别名区伸出段并进窗口（vawin.c s2a_window_extend_up）
NATIVE_TEST_OWN += vawin_extend
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-vawin_extend
native-test-vawin_extend: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_extend runtime/tests/t_vawin_extend.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_extend
TEST_TARGETS += native-test-vawin_extend
endif
