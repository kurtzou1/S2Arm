# native-test-nvn_mesh_pad：网格着色器补齐变体（#674）的源码改写（graphics/nvn/host/mesh_pad.h）与 Metal 真建管线（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_mesh_pad
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_mesh_pad: graphics/nvn/tests/t_nvn_mesh_pad.m graphics/nvn/host/mesh_pad.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Igraphics/nvn/host -o $@ graphics/nvn/tests/t_nvn_mesh_pad.m -framework Metal -framework Foundation
.PHONY: native-test-nvn_mesh_pad
native-test-nvn_mesh_pad: $(BUILD)/tests/t_nvn_mesh_pad
	timeout 60 $(BUILD)/tests/t_nvn_mesh_pad
else
.PHONY: native-test-nvn_mesh_pad
native-test-nvn_mesh_pad:
	@echo "✓ t_nvn_mesh_pad：非 macOS 跳过（要 Metal 网格管线）"
endif
