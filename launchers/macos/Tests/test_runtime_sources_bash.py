#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""随包 bash 钉版来源（launchers/macos/runtime_sources.py，11-28）。期望按 GNU 发布规则手写，不跑编译：
  ① 补丁正好是 bash52-001 … bash52-<BASH_PATCHLEVEL>，连续、无缺号，每个 sha256 是 64 位十六进制
  ② downloads()（出包机离线 / 冷缓存预取按它取）覆盖 python + SOURCES 全部 + 每个补丁，缓存路径互不相同，都在 CACHE/downloads 下；
     补丁存成原名（不加 .tar.gz），源码包加 .tar.gz
  ③ 编法不碰出包机 Homebrew：bundle_runtime.py 不再调 brew，bash 从钉版工具前缀取
  ④ 运行环境复用指纹（bundle_runtime.runtime_deps_fingerprint）跟着每项输入变：任一下载件 sha256 换了、工具链（SDK / clang）换了 → 指纹不同；
     输入不变 → 指纹相同（11-28：Homebrew 拷来的 bash 不在指纹里，旧件一直被沿用）
真编出来的 bash 最低系统 / 依赖由出包时 build_app 的最低系统检查（runtime_audit.verify_minimum_macos）把关。"""
import pathlib
import re
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runtime_sources  # noqa: E402
from unittest import mock  # noqa: E402


class BashPinnedSource(unittest.TestCase):
    def test_patches_contiguous(self):
        want = [f"bash52-{n:03d}" for n in range(1, runtime_sources.BASH_PATCHLEVEL + 1)]
        self.assertEqual(list(runtime_sources.BASH_PATCHES), want)
        for name, spec in runtime_sources.BASH_PATCHES.items():
            self.assertRegex(spec["sha256"], r"^[0-9a-f]{64}$", name)
            self.assertTrue(spec["url"].endswith("/bash-5.2-patches/" + name), spec["url"])

    def test_downloads_cover_everything(self):
        rows = runtime_sources.downloads()
        self.assertEqual(len(rows), 1 + len(runtime_sources.SOURCES) + runtime_sources.BASH_PATCHLEVEL)
        paths = [p for _, _, p in rows]
        self.assertEqual(len(set(paths)), len(paths))
        for url, sha, path in rows:
            self.assertEqual(path.parent, runtime_sources.CACHE / "downloads")
            self.assertRegex(sha, r"^[0-9a-f]{64}$")
        self.assertIn(runtime_sources.CACHE / "downloads/bash.tar.gz", paths)
        self.assertIn(runtime_sources.CACHE / "downloads/bash52-037", paths)

    def test_bundle_runtime_does_not_copy_homebrew(self):
        text = (HERE.parent / "bundle_runtime.py").read_text(encoding="utf-8")
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        self.assertIsNone(re.search(r"\bbrew\b", code))
        self.assertIn("'zstd', 'bash')}", code)


class FingerprintCoversInputs(unittest.TestCase):
    def setUp(self):
        import bundle_runtime
        self.br = bundle_runtime
        p = mock.patch.object(bundle_runtime, "toolchain_identity", return_value="sdk 27.0; clang A")
        p.start(); self.addCleanup(p.stop)

    def test_same_inputs_same_fingerprint(self):
        self.assertEqual(self.br.runtime_deps_fingerprint(), self.br.runtime_deps_fingerprint())

    def test_patch_sha_changes_fingerprint(self):
        base = self.br.runtime_deps_fingerprint()
        changed = dict(runtime_sources.BASH_PATCHES)
        changed["bash52-037"] = dict(changed["bash52-037"], sha256="0" * 64)
        with mock.patch.object(runtime_sources, "BASH_PATCHES", changed):
            self.assertNotEqual(self.br.runtime_deps_fingerprint(), base)

    def test_toolchain_changes_fingerprint(self):
        base = self.br.runtime_deps_fingerprint()
        with mock.patch.object(self.br, "toolchain_identity", return_value="sdk 28.0; clang B"):
            self.assertNotEqual(self.br.runtime_deps_fingerprint(), base)


if __name__ == "__main__":
    unittest.main()
