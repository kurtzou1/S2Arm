#!/usr/bin/env python3
# 嵌进服务程序集的合成系统数据（services/S2A.Services/systemdata_synth.tar）与生成器 pack/sysdata_synth.py 不漂移：
#   期望 = 现在重跑 tools/make_sysdata_synth_tar.py 的输出，逐字节相同；成员覆盖生成器登记的全部号（GEN）。改了生成器忘了重出这份 tar → 红，
#   提示命令：python3 tools/make_sysdata_synth_tar.py services/S2A.Services/systemdata_synth.tar
import io, os, sys, tarfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(H, "tools")); sys.path.insert(0, os.path.join(H, "pack"))
import make_sysdata_synth_tar as m
import sysdata_synth
fails = []
committed = open(os.path.join(H, "services", "S2A.Services", "systemdata_synth.tar"), "rb").read()
fresh = m.build()
if committed != fresh:
    fails.append(f"仓库里的 systemdata_synth.tar（{len(committed)} 字节）与生成器重出的（{len(fresh)} 字节）不同：运行 python3 tools/make_sysdata_synth_tar.py services/S2A.Services/systemdata_synth.tar")
ids = sorted({n.split("/")[0] for n in tarfile.open(fileobj=io.BytesIO(committed)).getnames()})
if ids != sorted(sysdata_synth.GEN):
    fails.append(f"tar 里的号 {ids} ≠ 生成器登记的 {sorted(sysdata_synth.GEN)}")
for f in fails: print("不通", f)
print("sysdata_synth_tar：" + ("全通" if not fails else f"{len(fails)} 处不通"))
sys.exit(1 if fails else 0)
