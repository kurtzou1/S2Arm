# native-test-bcd_gpu：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += bcd_gpu
ifeq ($(shell uname -s),Darwin)
# 无 BC 显卡上 BC1–5、BC6H 与 BC7 的 GPU 解压核 bcd 对 CPU 端 bcdec 逐纹素比（10-26；BC7 / BC6H 11-13，#582）
$(BUILD)/tests/t_bcd_gpu: graphics/nvn/tests/t_bcd_gpu.m graphics/nvn/gfx/tex/nvn_bcd_msl.h graphics/nvn/gfx/tex/nvn_bcdec.c graphics/nvn/gfx/tex/nvn_bcdec.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ graphics/nvn/tests/t_bcd_gpu.m graphics/nvn/gfx/tex/nvn_bcdec.c -framework Metal -framework Foundation
.PHONY: native-test-bcd_gpu
native-test-bcd_gpu: $(BUILD)/tests/t_bcd_gpu
	$(BUILD)/tests/t_bcd_gpu
TEST_TARGETS += native-test-bcd_gpu
endif
