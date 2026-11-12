#!/bin/bash
# 运行时现编空直连库（抽取缺口时用；11-06 两条链共用一份：Mac 链 pack/stage_direct.sh、Windows 出包机链 graphics/tools/direct/direct_lib.sh 现场抽取退 3 时）：
#   bash graphics/tools/direct/runtime_only_lib.sh <输出目录> <链号> <程序号> <inputs 标签> <缺口原因文件> [配置档 game.tsv]
# 出：<输出目录>/b-<链号>/lib.idx 空容器（48 字节头、0 条 0 分片，graphics/nvn/lib_pack.inc）+ b-<链号>/inputs.tsv 戳（game / inputs runtime-only-<标签>）
#   + 空 shader_map.tsv / keys.tsv + 空答案表 shader_facts.tsv / 配对表 shader_pairs.tsv + game.tsv（给了配置档才拷）+ runtime_only.txt（原因）；宿主见到 b-<链> + shader_map.tsv + lib.idx 就按直连起
#   （11-06 质量线疯狂兔子：原先不带两张表，宿主兜底现编载表（graphics/tools/direct/dsh/Tables.cs）缺 shader_facts.tsv 报「no answer table」、整支失败，8 秒丢 8231 笔绘制；
#    空表 = 全部按缺省答）。c1_full.tsv / cb_extent.tsv 故意不给：给了合法表头就被当真用（空 c1_full = 没有满 64 KiB 的 c1），运行时现编的着色器事先不知道，
#    缺表时宿主走安全缺省（每个 c1 给 64 KiB、整段绑定都可读）
#   （runtime/src/gfxmode.c s2a_direct_packaged），映射表里没有的键首遇现编。同 OpenGL 款离线 0 支的先例。
# 退出码：0 写成；1 参数 / 写文件失败。输出目录须是空的或新建的（调用方负责）
# 实现在同目录 runtime_only_lib.py（一个进程做完，内存吃紧时也做得完；产物见它的头注）
set -u
PY=${S2A_PYTHON:-${S2A_PY:-$(command -v python3)}}
exec "$PY" "$(dirname "$0")/runtime_only_lib.py" "$@"
