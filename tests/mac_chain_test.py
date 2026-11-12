"""临时索引验证正式 Mac 入口的起局链号判定，不使用游戏数据。"""
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
header = (repo / "graphics/nvn/gfx/nvn/dmsh_chain.h").read_text()
host = re.search(r'^#define DMSH_CHAIN "([0-9a-f]{12})"$', header, re.MULTILINE)[1]
other = "0" * 12 if host != "0" * 12 else "1" * 12
env = {key: value for key, value in os.environ.items()
       if key not in ("S2A_ALLOW_CHAIN_MISMATCH", "S2A_GAME_DATA", "S2A_IN")}


def fixture(root, directory_chain, index_chain, flags=0):
    library = root / "shaders/direct" / ("b-" + directory_chain)
    library.mkdir(parents=True)
    (library / "lib.idx").write_bytes(struct.pack(
        "<8sIIII12s12x", b"S2ALIB\0\0", 1, 0, 0, flags, index_chain.encode("ascii")))


def run(root, output, override=None, game_data=None):
    actual = env | {"S2A_IN": str(root), "S2A_PY": sys.executable}
    if override is not None:
        actual["S2A_ALLOW_CHAIN_MISMATCH"] = override
    if game_data is not None:
        actual["S2A_GAME_DATA"] = str(game_data)
    return subprocess.run(["bash", str(repo / "runtime/run_mac.sh"), "chain-check", str(output), "1"],
                          env=actual, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix="s2arm-chain-") as temp:
    temp = Path(temp)
    same, different, renamed = (temp / name for name in ("same", "different", "renamed"))
    fixture(same, host, host)
    fixture(different, other, other)
    fixture(renamed, host, other)

    def allowed(root, override=None):
        output = temp / "run"
        result = run(root, output, override)
        assert result.returncode != 0 and "既没有改写产物也没有 exefs/" in result.stdout, result
        assert output.is_dir() and "【红】" not in result.stderr, result
        output.rmdir()
        return result

    allowed(same)
    print("✓ 同链通过正式入口核链，随后因空产物根停止")
    empty = temp / "empty"
    empty.mkdir()
    allowed(empty)
    print("✓ 无 NVN 库目录放行")
    for root in (different, renamed):
        for override in (None, "0", "true", "2"):
            output = temp / "run"
            result = run(root, output, override)
            assert result.returncode != 0 and result.stderr.count("【红】") == 1, result
            assert host in result.stderr and other in result.stderr and not output.exists(), result
        result = allowed(root, "1")
        assert "【黄】" in result.stderr and "显式放行" in result.stderr, result
    print("✓ 异链及改名索引在创建局目录前拒绝，仅值 1 显式放行")
    fixture(same, other, other)
    allowed(same)
    print("✓ 同链与旧链并存时放行")
    output = temp / "run"
    result = run(same, output, game_data=different)
    assert result.returncode != 0 and "【红】" in result.stderr and not output.exists(), result
    print("✓ 正式入口优先检查 S2A_GAME_DATA")
    # lib.idx 头偏移 20 是 flags（位 0 = 全部计算程序为 tensor ABI 1，LibPack.cs 写）：带这一位的同链库照常放行，未定义的位才算头无效
    tensor = temp / "tensor"
    fixture(tensor, host, host, flags=1)
    allowed(tensor)
    print("✓ 同链、flags 位 0（tensor ABI）照常放行")
    unknown = temp / "unknown"
    fixture(unknown, host, host, flags=2)
    output = temp / "run"
    result = run(unknown, output)
    assert result.returncode != 0 and "头无效" in (result.stdout + result.stderr) and not output.exists(), result
    print("✓ flags 出现未定义的位 → 头无效、不起局")
