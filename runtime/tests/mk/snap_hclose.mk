NATIVE_TEST_OWN += snap_hclose
.PHONY: native-test-snap_hclose
native-test-snap_hclose:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_snap_hclose runtime/tests/t_snap_hclose.c runtime/src/thread.c -lpthread
	$(BUILD)/tests/t_snap_hclose
TEST_TARGETS += native-test-snap_hclose
