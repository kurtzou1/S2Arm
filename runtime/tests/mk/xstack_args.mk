# native-test-xstack_args：AAPCS64 栈参数切栈；H.264 编码初始化有 13 个栈槽，旧 64 字节副本会丢后 5 格。
NATIVE_TEST_OWN += xstack_args
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-xstack_args
native-test-xstack_args:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_xstack_args runtime/tests/t_xstack_args.c runtime/src/xstack.c runtime/src/entry.S platform/apple/plat_apple.c -Wl,-undefined,dynamic_lookup
	timeout 30 $(BUILD)/tests/t_xstack_args
TEST_TARGETS += native-test-xstack_args
endif
