# native-test-nvn_tex：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tex
ifeq ($(shell uname -s),Darwin)
# Texture 组（#270 N12）：GL 名字往返、稀疏布局同构造器口径、调试 ID 稳定。
$(BUILD)/tests/t_nvn_tex: graphics/nvn/tests/t_nvn_tex.c graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_tex.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tex
native-test-nvn_tex: $(BUILD)/tests/t_nvn_tex
	timeout 60 $(BUILD)/tests/t_nvn_tex
TEST_TARGETS += native-test-nvn_tex
endif
