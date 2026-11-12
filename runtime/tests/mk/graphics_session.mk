# Explicit real-resource probe. The native retirement stage is called only by
# this guest-free process; production restart must first join every guest thread.
NATIVE_TEST_OWN += graphics_session
ifeq ($(shell uname -s),Darwin)
.PHONY: native-graphics-session-probe native-test-graphics_session
native-graphics-session-probe: $(BUILD)/s2arm-host graphics/nvn/tests/t_session_resources.m graphics/nvn/tests/gl/t_session_resources.m graphics/nvn/tests/vk/t_session_resources.m
	@test "$(S2A_CS)" = 1 || { echo 'native-graphics-session-probe requires S2A_CS=1'; exit 1; }
	@mkdir -p $(BUILD)/graphics-session-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/graphics-session-probe/host_main.o
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/gfx/nvn -Igraphics/nvn/third_party/vulkan-headers/include -o $(BUILD)/probe_graphics_session graphics/nvn/tests/t_session_resources.m graphics/nvn/tests/gl/t_session_resources.m graphics/nvn/tests/vk/t_session_resources.m $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/graphics-session-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK)
native-test-graphics_session:
	$(MAKE) S2A_CS=1 BUILD=$(BUILD)/graphics-session-test native-graphics-session-probe
	$(BUILD)/graphics-session-test/probe_graphics_session
	S2A_TEST_VK_BC=1 $(BUILD)/graphics-session-test/probe_graphics_session
	S2A_TEST_VK_BC=1 DM_TEST_NO_BC=1 $(BUILD)/graphics-session-test/probe_graphics_session
	@echo '✓ t_session_resources'
	@echo '✓ t_graphics_session'
TEST_TARGETS += native-test-graphics_session
endif
