# native-test-snap_save_undo：即时存档恢复失败撤销退回存档（runtime/src/snapshot.c save_undo_at，#2292）。从生产源文件原样截取三个函数编进来
NATIVE_TEST_OWN += snap_save_undo
.PHONY: native-test-snap_save_undo
native-test-snap_save_undo:
	@mkdir -p $(BUILD)/tests/snap_save_undo
	awk '/^static void tree_files\(/{f=1} /^static int save_tree_put_at\(/{f=1} /^static int save_undo_at\(/{f=1} f{print} f&&/^}/{f=0}' runtime/src/snapshot.c > $(BUILD)/tests/snap_save_undo/snap_save_undo_ext.c
	@grep -q '^static int save_undo_at(' $(BUILD)/tests/snap_save_undo/snap_save_undo_ext.c || { echo "✗ t_snap_save_undo：snapshot.c 里没有 save_undo_at"; exit 1; }
	$(CC) $(CFLAGS) -I$(BUILD)/tests/snap_save_undo -o $(BUILD)/tests/t_snap_save_undo runtime/tests/t_snap_save_undo.c
	$(BUILD)/tests/t_snap_save_undo
TEST_TARGETS += native-test-snap_save_undo
