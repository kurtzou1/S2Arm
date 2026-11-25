# native-test-snapdel：即时快照删除与新快照原子换上（runtime/src/snapdel.c，只在苹果端编；单测只链本文件，s2a_snap_busy 由单测自己给替身、不链引擎）
NATIVE_TEST_OWN += snapdel
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-snapdel
native-test-snapdel:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Wall -Wextra -Werror -o $(BUILD)/tests/t_snapdel runtime/tests/t_snapdel.c runtime/src/snapdel.c
	$(BUILD)/tests/t_snapdel
TEST_TARGETS += native-test-snapdel
endif
