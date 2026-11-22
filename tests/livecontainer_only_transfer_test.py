# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LiveContainerOnlyTransfer(unittest.TestCase):
    def test_no_wifi_dependency_or_receiver_hook(self):
        paths = [
            "launchers/macos/adapter/Package.swift", "shell/Package.swift",
            "shell/Sources/S2ArmShellHost/S2ArmShellHostView.swift",
            "launchers/macos/bundle_engine.py", "pack/stage_inputs/shell.tsv",
        ]
        for path in paths:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                self.assertNotIn("LocalTransfer", source)
                self.assertNotIn("automaticGameTransfer", source)

    def test_wifi_implementation_removed(self):
        self.assertFalse((ROOT / "launchers/shared/LocalTransfer/Package.swift").exists())
        self.assertFalse((ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/LocalGamePush.swift").exists())

    def test_device_overview_keeps_host_detection_without_duplicate_wifi_rows(self):
        source = (ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/S2ArmEngineProvider.swift").read_text()
        self.assertIn('extra["liveContainer"] = true', source)
        for marker in ["localTransferBrowser", "pushLocalGames", 'hasPrefix("lan:")']:
            self.assertFalse(marker in source, "withdrawn Wi-Fi marker remains: " + marker)
        self.assertIn("PhoneOverview(result:", source)

    def test_wifi_export_operation_removed_but_host_export_kept(self):
        source = (ROOT / "pack/jobs/install.py").read_text()
        functions = {node.name for node in ast.parse(source).body if isinstance(node, ast.FunctionDef)}
        self.assertNotIn("transfer_export", functions)
        self.assertNotIn('"transferExport"', (ROOT / "pack/jobs/main.py").read_text())
        self.assertIn("export_s2arm", functions)
        self.assertIn("livecontainer.push", source)

    def test_multiplayer_and_cloud_saves_are_not_removed(self):
        self.assertIn("_s2arm-ldn._tcp", (ROOT / "runtime/build.mk").read_text())
        self.assertNotIn('"_http._tcp"', (ROOT / "runtime/build.mk").read_text())
        self.assertIn("SaveSync", (ROOT / "shell/Package.swift").read_text())
        source = (ROOT / "ios/app.m").read_text()
        self.assertIn("static void img_scan_bg(void)", source)
        self.assertNotIn("s2a_shell_transfer_awake", source)
        self.assertNotIn("s2a_shell_scan_imports", source)


if __name__ == "__main__":
    unittest.main()
