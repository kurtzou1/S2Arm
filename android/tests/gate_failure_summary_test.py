#!/usr/bin/env python3
"""Failure summaries must identify the failing child, not earlier red controls."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'android/tools/gate_step.sh'


class GateFailureSummaryTest(unittest.TestCase):
    def run_steps(self, failing):
        script = r'''set -euo pipefail
source "$1"
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
s2a_gate_step bash -c 'echo "【红】earlier expected negative control"; exit 0'
s2a_gate_step bash -c "$2"
'''
        return subprocess.run(['bash', '-c', script, 'fixture', str(HELPER), failing],
                              text=True, capture_output=True)

    def test_first_red_of_failing_child_is_final_line_and_rc_is_preserved(self):
        result = self.run_steps('echo "【红】actual failing child" >&2; echo "【红】later detail"; echo "success-looking output"; exit 7')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stderr.splitlines()[-1], '【红】actual failing child')
        self.assertIn('earlier expected negative control', result.stdout)
        self.assertIn('success-looking output', result.stdout)

    def test_unmarked_failure_stays_red_and_includes_child_rc(self):
        result = self.run_steps('echo "compiler failed" >&2; exit 9')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn('rc=9', result.stderr.splitlines()[-1])
        self.assertIn('compiler failed', result.stderr.splitlines()[-1])

    def test_failing_child_overrides_earlier_informational_note(self):
        # 11-07 gate-host：先有一条「仅 Linux 未运行」说明，之后视频工厂合同那一步 rc=75；摘要必须是 rc=75 那一步，不是说明
        script = r'''set -euo pipefail
source "$1"
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
s2a_gate_note "W2 dispatch snapshot / record chain：未运行（仅 Linux 主机 libvulkan.so.1 组件测试）"
s2a_gate_step bash -c 'echo "PASS earlier"; echo "missing repository-pinned .NET SDK" >&2; exit 75'
s2a_gate_note "later informational note"
'''
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 75, result.stderr)
        last = result.stderr.splitlines()[-1]
        self.assertIn('rc=75', last)
        self.assertIn('missing repository-pinned .NET SDK', last)
        self.assertNotIn('W2 dispatch', last)

    def test_note_alone_before_exit_stays_the_summary(self):
        script = r'''source "$1"; s2a_gate_init; trap 's2a_gate_finish $?' EXIT
s2a_gate_note "🔴 门禁找不到 JDK 17 的 javac"; exit 1'''
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.splitlines()[-1], '🔴 门禁找不到 JDK 17 的 javac')

    def test_success_has_no_failure_summary(self):
        script = 'set -euo pipefail; source "$1"; s2a_gate_init; trap \'s2a_gate_finish $?\' EXIT; s2a_gate_step bash -c "echo ok"'
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'ok')
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
