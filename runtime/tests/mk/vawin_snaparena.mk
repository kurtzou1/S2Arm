# native-test-vawin_snaparena：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_snaparena
ifeq ($(S2A_UNAME),Darwin)
# 即时存档命令记录区放哪（vawin.c s2a_snap_arena_place，纯函数）：纯函数在 layout.c，只链它
.PHONY: native-test-vawin_snaparena
native-test-vawin_snaparena:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_snaparena runtime/tests/t_vawin_snaparena.c runtime/src/layout.c
	$(BUILD)/tests/t_vawin_snaparena
TEST_TARGETS += native-test-vawin_snaparena
endif
