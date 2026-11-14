#!/bin/bash
# 门禁覆盖：launchers/macos/bundle_engine.py launchers/macos/build_app.py tests/mac_bundle_bytecode_test.py tests/mac_bundle_bytecode_test.sh
# App 包运行时不写 .pyc（预编 checked-hash 签进包 + sitecustomize 关写字节码，约 1 秒）：bash tests/mac_bundle_bytecode_test.sh
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${PYTHON:-python3}" "$H/tests/mac_bundle_bytecode_test.py"
