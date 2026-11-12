#!/usr/bin/env python3
"""Mac 起局前只读核对 NVN 产物链；无 NVN 库的根不受影响。"""
import os
from pathlib import Path
import re
import struct
import sys

LIB_FLAGS_KNOWN = 0x1   # lib.idx 头 flags 已定义的位（位 0：tensor ABI 1）


def check(root):
    # 正常重建的 NVN 宿主编译这个生成头，不采用当前环境的出库选项。
    header = Path(__file__).resolve().parents[1] / "graphics/nvn/gfx/nvn/dmsh_chain.h"
    host = re.search(r'^#define DMSH_CHAIN "([0-9a-f]{12})"$', header.read_text(), re.MULTILINE)
    if not host:
        raise ValueError("宿主 DMSH_CHAIN 头格式无效")
    host = host[1]
    direct = Path(root) / "shaders/direct"
    if not direct.exists():
        return 0
    chains = sorted(p.name[2:] for p in direct.iterdir() if p.is_dir() and p.name.startswith("b-"))
    if not chains:
        return 0
    if host in chains:
        # 容器自带身份也须一致，防止目录改名掩盖旧链；逐键旧格式没有此索引。
        index = direct / ("b-" + host) / "lib.idx"
        if index.exists():
            with index.open("rb") as stream:
                raw = stream.read(48)
            if len(raw) != 48:
                raise ValueError("直连库 lib.idx 头截断")
            # 偏移 20 是 flags（graphics/nvn/lib_pack_core.inc 头格式；位 0 = 全部计算程序为 tensor ABI 1，LibPack.cs 11-09 起会写 1）：
            #   原先当成保留字段要求为 0，带这个标志的游戏 Mac 局在起局前一律被拒。只认已定义的位，出现别的位才算头无效
            magic, version, _, _, flags, chain = struct.unpack("<8sIIII12s12x", raw)
            if magic != b"S2ALIB\0\0" or version != 1 or flags & ~LIB_FLAGS_KNOWN:
                raise ValueError("直连库 lib.idx 头无效")
            actual = chain.rstrip(b"\0").decode("ascii")
            if actual == host:
                return 0
            chains = [actual]
        else:
            return 0
    message = f"Mac 起局链号不一致：产物 {','.join(chains)}，宿主 {host}"
    if os.environ.get("S2A_ALLOW_CHAIN_MISMATCH") == "1":
        print(f"【黄】{message}；S2A_ALLOW_CHAIN_MISMATCH=1 显式放行", file=sys.stderr)
        return 0
    print(f"【红】{message}；请重出产物，专测回退时设 S2A_ALLOW_CHAIN_MISMATCH=1", file=sys.stderr)
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法：mac_chain_check.py <产物根>")
    try:
        result = check(sys.argv[1])
    except (OSError, ValueError) as error:
        print(f"【红】Mac 起局链号检查失败：{error}", file=sys.stderr)
        result = 1
    sys.exit(result)
