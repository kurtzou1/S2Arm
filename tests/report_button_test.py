#!/usr/bin/env python3
"""顶栏「故障报修」与报错页指引（11-13）：Mac / Windows 两端同一位置一个全局按钮，报错页统一一句指引。只读源码与共享规格，标准库。
期望（按需求手写）：
  ① 共享规格 launcher.items 有 report.button / report.hint，zh-Hans / en 都有；指引里用 {button} 引用按钮名（两份不会写岔），中文写「右上角」、英文写 top right
  ② 指引文字只在一处生成：两端各只有一个函数读 report.hint（Mac BackendText.reportHint、Windows SharedText.ReportHint），别处不手抄、不直接读
  ③ 凡有「上传给开发者」按钮的报错页（Mac CopyReportButton(model:…)、Windows CopyReportButton(…) 调用）同一文件里挂了指引，且个数不少于按钮
  ④ 顶栏：Mac topActions 的最后一个按钮、Windows 顶栏右侧那一排最后加进去的按钮，都是标识 top.report、文字取 report.button 的那个
     （Windows 各页实际渲染的核对在 launchers/windows/launcher/UI.Snapshots/ReportProbe.cs，门禁 launchers/windows/launcher/tests/run.py 跑）"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "launchers/macos/frontend/Sources/NX2Apple"
MAC_ADAPTER = ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter"
WIN = ROOT / "launchers/windows/launcher"


def read(p): return p.read_text(encoding="utf-8")


class ReportButton(unittest.TestCase):
    def test_spec_keys(self):   # ①
        items = {i["id"]: i for i in json.loads(read(ROOT / "launchers/shared/experience.v1.json"))["launcher"]["items"]}
        for k in ("report.button", "report.hint"):
            self.assertIn(k, items)
            self.assertTrue(items[k]["zh-Hans"].strip() and items[k]["en"].strip(), k)
        self.assertIn("{button}", items["report.hint"]["zh-Hans"]); self.assertIn("{button}", items["report.hint"]["en"])
        self.assertIn("右上角", items["report.hint"]["zh-Hans"]); self.assertIn("top right", items["report.hint"]["en"])

    def test_hint_generated_in_one_place(self):   # ②
        files = list(MAC.rglob("*.swift")) + list(MAC_ADAPTER.rglob("*.swift")) + [p for p in WIN.rglob("*.cs") if "/obj/" not in str(p) and "/bin/" not in str(p)]
        readers = sorted(str(p.relative_to(ROOT)) for p in files if re.search(r'(launcherText|Get|T|txt|t)\("report\.hint"', read(p)))
        self.assertEqual(readers, ["launchers/macos/adapter/Sources/S2ArmAppleAdapter/BackendText.swift", "launchers/windows/launcher/Protocol/SharedText.cs"])

    def test_every_upload_page_has_hint(self):   # ③
        checked = 0
        for p in MAC.rglob("*.swift"):
            s = read(p); n = len(re.findall(r"CopyReportButton\(model:", s))
            if n: checked += 1; self.assertGreaterEqual(len(re.findall(r"\bReportHint\(\)", s)), n, p.name)
        for p in (WIN / "App").glob("*.cs"):
            s = read(p); n = len(re.findall(r"(?<!Button )CopyReportButton\(", s))
            if n: checked += 1; self.assertGreaterEqual(len(re.findall(r"\bReportHintText\(\)", s)) - (1 if "private TextBlock ReportHintText()" in s else 0), n, p.name)
        self.assertGreaterEqual(checked, 8)   # Mac 5 个文件 + Windows 4 个文件有上传按钮（射程：少于这个数说明匹配失效）

    def test_top_bar_last_button(self):   # ④
        mac = read(MAC / "LauncherView.swift")
        top = mac[mac.index("private var topActions"):]; top = top[:top.index(".padding(.trailing, 8)")]
        last = top[top.rindex("Button {"):]
        self.assertIn('accessibilityIdentifier("top.report")', last); self.assertIn('"report.button"', last)
        win = read(WIN / "App/EnvironmentWindow.cs")
        bar = win[win.index("var rightBar = new StackPanel"):win.index("Grid.SetColumn(rightBar, 1)")]
        adds = re.findall(r"rightBar\.Children\.Add\((\w+)", bar)
        self.assertEqual(adds[-1], "reportBtn")
        self.assertIn('SetAutomationId(reportBtn, "top.report")', bar); self.assertIn('T("report.button")', bar)


if __name__ == "__main__":
    unittest.main()
