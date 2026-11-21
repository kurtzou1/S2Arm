#!/usr/bin/env python3
# 门禁手动：由同目录 run.py 在进程内导入（from publication_revoke import run），run.py 只在 Linux ARM64 上跑、尚无门禁入口，随它定
"""Real writer admission; only host lifecycle/publication inputs use a shared page."""
import ctypes
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess
import sys
import time


def run(binary, root):
    rows = []
    for revoke in (False, True):
        name = "withdraw-before-writer-release" if revoke else "publication-retained-control"
        path = root / (name + ".shared")
        path.write_bytes(bytes(256))
        with path.open("r+b") as file, mmap.mmap(file.fileno(), 256) as page:
            def put(index, value):
                struct.pack_into("Q", page, 8 * index, value)

            def get(index):
                return struct.unpack_from("Q", page, 8 * index)[0]

            for index, value in enumerate([1, 3000, 30000, 1, 0, 0, 0]):
                put(index, value)
            lib = ctypes.CDLL(str(root/'libs2a_backing_test.so'))
            ptr = ctypes.addressof(ctypes.c_char.from_buffer(page))
            lib.test_shared_lifecycle.argtypes=[ctypes.c_void_p,ctypes.c_int]
            lib.test_shared_publish.argtypes=[ctypes.c_void_p,ctypes.c_uint64,ctypes.c_int]
            lib.test_shared_publish.restype=ctypes.c_uint64
            process = subprocess.Popen(
                [str(binary), "external-published"],
                env=dict(os.environ, S2A_BACKING_SHARED=str(path)),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                limit = time.monotonic() + 5
                while not get(5) and process.poll() is None and time.monotonic() < limit:
                    time.sleep(.005)
                if not get(5):
                    raise RuntimeError("actual writer admission did not start")
                lib.test_shared_lifecycle(ptr,0)
                time.sleep(4.2)
                alive_in_background = process.poll() is None
                if revoke:
                    lib.test_shared_publish(ptr,1,0)
                lib.test_shared_lifecycle(ptr,1)
                start = time.monotonic()
                time.sleep(.35)
                premature = process.poll() is not None
                put(6, 1)
                stdout, stderr = process.communicate(timeout=5)
                (root / (name + ".stdout")).write_text(stdout)
                (root / (name + ".stderr")).write_text(stderr)
                rows.append(dict(
                    name=name, alive_in_background=alive_in_background,
                    exited_before_writer_release=premature, exit=process.returncode,
                    after_resume_seconds=time.monotonic() - start, stdout=stdout, stderr=stderr,
                ))
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate()
    (root / "revoke-probe-results.json").write_text(json.dumps(rows, indent=2) + "\n")
    for row in rows:
        assert row["alive_in_background"] and row["exit"] == 0 and not row["exited_before_writer_release"], row
    print("PASS actual-gate retained/withdrawn publication: background 4.2s, resume, writer released after 350ms")


if __name__ == "__main__":
    root = Path(sys.argv[2])
    root.mkdir(parents=True, exist_ok=True)
    run(Path(sys.argv[1]), root)
