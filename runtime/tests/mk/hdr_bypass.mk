# native-test-hdr_bypass：PR3d AA/FX/FI 旁路判定单测（graphics/nvn/tests/t_hdr_bypass.c；评审稿 v3 §2.5 开关矩阵 / §3 A3 行 / §4 PR3d「新单测」行）——
#   旁路判定纯逻辑（窗口格式 × S2A_HDR 开关 × vi 答过 latch）全矩阵 + nvn2.c 存储侧入口（latch 不在快路径 0、
#   SDR 窗照常、off 不变量经存储入口同成立）；纯 C，不需要 GPU / 游戏（同 t_hdr_layer 口径）。
#   三态流：基线（无 PR3d 实现）上 hdr_bypass_upscale / nvn2_hdr_bypass_upscale 不存在 → 编译期报未声明函数——红。
NATIVE_TEST_OWN += hdr_bypass
.PHONY: native-test-hdr_bypass
native-test-hdr_bypass:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -o $(BUILD)/tests/t_hdr_bypass graphics/nvn/tests/t_hdr_bypass.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c
	$(BUILD)/tests/t_hdr_bypass
TEST_TARGETS += native-test-hdr_bypass
