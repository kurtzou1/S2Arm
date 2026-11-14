#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Repair existing Mac compute libraries with the production outliner, without repacking a game.

Preparation is read-only for the installed library. --apply publishes one extra shard and
atomically switches lib.idx, retaining its original in --work. --rollback restores that index.
The application and game must be closed for either switch. No saves or caches are removed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zlib

RECORD = struct.Struct("<QBBHIQ")


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Library:
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        self.index = (self.path / "lib.idx").read_bytes()
        if len(self.index) < 48 or self.index[:8] != b"S2ALIB\0\0":
            raise ValueError("Not a direct library container")
        version, self.count, self.shards = struct.unpack_from("<III", self.index, 8)
        self.base = 48 + self.shards * 16
        if version != 1 or not 0 < self.shards <= 256 or len(self.index) != self.base + self.count * RECORD.size:
            raise ValueError("Unsupported library container version, shard count or length")
        self.records = {}
        for i in range(self.count):
            key, kind, shard, reserved, length, offset = RECORD.unpack_from(self.index, self.base + i * RECORD.size)
            if shard >= self.shards or offset + length > struct.unpack_from("<Q", self.index, 48 + shard * 16)[0] or (key, kind) in self.records:
                raise ValueError("Invalid library record")
            self.records[key, kind] = (i, shard, reserved, length, offset)

    def read(self, key, kind):
        _, shard, _, length, offset = self.records[key, kind]
        path = self.path / f"lib.{shard:03}.pak"
        if path.stat().st_size != struct.unpack_from("<Q", self.index, 48 + shard * 16)[0]:
            raise ValueError("Library shard size changed")
        with path.open("rb") as stream:
            stream.seek(offset)
            data = stream.read(length)
        if len(data) != length:
            raise ValueError("Truncated library record")
        return data


def cache_files(path):
    packed = path.read_bytes()
    if packed[:4] != b"DSZ1":
        raise ValueError("Unknown translation cache format")
    data = zlib.decompress(packed[4:])
    if len(data) < 40 or data[:4] != b"DSE1" or hashlib.sha256(data[:-32]).digest() != data[-32:]:
        raise ValueError("Translation cache checksum failed")
    count = struct.unpack_from("<I", data, 4)[0]
    at, files = 8, {}
    for _ in range(count):
        n = struct.unpack_from("<I", data, at)[0]
        at += 4
        name = data[at:at + n].decode("utf-8")
        at += n
        length = struct.unpack_from("<I", data, at)[0]
        at += 4
        if name in files or at + length > len(data) - 32:
            raise ValueError("Invalid translation cache entry")
        files[name] = data[at:at + length]
        at += length
    cache_key = data[at:-32]
    if not cache_key.startswith(b"xl/") or digest(cache_key) != path.stem:
        raise ValueError("Translation cache key identity failed")
    return files


def find_sources(cache, wanted):
    """Read small prefixes first; fully decode only matching compute translations."""
    def probe(path):
        with path.open("rb") as stream:
            head = stream.read(4096)
        if head[:4] != b"DSZ1":
            return None
        prefix = zlib.decompressobj().decompress(head[4:], 8192)
        match = re.search(rb'"key"\s*:\s*"([0-9a-f]{16})_b"', prefix)
        key = int(match[1], 16) if match else None
        if key not in wanted:
            return None
        files = cache_files(path)
        source = files.get("_b.metal")
        if source is None or "s" + digest(source)[:16] + "_" != wanted[key]:
            return None
        return key, source

    seen = set()
    with ThreadPoolExecutor(max_workers=4) as pool:
        paths = iter(cache.glob("*/*.e"))
        while batch := list(islice(paths, 256)):
            for result in pool.map(probe, batch):
                if result is None or result[0] in seen:
                    continue
                seen.add(result[0])
                yield result
    missing = wanted.keys() - seen
    if missing:
        raise ValueError(f"Exact translation source missing for {len(missing)} compute shaders; rebuild the shader library instead")


def closed():
    processes = subprocess.run(["ps", "-axo", "comm="], check=True, text=True, capture_output=True).stdout
    # A loaded host may retain the old index mapping, and the launcher can concurrently publish a package.
    if any(Path(line.strip()).name == "s2arm-host" or re.search(r"/S2Arm\.app/Contents/MacOS/", line) for line in processes.splitlines()):
        raise ValueError("Quit S2Arm and all running games before switching the library index")


def atomic(path, data, create=False):
    fd, name = tempfile.mkstemp(prefix=path.name + ".compute-", dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, path.stat().st_mode & 0o777 if path.exists() else 0o600)
        if create:
            os.link(temp, path)  # Publish a complete new shard without overwriting a concurrent writer.
        else:
            os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def switch(library, work, rollback=False):
    report = json.loads((work / "repair.json").read_text())
    if report["library"] != str(library.path):
        raise ValueError("Repair belongs to a different library")
    index = library.path / "lib.idx"
    current = digest(index.read_bytes())
    before, after = report["before"], report["after"]
    manifest = Path(report["manifest"]) if report.get("manifest") else None
    current_manifest = digest(manifest.read_bytes()) if manifest else None
    target_manifest = report.get("manifest_before" if rollback else "manifest_after")
    if current == (before if rollback else after) and current_manifest == target_manifest:
        print("Already restored" if rollback else "Already applied")
        return
    if current not in (before, after) or manifest and current_manifest not in (report["manifest_before"], report["manifest_after"]):
        raise ValueError("Library changed since preparation; refusing to overwrite it")
    closed()
    index_data = (work / ("original.idx" if rollback else "patched.idx")).read_bytes()
    if digest(index_data) != (before if rollback else after):
        raise ValueError("Prepared index checksum failed")
    manifest_data = (work / ("original-manifest.json" if rollback else "patched-manifest.json")).read_bytes() if manifest else None
    if manifest and digest(manifest_data) != target_manifest:
        raise ValueError("Prepared manifest checksum failed")
    shard = library.path / report["shard"]
    if not rollback:
        source = work / report["shard"]
        data = source.read_bytes()
        if digest(data) != report["shard_sha256"]:
            raise ValueError("Prepared repair checksum failed")
        if shard.exists():
            if digest(shard.read_bytes()) != report["shard_sha256"]:
                raise ValueError("Repair shard name already in use")
        else:
            atomic(shard, data, create=True)
        atomic(index, index_data)
    else:
        atomic(index, index_data)
        # The unused repair shard stays on disk: rollback never deletes game files.
    if manifest and current_manifest != target_manifest:
        atomic(manifest, manifest_data)
    print("Restored original library index" if rollback else "Repair applied; launch the game normally in S2Arm")


def prepare_manifest(manifest, outliner, library, work, report):
    manifest = manifest.resolve(strict=True)
    original = manifest.read_bytes()
    info = json.loads(original)
    relative = library.path.relative_to(manifest.parent)
    old_entry = info["files"][str(relative / "lib.idx")]
    if old_entry != [len(library.index), report["before"]]:
        raise ValueError("Installed manifest does not describe the original library index")
    patched = (work / "patched.idx").read_bytes()
    info["files"][str(relative / "lib.idx")] = [len(patched), report["after"]]
    info["files"][str(relative / report["shard"])] = [(work / report["shard"]).stat().st_size, report["shard_sha256"]]
    info["localComputeRepair"] = {"originalIndexSha256": report["before"], "outlinerSha256": digest(outliner.read_bytes()),
                                "translatorSha256": digest(outliner.with_name("S2A.Dsh.dll").read_bytes()), "replaced": report["compute_replaced"]}
    updated = (json.dumps(info, indent=2, ensure_ascii=False) + "\n").encode()
    (work / "original-manifest.json").write_bytes(original)
    (work / "patched-manifest.json").write_bytes(updated)
    report.update(manifest=str(manifest), manifest_before=digest(original), manifest_after=digest(updated))


def write_replacements(library, work, replacements):
    records = bytearray(library.index[library.base:])
    shard_name = f"lib.{library.shards:03}.pak"
    with (work / shard_name).open("xb") as shard:
        for key, data in sorted(replacements.items()):
            # The runtime has another cache keyed by fn_lib, in addition to the container's slice cache.
            # A single-function replacement must not retain the shared batch identity from its original JSON.
            meta = json.loads(library.read(key, 1))
            meta.pop("fn_lib", None)
            reflection = (json.dumps(meta, ensure_ascii=False) + "\n").encode()
            for kind, payload in ((0, data), (1, reflection)):
                shard.write(b"\0" * (-shard.tell() % 16))  # Same segment alignment as LibPack.PackFiles.
                if shard.tell() + len(payload) > 64 << 20:
                    raise ValueError("Repair exceeds one library shard; rebuild the shader library instead")
                offset = shard.tell()
                shard.write(payload)
                i, _, reserved, _, _ = library.records[key, kind]
                RECORD.pack_into(records, i * RECORD.size, key, kind, library.shards, reserved, len(payload), offset)
        size = shard.tell()
    header = bytearray(library.index[:48])
    struct.pack_into("<I", header, 16, library.shards + 1)
    patched = header + library.index[48:library.base] + struct.pack("<QQ", size, 0) + records
    (work / "original.idx").write_bytes(library.index)
    (work / "patched.idx").write_bytes(patched)
    return {"library": str(library.path), "before": digest(library.index), "after": digest(patched), "shard": shard_name,
            "shard_sha256": digest((work / shard_name).read_bytes()), "compute_replaced": [f"{key:016x}" for key in sorted(replacements)]}


def prepare(options, library, work):
    if (work / "repair.json").exists():
        raise ValueError("Repair already prepared; use --apply/--rollback, or choose a new work directory")
    work.mkdir(parents=True, exist_ok=True)
    if library.shards == 256:
        raise ValueError("Library has no free shard slots; rebuild the shader library instead")
    wanted = {}
    for key, kind in library.records:
        if kind != 1:
            continue
        meta = json.loads(library.read(key, kind))
        if meta.get("stage") != "cs":
            continue
        prefix = meta.get("fn_prefix", "")
        if not re.fullmatch(r"s[0-9a-f]{16}_", prefix) or (key, 0) not in library.records:
            raise ValueError("Compute library has no supported function identity")
        wanted[key] = prefix
    print(f"Checking exact cached source for {len(wanted)} compute shaders", flush=True)
    checker = work / "compute-probe"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal", str(options.probe_source), "-o", str(checker)], check=True, timeout=60)
    replacements = {}
    for key, source in find_sources(options.cache, wanted):
        # Match the production outliner's size floor without launching dotnet for small kernels.
        if source.count(b"\n") < 8192:
            continue
        name = f"{key:016x}"
        with tempfile.TemporaryDirectory(prefix=name + "-", dir=work) as temp:
            folder = Path(temp)
            src, out = folder / "original.metal", folder / "outlined.metal"
            src.write_bytes(source)
            result = subprocess.run([str(options.dotnet), str(options.outliner), "--outline-file", str(src), str(out)], check=True, text=True, capture_output=True, timeout=60)
            if result.stdout.strip() == "outlined 0":
                continue
            if result.stdout.strip() != "outlined 1":
                raise ValueError("Unexpected outliner result")
            # Keep the installed entry identity; other entries in the original shared batch remain untouched.
            text = out.read_text().replace("kernel void main0(", f'kernel void main0 [[host_name("{wanted[key]}main0")]](', 1)
            out.write_text(text)
            air, lib = folder / "outlined.air", folder / "outlined.metallib"
            with (work / (name + "-build.log")).open("w") as log:
                subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-c", "-fmetal-math-mode=relaxed", "-fpreserve-invariance", "-mmacosx-version-min=15.0", str(out), "-o", str(air)], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                subprocess.run(["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(lib)], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            with (work / (name + "-pipeline.log")).open("w") as log:
                subprocess.run([str(checker), str(lib), wanted[key] + "main0"], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            replacements[key] = lib.read_bytes()
        print(f"Validated compute {name}", flush=True)
    if not replacements:
        raise ValueError("No safely outlineable large compute shaders found; installed library unchanged")
    report = write_replacements(library, work, replacements)
    report["compute_checked"] = len(wanted)
    if options.manifest:
        prepare_manifest(options.manifest, options.outliner, library, work, report)
    (work / "repair.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Prepared {len(replacements)} replacements; installed library unchanged. Run with --apply to switch.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True, help="installed b-<chain> directory")
    parser.add_argument("--work", type=Path, required=True, help="private repair output and rollback directory")
    parser.add_argument("--cache", type=Path, help="existing translation store/dshb directory; preparation only")
    parser.add_argument("--dotnet", type=Path, help=".NET 10 runtime; preparation only")
    parser.add_argument("--outliner", type=Path, help="built dsh_batch.dll; preparation only")
    parser.add_argument("--manifest", type=Path, help="Mac image manifest.json; required when the library belongs to a managed image")
    parser.add_argument("--probe-source", type=Path, default=Path(__file__).resolve().parents[2] / "metal/tests/compute_probe.m", help="Metal pipeline probe source; preparation only")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--rollback", action="store_true")
    options = parser.parse_args()
    library, work = Library(options.library), options.work.resolve()
    if work == library.path or library.path in work.parents:
        parser.error("work directory must be outside the installed library")
    if options.apply or options.rollback:
        switch(library, work, options.rollback)
        return
    if any(value is None for value in (options.cache, options.dotnet, options.outliner)):
        parser.error("preparation needs --cache, --dotnet and --outliner")
    image_manifest = library.path.parent.parent.parent / "manifest.json"
    if image_manifest.exists() and options.manifest is None:
        parser.error("managed image detected; provide --manifest so the launcher's integrity checks remain valid")
    prepare(options, library, work)


if __name__ == "__main__":
    main()
