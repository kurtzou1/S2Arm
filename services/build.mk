# 服务接入线（services/、compat/）构建片段：被顶层 Makefile 包含。
# S2A_CS=1 时把 C# 侧（NativeAOT 静态库：服务层 + Ryujinx + NxGal）链进宿主；缺省不链（原生层单独构建时进 C# 的系统调用一律报红）。
# 链 C# 还需要渲染器 libnxgal（帧率能耗线）与原生层的全部 s2a_* 导出。
ifeq ($(S2A_CS),1)
# 纯 iOS 目标用下面的 IOS_LIBS，不在解析 Makefile 时先构建 Mac 库。
# 默认宿主目标与混合目标仍保留 Mac 依赖及失败检查。
ifneq ($(strip $(if $(MAKECMDGOALS),$(filter-out ios ios-%,$(MAKECMDGOALS)),host)),)
S2A_CS_LDFLAGS := $(shell mkdir -p build/cs && bash services/nxaot.sh osx-arm64 2>build/cs/nxaot_osx.err | tail -1)
ifeq ($(S2A_CS_LDFLAGS),)
$(info $(shell tail -15 build/cs/nxaot_osx.err | tr '\n' '|'))
$(error services/nxaot.sh 失败（上一行是它输出的末尾，| 分行；全文 build/cs/nxaot_osx.err）)
endif
# 原生层有弱符号 S2A_Init 空实现，引用已满足，静态库成员不会被自动拉进来：用 -force_load 强制载入（库是 ld -r 合成的单成员），强符号覆盖弱符号
S2A_CS_LIB := $(firstword $(S2A_CS_LDFLAGS))
HOST_LIBS += -Wl,-force_load,$(S2A_CS_LIB) $(wordlist 2,999,$(S2A_CS_LDFLAGS))
# libvpx VP8 解码（Nvdec，DirectPInvoke s2a_vpx）：libvpx + 垫片合成的静态库
S2A_VPX_LIB := $(shell bash services/vpx/build.sh osx-arm64 2>build/cs/vpx_osx.err | tail -1)
ifeq ($(S2A_VPX_LIB),)
$(info $(shell tail -8 build/cs/vpx_osx.err | tr '\n' '|'))
$(error services/vpx/build.sh 失败（全文 build/cs/vpx_osx.err）)
endif
HOST_LIBS += $(S2A_VPX_LIB)
# dav1d AV1 软件解码（Switch 2 直连档 nn::codec AV1 解码器在 VideoToolbox 不支持 AV1 时用，graphics/nvn/gfx/nvn/nvn2_codec.c）：dav1d + 垫片合成的静态库
# S2A_DAV1D=0：不链软件兜底（仅适合确认所有目标机都有 AV1 硬件解码的本地构建；默认 1）
ifneq ($(S2A_DAV1D),0)
S2A_DAV1D_LIB := $(shell bash services/dav1d/build.sh osx-arm64 2>build/cs/dav1d_osx.err | tail -1)
ifeq ($(S2A_DAV1D_LIB),)
$(info $(shell tail -8 build/cs/dav1d_osx.err | tr '\n' '|'))
$(error services/dav1d/build.sh 失败（全文 build/cs/dav1d_osx.err）)
endif
HOST_LIBS += $(S2A_DAV1D_LIB)
endif
# libopus 解码（Horizon hwopus，DirectPInvoke s2a_opus）：libopus + 垫片合成的静态库
S2A_OPUS_LIB := $(shell bash services/opus/build.sh osx-arm64 2>build/cs/opus_osx.err | tail -1)
ifeq ($(S2A_OPUS_LIB),)
$(info $(shell tail -8 build/cs/opus_osx.err | tr '\n' '|'))
$(error services/opus/build.sh 失败（全文 build/cs/opus_osx.err）)
endif
HOST_LIBS += $(S2A_OPUS_LIB)
# 库按源码内容哈希放整机缓存（services/nxaot.sh）：C# 改回旧内容时换回一份更早建好的库，按修改时间判不出要重链，宿主静默带着上一版 C#
#   （10-31 直连线帧回放实测：改回 WidenSession.cs 后 make 秒过、宿主仍是带实验开关的旧库）。库路径进戳文件（路径变了才改写），宿主依赖它；
#   不进 .host_cfg：那份戳所有目标文件都依赖，C# 一改会把全部 C 代码重编
S2A_CS_LIB_STAMP := $(BUILD)/.cs_lib
$(shell mkdir -p $(BUILD); [ "$$(cat $(S2A_CS_LIB_STAMP) 2>/dev/null)" = '$(S2A_CS_LIB)' ] || printf '%s' '$(S2A_CS_LIB)' > $(S2A_CS_LIB_STAMP))
$(BUILD)/s2arm-host: $(S2A_CS_LIB) $(S2A_CS_LIB_STAMP)
endif
endif

# iOS App 一律链 C#（产品）：同一份 NativeAOT 镜像（服务层 + Ryujinx + NxGal + 渲染循环）的 ios-arm64 版，-force_load 同 Mac。
# 只在链接参数首次展开时出库并缓存结果；失败立即停止，诊断保存在本次 BUILD/cs 下。
# 先检查脚本退出码再取最后一行，避免 tail 掩盖失败或把失败前的 stdout 当成链接参数。
# 失败时把 stderr 里的红行（没有就末三行）带进错误行（#449）：出壳 pack/shell_build.sh 只摘 make.log 里的红行，出壳临时目录（含这份 .err）随后就删，原先报红内容是空的。
define s2a_ios_lib
$(eval $(1) := $(shell mkdir -p "$(BUILD)/cs" && result=$$(bash $(2) ios-arm64 2>"$(BUILD)/cs/$(3)_ios.err") && printf '%s\n' "$$result" | tail -1))$(if $(strip $($(1))),$($(1)),$(error $(2) 失败：$(shell { grep -a -m1 -E '🔴|【红】' "$(BUILD)/cs/$(3)_ios.err" || tail -3 "$(BUILD)/cs/$(3)_ios.err"; } | tr '\n' ' ')（全文 $(BUILD)/cs/$(3)_ios.err）))
endef
S2A_CS_IOS_LDFLAGS = $(call s2a_ios_lib,S2A_CS_IOS_LDFLAGS,services/nxaot.sh,nxaot)
S2A_VPX_IOS_LIB = $(call s2a_ios_lib,S2A_VPX_IOS_LIB,services/vpx/build.sh,vpx)
S2A_OPUS_IOS_LIB = $(call s2a_ios_lib,S2A_OPUS_IOS_LIB,services/opus/build.sh,opus)
ifneq ($(S2A_DAV1D),0)
S2A_DAV1D_IOS_LIB = $(call s2a_ios_lib,S2A_DAV1D_IOS_LIB,services/dav1d/build.sh,dav1d)
endif
IOS_LIBS += -Wl,-force_load,$(firstword $(S2A_CS_IOS_LDFLAGS)) $(wordlist 2,999,$(S2A_CS_IOS_LDFLAGS)) $(S2A_VPX_IOS_LIB) $(S2A_OPUS_IOS_LIB) $(S2A_DAV1D_IOS_LIB)

.PHONY: services-test ryujinx-verify
services-test:
	bash services/test.sh
ryujinx-verify:
	bash compat/verify.sh
TEST_TARGETS += ryujinx-verify services-test
