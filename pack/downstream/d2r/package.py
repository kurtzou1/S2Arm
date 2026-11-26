# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Assemble an opt-in D2R-Mobile iPad IPA from local development inputs."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import tempfile
import zipfile

from build import FRAMEWORK, ROOT, build, run, shader_chain, source_tree

TITLE_ID = "0100726014352000"
D2R_APP = ("Payload", "DmIOS.app")
ASSET_DIRECTORIES = {"dm", "msl", "romfs_overlay", "romfs_overlay_variants", "hud_v4_ui", "mapgoal"}


def copy_assets(ipa, app):
    with zipfile.ZipFile(ipa) as archive:
        for entry in archive.infolist():
            path = PurePosixPath(entry.filename)
            rel = path.parts[2:]
            if path.parts[:2] != D2R_APP or not rel or entry.is_dir() or "_CodeSignature" in rel:
                continue
            if (
                rel[0] not in ASSET_DIRECTORIES
                and rel[:2] != ("Frameworks", "Guest.framework")
                and not (len(rel) == 1 and (
                    rel[0].startswith("dm_") and rel[0].endswith(".png")
                    or rel[0] == "native_art_manifest.json"
                ))
            ):
                continue
            mode = entry.external_attr >> 16
            if ".." in rel or stat.S_ISLNK(mode):
                raise ValueError(f"Invalid member of D2R-Mobile IPA: {entry.filename}")
            target = app.joinpath(*rel)
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open("xb") as dest:
                shutil.copyfileobj(source, dest)
            target.chmod(0o755 if mode & 0o111 or rel[-1] == "Guest" else 0o644)


def verify_assets(app, chain):
    for member in (app / "dm/shell_manifest.txt").read_text().splitlines():
        if not member:
            continue
        path = PurePosixPath(member)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"Invalid manifest entry: {member}")
        entry = app / path
        if not (entry.is_dir() if member.endswith("/") else entry.is_file()):
            raise ValueError(f"Missing D2R-Mobile manifest entry: {member}")
    header = (app / "dm/c1_full.tsv").read_text().splitlines()[0].split()
    if header[:3] != ["#", "chain", f"b-{chain}"]:
        raise ValueError("The shader index does not match the D2R-Mobile shell")
    keys = {
        row.split("\t")[3] for row in (app / "dm/shader_map.tsv").read_text().splitlines()
        if re.match(r"^[^#\t]+\t\d+\t", row)
    }
    if not keys:
        raise ValueError("D2R-Mobile shader map is empty")
    library = app / "msl" / f"b-{chain}"
    for key in sorted(keys):
        if not re.fullmatch(r"[0-9a-f]{16}", key):
            raise ValueError(f"Invalid shader key: {key}")
        reflection = json.loads((library / f"{key}_b.json").read_text())
        with (library / f"{key}_b.metallib").open("rb") as binary:
            if reflection.get("chain") != chain or binary.read(4) != b"MTLB":
                raise ValueError(f"D2R-Mobile shader {key} is inconsistent with {chain}")


def configure(app):
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(S2AD2RTitleID=TITLE_ID, MinimumOSVersion="26.0",
                UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
    info_path.write_bytes(plistlib.dumps(info))
    catalogue = app / "s2a_catalogue.json"
    data = json.loads(catalogue.read_text()) if catalogue.is_file() else {"schema": 1, "games": []}
    game = next((entry for entry in data["games"] if entry.get("title_id") == TITLE_ID), None)
    if game is None:
        game = {"title_id": TITLE_ID, "name": "Diablo II: Resurrected"}
        data["games"].append(game)
    game.update(display_version="1.0.34.0", state="playable")
    catalogue.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def package(args):
    if args.output.exists():
        raise FileExistsError(args.output)
    if not (args.app / "S2Arm").is_file() or b"S2AD2RTitleID\0" not in (args.app / "S2Arm").read_bytes():
        raise ValueError("Build the iOS S2Arm app from this branch first")
    if (args.app / "embedded.mobileprovision").exists():
        raise ValueError("Use the local development app before provisioning")
    chain = shader_chain(args.d2r_ipa)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="s2arm-d2r-") as name:
        work = Path(name)
        dm = source_tree(args.d2r_source, work)
        framework = build(dm, args.romfs, work, chain)
        payload = work / "Payload"
        app = payload / "S2Arm.app"
        shutil.copytree(args.app, app, symlinks=True)
        copy_assets(args.d2r_ipa, app)
        shutil.copytree(framework, app / "Frameworks" / FRAMEWORK)
        verify_assets(app, chain)
        configure(app)
        for library in sorted((app / "Frameworks").glob("*.framework")):
            run(["codesign", "--force", "--sign", "-", str(library)])
        run(["codesign", "--force", "--sign", "-", "--entitlements", str(ROOT / "pack/app.entitlements"), str(app)])
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        # Build the archive next to its destination and publish without replacing an existing IPA.
        with tempfile.TemporaryDirectory(prefix=".s2arm-d2r-", dir=args.output.parent) as name:
            ipa = Path(name) / "S2Arm.ipa"
            run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(ipa)])
            os.link(ipa, args.output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="S2Arm.app built from this branch")
    parser.add_argument("--d2r-source", type=Path, required=True, help="Git checkout of d2r-mobile v2.3.5")
    parser.add_argument("--d2r-ipa", type=Path, required=True, help="locally generated D2R-Mobile iOS IPA")
    parser.add_argument("--romfs", type=Path, required=True, help="RomFS used to generate that IPA")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for key, value in vars(args).items():
        setattr(args, key, value.resolve())
    package(args)


if __name__ == "__main__":
    main()
