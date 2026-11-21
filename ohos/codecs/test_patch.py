# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic full-patch idempotency and stale/partial source rejection."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('codecs_build', Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class PatchTest(unittest.TestCase):
    def test_complete_patch(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root/'a').write_text('before\n')
            (root/'b').write_text('before\n')
            patch = root/'change.diff'
            patch.write_text(''.join('diff --git a/{0} b/{0}\n--- a/{0}\n+++ b/{0}\n@@ -1 +1 @@\n-before\n+after\n'.format(n) for n in ('a','b')))
            build.ensure_patch(root, patch)
            self.assertEqual((root/'a').read_text(), 'after\n')
            self.assertEqual((root/'b').read_text(), 'after\n')
            build.ensure_patch(root, patch)
            self.assertEqual((root/'a').read_text(), 'after\n')
            (root/'b').write_text('before\n')
            with self.assertRaises(RuntimeError): build.ensure_patch(root, patch)
            (root/'a').write_text('unrelated\n')
            with self.assertRaises(RuntimeError): build.ensure_patch(root, patch)

if __name__ == '__main__': unittest.main()
