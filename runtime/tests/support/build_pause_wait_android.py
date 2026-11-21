# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""仅用已有 NDK 编译本项目真实线程夹具；不下载、安装、连接或执行设备。"""
import argparse, hashlib, json, os
from pathlib import Path
import runpy, subprocess

ROOT=Path(__file__).resolve().parents[3]
FAULT=Path("android/native/runtime/fault")

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cc",type=Path,required=True,help="已有 NDK clang 的绝对路径")
    ap.add_argument("--out",type=Path,required=True)
    a=ap.parse_args();out=a.out.resolve();cc=a.cc.resolve()
    if not cc.is_file() or not os.access(cc,os.X_OK):ap.error("需要现有可执行 NDK clang")
    if out==ROOT or ROOT in out.parents:ap.error("产物目录必须在检出外")
    out.mkdir(parents=True,exist_ok=True)
    sources=runpy.run_path(str(ROOT/FAULT/"tests/run_thread.py"))["SOURCES"]
    # 本支 f31728606 在 crash_android_fatal.inc:300 的 fatal 行末尾新增弱符号
    # s2a_android_redlog_write 补写 red.log（声明本身是 weak，单独链接允许为 0）；这个
    # 只编译/链接的 Android 夹具原先碰巧不需要 provider——guest_signal.c 的强引用段被
    # --gc-sections 丢掉。与 crash.c 的新弱引用组合后 ld.lld 21 仍按“必须定义”处理并报
    # undefined。生产正式链接本来就把 provider 收在清单里（core-link/LinkSources.cmake:18
    # android/native/redlog.c），所以这里补的是真实实现而不是桩：red.log 落盘
    # 路径保持生产语义，不因夹具改成空实现。
    sources=sources+[Path("android/native/redlog.c")]
    env=dict(os.environ,TMPDIR=str(out),TMP=str(out),TEMP=str(out),
             CLANG_MODULE_CACHE_PATH=str(out/"clang"),PYTHONDONTWRITEBYTECODE="1")
    rows=[];objects=[]
    def run(cmd,name):
        p=subprocess.run(list(map(str,cmd)),env=env,capture_output=True,timeout=90)
        (out/(name+".log")).write_bytes(p.stdout+p.stderr)
        rows.append(dict(command=list(map(str,cmd)),exit=p.returncode))
        if p.returncode:raise RuntimeError(name+": "+(p.stdout+p.stderr).decode()[-2000:])
    for i,src in enumerate(sources):
        obj=out/(str(i)+".o");objects.append(obj)
        flags=["--target=aarch64-none-linux-android34","-I"+str(ROOT/"runtime/include"),
               "-std=gnu11","-O2","-Wall","-Wextra","-Werror","-Wno-unused-parameter",
               "-Wno-unused-function","-Wno-unused-variable","-Wno-missing-field-initializers",
               "-Wno-misleading-indentation","-ffunction-sections","-fdata-sections","-pthread"]
        if str(src) in ["runtime/src/crash.c","runtime/src/xstack.c"]:flags+=["-D_GNU_SOURCE"]
        run([cc,*flags,"-c",ROOT/src,"-o",obj],str(i))
    exe=out/"thread-pause-test"
    run([cc,"--target=aarch64-none-linux-android34","-pthread",*objects,
         "-Wl,--gc-sections","-Wl,-z,max-page-size=16384","-ldl","-llog","-o",exe],"link")
    files=set(sources+[Path("runtime/src/thread.c"),Path("runtime/src/thread_wait_diag.inc"),
                      Path("runtime/src/native.h"),Path("platform/plat.h"),Path("graphics/track/s2a_track.h"),
                      Path("android/native/guest_signal.h")])
    files.update(p.relative_to(ROOT) for p in (ROOT/"runtime/include").glob("*.h"))
    files.update(p.relative_to(ROOT) for p in (ROOT/FAULT).rglob("*") if p.is_file() and p.suffix in [".h",".inc"])
    data=dict(commands=rows,source_sha256={str(p):hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sorted(files)},
              binary=str(exe),sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),bytes=exe.stat().st_size,
              Android_Bionic_executed=False,downloads_or_installs=False,
              boundaries="真实 thread/crash/redlog/xstack/fault、pthread/futex/signal；module/TSD/TLR/track 由夹具提供，未执行游戏或托管服务")
    (out/"build.json").write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n")
    print("PASS compile/link only "+data["sha256"])
if __name__=="__main__":main()
