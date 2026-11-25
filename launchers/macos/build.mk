# Mac game window/input shell; launcher preparation opts in with a private BUILD.
ifeq ($(S2A_MAC_FRONTEND),1)
CFLAGS += -fobjc-arc
# 玩家入口：自动玩家缺省关（tests/autoplay/ap_default.h）
CFLAGS += -DS2A_MAC_FRONTEND=1
HOST_SRCS += macos/heartbeat_mac.c macos/front_mac.m macos/joycon_imu.m macos/hid_pad.m macos/input_guide.m macos/controller_view.m macos/textinput_mac.m macos/perf_brief.m
HOST_SRCS += macos/ns2_controller.c $(wildcard runtime/ns2pro/*.c) runtime/ns2pro/NS2Transport.m
# 本地联机·同一 Wi-Fi：共用 iOS 的 Bonjour 发现（只依赖 Foundation），Mac 版权限提示在 macos/lan_permission.m（原先只链 host_main.c 的空实现，Mac 与 iPhone 互相搜不到）
HOST_SRCS += ios/ldn_lan.m macos/lan_permission.m
CFLAGS += -Iruntime/ns2pro/include -DNS2_SCAN_SECONDS=60
HOST_LIBS += -framework AppKit -framework CoreGraphics -framework GameController -framework CoreHaptics -framework CoreBluetooth -framework IOKit
NS2_HELPER := $(BUILD)/S2ArmNS2Connection
NS2_HELPER_SRCS := macos/ns2_connection_helper.m macos/ns2_parent_watch.c runtime/ns2pro/NS2Transport.m $(wildcard runtime/ns2pro/*.c)
$(NS2_HELPER): $(NS2_HELPER_SRCS) $(wildcard runtime/ns2pro/include/*.h) macos/ns2_relay.h macos/ns2_parent_watch.h
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include -DNS2_SCAN_SECONDS=60 $(NS2_HELPER_SRCS) -framework Foundation -framework CoreBluetooth -framework IOBluetooth -o $@
host: $(NS2_HELPER)
$(BUILD)/s2arm-host: launchers/macos/build.mk
endif
