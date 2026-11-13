# native-test-vawin_widen：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_widen
ifeq ($(shell uname -s),Darwin)
# 按学到的跨度收窄后放不下：同一次启动当场放宽（vawin.c s2a_window_span_widen，v0.3.4）；S2A_VA_IOS26=1 造放不下标准布局的空洞
.PHONY: native-test-vawin_widen
native-test-vawin_widen: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_widen runtime/tests/t_vawin_widen.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	S2A_VA_IOS26=1 $(BUILD)/tests/t_vawin_widen
TEST_TARGETS += native-test-vawin_widen
endif
