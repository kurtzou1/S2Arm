#!/usr/bin/env python3
"""把可合成的系统数据（pack/sysdata_synth.py 的 GEN：0802 Mii、0806 旧版屏蔽词、0823 屏蔽词、0849 Switch 2 Mii）打成一个确定的 tar，
嵌进服务程序集（services/S2A.Services/systemdata_synth.tar）：游戏资源包里缺这几个号时，运行时当场解出来挂上（Host.cs SynthSystemData），
不要求玩家重出资源包（诊断#3d2d3e / #5a5ee9：#886 之前出的包没有 0806，招募改名一确认就 Break）。
用法：make_sysdata_synth_tar.py <输出 tar>。逐字节确定：成员按路径排序、mtime 0、uid / gid 0、模式 0644 / 0755、不带用户名。
单一来源是 sysdata_synth.py；tests/sysdata_synth_tar_test.py 重算比对，防仓库里这份和生成器漂移。"""
import io, os, subprocess, sys, tarfile, tempfile

H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ids():
    sys.path.insert(0, os.path.join(H, "pack"))
    import sysdata_synth
    return sorted(sysdata_synth.GEN)


def build():
    buf = io.BytesIO()
    with tempfile.TemporaryDirectory() as t, tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for i in ids():
            out = os.path.join(t, i)
            subprocess.run([sys.executable, os.path.join(H, "pack", "sysdata_synth.py"), i, out], check=True, capture_output=True)
            entries = []
            for d, dn, fn in os.walk(out):
                dn.sort()
                entries += [os.path.join(d, f) for f in fn]
            for p in sorted(entries, key=lambda p: os.path.relpath(p, t).replace(os.sep, "/")):
                data = open(p, "rb").read()
                ti = tarfile.TarInfo(os.path.relpath(p, t).replace(os.sep, "/"))
                ti.size, ti.mtime, ti.mode, ti.uid, ti.gid, ti.uname, ti.gname = len(data), 0, 0o644, 0, 0, "", ""
                tar.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


if __name__ == "__main__":
    if len(sys.argv) != 2: sys.exit(__doc__)
    open(sys.argv[1], "wb").write(build())
