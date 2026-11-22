#!/bin/bash
# 门禁覆盖：pack/jobs/livecontainer.py tests/livecontainer_only_transfer_test.py
# LiveContainer 宿主直推只走已配对设备的文件通道、不依赖 Wi-Fi 接收端（#2010）：读源码断言，约 1 秒；见 tests/livecontainer_only_transfer_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/livecontainer_only_transfer_test.py
