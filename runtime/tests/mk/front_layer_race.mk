# native-test-front_layer_race：Mac 出图层首次取用多线程竞争（graphics/nvn/tests/t_front_layer_race.m）——
#   8 线程同时首调 front_metal_layer，每轮新进程、40 轮：配置块只进一次、都拿到配好的同一块层、不崩。
#   只编 host_adapt.m 一个文件，dead_strip 后用到的宿主符号由单测给（日志、HDR 开关）；要 Metal 设备，不要游戏。
NATIVE_TEST_OWN += front_layer_race
.PHONY: native-test-front_layer_race
native-test-front_layer_race:
	@mkdir -p $(BUILD)/tests
	xcrun --sdk macosx clang -std=gnu11 -O1 -g -fobjc-arc -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/host -Iruntime/include -c graphics/nvn/host_adapt.m -o $(BUILD)/tests/t_front_layer_race_ha.o
	xcrun --sdk macosx clang -std=gnu11 -O1 -g -fobjc-arc -Iruntime/include -o $(BUILD)/tests/t_front_layer_race graphics/nvn/tests/t_front_layer_race.m $(BUILD)/tests/t_front_layer_race_ha.o \
		-Wl,-dead_strip -framework Metal -framework QuartzCore -framework Foundation -framework CoreGraphics
	$(BUILD)/tests/t_front_layer_race
TEST_TARGETS += native-test-front_layer_race
