# native-test-ladder_present30：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ladder_present30
ifeq ($(S2A_UNAME),Darwin)
# 档位梯子压回 30 帧档时直连出图封顶 30（#1766）：链生产 runtime/src/fps.c（降档原因）与直连库 hle_nvn.c（出图节拍），不打桩
$(BUILD)/tests/t_ladder_present30: graphics/nvn/tests/t_ladder_present30.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(NATIVE_INC) \
	  -o $@ graphics/nvn/tests/t_ladder_present30.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-ladder_present30
native-test-ladder_present30: $(BUILD)/tests/t_ladder_present30
	S2A_GFX=direct $(BUILD)/tests/t_ladder_present30
TEST_TARGETS += native-test-ladder_present30
endif
