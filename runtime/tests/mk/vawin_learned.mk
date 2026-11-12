# native-test-vawin_learned：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_learned
ifeq ($(shell uname -s),Darwin)
# 放不下标准布局时宿主预留按学到的跨度（vawin.c s2a_window_host_below，#783）
.PHONY: native-test-vawin_learned
native-test-vawin_learned: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_learned runtime/tests/t_vawin_learned.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_learned
TEST_TARGETS += native-test-vawin_learned
endif
