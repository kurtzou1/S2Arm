# native-test-nvn_mesh_emu：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_mesh_emu
ifeq ($(S2A_UNAME),Darwin)
# 宿主自跑任务 / 网格阶段的 GPU 改写（mxe_scan 两级前缀和、mxc_patch 剔三角形、mxd_patch 阶段内存放设备内存）：真 GPU 上跑生产的核 / 改写后的核，和 CPU 参考逐字比。
#   夹具 t_nvn_mesh_emu.metal 是翻译器原样输出（只换阶段函数体），本测读源码现编
$(BUILD)/tests/t_nvn_mesh_emu: graphics/nvn/tests/t_nvn_mesh_emu.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_mesh_emu.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_mesh_emu
native-test-nvn_mesh_emu: $(BUILD)/tests/t_nvn_mesh_emu graphics/nvn/tests/t_nvn_mesh_emu.metal
	T_MESH_EMU_SRC=$(abspath graphics/nvn/tests/t_nvn_mesh_emu.metal) timeout 120 $(BUILD)/tests/t_nvn_mesh_emu
TEST_TARGETS += native-test-nvn_mesh_emu
endif
