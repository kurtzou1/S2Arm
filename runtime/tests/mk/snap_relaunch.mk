# native-test-snap_relaunch：Mac 进程内接不上快照时原地重新执行自己（runtime/src/snaprelaunch.c）
NATIVE_TEST_OWN += snap_relaunch
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-snap_relaunch
native-test-snap_relaunch:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_snap_relaunch runtime/tests/t_snap_relaunch.c runtime/src/snaprelaunch.c
	$(BUILD)/tests/t_snap_relaunch
TEST_TARGETS += native-test-snap_relaunch
endif
