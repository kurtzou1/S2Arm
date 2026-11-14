#!/bin/bash
# 门禁只看：pack/sysdata_synth.py pack/sysdata_mii.py tools/make_sysdata_synth_tar.py services/S2A.Services/systemdata_synth.tar tests/sysdata_synth_tar_test.py
# 嵌进服务程序集的合成系统数据与生成器不漂移（逐字节同重出的 tar、覆盖生成器登记的全部号）：bash tests/sysdata_synth_tar_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/sysdata_synth_tar_test.py"
