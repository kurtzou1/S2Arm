#!/usr/bin/env python3
"""审计 P1-173：直连库换进位的三步改名（Windows / 不支持原子互换的外接盘）不丢上一份直连库。
直接调 graphics/tools/direct/direct_lib.py 的 swap（win=True 走三步改名）与起跑清扫 recover，合成目录夹具，期望手写：
① 成功：正式目录是新库、临时目录是旧库、没有 .swapold 残留；
② 第二步失败（临时目录不在）：正式目录仍是旧库、没有 .swapold 残留，抛错；
③ 停在第一步之后（正式目录在 .swapold、正式名不在）：起跑清扫把它改回正式位置，清扫临时目录时不删它（死进程的临时目录照清）；
④ 原子互换（本机 APFS renamex_np / Linux renameat2）：正式是新库、临时目录是旧库"""
import contextlib, io, os, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "graphics/tools/direct"))
import direct_lib  # noqa: E402
bad = 0
def ck(ok, msg):
    global bad
    print(("通 " if ok else "不通 ") + msg); bad += not ok

def run(a, b, win=True):
    try: direct_lib.swap(a, b, win=win); return 0
    except (OSError, direct_lib.SwapError): return 1

def clear(*ps):
    for p in ps:
        if p.exists():
            for f in p.iterdir(): f.unlink()
            p.rmdir()

with tempfile.TemporaryDirectory() as t:
    T = Path(t); out, stage = T / "lib", T / "lib.stage.123"
    out.mkdir(); (out / "lib.idx").write_text("old"); stage.mkdir(); (stage / "lib.idx").write_text("new")
    rc = run(str(stage), str(out))
    ck(rc == 0 and (out / "lib.idx").read_text() == "new" and (stage / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists(), "① 三步改名成功：正式是新库、临时目录是旧库、无残留")
    clear(out, stage)
    out.mkdir(); (out / "lib.idx").write_text("old")
    rc = run(str(stage), str(out))   # 临时目录不在：第二步失败
    ck(rc != 0 and (out / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists(), "② 第二步失败：正式目录还是旧库、改回了正式名")
    os.rename(out, T / "lib.swapold"); (T / "lib.stage.999999").mkdir()
    with contextlib.redirect_stdout(io.StringIO()): direct_lib.recover(str(T / "c"), str(out))
    ck((out / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists() and not (T / "lib.stage.999999").exists(),
       "③ 停在第一步后：起跑改回正式位置、死进程的临时目录照清")
    clear(out); out.mkdir(); (out / "lib.idx").write_text("old"); stage.mkdir(); (stage / "lib.idx").write_text("new")
    if os.name != "nt":
        rc = run(str(stage), str(out), win=False)
        ck(rc == 0 and (out / "lib.idx").read_text() == "new" and (stage / "lib.idx").read_text() == "old", "④ 原子互换：正式是新库、临时目录是旧库")

print(f"直连库换进位单测：{'全通' if not bad else f'{bad} 项不通'}"); sys.exit(1 if bad else 0)
