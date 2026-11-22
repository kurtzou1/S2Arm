# native-test-vawin_snap_retake：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_snap_retake
ifeq ($(S2A_UNAME),Darwin)
# 即时存档恢复局起宿主前按快照清单原址重占窗口与命令记录区（vawin.c snap_retake）：清单读取函数由单测给强定义
.PHONY: native-test-vawin_snap_retake
native-test-vawin_snap_retake: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_snap_retake runtime/tests/t_vawin_snap_retake.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_snap_retake
TEST_TARGETS += native-test-vawin_snap_retake
endif
