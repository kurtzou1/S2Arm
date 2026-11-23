# native-test-vawin_snap_guard：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_snap_guard
ifeq ($(S2A_UNAME),Darwin)
# 快照原址护栏（vawin.c snap_guard_take）：构造期替有快照的款占住快照那局的落点，起宿主前放；清单读取函数由单测给强定义。三种模式各起一个进程（构造期只占一次）
.PHONY: native-test-vawin_snap_guard
native-test-vawin_snap_guard: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_snap_guard runtime/tests/t_vawin_snap_guard.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	T_SG_MODE=A $(BUILD)/tests/t_vawin_snap_guard
	T_SG_MODE=B $(BUILD)/tests/t_vawin_snap_guard
	T_SG_MODE=C $(BUILD)/tests/t_vawin_snap_guard
TEST_TARGETS += native-test-vawin_snap_guard
endif
