# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""玩家句里指代「这一台」设备的写法不写死 iPhone（#1962）：已经知道接的是 iPad，提示还说「这台 iPhone」「在 iPhone 上」。
这类句子用 {0} 占位、按实际设备类型填（install.device_kind / 装机结果 deviceKind，认不出填「iPhone / iPad」），见 install.S_OFFLINE。

扫两处玩家句：
  ① pack/jobs 的 install.py / errors.py / devcert.py 里的字符串字面量与 f-string（不含 docstring、日志调用参数、行尾带「# 非玩家句」的行）；
     c.begin 的阶段名照扫：导出页设备行把它原样显示给玩家（#1962 复测：PROGRAM_WAIT「等 iPhone 上的 S2Arm…」原先因跳过 begin 扫不到）；
  ② 共享文案表 launchers/shared/experience.v1.json 的 launcher.items 与 errors.items（title / detail）的简中原文。
命中 DEVICE（这台 iPhone / 在 iPhone 上 / iPhone 上的 / 确认 iPhone 连着 / 交给 iPhone / 传到 iPhone / 已推到·已装到 iPhone）就报红，点名文件与原句。
不算：
  - GENERIC 里的通用叫法（按钮 / 操作名，如「推到 iPhone」「iPhone 总控台」「更新 iPhone 上的 S2Arm」）：先从原句里去掉再查，定名归维护者；
  - KNOWN 里的存量（本次没改的句子，见各条说明）：只许变少；已经改掉的条目留在表里只是不再命中，不报红（别的支删句子不该打红你）。
反证：把 install.PHONE_APP_CHOICE 改回「这台 iPhone 上装着不止一个 S2Arm…」→ ① 红；把共享表 errors.usb_slow 的 detail 改回「这台 iPhone 按 USB 2.0…」→ ② 红。
  （改动前在 main 上跑：① ② 共 40 句命中。）"""
import ast
import json
import re
import sys
import unittest
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))   # 门禁按单文件跑（unittest discover -p 本文件），不靠别的测试先把 pack/jobs 加进路径
ROOT = JOBS.parents[1]
FILES = ("install.py", "errors.py", "devcert.py")
SHARED = ROOT / "launchers/shared/experience.v1.json"
MARK = "# 非玩家句"
LOG = re.compile(r"(log|print|debug|warn|trace|note)$", re.I)

DEVICE = re.compile(r"这台 ?iPhone|在 ?iPhone ?上|iPhone ?上的|确认 ?iPhone|交给 ?iPhone|传到 ?iPhone|已(?:推|装)到 ?iPhone")
# 通用叫法（第 2 类：按钮 / 操作名 / 产物名），不指代某一台；改不改、改成什么由维护者定名。
#   前面带「已」的（「已推到 iPhone」「已装到 iPhone」）是装完的状态，说的是装过的那一台，不按通用叫法去掉（#1962 复测：游戏库状态）
GENERIC = ("更新 iPhone 上的 S2Arm", "iPhone 总控台", "推到 iPhone", "装到 iPhone", "iPhone 包", "iPhone 版")
# 存量：(文件或共享表位置, 原句开头)。本次（#1962 第 1 类）没改的，各条写明为什么留着
KNOWN = {
    # 共享表里的通用说明（第 2 类：讲这类设备怎么用，不是在说连着的那一台）
    ("launcher:console.status.introduce", "在 iPhone 上玩"),
    ("launcher:console.intro.body", "S2Arm App 在 iPhone 上只装一次"),
    ("launcher:install.mode.export_note", "每款导出 .s2arm 和 .img 到「S2Arm 游戏包」"),
    ("launcher:export.after.export_note", "导出到「S2Arm 游戏包」文件夹，在 iPhone 上用 S2Arm 导入"),
    ("launcher:install.done.open", "已传到 iPhone，打开 S2Arm 会自动完成安装"),   # #1962 清单以外，两端调用不带设备参数，后续项
    ("launcher:update.done", "已更新 iPhone 上的 S2Arm"),   # #1962 复测清单以外：两端调用不带设备参数，后续项（守卫不再把「已更新…」当按钮名去掉后扫出）
    # 作业层：#1962 清单以外、还写着 iPhone 的句子（后续项，见 #1962 讨论）
    ("install.py", "这台 iPhone 在描述文件的设备列表里"),             # 证书清单项标题
    ("devcert.py", "连着的这台 iPhone 不在描述文件的设备列表里"),     # 证书体检提醒
    ("errors.py", "先试这两步：①在 iPhone 上打开一次 S2Arm"),        # ios_install_dir_unwritable
    ("errors.py", "之前已经装到 iPhone 上的这款可以照常接着玩"),      # rewrite_gap
    ("errors.py", "手机上已经有一个用别的签名装的 S2Arm"),            # app_other_signer
    ("errors.py", "免费 Apple ID 有苹果的限制"),                     # free_app_limit_note
    ("errors.py", "新装的独立 App 用的是从旧 App 复制来的存档"),      # save_carried
    ("errors.py", "装好的包能用；要在 iPhone Duo 等新机型上铺满全屏"),  # shell_sdk_old
}


def _strip(text):
    for g in GENERIC:
        text = re.sub("(?<!已)" + re.escape(g), "", text)
    return text


def _known(where, text):
    return any(where == w and text.startswith(p) for w, p in KNOWN)


def job_sentences(path):
    """(行号, 原句)：f-string 的表达式段换成 {}"""
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    tree = ast.parse(source)
    parent = {c: n for n in ast.walk(tree) for c in ast.iter_child_nodes(n)}
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if isinstance(parent.get(node), ast.JoinedStr):
                continue
            text = node.value
        elif isinstance(node, ast.JoinedStr):
            text = "".join(v.value if isinstance(v, ast.Constant) else "{}" for v in node.values)
        else:
            continue
        up = parent.get(node)
        if isinstance(up, ast.Expr):
            continue   # docstring / 裸字符串
        if isinstance(up, ast.Call) and LOG.search(ast.unparse(up.func).split(".")[-1]):
            continue   # 日志 / 阶段名（c.begin：操作名，第 2 类）
        if any(MARK in line for line in lines[node.lineno - 1:(node.end_lineno or node.lineno)]):
            continue
        yield node.lineno, text


def shared_sentences(spec):
    """(位置, 简中原文)"""
    for item in (spec.get("launcher") or {}).get("items") or []:
        if isinstance(item.get("zh-Hans"), str):
            yield "launcher:" + item["id"], item["zh-Hans"]
    for item in (spec.get("errors") or {}).get("items") or []:
        for part in ("title", "detail"):
            text = (item.get(part) or {}).get("zh-Hans")
            if isinstance(text, str):
                yield f"errors:{item['code']}.{part}", text


def offenders():
    bad = []
    for name in FILES:
        for line, text in job_sentences(JOBS / name):
            if DEVICE.search(_strip(text)) and not _known(name, text):
                bad.append(f"{name}:{line}: {text[:80]}")
    for where, text in shared_sentences(json.loads(SHARED.read_text(encoding="utf-8"))):
        if DEVICE.search(_strip(text)) and not _known(where, text):
            bad.append(f"experience.v1.json {where}: {text[:80]}")
    return bad


class DeviceKindCopy(unittest.TestCase):
    def test_no_hardcoded_iphone_for_this_device(self):
        bad = offenders()
        self.assertEqual(bad, [], "这些玩家句指代的是连着的那一台，写死了 iPhone：改成 {0} 占位、按设备类型填（install.device_kind / deviceKind，"
                                  "认不出填「iPhone / iPad」）；确实是通用叫法的加进 GENERIC：\n" + "\n".join(bad))

    def test_scan_reaches(self):
        """射程：三个文件都扫到了玩家句、共享表两类条目都扫到了（文件挪走 / 表结构变了不会悄悄全绿）"""
        for name in FILES:
            self.assertGreater(sum(1 for _ in job_sentences(JOBS / name)), 20, name)
        where = [w for w, _ in shared_sentences(json.loads(SHARED.read_text(encoding="utf-8")))]
        self.assertGreater(sum(w.startswith("launcher:") for w in where), 500)
        self.assertGreater(sum(w.startswith("errors:") for w in where), 100)

    def test_catches_known_shapes(self):
        """规则本身：指代写法命中，通用叫法不命中（期望手写）"""
        for s in ("这台 iPhone 上装着不止一个 S2Arm", "先在 iPhone 上退出 S2Arm", "没能交给 iPhone 上的 S2Arm", "确认 iPhone 连着、已解锁",
                  "资源包已传到 iPhone，但手机上解开失败", "已推到 iPhone · 还有 {0} 天", "已推到 iPhone", "已装到 iPhone"):
            self.assertTrue(DEVICE.search(_strip(s)), s)
        for s in ("在 {0} 上点「信任」", "先点游戏库最前面的「S2Arm」选好用哪一个", "点「更新 iPhone 上的 S2Arm」", "先点「打 iPhone 包」", "推到 iPhone"):
            self.assertFalse(DEVICE.search(_strip(s)), s)

    def test_no_invisible_console_name(self):
        """#1966：「总控台」是内部叫法，界面上没有这个名字（Mac 是游戏库首位「S2Arm」卡、Windows 是首行「S2Arm」）。
        玩家句（含独立 App 文件夹 README，那几行带「# 非玩家句」也照样扫）指路时要写界面上看得到的「游戏库最前面的「S2Arm」」。
        反证：把 install.PHONE_APP_GONE 改回「…在总控台重新选一次」→ 红。"""
        bad = [f"{name}:{line}: {text[:60]}" for name in FILES for line, text in job_sentences(JOBS / name) if "总控台" in text]
        tree = ast.parse((JOBS / "app_folder.py").read_text(encoding="utf-8"))
        bad += [f"app_folder.py:{n.lineno}: {n.value[:60]}" for n in ast.walk(tree)
                if isinstance(n, ast.Constant) and isinstance(n.value, str) and "总控台" in n.value]
        bad += [f"experience.v1.json {w}" for w, t in shared_sentences(json.loads(SHARED.read_text(encoding="utf-8"))) if "总控台" in t]
        self.assertEqual(bad, [], "玩家句写了界面上不存在的「总控台」，改成「游戏库最前面的「S2Arm」」：\n" + "\n".join(bad))

    def test_fill_device_kind(self):
        """填法（期望手写）：认出的类型照填；认不出 / 上下文没记 / 记的不是字符串（测试替身）→「iPhone / iPad」；下一步按码取时同样填"""
        import types
        from unittest import mock
        import errors
        self.assertEqual(errors.on_device("这台 {0} 上", "iPad"), "这台 iPad 上")
        self.assertEqual(errors.on_device("这台 {0} 上", ""), "这台 iPhone / iPad 上")
        self.assertEqual(errors.device_of(types.SimpleNamespace(device_kind="iPad")), "iPad")
        self.assertEqual(errors.device_of(types.SimpleNamespace()), "")
        self.assertEqual(errors.device_of(mock.Mock()), "")
        self.assertEqual(errors.recovery("phone_app_gone", packaged=True, windows=False, device="iPad"),
                         "点游戏库最前面的「S2Arm」，重新选一次用哪一个 S2Arm：选过的那个已经不在这台 iPad 上了。")
        self.assertNotIn("{0}", errors.recovery("usb_slow", packaged=True, windows=False))


if __name__ == "__main__":
    unittest.main()
