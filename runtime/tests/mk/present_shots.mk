# native-test-present_shots：PR6 截图/判定/录像 mode 1 副本（graphics/nvn/tests/t_present_shots.m；评审稿 v3 §4 PR6 / §3 A9、B8 行）——
#   HDR 源 → grab 副本闭环对拍（复用 PR3b 闭环基建：生产 nvn_mtl.m 源码 + 真 Metal 设备，CPU 双精度复算 ±1）
#   + fit_judge 在 PQ 源上无误报 + 截图（shot）非 8 位窗走 present 同一离屏编码。
#   第二遍进程跑 DM_NVN_SHOT_OUT=64x9（显式尺寸优先路径——该分支先于本 PR 已在，锁 PR6 合并不动它）
NATIVE_TEST_OWN += present_shots
ifeq ($(S2A_UNAME),Darwin)
PRESENT_SHOTS_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
PRESENT_SHOTS_BINARY ?= $(BUILD)/tests/t_nvn_present_shots   # 目标名以 t_nvn_ 开头：吃到 runtime/build.mk 生成头（gen/gal_tess_msl.h、AA 表）的 -I（同 present_hdr.mk 先例）
$(PRESENT_SHOTS_BINARY): graphics/nvn/tests/t_present_shots.m $(PRESENT_SHOTS_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DT_PRESENT_SHOTS_SOURCE='"$(abspath $(PRESENT_SHOTS_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_present_shots.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-present_shots
native-test-present_shots: $(PRESENT_SHOTS_BINARY)
	$(PRESENT_SHOTS_BINARY)
	DM_NVN_SHOT_OUT=64x9 T_PRESENT_SHOTS_SHOTOUT=1 $(PRESENT_SHOTS_BINARY)
TEST_TARGETS += native-test-present_shots
endif
