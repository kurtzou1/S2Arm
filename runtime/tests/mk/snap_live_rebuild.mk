NATIVE_TEST_OWN += snap_live_rebuild
.PHONY: native-test-snap_live_rebuild
native-test-snap_live_rebuild:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_snap_live_rebuild runtime/tests/t_snap_live_rebuild.c runtime/src/thread.c -lpthread
	$(BUILD)/tests/t_snap_live_rebuild
TEST_TARGETS += native-test-snap_live_rebuild
