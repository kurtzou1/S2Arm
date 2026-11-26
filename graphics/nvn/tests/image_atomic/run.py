"""Run the built production-NVN fixture serially with API/shader validation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--assets", required=True, type=Path)
parser.add_argument("--out", required=True, type=Path)
parser.add_argument("--backend", choices=("mtl3", "mtl4", "all"), default="all")
parser.add_argument("--mode", choices=("production", "alias-view-only", "upgrade-only", "native-buffer-only", "unbound-only", "unsupported-only", "stale-only", "all"), default="all")
args = parser.parse_args()
binary, assets = args.binary.resolve(), args.assets.resolve()
if not binary.is_file() or not (assets / "generated.stamp").is_file():
    raise FileNotFoundError("build the real fixture and generated shader assets first")
args.out.mkdir(parents=True, exist_ok=False)
modes = ("production", "alias-view-only", "upgrade-only", "native-buffer-only", "unbound-only", "unsupported-only", "stale-only") if args.mode == "all" else (args.mode,)
backends = ("mtl4", "mtl3") if args.backend == "all" else (args.backend,)
results = []
for backend in backends:
    for mode in modes:
        out = args.out / (backend + "-" + mode)
        out.mkdir()
        env = dict(os.environ, DM_NVN_ENC_THREAD="0", DM_PRESENT_LINK="0", DM_NVN_DISPATCH_OWN="0",
                   S2A_WIDEN_DIRECT="0", MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1")
        if backend == "mtl3":
            env["NXGAL_BE"] = "mtl3"
        else:
            env.pop("NXGAL_BE", None)
        command = [str(binary), str(assets), "--" + mode]
        identity = {"command": command, "environment": {k: env.get(k) for k in (
            "NXGAL_BE", "DM_NVN_ENC_THREAD", "DM_PRESENT_LINK", "DM_NVN_DISPATCH_OWN", "S2A_WIDEN_DIRECT", "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION")},
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "boundary": "Authored GLSL / production APIs; no Maxwell input, game, device portability or performance claim."}
        (out / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
        start = time.monotonic()
        with (out / "raw.log").open("wb") as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=80)
        raw = (out / "raw.log").read_text(encoding="utf-8", errors="replace")
        rejected = mode == "unsupported-only"
        ok = result.returncode == (3 if rejected else 0)
        if rejected:
            ok = ok and "【红】" in raw and "native image atomic binding is unsupported" in raw and "EXPECTED_UNSUPPORTED" in raw
        else:
            ok = ok and "✓ t_nvn_image_atomic:" in raw and "0 failures" in raw
        entry = {"backend": backend, "mode": mode, "exit": result.returncode,
                 "wall_seconds": time.monotonic() - start, "expected_rejection": rejected,
                 "gpu_correctness_accepted": ok and not rejected, "ok": ok}
        (out / "result.json").write_text(json.dumps(entry, indent=2) + "\n")
        results.append(entry)
        verdict = "FAIL" if not ok else "expected rejection, excluded from GPU acceptance" if rejected else "pass"
        print(f"{backend} {mode}: exit={result.returncode}; {verdict}; {out / 'raw.log'}", flush=True)
        if not ok:
            raise SystemExit(1)
(args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print("✓ t_nvn_image_atomic: supported cases passed; unsupported cases explicitly rejected; no gameplay proof")
