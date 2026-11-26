# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Mac / iPhone 多程序合集出包：合成 NSO 与假刷新，不依赖游戏、密钥或真机。"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import ROOT, JobCase


def load_helper(path=None):
    path = Path(path or ROOT / "pack/multi_program.py")
    spec = importlib.util.spec_from_file_location("s2arm_multi_program_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MetadataTests(unittest.TestCase):
    def test_programs_of(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "unpack.tsv").write_text("title_id\t0100ABCD00000000\n", encoding="utf-8")
            self.assertEqual(helper.programs_of(root), 1)
            (root / "unpack.tsv").write_text(
                "title_id\t0100ABCD00000000\nprograms\t2\nprogram_index\t0\n", encoding="utf-8"
            )
            self.assertEqual(helper.programs_of(root), 2)


class SyntheticBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="s2a-multi-program-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        for directory in (
            "pack/orch",
            "tools",
            "sources",
            "extract/exefs",
            "extract/ctl",
            "extract/romfs",
        ):
            (self.repo / directory).mkdir(parents=True, exist_ok=True)
        for name in (
            "pack/multi_program.py",
            "pack/roots.sh",
            "pack/seed_root.sh",
            "pack/orch/current.py",
            "tools/clonedir.py",
            "tools/plock.sh",
            "tools/flock_hold.py",
        ):
            shutil.copyfile(ROOT / name, self.repo / name)
        (self.repo / "pack/direct_profile_input.py").write_text(
            "import json, pathlib, sys\np=pathlib.Path(sys.argv[1])\n"
            "rows=dict(line.rstrip('\\n').split('\\t',1) for line in (p/'unpack.tsv').read_text().splitlines() if '\\t' in line)\n"
            "(p/'direct-profile-input.json').write_text(json.dumps({'title_id':rows['title_id']}))\n",
            encoding="utf-8",
        )
        (self.repo / "pack/refresh.sh").write_text(
            '#!/bin/bash\nset -e\nH=$(cd "$(dirname "$0")" && pwd); source "$H/roots.sh"\n'
            'tag=$(root_tag "$1" refresh); w=$(root_begin "$1" "$tag")\n'
            'mkdir -p "$w/shaders/direct"; printf \'keys.tsv\\n\' > "$w/shaders/direct/keys.tsv"\n'
            'cp "$w/exefs/main.npdm" "$w/main.npdm"; cp "$w/exefs/main" "$w/main"\n'
            'printf \'direct\\tfixture\\n\' > "$w/.stage_direct"; root_commit "$1" "$tag"\n',
            encoding="utf-8",
        )
        (self.repo / "pack/refresh.sh").chmod(0o755)
        (self.repo / "pack/seed_root.sh").chmod(0o755)
        self.main_tid = "0100C6F01C4F8000"
        self.game = "t" + self.main_tid.lower()
        self.write_extract(self.repo / "extract", 0)
        (self.repo / "sources/game.nsp").write_bytes(b"synthetic container")
        self.nxu = self.repo / "nxu"
        self.nxu.write_text(
            f"#!{sys.executable}\n"
            "import os, pathlib, sys\n"
            "a=sys.argv[1:]\n"
            "if a[0]=='--npdm-isa': print('aarch64'); raise SystemExit(0)\n"
            "out=pathlib.Path(a[1]); out.mkdir(parents=True, exist_ok=True)\n"
            "i=int(next(x.split('=',1)[1] for x in a if x.startswith('--program-index=')))\n"
            "tid=f'{int(os.environ['FAKE_MAIN_TID'],16)+i:016X}'\n"
            "(out/'exefs').mkdir(exist_ok=True); (out/'ctl').mkdir(exist_ok=True); (out/'romfs').mkdir(exist_ok=True)\n"
            "(out/'exefs/main').write_bytes(f'main-{i}'.encode()); (out/'exefs/main.npdm').write_bytes(f'META-{i}'.encode())\n"
            "(out/'ctl/control.nacp').write_bytes(f'nacp-{i}'.encode()); (out/'romfs/data').write_bytes(f'romfs-{i}'.encode())\n"
            "(out/'unpack.tsv').write_text(f'title_id\\t{tid}\\nprograms\\t2\\nprogram_index\\t{i}\\n')\n"
            "with open(os.environ['FAKE_NXU_LOG'],'a') as f: f.write(str(i)+'\\n')\n",
            encoding="utf-8",
        )
        self.nxu.chmod(0o755)
        self.env = dict(
            os.environ,
            S2A_ROOTS=str(self.root / "roots"),
            S2A_ROOTS_SHARED=str(self.root / "shared"),
            S2A_ROOTS_PRIV=str(self.root / "private"),
            S2A_RUN_ROOT=str(self.root / "run"),
            S2A_SEED_AOC="1",
            S2A_ROMFS_SEAL="0",
            S2A_PY=sys.executable,
            S2A_NX_UNPACK=str(self.nxu),
            S2A_KEYS=str(self.root / "synthetic.keys"),
            FAKE_MAIN_TID=self.main_tid,
            FAKE_NXU_LOG=str(self.root / "nxu.log"),
        )
        (self.root / "synthetic.keys").write_text(
            "header_key = " + "0" * 64 + "\n", encoding="utf-8"
        )
        seeded = subprocess.run(
            [
                "bash",
                str(self.repo / "pack/seed_root.sh"),
                self.game,
                "main",
                str(self.repo / "extract"),
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(seeded.returncode, 0, seeded.stdout + seeded.stderr)
        refreshed = subprocess.run(
            ["bash", str(self.repo / "pack/refresh.sh"), self.game],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(refreshed.returncode, 0, refreshed.stdout + refreshed.stderr)
        self.helper = load_helper()

    @staticmethod
    def write_extract(path, index):
        (path / "exefs").mkdir(parents=True, exist_ok=True)
        (path / "ctl").mkdir(exist_ok=True)
        (path / "romfs").mkdir(exist_ok=True)
        (path / "exefs/main").write_bytes(f"main-{index}".encode())
        (path / "exefs/main.npdm").write_bytes(f"META-{index}".encode())
        (path / "ctl/control.nacp").write_bytes(f"nacp-{index}".encode())
        (path / "romfs/data").write_bytes(f"romfs-{index}".encode())
        tid = f"{int('0100C6F01C4F8000', 16) + index:016X}"
        (path / "unpack.tsv").write_text(
            f"title_id\t{tid}\nprograms\t2\nprogram_index\t{index}\n", encoding="utf-8"
        )

    def current(self):
        return self.helper.current_root(Path(self.env["S2A_ROOTS"]), self.game)

    def build(self):
        return self.helper.build(
            extract=self.repo / "extract",
            work=self.root / "work",
            logs=self.root / "logs",
            product=self.current(),
            game=self.game,
            source_dir=self.repo / "sources",
            platform="macos",
            env=self.env,
            repo=self.repo,
        )

    def test_mac_and_ios_share_the_same_builder_and_execute_program_sees_slot_1(self):
        final = self.build()
        self.assertIsNotNone(final)
        self.assertEqual((self.root / "nxu.log").read_text().splitlines(), ["1"])
        sub = final / "programs/1"
        self.assertEqual((sub / "main.npdm").read_bytes(), b"META-1")
        self.assertIn("title_id\t0100C6F01C4F8001", (sub / "unpack.tsv").read_text())
        self.assertFalse((sub / "romfs").is_symlink())
        self.assertEqual((sub / "romfs/data").read_bytes(), b"romfs-1")

        probe = self.root / "probe.c"
        probe.write_text(
            '#include "s2a_programs.h"\n#include <stdio.h>\nint main(int argc,char **argv){char d[1200];'
            "s2a_programs_init(argv[1]);int select=s2a_host_select_program(1);int take=s2a_programs_take(d,sizeof d);"
            'printf("%d\\n%d\\n%d\\n%s\\n",s2a_host_program_count(),select,take,d);return 0;}\n',
            encoding="utf-8",
        )
        binary = self.root / "probe"
        compiled = subprocess.run(
            [
                "cc",
                "-I",
                str(ROOT / "runtime/src"),
                "-I",
                str(ROOT / "runtime/include"),
                str(probe),
                str(ROOT / "runtime/src/programs.c"),
                "-o",
                str(binary),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        result = subprocess.run(
            [str(binary), str(final)], capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["2", "0", "1", str(sub)])

    def test_without_attach_execute_program_1_is_still_missing(self):
        current = self.current()
        with patch.object(self.helper, "attach_programs", lambda *args, **kwargs: current):
            final = self.build()
        self.assertFalse((final / "programs/1/main.npdm").exists())
        self.assertEqual(
            self.helper.programs_of(final), 2, "unpack.tsv 仍声明两支，但产物没有序号 1"
        )

    def test_single_program_does_not_require_sources_or_change_the_root(self):
        (self.repo / "extract/unpack.tsv").write_text(
            f"title_id\t{self.main_tid}\nbase\t4096\n", encoding="utf-8"
        )
        current = self.current()
        final = self.helper.build(
            extract=self.repo / "extract",
            work=self.root / "single-work",
            logs=self.root / "single-logs",
            product=current,
            game=self.game,
            source_dir=self.root / "missing-sources",
            platform="macos",
            env=self.env,
            repo=self.repo,
        )
        self.assertEqual(final, current)
        self.assertFalse((self.root / "nxu.log").exists())


class BuildWiringTests(JobCase):
    def test_mac_prepare_invokes_shared_builder_with_staged_sources(self):
        import build

        root = self.root / "build-key"
        current = root / "roots" / (self.game_id() + "@v1")
        current.mkdir(parents=True)
        (current / "main.npdm").write_bytes(b"META")
        (root / "roots" / (self.game_id() + "@现行")).write_text(current.name + "\n")
        extraction = self.root / "extract"
        source = self.root / "staged-sources"
        logs = self.root / "logs"
        seen = []

        def run(args, log=None, env=None, **kwargs):
            seen.append(([str(arg) for arg in args], Path(log), env))
            return 0

        self.c.run = run
        result = build.prepare_sub_programs(
            self.c,
            root,
            current,
            extraction,
            source,
            logs,
            dict(S2A_ROOTS=str(root / "roots")),
            self.game_id(),
        )
        self.assertEqual(result, current)
        args, log, env = seen[0]
        self.assertIn(str(ROOT / "pack/multi_program.py"), args)
        self.assertEqual(args[args.index("--source-dir") + 1], str(source))
        self.assertEqual(args[args.index("--platform") + 1], "macos")
        self.assertEqual(log, logs / "sub_programs.log")
        self.assertEqual(env["S2A_ROOTS"], str(root / "roots"))

    @staticmethod
    def game_id():
        return "0100C6F01C4F8000"


if __name__ == "__main__":
    unittest.main()
