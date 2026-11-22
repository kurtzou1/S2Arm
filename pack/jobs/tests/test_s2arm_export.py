# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳两件套导出的小游戏包 .s2arm（pack/jobs/install.py export_s2arm，《文件与程序管理体系》B 项、⑦ ①）。
游戏库、资源包目录是真的（library.setup + jobcase.ios_fixture），程序包出包与改写核对用替身；导出的 .s2arm 解开逐项核，期望按夹具手写。"""
import hashlib
import io
import json
import os
import sys
import tarfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import programs  # noqa: E402
import rewrite_refresh  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from tests.jobcase import ios_fixture  # noqa: E402

DYLIB = b"\xcf\xfa\xed\xfe unsigned dylib bytes"


class S2armExport(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown
    A, B = "0100000000010000", "0100000000020000"

    def fixture(self, names=None):
        names = names or {self.A: "测试游戏", self.B: "别的游戏"}
        self.c.catalog = lambda: {"games": [{"id": g, "name": n} for g, n in names.items()]}
        ios_fixture(self.c, self.A, compat=dict(rewriterId="RID", hostAbi=1, dmshChain="chain1"))
        self.pack = layout.image_ios(self.c, self.A) / ".pack"
        (self.pack / "game.img").write_bytes(b"BIG" * 1000)
        (self.pack / "shaders").mkdir(); (self.pack / "shaders/lib.bin").write_bytes(b"shader")
        pkg = Path(self.root) / "pkg"
        (pkg / "Games" / self.A).mkdir(parents=True)
        (pkg / program_pack.image_name(self.A)).write_bytes(DYLIB)
        (pkg / "Games" / self.A / "main.npdm").write_bytes(b"META")
        (pkg / program_pack.META).write_text(json.dumps(dict(name="测试游戏", display_version="1.0", host_abi=1, chain="chain1", rewriter_id="RID")))
        (pkg / program_pack.KEY).write_text("k")
        self.pkg = pkg

    def export(self, on=True):
        self.c.r.update(gameId=self.A, mode="export")
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), patch.object(install, "export_sign_mode", lambda c: "external"):
            return install.export_s2arm(self.c, self.A)

    def members(self, path):
        raw = programs._decompress(Path(path).read_bytes())
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as t:
            ms = t.getmembers()
            assert all(m.type == tarfile.REGTYPE for m in ms), "只有普通文件条目"
            assert not any(m.pax_headers for m in ms), "不用 pax 头"
            return [m.name for m in ms], {m.name: t.extractfile(m).read() for m in ms}, t

    def test_s2arm_contents(self):
        self.fixture()
        r = self.export()
        out = Path(self.c.library) / "S2Arm 游戏包" / "测试游戏.s2arm"
        raw = out.read_bytes()
        self.assertEqual(raw[:4], b"\x28\xb5\x2f\xfd", "zstd 帧")
        self.assertTrue(raw[4] & 0x04, "zstd 帧头带内容校验标记（Content_Checksum_flag）")
        self.assertEqual(r["s2armPath"], str(out))
        names, data, t = self.members(out)
        self.assertEqual(names[0], "s2arm.json", "第一个条目是清单（手机读到它就能先显示）")
        head = json.loads(data["s2arm.json"])
        want_sha = hashlib.sha256(DYLIB).hexdigest()
        rest = sum(len(v) for k, v in data.items() if k != "s2arm.json")
        self.assertEqual(head, dict(format="s2arm", schema=1, title_id=self.A, name="测试游戏", display_version="1.0", host_abi=1, chain="chain1",
                                    rewriter_id="RID", image=program_pack.image_name(self.A), image_sha256=want_sha, source_sha256=want_sha,
                                    pack="cafe01", bytes=rest, signer=None))
        self.assertEqual(set(names), {"s2arm.json", "program/catalogue.json", f"program/{program_pack.image_name(self.A)}",
                                      f"program/Games/{self.A}/main.npdm", "pack/index.tsv", "pack/manifest.json", "pack/romfs/a", "pack/shaders/lib.bin"})
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], DYLIB)
        self.assertNotIn("pack/game.img", names, "资源本体不进 .s2arm")
        self.assertEqual(json.loads(data["program/catalogue.json"])["team"], None, "程序未签名，留给手机签")
        link = out.with_suffix(".img")
        self.assertEqual((r["resourcePath"], r["resourceLinked"]), (str(link), True), "资源本体硬链接进游戏包文件夹，和 .s2arm 放一起")
        self.assertTrue(os.path.samefile(link, self.pack / "game.img"), "同一个文件（不占新空间）")
        self.assertEqual(os.stat(self.pack / "game.img").st_nlink, 2)

    def test_resource_link_refresh_and_fallback(self):
        # 同名的是上次链的旧 game.img（后来换过）→ 换成现在这份；建不了硬链接（exFAT：os.link 报 EPERM / ENOTSUP）→ 给原位置、文件夹里不留东西
        self.fixture()
        link = Path(self.c.library) / "S2Arm 游戏包" / "测试游戏.img"
        link.parent.mkdir(parents=True); link.write_bytes(b"old")
        r = self.export()
        self.assertTrue(os.path.samefile(link, self.pack / "game.img")); self.assertTrue(r["resourceLinked"])
        link.unlink()
        def no_link(a, b):
            raise OSError(1, "Operation not permitted")
        with patch.object(install.os, "link", no_link):
            r = self.export()
        self.assertEqual((r["resourcePath"], r["resourceLinked"]), (str(self.pack / "game.img"), False))
        self.assertFalse(link.exists())
        self.assertEqual([p.name for p in link.parent.iterdir() if p.name.endswith(".link")], [], "临时链接名不留")

    def signed_export(self, choice="appleId", once=None):
        # 玩家选了用 Apple ID 签（或这次换成…）：签名器替身在 dylib 尾部加一段（真签名同样只改头尾），期望按加的字节手算
        self.c.r.update(gameId=self.A, mode="export", **({"sign": once} if once else {}))
        if choice == "external":
            (Path(self.c.private) / install.SIGN_CHOICE).write_text('{"mode": "external"}')
        def signer(dylib, team, bundle):
            Path(dylib).write_bytes(Path(dylib).read_bytes() + f"|signed {team} {bundle}".encode())
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), \
                patch.object(install, "export_signer", lambda c, mode: ("TEAMX", "io.example.app", signer, "测试账号")):
            return install.export_s2arm(self.c, self.A)

    def test_signed_with_chosen_apple_id(self):
        self.fixture()
        r = self.signed_export()
        names, data, _ = self.members(r["s2armPath"])
        signed = DYLIB + b"|signed TEAMX io.example.app"
        head = json.loads(data["s2arm.json"])
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], signed)
        self.assertEqual((head["signer"], head["image_sha256"], head["source_sha256"]),
                         (dict(mode="appleId", team="TEAMX"), hashlib.sha256(signed).hexdigest(), hashlib.sha256(DYLIB).hexdigest()))
        self.assertEqual(json.loads(data["program/catalogue.json"])["team"], "TEAMX", "手机看 team 非空就不再签")
        self.assertEqual(names.count("program/catalogue.json"), 1, "签好的包自带清单，不重复打进去")
        self.assertEqual(r["signedWith"], dict(mode="appleId", name="测试账号", team="TEAMX"))

    def test_external_choice_and_one_off_switch(self):
        # 设置里选了「自己用别的工具签」：登录着也不签；完成页「这次换成用 Apple ID」只管这一次
        self.fixture()
        r = self.signed_export(choice="external")
        _, data, _ = self.members(r["s2armPath"])
        self.assertEqual((json.loads(data["s2arm.json"])["signer"], r["signedWith"]), (None, dict(mode="none", name="", team=None)))
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], DYLIB)
        r = self.signed_export(choice="external", once="appleId")
        self.assertEqual(r["signedWith"]["mode"], "appleId")
        self.assertEqual(install.chosen_sign_mode(self.c), "external", "这次换成不改设置")
        r = self.signed_export(choice="appleId", once="none")
        self.assertEqual(r["signedWith"]["mode"], "none", "选了 Apple ID 这次也能不签")

    def test_apple_id_not_signed_in_still_exports_unsigned(self):
        # 11-19 维护者：导出不加拦截。Apple ID 方式读不到登录（Windows：Impactor 里没账号）→ 修前「没装上」；期望照样导出未签名的（同不签），
        #   完成页 signedWith none，诊断一条黄字说导入后由手机签（码 apple_not_signed_in：下一步是去登录）
        self.fixture()
        self.c.r.update(gameId=self.A, mode="export")
        def no_login(c, mode):
            raise install.Failure("读不到 Impactor 里登录的 Apple ID", code="apple_not_signed_in")
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), patch.object(install, "export_signer", no_login):
            r = install.export_s2arm(self.c, self.A)
        _, data, _ = self.members(r["s2armPath"])
        self.assertEqual((json.loads(data["s2arm.json"])["signer"], r["signedWith"]), (None, dict(mode="none", name="", team=None)))
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], DYLIB, "程序库原样、没签")
        warn = [d for d in self.c.job["diagnostics"] if d.get("code") == "apple_not_signed_in"]
        self.assertEqual([d["severity"] for d in warn], ["warning"])
        self.assertEqual(warn[0]["summary"], install.EXPORT_UNSIGNED_NO_ID, "没有交过身份的手机：如实说导入后签不了、下一步是什么")
        layout.save_device(self.c, "PHONE1", dict(identity=dict(team="T1", key_fp="f", cert_sha1="s")))
        self.c.job["diagnostics"].clear()
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), patch.object(install, "export_signer", no_login):
            install.export_s2arm(self.c, self.A)
        self.assertEqual([d["summary"] for d in self.c.job["diagnostics"] if d.get("code") == "apple_not_signed_in"], [install.EXPORT_UNSIGNED],
                         "交过身份的手机：未签名，导入后由手机上的 S2Arm 签名")
        # 别的签不成（证书缺件等）照旧报
        def broken(c, mode):
            raise install.Failure("证书缺件", code="devcert_missing")
        self.c.r.update(sign="devCert")
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), patch.object(install, "export_signer", broken):
            with self.assertRaises(install.Failure) as e:
                install.export_s2arm(self.c, self.A)
        self.assertEqual(e.exception.code, "devcert_missing")

    def test_team_without_devices_still_exports_unsigned(self):
        # D-VX6J：plumesign 签程序库要先拿团队描述文件，团队里一台设备都没有（Apple 8220）→ 修前整次导出报通用「本地任务失败」；
        #   期望同没登录：照样导出未签名的，黄字照实说团队里没设备、怎么让电脑能签（码 device_not_visible）；别的签名失败照旧抛
        self.fixture()
        self.c.r.update(gameId=self.A, mode="export")
        def no_devices(dylib, team, bundle):
            raise RuntimeError("签名装机失败（device_not_connected）：r team has no devices from which to generate a provisioning profile. Connect a device")
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), \
                patch.object(install, "export_signer", lambda c, mode: ("TEAMX", "io.example.app", no_devices, "测试账号")):
            r = install.export_s2arm(self.c, self.A)
        _, data, _ = self.members(r["s2armPath"])
        self.assertEqual((json.loads(data["s2arm.json"])["signer"], r["signedWith"]), (None, dict(mode="none", name="", team=None)))
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], DYLIB, "程序库原样、没签")
        warn = [d for d in self.c.job["diagnostics"] if d.get("code") == "device_not_visible"]
        self.assertEqual([(d["severity"], d["summary"]) for d in warn], [("warning", install.EXPORT_NO_DEVICE_NO_ID)])
        def other(dylib, team, bundle):
            raise RuntimeError("签名装机失败（signing_server_unreachable）：os error 11001")
        with patch.object(program_pack, "build", lambda c, g, **k: self.pkg), patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []), \
                patch.object(install, "export_signer", lambda c, mode: ("TEAMX", "io.example.app", other, "测试账号")):
            with self.assertRaises(RuntimeError):
                install.export_s2arm(self.c, self.A)

    def test_export_brings_game_to_current_like_update(self):
        # #1162：导出 .s2arm 原先只重核程序（refresh_ios）、不重编着色器库，玩家导出装好后电脑上「建议更新」照亮。
        #   期望和「更新这款」同一份定义（refresh_local）：着色器库重编在打包之前、在这款的程序锁里
        import sgrade_bf
        self.fixture()
        order = []
        with patch.object(sgrade_bf, "rechain_ios", lambda c, g: order.append(("rechain", g)) or "done"), \
                patch.object(program_pack, "build", lambda c, g, **k: order.append(("build", g)) or self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: order.append(("refresh", tuple(games))) or []), \
                patch.object(install, "export_sign_mode", lambda c: "external"):
            self.c.r.update(gameId=self.A, mode="export")
            install.export_s2arm(self.c, self.A)
        self.assertEqual(order, [("rechain", self.A), ("refresh", (self.A,)), ("build", self.A)])

    def test_sign_mode_set(self):
        from core import Failure
        for mode, want in (("external", "external"), ("appleId", "appleId")):
            self.c.r.update(mode=mode)
            self.assertEqual(install.sign_mode_set(self.c), dict(signMode=want))
        self.c.r.update(mode="devCert")
        with self.assertRaises(Failure) as e:
            install.sign_mode_set(self.c)
        self.assertEqual(e.exception.code, "devcert_missing", "没导入过证书选不了证书")

    def test_folder_shared_and_recreated(self):
        # 只换这一款的 .s2arm，同文件夹别的东西不动；玩家删了整个文件夹，下次导出重新建
        self.fixture()
        folder = Path(self.c.library) / "S2Arm 游戏包"
        folder.mkdir(); (folder / "别的东西.txt").write_text("留着")
        self.export()
        self.assertTrue((folder / "别的东西.txt").is_file())
        import shutil
        shutil.rmtree(folder)
        self.export()
        self.assertTrue((folder / "测试游戏.s2arm").is_file())
        self.assertEqual([p.name for p in folder.iterdir() if p.name.endswith(".partial")], [], "不留临时文件")

    def test_folder_readme_three_sentences(self):
        # 「S2Arm 游戏包」里的说明只讲三件事（维护者 11-17 定稿），中文界面中文、别的界面英文；删了下次导出写回
        self.fixture()
        self.export()
        zh = Path(self.c.library) / "S2Arm 游戏包" / "怎么导入.txt"
        self.assertEqual(zh.read_text(encoding="utf-8"), install.S2ARM_README_TEXT["zh"])
        self.assertIn(".s2arm 删了，在启动器里再导出一次就有。", zh.read_text(encoding="utf-8"))
        zh.unlink()
        self.export()
        self.assertTrue(zh.is_file())
        self.assertIn("If you delete a .s2arm file, just export it again from the launcher.", install.S2ARM_README_TEXT["en"])
        self.assertIn("“Import Here”", install.S2ARM_README_TEXT["en"], "同 iOS 端「放这里导入」的英文 img.importFolder")

    def test_same_name_gets_game_id(self):
        self.fixture({self.A: "同名", self.B: "同名"})
        self.assertTrue(self.export()["s2armPath"].endswith(f"同名 [{self.A[-4:]}].s2arm"))

    def test_existing_folder_kept_across_ui_language(self):
        # 固定文件夹：库根已有英文那个（第一次建时是英文界面），之后换中文界面也写进它，不建第二个
        self.fixture()
        en = Path(self.c.library) / "S2Arm Game Packs"; en.mkdir()
        self.c.r["uiLanguage"] = "zh-Hans"
        self.assertEqual(Path(self.export()["s2armPath"]).parent, en)
        self.assertFalse((Path(self.c.library) / "S2Arm 游戏包").exists())

    def test_english_ui_first_time_uses_english_name(self):
        self.fixture()
        self.c.r["uiLanguage"] = "ja"
        self.assertEqual(Path(self.export()["s2armPath"]).parent.name, "S2Arm Game Packs")

    def test_path_too_long_for_ustar_is_reported(self):
        # 只用 ustar（手机只认它）：放不下的路径不改用 pax 长名，报错
        self.fixture()
        deep = self.pkg / "Games" / self.A / ("x" * 120) / ("y" * 120)
        deep.mkdir(parents=True); (deep / ("z" * 60)).write_bytes(b"1")
        from core import Failure
        with self.assertRaises(Failure):
            self.export()

    def test_install_export_goes_to_s2arm(self):
        # 导出一款（通用 S2Arm）：.s2arm 两件套 + 同文件夹本版 S2Arm.ipa（#502）；0.6.0 起没有旧的自签导出
        self.fixture()
        self.c.r.update(gameId=self.A, mode="export")
        calls = []
        with patch.object(install, "export_s2arm", lambda c, g: calls.append(("s2arm", g)) or {}), \
                patch.object(install, "ensure_shell_ipa", lambda c: calls.append(("ipa",)) or Path("S2Arm.ipa")), \
                patch.object(install, "ios_pack", lambda c, g: self.pack), patch("downstream.requested", lambda c, g: None, create=True):
            install._install(self.c)
        self.assertEqual(calls, [("ipa",), ("s2arm", self.A)], "通用 S2Arm 导出到文件夹：先放本版 S2Arm.ipa，再出这款的 .s2arm（#502）")


if __name__ == "__main__":
    unittest.main()
