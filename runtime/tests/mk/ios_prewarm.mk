# Real VA reservation, boot continuation and Foundation preferences; UIKit remains a device check.
NATIVE_TEST_OWN += ios_prewarm
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-ios_prewarm
native-test-ios_prewarm: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests/ios_prewarm
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/tests/support/ios_prewarm -c runtime/src/vawin.c -o $(BUILD)/tests/ios_prewarm/vawin.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -c runtime/src/envfile.c -o $(BUILD)/tests/ios_prewarm/envfile.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_ios_prewarm $(BUILD)/tests/ios_prewarm/envfile.o runtime/tests/t_ios_prewarm.m runtime/src/boot.c runtime/src/boot_defer.c runtime/src/caps.c runtime/src/patch.c ios/settings.m ios/cpatch_model.m runtime/src/launchctx.c $(BUILD)/tests/ios_prewarm/vawin.o -Wl,-weak_library,$(TEST_VAGUARD)
	@env -u ActivePrewarm -u S2A_RES_SCALE S2A_DOCS=$(abspath $(BUILD))/tests/ios_prewarm S2A_WIN_NEED_MB=63488 $(BUILD)/tests/t_ios_prewarm normal > $(BUILD)/tests/ios_prewarm/normal.log 2>&1 || { cat $(BUILD)/tests/ios_prewarm/normal.log; exit 1; }
	@for value in 0 11 true; do env -u S2A_RES_SCALE S2A_DOCS=$(abspath $(BUILD))/tests/ios_prewarm S2A_WIN_NEED_MB=63488 ActivePrewarm=$$value $(BUILD)/tests/t_ios_prewarm normal > $(BUILD)/tests/ios_prewarm/value-$$value.log 2>&1 || { cat $(BUILD)/tests/ios_prewarm/value-$$value.log; exit 1; }; done
	@env -u S2A_RES_SCALE S2A_DOCS=$(abspath $(BUILD))/tests/ios_prewarm S2A_WIN_NEED_MB=63488 ActivePrewarm=1 $(BUILD)/tests/t_ios_prewarm prewarm > $(BUILD)/tests/ios_prewarm/prewarm.log 2>&1 || { cat $(BUILD)/tests/ios_prewarm/prewarm.log; exit 1; }
	@env -u S2A_RES_SCALE S2A_DOCS=$(abspath $(BUILD))/tests/ios_prewarm S2A_WIN_NEED_MB=63488 ActivePrewarm=1 S2A_PACK_APPLY_ONLY=1 $(BUILD)/tests/t_ios_prewarm prewarm-apply > $(BUILD)/tests/ios_prewarm/prewarm-apply.log 2>&1 || { cat $(BUILD)/tests/ios_prewarm/prewarm-apply.log; exit 1; }
	@env -u ActivePrewarm -u S2A_RES_SCALE S2A_DOCS=$(abspath $(BUILD))/tests/ios_prewarm S2A_WIN_NEED_MB=63488 $(BUILD)/tests/t_ios_prewarm need-ui > $(BUILD)/tests/ios_prewarm/need-ui.log 2>&1 || { cat $(BUILD)/tests/ios_prewarm/need-ui.log; exit 1; }
	@echo "✓ t_ios_prewarm：真实窗口、iOS一律等待激活、续体仅取一次；UIKit/dguard提示与加载页显示未在此测试"
TEST_TARGETS += native-test-ios_prewarm
endif
