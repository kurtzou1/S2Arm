# native-test-cloud_seed：手机直导 .s2arm 的款补取云端管线种子（ios/cloud_seed.m）单测：本地目录当下载站，不联网。要 Foundation / zlib，只 Mac
NATIVE_TEST_OWN += cloud_seed
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-cloud_seed
native-test-cloud_seed:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -DS2A_UNIT_TEST -fobjc-arc -o $(BUILD)/tests/t_cloud_seed runtime/tests/t_cloud_seed.m ios/cloud_seed.m -framework Foundation -lz
	$(BUILD)/tests/t_cloud_seed
TEST_TARGETS += native-test-cloud_seed
endif
