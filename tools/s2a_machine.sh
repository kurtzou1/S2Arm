#!/bin/bash
# 「我方机器 / 单机」判定，全仓库只此一处（维护者 11-04）：source 本文件后调 s2a_ours，0 = 我方机器、1 = 单机。只定义函数，不改环境、不打输出。
#   用方：维护方工具（我方机器只认运行区局槽仲裁副本，单机用树内）；mem_admit 读运行区估值表时同样调它，不另写。
# 判据：${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/env/layout.env 存在，或在 维护方工具 派的远端（S2A_REMOTE_RUN=1）→ 我方机器；其余一律单机。
#   理由：不用「运行区根目录存在」——它会被我方脚本自己建出来（维护方工具 mkdir -p 槽目录 locks/、graphics/tools/direct/direct_lib.py 在
#   ${S2A_RUN_ROOT}/s2arm/cache/direct/ 下建缓存目录），单机第 1 局后、玩家机出包途中都会被误判成我方机器（11-04 实测）；
#   layout.env 只由运维写、仓库只读不写，是我方机器的专属标记。单机没人抢槽，共享资源的仲裁问题不存在，用树内那份是对的
s2a_ours() { [ -f "${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/env/layout.env" ] || [ "${S2A_REMOTE_RUN:-}" = 1 ]; }
