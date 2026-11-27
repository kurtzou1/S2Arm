# native-test-game_defaults：逐款测过的缺省宿主端单测（runtime/src/gdefaults.c，11-27）。夹具表按生产同一条路生成头（tools/game_defaults.py emit）
NATIVE_TEST_OWN += game_defaults
.PHONY: native-test-game_defaults
native-test-game_defaults:
	@mkdir -p $(BUILD)/tests/game_defaults
	python3 -c "import sys; sys.path.insert(0, 'tools'); import game_defaults as g; r = g.parse(open('runtime/tests/data/game_defaults_fixture.tsv', encoding='utf-8').read()); e = g.lint(r, g.settings_items()); sys.exit('\n'.join(e)) if e else open('$(BUILD)/tests/game_defaults/s2a_game_defaults_fixture.h', 'w', encoding='utf-8').write(g.emit(r, g.settings_items()))"
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_GAME_DEFAULTS_NO_TABLE -I$(BUILD)/tests/game_defaults -o $(BUILD)/tests/t_game_defaults runtime/tests/t_game_defaults.c runtime/src/gdefaults.c
	$(BUILD)/tests/t_game_defaults
TEST_TARGETS += native-test-game_defaults
