# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original Markdown and shell fixtures with independently specified values."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('docs_consistency', ROOT / 'tools/docs_consistency.py')
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

TRAIN = '''FA=(${FA[@]+"${FA[@]:0:${TRAIN_BATCH_MAX:-7}}"})
M=${TRAIN_FULL_MAX:-9}
seqchk() {
  if [ -n "$s" ] && [ $# -gt "${TRAIN_BISECT_MIN:-3}" ]; then
    if [ "$d" -lt "${TRAIN_PAR_DEPTH:-4}" ]; then
      ( export S2A_TRAIN_PD=$((d + 1)); halfland "$s" ) & pa=$!
      ( export S2A_TRAIN_PD=$((d + 1)); halfland "$s" ) & pb=$!
      wait $pa $pb; return 0; fi
  fi
  for e in "$@"; do land "$e"; done
}
halfland() { land "$@"; }
'''
CONTRIB = 'exit 0\nexit 1\nexit 2\nEXIT=75\nexit 130\n'
# Handwritten expectation: fixture defaults deliberately differ from real main.
BLOCK = '''<!-- S2ARM_POLICY:BEGIN -->
以下内容由 `python3 tools/docs_consistency.py --render` 从实际脚本生成；修改后用同一工具核对。
- 批上限：快档 `TRAIN_BATCH_MAX` 缺省 7 支；full 档 `TRAIN_FULL_MAX` 缺省 9 支。
- 红批归责：先按红行/红步定位并隔离相关支；无关支只继承输入未变的检查结论。相关支多于 `TRAIN_BISECT_MIN`（缺省 3）时，实际 `seqchk` 会对半分批，只核红步及两半共路由的步骤；并行深度低于 `TRAIN_PAR_DEPTH`（缺省 4）时两半同时跑，到上限后先后跑；不满足分批条件时逐支核。路由不明则跑整份门禁。
- 自检退出码：`0` 第一层本机已证通过（待宿主/第二层仍单列）；`1` 有红；`2` 不完整或参数/基线错误；`75` 环境未就绪；`130` 被中断。
<!-- S2ARM_POLICY:END -->'''


class PolicyTests(unittest.TestCase):
    def test_handwritten_values_and_split_semantics(self):
        self.assertEqual(lint.policy_block(TRAIN, CONTRIB), BLOCK)

    def test_changed_numeric_default_changes_document(self):
        self.assertIn('缺省 11 支', lint.policy_block(TRAIN.replace('TRAIN_BATCH_MAX:-7', 'TRAIN_BATCH_MAX:-11'), CONTRIB))

    def test_conflicting_default_is_not_guessed(self):
        for value in ['12', '0', '$OTHER']:
            with self.subTest(value=value), self.assertRaises(lint.PolicyError):
                lint.policy_block(TRAIN + '\necho ${TRAIN_FULL_MAX:-' + value + '}\n', CONTRIB)

    def test_missing_or_dynamic_default_is_not_guessed(self):
        for old, new in [('TRAIN_BATCH_MAX:-7', 'TRAIN_BATCH_MAX:-0'),
                         ('TRAIN_FULL_MAX:-9', 'TRAIN_FULL_MAX:-$OTHER')]:
            with self.subTest(new=new), self.assertRaises(lint.PolicyError):
                lint.policy_block(TRAIN.replace(old, new), CONTRIB)

    def test_full_line_comment_does_not_override_source(self):
        self.assertEqual(lint.policy_block('# ${TRAIN_BATCH_MAX:-99}\n' + TRAIN, CONTRIB), BLOCK)

    def test_changed_split_condition_requires_review(self):
        with self.assertRaises(lint.PolicyError):
            lint.policy_block(TRAIN.replace('$# -gt', '$# -le'), CONTRIB)

    def test_changed_parallel_boundary_requires_review(self):
        with self.assertRaises(lint.PolicyError):
            lint.policy_block(TRAIN.replace('"$d" -lt', '"$d" -gt'), CONTRIB)

    def test_new_exit_code_requires_description(self):
        with self.assertRaises(lint.PolicyError):
            lint.policy_block(TRAIN, CONTRIB + 'exit 42\n')


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        # 假仓库自带 tools/train.sh：清掉 S2A_PRIVATE_TOOLS，否则被测工具优先读维护方真实列车脚本、与夹具对不上（11-09 门禁环境下 2 例红）
        saved = os.environ.pop('S2A_PRIVATE_TOOLS', None)
        if saved is not None: self.addCleanup(os.environ.__setitem__, 'S2A_PRIVATE_TOOLS', saved)
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm-docs-')
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        for name, value in {'tools/train.sh': TRAIN, 'tools/contrib_check.sh': CONTRIB,
                            'CONTRIBUTING.md': '# 贡献\n' + BLOCK + '\n'}.items():
            self.write(name, value)

    def write(self, name, value):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding='utf-8')

    def test_original_repository_passes(self):
        self.assertEqual(lint.check(self.repo), [])

    def test_stale_document_has_one_diagnostic(self):
        self.write('CONTRIBUTING.md', BLOCK.replace('缺省 7 支', '缺省 8 支'))
        self.assertEqual(len(lint.check(self.repo)), 1)
        self.assertIn('文档规则与脚本不一致', lint.check(self.repo)[0])

    def test_missing_and_multiple_markers_are_rejected(self):
        for value in ['普通文档', BLOCK + '\n' + BLOCK]:
            with self.subTest(value=value[:10]):
                self.write('CONTRIBUTING.md', value)
                self.assertIn('缺少唯一', lint.check(self.repo)[0])

    def test_reversed_marker_is_rejected(self):
        self.write('CONTRIBUTING.md', lint.END + '\n' + lint.BEGIN)
        self.assertIn('边界倒置', lint.check(self.repo)[0])

    def test_check_is_read_only(self):
        def hashes():
            return {p.relative_to(self.repo).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in self.repo.rglob('*') if p.is_file()}
        before = hashes()
        lint.check(self.repo)
        self.assertEqual(hashes(), before)

    def test_cli_non_utf8_mode_is_explicit_utf8_and_red(self):
        self.write('CONTRIBUTING.md', BLOCK.replace('缺省 7 支', '缺省 8 支'))
        result = subprocess.run([sys.executable, '-X', 'utf8=0', '-I', '-B',
                                 str(ROOT / 'tools/docs_consistency.py'), '--repo', str(self.repo)],
                                capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 1)
        self.assertIn('文档规则与脚本不一致', result.stdout)

    def test_missing_source_is_incomplete_not_green(self):
        (self.repo / 'tools/train.sh').unlink()
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'tools/docs_consistency.py'),
                                 '--repo', str(self.repo)], capture_output=True, encoding='utf-8',
                                env={**os.environ, 'S2A_PRIVATE_TOOLS': str(self.repo / 'tools')})
        self.assertEqual(result.returncode, 2)
        self.assertIn('未完成', result.stderr)

    def test_public_checkout_without_train_checks_markers_only(self):
        (self.repo / 'tools/train.sh').unlink()
        with mock.patch.dict(os.environ):
            os.environ.pop('S2A_PRIVATE_TOOLS', None)
            self.write('CONTRIBUTING.md', BLOCK.replace('缺省 7 支', '缺省 8 支'))
            self.assertEqual(lint.check(self.repo), [])
            self.write('CONTRIBUTING.md', '普通文档')
            self.assertIn('缺少唯一', lint.check(self.repo)[0])

    def test_import_does_not_replace_output_streams(self):
        out, err = sys.stdout, sys.stderr
        isolated_spec = importlib.util.spec_from_file_location('docs_import_probe', ROOT / 'tools/docs_consistency.py')
        isolated_spec.loader.exec_module(importlib.util.module_from_spec(isolated_spec))
        self.assertIs(sys.stdout, out)
        self.assertIs(sys.stderr, err)


if __name__ == '__main__':
    unittest.main(verbosity=2)
