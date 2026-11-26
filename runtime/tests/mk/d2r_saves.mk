# native-test-d2r_saves covers D2R-Mobile local save migration and character import.
NATIVE_TEST_OWN += d2r_saves
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-d2r_saves
native-test-d2r_saves:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -fobjc-arc -o $(BUILD)/tests/t_d2r_saves ios/d2r/t_local_saves.m ios/d2r/d2r_saves.m -framework Foundation
	$(BUILD)/tests/t_d2r_saves
TEST_TARGETS += native-test-d2r_saves
endif
