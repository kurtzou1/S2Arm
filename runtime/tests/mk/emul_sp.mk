# native-test-emul_sp：栈指针未对齐替做读写（emul_sp.c 复用 emul_ld.c / emul_st.c 的解码，三个一起链）；runtime/build.mk 按 runtime/tests/mk/*.mk 收进来
NATIVE_TEST_OWN += emul_sp
.PHONY: native-test-emul_sp
native-test-emul_sp:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_emul_sp runtime/tests/t_emul_sp.c runtime/src/emul_sp.c runtime/src/emul_ld.c runtime/src/emul_st.c
	$(BUILD)/tests/t_emul_sp
TEST_TARGETS += native-test-emul_sp
