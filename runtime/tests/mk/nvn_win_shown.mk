# native-test-nvn_win_shown：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_win_shown
ifeq ($(shell uname -s),Darwin)
# #141：取图撞上还在屏上的那张——等下一次呈现翻走再交（真机语义）、等不到 2 个呈现周期兜底、没撞立即返回。
$(BUILD)/tests/t_nvn_win_shown: graphics/nvn/tests/t_nvn_win_shown.c $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_win_shown.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_win_shown
native-test-nvn_win_shown: $(BUILD)/tests/t_nvn_win_shown
	timeout 60 $(BUILD)/tests/t_nvn_win_shown
TEST_TARGETS += native-test-nvn_win_shown
endif
