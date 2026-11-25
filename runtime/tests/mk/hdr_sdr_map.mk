# native-test-hdr_sdr_map：PR-B（#625 第二阶段）S4「SDR 转 HDR」开关解析与 present 接线单测
#   （graphics/nvn/tests/t_hdr_sdr_map.c；设计稿 §3.1 开关 / §2.3 engage 门 / §2.4 填充落点 / §3.5 探针口径 / §5.1 用例 2·4·5；
#   PR #2162 评审终稿联动面 = 相 14/15——层视角开关 nvn2_hdr_layer_sw：S4 开而玩家 S2A_HDR 未设/off ⇒ 层按 auto 进/持 PQ、
#   vi 照玩家 off 口径恒不答 on=1；玩家设 auto/on 以玩家为准）：
#   三开关（S2A_HDR_SDR_MAP 总开关 1/0 + S2A_HDR_SDR_MAP_NITS / S2A_HDR_SDR_MAP_TARGET_NITS 调校位）一次缓存解析
#   + nvn2_hdr_present 读缓存传 hdr_present_fill（关 ⇒ 0,0 纯 mode 2；开 ∧ engage 门 ⇒ p[2]=sdr、p[3]=effective target）
#   + 首次 engage 的 host.log 生效行（打一次，行文按设计稿 §3.5 定死）。开关读一次缓存、进程内不换——
#   分进程多遍起（每相一条命令行，present_hdr.mk 第二遍进程先例；S2A_HDR 由 nvn2_hdr_switch 逐次读环境，相 14/15 内自翻）。
#   纯 C，不需要 GPU / 游戏（t_hdr_layer 口径）。
#   三态流：基线（PR-A 在、PR-B 未实现）上 nvn_hdr_policy.h 无 NVN2_HDR_SDR_MAP_SWITCH 在位标记 → 本测显式红
#   （HDR_SDR_MAP_FILL 特征检测同款口径——PR-A 先例）。
NATIVE_TEST_OWN += hdr_sdr_map
.PHONY: native-test-hdr_sdr_map
native-test-hdr_sdr_map:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -o $(BUILD)/tests/t_hdr_sdr_map graphics/nvn/tests/t_hdr_sdr_map.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c
	$(BUILD)/tests/t_hdr_sdr_map off
	S2A_HDR_SDR_MAP=1 $(BUILD)/tests/t_hdr_sdr_map on
	S2A_HDR_SDR_MAP=0 $(BUILD)/tests/t_hdr_sdr_map zero
	S2A_HDR_SDR_MAP=yes $(BUILD)/tests/t_hdr_sdr_map garbage
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_NITS=203 $(BUILD)/tests/t_hdr_sdr_map nits_in
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_NITS=50 $(BUILD)/tests/t_hdr_sdr_map nits_low
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_NITS=2000 $(BUILD)/tests/t_hdr_sdr_map nits_high
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_NITS=abc $(BUILD)/tests/t_hdr_sdr_map nits_garbage
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_TARGET_NITS=1000 $(BUILD)/tests/t_hdr_sdr_map target_in
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_TARGET_NITS=100 $(BUILD)/tests/t_hdr_sdr_map target_eq_sdr
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_TARGET_NITS=50 $(BUILD)/tests/t_hdr_sdr_map target_low
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_TARGET_NITS=20000 $(BUILD)/tests/t_hdr_sdr_map target_high
	S2A_HDR_SDR_MAP=1 S2A_HDR_SDR_MAP_TARGET_NITS=9x9 $(BUILD)/tests/t_hdr_sdr_map target_garbage
	$(BUILD)/tests/t_hdr_sdr_map layer_player
	S2A_HDR_SDR_MAP=1 $(BUILD)/tests/t_hdr_sdr_map layer_s4
TEST_TARGETS += native-test-hdr_sdr_map
