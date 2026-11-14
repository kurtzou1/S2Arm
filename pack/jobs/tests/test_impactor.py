#!/usr/bin/env python3
"""Windows 签装交给玩家自装的 Impactor（pack/jobs/impactor.py + impactor_guide.json）单测。
期望按规则写：报错原文取自 11-04 Windows 出包机实测与上游报告的原句；实测版本 2.7.2；引导两种语言齐全、引用的码全在共用表。"""
import json, os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

H = os.path.dirname(os.path.abspath(__file__)); J = os.path.dirname(H)
sys.path.insert(0, J)
import impactor   # noqa: E402
from errors import RECOVERY   # noqa: E402

with open(os.path.join(J, 'impactor_guide.json'), encoding='utf-8') as _f: GUIDE = json.load(_f)


class Explain(unittest.TestCase):
    def test_real_messages(self):
        for text, code in (
                ('Authentication SRP error -80046: This action could not be completed.', 'login_identity_rejected'),   # 11-04 维护者 Windows 出包机原文
                ('Authentication SRP error -20970: Your account information was entered incorrectly.', 'apple_id_wrong'),   # 11-04 Windows 出包机原文
                ('An unknown error occured while reading the file.', 'ipa_needs_repack'),   # AltServer 读 zip64（11-04）
                ('The name for this app is invalid.', 'ipa_needs_repack'),   # AltServer 中文显示名（11-04）
                ('You have reached the maximum number of apps', 'free_app_limit'),
                ('Application verification failed: This device has reached the maximum number of installed apps using a free developer profile', 'free_app_limit'),   # 11-06 Windows 出包机 plumesign 原文（测试设备2 iOS 27）
                ('Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.', 'free_appid_limit'),   # Apple 9120 的 Xcode 原文措辞
                ('Developer services error 9120: Your maximum App ID limit has been reached.', 'free_appid_limit'),   # 带 Apple 错误码的转述形态
                ("Developer API error 9401 (HTTP Some(200)): An App ID with Identifier 'io.s2arm.games.abcde12345' is not available. Please enter a different string.", 'app_id_taken'),   # #408 Windows plumesign 原文
                ('Developer Mode is disabled', 'developer_mode_required'),
                ('完全看不懂的报错', 'device_install_failed')):
            with self.subTest(text=text): self.assertEqual(impactor.explain(text), code)

    def test_identity_before_account(self):   # -80046 的原文里也带「could not be completed」，不能被账号类先吃掉
        self.assertEqual(impactor.explain('-80046 entered incorrectly'), 'login_identity_rejected')

    def test_all_codes_shared(self):
        codes = {c for _, c in impactor.EXPLAIN} | {e['code'] for e in GUIDE['errors']} | {'impactor_missing', 'impactor_version_untested'}
        self.assertEqual(sorted(c for c in codes if c not in RECOVERY), [])


class Status(unittest.TestCase):
    def run_with(self, found):
        with mock.patch.object(impactor, 'candidates', return_value=['C:/x/Impactor.exe']), \
             mock.patch.object(impactor, 'exe_version', return_value=found):
            return impactor.status()

    def test_tested_version_ok(self):
        r = self.run_with(('plumeimpactor', '2.7.2'))
        self.assertEqual((r['verdict'], r['code'], r['version']), ('ok', None, '2.7.2'))

    def test_other_version_untested(self):
        r = self.run_with(('plumeimpactor', '2.8.0'))
        self.assertEqual((r['verdict'], r['code']), ('untested', 'impactor_version_untested'))
        self.assertIn('2.7.2', r['next'])

    def test_missing_and_wrong_product(self):
        for found in ((None, None), ('someotherapp', '2.7.2')):
            with self.subTest(found=found):
                r = self.run_with(found)
                self.assertEqual((r['verdict'], r['code']), ('missing', 'impactor_missing'))
                self.assertTrue(r['download'].startswith('https://github.com/claration/impactor/releases/tag/v2.7.2'))


class StatusContract(unittest.TestCase):   # 启动器（两个前端）靠这一行 JSON 判：字段名与 verdict 取值钉死，改了要同笔改前端（满屏补丁线 11-04）
    def test_fields_and_verdicts(self):
        seen = set()
        for found in (('plumeimpactor', '2.7.2'), ('plumeimpactor', '9.9.9'), (None, None)):
            with mock.patch.object(impactor, 'candidates', return_value=['x.exe']), mock.patch.object(impactor, 'exe_version', return_value=found):
                r = json.loads(json.dumps(impactor.status()))
            base = {'tested', 'download', 'path', 'version', 'verdict', 'code'}
            self.assertEqual(set(r), base | ({'next'} if r['code'] else set()))
            seen.add((r['verdict'], r['code']))
        self.assertEqual(seen, {('ok', None), ('untested', 'impactor_version_untested'), ('missing', 'impactor_missing')})

    def test_online_adds_latest_only(self):
        with mock.patch.object(impactor, 'candidates', return_value=[]), mock.patch.object(impactor.urllib.request, 'urlopen', side_effect=OSError('offline')):
            r = impactor.status(online=True)
        self.assertIsNone(r['latest']); self.assertEqual(r['verdict'], 'missing')   # 查不到最新版不影响判定


class Guide(unittest.TestCase):
    def test_both_languages_complete(self):
        for s in GUIDE['steps']:
            for lang in ('zh-Hans', 'en'):
                self.assertTrue(s['title'][lang] and s['do'][lang] and all(s['do'][lang]))
                if 'note' in s: self.assertTrue(s['note'][lang])
            self.assertEqual(len(s['do']['zh-Hans']), len(s['do']['en']), s['title']['zh-Hans'])

    def test_steps_cover_requirements(self):   # 维护者 11-04 列的六项都在引导里
        text = json.dumps(GUIDE['steps'], ensure_ascii=False)
        for must in ('iTunes', '添加账号', '导入 .ipa/.tipa', '自动刷新 [BETA]', '私有无线局域网地址', '开发者模式', '8177 MB'):
            self.assertIn(must, text)

    def test_html(self):
        st = {'verdict': 'missing', 'version': None}
        with tempfile.NamedTemporaryFile(suffix='.ipa', delete=False) as f: ipa = f.name
        try: h = impactor.guide_html(ipa=ipa, st=st)
        finally: os.remove(ipa)
        for s in GUIDE['steps']: self.assertIn(s['title']['zh-Hans'], h)
        self.assertIn(GUIDE['status']['missing']['zh-Hans'][:10], h)
        self.assertIn(impactor.RELEASE_PAGE, h)
        self.assertNotIn('<script', h.lower())
        for e in GUIDE['errors']: self.assertIn(RECOVERY[e['code']][:12], h)

    def test_reveal_missing_file(self):
        with self.assertRaises(FileNotFoundError): impactor.reveal('/nonexistent/x.ipa')


if __name__ == '__main__':
    unittest.main()


class SelectedTeamTests(unittest.TestCase):
    """账号存档（%APPDATA%\\PlumeImpactor\\accounts.json）里当前选中账号的团队号：给 Windows 装机定包名用（9401）"""
    def test_selected_account_team(self):
        import json, tempfile
        import impactor
        with tempfile.TemporaryDirectory() as d:
            store = Path(d) / "PlumeImpactor"; store.mkdir()
            (store / "accounts.json").write_text(json.dumps({"selected_account": "b@x", "accounts": {
                "a@x": {"team_id": "FGHIJ67890"}, "b@x": {"team_id": "ABCDE12345"}}}))
            self.assertEqual(impactor.selected_team(d), "ABCDE12345")
            (store / "accounts.json").write_text(json.dumps({"selected_account": "c@x", "accounts": {"a@x": {"team_id": "FGHIJ67890"}}}))
            self.assertIsNone(impactor.selected_team(d))
            (store / "accounts.json").write_text("{broken")
            self.assertIsNone(impactor.selected_team(d))
        self.assertIsNone(impactor.selected_team("/nonexistent-dir"))


class UnselectedAccountTests(unittest.TestCase):
    """D-ZM37：账号存档存了 Apple ID 却没选中（同版 v2.7.2 plume_store：删掉选中的那个只把 selected_account 置空），plumesign 报
    「No account selected」。只存一个 → 用官方 plumesign account switch 选上；存多个 → 不替玩家挑"""
    def setUp(self):
        self.d = tempfile.mkdtemp(); self.addCleanup(lambda: __import__("shutil").rmtree(self.d, ignore_errors=True))
        self.f = Path(self.d) / "PlumeImpactor" / "accounts.json"; self.f.parent.mkdir()

    def put(self, selected, emails):
        self.f.write_text(json.dumps({"selected_account": selected, "accounts": {e: {"team_id": "ABCDE12345"} for e in emails}}))

    def test_unselected(self):
        for selected, emails, want in ((None, ["a@x"], ["a@x"]), ("gone@x", ["b@x", "a@x"], ["a@x", "b@x"]),
                                       ("a@x", ["a@x", "b@x"], []), (None, [], [])):
            with self.subTest(selected=selected, emails=emails):
                self.put(selected, emails); self.assertEqual(impactor.unselected_accounts(self.d), want)
        self.f.write_text("{broken"); self.assertEqual(impactor.unselected_accounts(self.d), [])

    def test_single_account_switched_by_plumesign(self):
        self.put(None, ["a@x"]); calls = []
        def fake_run(cmd, **kw):   # 官方 plumesign account switch 的效果：选中那个邮箱
            calls.append(cmd); self.put(cmd[-1], ["a@x"]); return mock.Mock(returncode=0)
        with mock.patch.object(impactor.subprocess, "run", fake_run):
            self.assertEqual(impactor.select_only_account("plumesign.exe", self.d), "a@x")
        self.assertEqual(calls, [["plumesign.exe", "account", "switch", "a@x"]])
        self.assertEqual(impactor.selected_team(self.d), "ABCDE12345")

    def test_many_or_selected_not_touched(self):
        for selected, emails in ((None, ["a@x", "b@x"]), ("a@x", ["a@x"])):
            with self.subTest(selected=selected, emails=emails), mock.patch.object(impactor.subprocess, "run") as run:
                self.put(selected, emails)
                self.assertIsNone(impactor.select_only_account("plumesign.exe", self.d)); run.assert_not_called()

    def test_switch_failed_is_none(self):
        self.put(None, ["a@x"])
        with mock.patch.object(impactor.subprocess, "run", return_value=mock.Mock(returncode=1)):
            self.assertIsNone(impactor.select_only_account("plumesign.exe", self.d))

    def test_no_account_selected_text(self):   # D-ZM37 原文
        self.assertEqual(impactor.explain("Error: No account selected. Please login first using 'plumesign account login'"), "apple_session_expired")
