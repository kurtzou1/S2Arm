#!/bin/bash
# 门禁覆盖：tools/game_defaults.py launchers/shared/game_defaults.v1.tsv launchers/shared/game_settings.v1.json runtime/include/s2a_game_defaults.h runtime/tests/data/game_defaults_fixture.tsv pack/jobs/community.py tests/game_defaults_test.py
# 逐款测过的缺省（11-27）：表合格、生成头与表一致（反证：改表不重新生成报红）、查表优先级与宿主单测 t_game_defaults 同一组期望、lint 正反、Mac 设置页「本款推荐」
#   bash tests/game_defaults_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H" && python3 -B tests/game_defaults_test.py 2>&1 | tail -25
r=${PIPESTATUS[0]}
[ "$r" = 0 ] && echo "✓ game_defaults 单测全过" || { echo "✗ game_defaults 单测有不通"; exit 1; }
