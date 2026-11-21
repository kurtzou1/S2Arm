# native-test-vawin_trimfar：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_trimfar
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-vawin_trimfar
native-test-vawin_trimfar: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_trimfar runtime/tests/t_vawin_trimfar.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_trimfar
TEST_TARGETS += native-test-vawin_trimfar
endif
