# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包与装机重叠（pack/jobs/early.py + ipa.py installAfter，11-06 出包速度线）：一键出包与装机全换替身，只验编排。
期望按 early.py 头注手写：
  ① 旁路信号到 → 早装件（early_pack.sh）→ 签名装 App → 推早期资源包（.early/pack），都在出包结束之前；出包结束 → 交付进 image/ios → 装正式包 → 推正式资源包（image/ios/pack）；
     返回的推送量 = 两次之和；早装件目录收尾删掉
  ② 早装件出不来（early_pack.sh 退 1）→ 不判整单失败、记一条进度消息、正式安装照装照推
  ③ 出包失败 → 抛出包的失败、不装正式包；没写信号时早装线程直接退出、不调早装件
  ④ 不带 installAfter → 不认设备、不设 S2A_EARLY_READY、不装
"""
import contextlib
import json
import os
import subprocess
import time
import unittest
import unittest.mock as um
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from test_jobs import img_step
from core import Context, Failure
import build
import cache_retention
import early
import install
import ipa
import library


GID = '0100000000000000'


class EarlyInstallCase(JobCase):
    def setUp(self):
        super().setUp()
        import install
        from unittest.mock import patch as _patch
        p = _patch.object(install, "phone_games", lambda c, ph: set()); p.start(); self.addCleanup(p.stop)   # 读手机游戏清单另有用例

    def run_ipa(self, suffix, *, install_after=True, signal=True, oneclick_fail=False, early_rc=0, push_s=0):
        c = Context(self.request | dict(taskId='early-' + suffix, operation='ipa', gameId=GID) | (dict(installAfter=True) if install_after else {}))
        calls, envs = [], []
        stamp = lambda what, *a: calls.append((time.time(), what) + a)

        def oneclick(args, log=None, env=None, **kwargs):   # 一键出包替身：先写旁路信号，「编直连库」2 秒，再交付
            if img_step(args, kwargs.get('cwd'), env): return   # 出包收尾转单一 IMG（ipa.to_img 经 c.run）：真跑
            args = [str(a) for a in args]
            if any(a.endswith('ship_ext.py') for a in args) and 'container' in args:   # assemble 的容器组装命令
                o = Path(args[args.index('--out') + 1]); o.mkdir(parents=True, exist_ok=True)
                (o / 's2a_catalogue.json').write_text(json.dumps({"schema": 1, "shell_id": "SID1", "games": [{"title_id": GID}]}))
                return
            if any(a.endswith('ship_ext.py') for a in args) and 'sign' in args:   # assemble 写完容器摘要后的统一签名
                return
            if 'write_ipa' in args:   # assemble 的 ipa 打包命令
                Path(args[-1]).write_bytes(b'early' if early_rc == 0 else b'final')
                return
            envs.append(dict(env))
            out = Path(args[args.index('--out') + 1])
            if signal and env.get('S2A_EARLY_READY'):
                Path(env['S2A_EARLY_READY']).write_text('tfake@rx-1\n')
            time.sleep(2)
            stamp('出包结束')
            events = Path(args[args.index('--events') + 1])
            if oneclick_fail:
                events.write_text(json.dumps(dict(ev='result', ok=False, msg='替身出包失败')) + '\n')
                raise Failure('替身出包失败', code='tool_exit')
            (out / 'tfake.ipa').write_bytes(b'final'); (out / 'tfake资源包').mkdir(exist_ok=True)
            (out / 'tfake资源包' / 'manifest.json').write_text(json.dumps(dict(version=2, index_sha256='final01')))   # 收尾 deliver 要资源包清单号
            (out / 'tfake资源包' / 'exefs').mkdir(exist_ok=True); (out / 'tfake资源包' / 'exefs' / 'main.npdm').write_bytes(b'META')   # 收尾转单一 IMG（pack/img.py convert）读清单
            (out / 'tfake资源包' / 'index.tsv').write_text('exefs/main.npdm\t4\tx\n')
            root = out / 'roots' / ('t' + GID.lower() + '@现行'); root.mkdir(parents=True, exist_ok=True); (root / 'main.npdm').write_bytes(b'META')   # 现行产物根（存容器件用）
            events.write_text(json.dumps(dict(ev='result', ok=True, ipa=str(out / 'tfake.ipa'), graphics_mode='direct', build_id='x')) + '\n')

        real_run = subprocess.run
        def sub_run(cmd, *a, **k):   # 只替 early_pack.sh：按退出码出 / 不出早装件
            if isinstance(cmd, list) and str(cmd[1]).endswith('pack/early_pack.sh'):
                stamp('早装件', cmd[2])
                d = Path(cmd[3]); d.mkdir(parents=True, exist_ok=True)
                if early_rc == 0: (d / f'{cmd[2]}.ipa').write_bytes(b'early'); (d / 'pack').mkdir(exist_ok=True)
                else: k['stdout'].write('【红】替身早装件失败\n')
                return subprocess.CompletedProcess(cmd, early_rc)
            return real_run(cmd, *a, **k)

        seen_udid = self.seen_udid = []   # 两次推包都要带 UDID（tools/push_pack.py 据此走 s2a-devpush 流式写，11-06）
        def mac_phone(c_, team=None, dev=None, udid=None):
            ph = um.Mock()
            def inst_(ipa, games, steps=True): stamp('装 App', Path(ipa).name)
            def push_(g, pack):   # 早期资源包 .early/pack，正式的 image/ios/pack：记「上级目录/名字」区分
                name = Path(pack).parent.name + '/' + Path(pack).name; is_early = name == '.early/pack'
                time.sleep(push_s if is_early else 0); stamp('推资源包', name); seen_udid.append(udid); return (3, 30) if is_early else (2, 20)
            ph.install.side_effect = inst_; ph.push.side_effect = push_
            ph.udid = udid; ph.key = udid; ph.bid = install.container_bundle_id('TEAM1')
            ph.info = dict(device=dev['name'], team=team['name'], free=team['free'])
            return ph
        game = dict(id=GID, packages=[])
        with contextlib.ExitStack() as st:
            for obj, name, value in (
                    (c, 'catalog', {'games': [game]}), (c, 'fonts_dir', self.root),
                    (library, 'require_game', None), (library, 'check_pack_space', None), (library, 'prune_build', lambda *a, **k: stamp('清理')),
                    (build, 'ensure_extract', self.root), (build, 'seed_from_sibling', False),
                    (ipa, 'dotnet_sdk', (self.root, self.root / 'dotnet')), (ipa, '_iml_device_hint', None),
                    (ipa, 'resolve_target', None), (ipa, 'current_shell_id', 'SID1'), (ipa, 'container_shell', self.root),
                    (cache_retention, 'trim', dict(accountingComplete=True, evictionErrors=0, diskErrors=0, pressureRemaining=False,
                                                    keepTitles=3, retainedBytes=0, removedEntries=0, freeBytes=100, minFreeBytes=0)),
                    (install, 'xcode_teams', [dict(id='TEAM1', name='t', free=True)]), (install, 'phone', dict(id='DEV1', name='测试设备')),
                    (install, 'udid_of', 'UDID1'), (install, 'MacPhone', mac_phone)):
                st.enter_context(patch.object(obj, name, return_value=value) if not callable(value) else patch.object(obj, name, side_effect=value))
            st.enter_context(patch.object(c, 'run', side_effect=oneclick))
            st.enter_context(patch.object(early.subprocess, 'run', side_effect=sub_run))
            try: result, err = ipa.build(c), None
            except Failure as e: result, err = None, e
            stamp('返回')
        return c, result, err, calls, envs

    def test_overlap_order_and_totals(self):
        c, r, err, calls, envs = self.run_ipa('ok')
        calls = [x for x in calls if x[1] not in ('清理', '返回')]   # 清理 / 返回只给 P1-146 那条用
        self.assertIsNone(err)
        what = [x[1:] for x in calls]
        end = next(t for t, w, *_ in calls if w == '出包结束')
        early_steps = [(w, *a) for t, w, *a in calls if t < end]
        self.assertEqual([s[0] for s in early_steps], ['早装件', '装 App', '推资源包'], what)   # ① 都在出包结束之前，顺序正确
        self.assertEqual(early_steps[0], ('早装件', 'tfake'))
        self.assertEqual(early_steps[2], ('推资源包', '.early/pack'))
        self.assertEqual([s[0] for s in [x[1:] for x in calls][-2:]], ['装 App', '推资源包'])
        self.assertEqual(calls[-1][2:], ('ios/pack',), what)   # 正式资源包已搬进这款的 image/ios
        self.assertEqual(r['packFiles'], 3 + 2)   # 早推 3 + 补推 2
        self.assertTrue(r['outputPath'].endswith(os.path.join('image', 'ios')))   # 出包页「打开位置」指这款的 image/ios

    def test_early_failure_falls_back_to_full_push(self):
        c, r, err, calls, _ = self.run_ipa('earlyred', early_rc=1)
        calls = [x for x in calls if x[1] not in ('清理', '返回')]   # 清理 / 返回只给 P1-146 那条用
        self.assertIsNone(err)   # ② 不判整单失败
        what = [x[1:] for x in calls]
        self.assertNotIn(('推资源包', '.early/pack'), what)
        self.assertEqual([s[0] for s in what[-2:]], ['装 App', '推资源包'], what)
        self.assertEqual(what[-1], ('推资源包', 'ios/pack'), what)
        msgs = [json.loads(l).get('message', '') for l in c.events.read_text().splitlines()]
        self.assertTrue(any('先装 App、先推资源没成' in m for m in msgs), msgs[-5:])

    def test_cleanup_waits_for_early_push(self):
        # 审计 P1-146：早装还在从 roots/ 与 .early 推（推得比出包慢），成功路径的清理要等它推完；失败路径要等早装线程退出再交回（main 随后清理）
        c, r, err, calls, _ = self.run_ipa('slowpush', push_s=3)
        self.assertIsNone(err)
        t = {w if not a else (w, *a): ts for ts, w, *a in calls}
        self.assertLess(t[('推资源包', '.early/pack')], t['清理'], [x[1:] for x in calls])
        c, r, err, calls, _ = self.run_ipa('slowpush-red', push_s=3, oneclick_fail=True)
        self.assertIsNotNone(err)
        t = {w if not a else (w, *a): ts for ts, w, *a in calls}
        self.assertLess(t[('推资源包', '.early/pack')], t['返回'], [x[1:] for x in calls])

    def test_package_failure_no_final_install(self):
        c, r, err, calls, _ = self.run_ipa('pkgred', oneclick_fail=True, signal=False)
        self.assertIsNotNone(err)   # ③
        self.assertEqual([w for _, w, *_ in calls], ['出包结束', '返回'])

    def test_without_install_after_nothing_extra(self):
        c, r, err, calls, envs = self.run_ipa('plain', install_after=False)
        self.assertIsNone(err)   # ④
        self.assertNotIn('S2A_EARLY_READY', envs[0])
        self.assertEqual([w for _, w, *_ in calls], ['出包结束', '清理', '返回'])
        self.assertNotIn('bundleId', r)


if __name__ == '__main__':
    unittest.main()
