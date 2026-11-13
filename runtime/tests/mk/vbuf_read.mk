# native-test-vbuf_read：bind_vbufs 只解析顶点着色器输入取数的流（nvn_vbuf_read.h，#618）；不需要 GPU / 游戏
NATIVE_TEST_OWN += vbuf_read
.PHONY: native-test-vbuf_read
native-test-vbuf_read:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_vbuf_read graphics/nvn/tests/t_vbuf_read.c
	$(BUILD)/tests/t_vbuf_read
TEST_TARGETS += native-test-vbuf_read
