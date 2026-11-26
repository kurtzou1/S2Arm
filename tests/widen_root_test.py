# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic identities, no game files; exercise the real IPA entry before reuse."""
import ctypes
import os
from pathlib import Path
import shutil
import signal
import struct
import sys
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PROGRAM = '0100111122220000'
BUILD = '0123456789abcdef0123456789abcdef'
ROW = f'{PROGRAM}\t{BUILD}\tfixture\tapple\t2026-11-01\t原创合成验证记录'
_SNAPSHOT = None
_CLONEFILE = getattr(ctypes.CDLL(None), 'clonefile', None) if sys.platform == 'darwin' else None
if _CLONEFILE is not None:
    _CLONEFILE.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]


def snapshot_tree():
    """本树已跟踪文件（取工作区内容）拷进临时 git 仓库并提交一次，真实 IPA 入口在这棵树里跑（整个单测文件只拷一次）。
    11-02 合入线：main 无缓存全套并发时别的步骤往共享树 native / gfx / services / ryujinx 里写文件，ipa.sh 先报「本树构建相关目录有
    未提交改动」就退出，根本没走到要测的宽屏验证闸，用例拿不到「缺失」而红。快照里只有跟踪文件、刚提交过，那条检查恒为干净；
    测的仍是本树当前的脚本（未提交的改动也一并带进快照）。"""
    global _SNAPSHOT
    if _SNAPSHOT is None:
        holder = tempfile.TemporaryDirectory(prefix='widen-root-tree-')
        tree = Path(holder.name) / 'S2Arm'
        listed = subprocess.run(['git', 'ls-files', '-z'], cwd=REPO, capture_output=True, check=True).stdout
        for rel in filter(None, listed.split(b'\0')):
            src, dst = REPO / os.fsdecode(rel), tree / os.fsdecode(rel)
            if not os.path.lexists(src):
                continue   # 工作区里删掉了的跟踪文件：快照里也没有，提交即删除
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_symlink():
                os.symlink(os.readlink(src), dst)
            elif _CLONEFILE is None or _CLONEFILE(os.fsencode(src), os.fsencode(dst), 0) != 0:
                shutil.copy2(src, dst)   # APFS 克隆（写时复制，9 千个文件约 1 秒）不成（跨卷 / 非 macOS）才逐字节拷
        git = ['git', '-c', 'user.name=widen-root-test', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null']
        subprocess.run(git + ['init', '-q'], cwd=tree, check=True, capture_output=True)
        objects = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=REPO,
                                 capture_output=True, text=True, check=True).stdout.strip() + '/objects'
        (tree / '.git/objects/info/alternates').write_text(objects + '\n')   # 借本仓库对象库：没改的文件不再压缩写一遍（add 约 10 秒 → 2 秒）
        for args in (['add', '-A'], ['commit', '-q', '-m', 'snapshot']):
            subprocess.run(git + args, cwd=tree, check=True, capture_output=True)
        _SNAPSHOT = (holder, tree)
    return _SNAPSHOT[1]


def tearDownModule():
    if _SNAPSHOT is not None:
        _SNAPSHOT[0].cleanup()


class WidenRootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='widen-root-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'roots' / 'fixture@source'
        exefs = self.root / 'exefs'
        exefs.mkdir(parents=True)
        (self.root / 'romfs').mkdir()   # 真实产物根都有 romfs/：包键的进包资源输入键要读它（审计 P1-54）
        nso = bytearray(0x100)
        nso[:4] = b'NSO0'
        nso[0x40:0x50] = bytes.fromhex(BUILD)
        (exefs / 'main').write_bytes(nso)
        npdm = bytearray(0x100)
        npdm[:4] = b'META'
        struct.pack_into('<I', npdm, 0x70, 0x80)
        npdm[0x80:0x84] = b'ACI0'
        struct.pack_into('<Q', npdm, 0x90, int(PROGRAM, 16))
        (exefs / 'main.npdm').write_bytes(npdm)
        (self.root / 'main.patched.bin').write_bytes(b'synthetic')
        nacp = bytearray(0x4000)   # 游戏自带标题（11-04：ipa.sh 只从它取桌面显示名，取不到报红）：美式英语一项
        nacp[:12] = b'Fixture Game'
        (self.root / 'ctl').mkdir()
        (self.root / 'ctl' / 'control.nacp').write_bytes(nacp)
        self.table = self.base / 'tables' / 'verified.tsv'
        self.table.parent.mkdir()
        self.table.write_text(ROW + '\n')
        (self.root.parent / 'fixture@现行').write_text(self.root.name + '\n')

    def checker(self, status=0, message=None, caps=None):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        command = [os.environ.get('S2A_PY', 'python3'), str(REPO / 'pack/widen_root.py'),
                   str(self.root), '--table', str(self.table)]
        if caps is not None:
            command += ['--caps', str(caps)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        if message:
            self.assertIn(message, result.stdout + result.stderr)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        self.assertEqual(before, after, '验证工具不能修改原始构建根')
        return result

    def test_matching_marker(self):
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n')
        self.checker(message='一致')

    def test_identity_case_and_comments(self):
        (self.root / 'widen_verified.tsv').write_text('# 注释\n\n' + ROW.lower() + '\n')
        self.checker()

    def test_unverified_root_needs_no_marker(self):
        self.table.write_text('# 无该身份的记录\n')
        self.checker(message='无已验证行且无标记')

    def test_missing_marker(self):
        self.checker(1, '缺失')

    def test_wrong_program_marker(self):
        (self.root / 'widen_verified.tsv').write_text(ROW.replace(PROGRAM, '0100999988880000') + '\n')
        self.checker(1, '身份不符')

    def test_wrong_build_marker(self):
        (self.root / 'widen_verified.tsv').write_text(ROW.replace(BUILD, 'f' * 32) + '\n')
        self.checker(1, '身份不符')

    def test_revoked_marker(self):
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n')
        self.table.write_text('# 撤销\n')
        self.checker(1, '遗留')

    def test_changed_evidence(self):
        (self.root / 'widen_verified.tsv').write_text(ROW.replace('原创合成验证记录', '旧证据') + '\n')
        self.checker(1, '不一致')

    def test_duplicate_table_identity(self):
        self.table.write_text(ROW + '\n' + ROW + '\n')
        self.checker(1, '多条')

    def test_android_table_row_does_not_count_for_ios_root(self):
        # F7 #1574：同身份的 android 行不算苹果验证——apple 行 + android 行并存不算「多条」，只有 android 行 = 未验证
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n')
        self.table.write_text(ROW + '\n' + ROW.replace('\tapple\t', '\tandroid\t') + '\n')
        self.checker(0, '一致')
        self.table.write_text(ROW.replace('\tapple\t', '\tandroid\t') + '\n')
        self.checker(1, '不在验证表')

    def test_multiple_marker_rows(self):
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n' + ROW + '\n')
        self.checker(1, '身份不符')

    def test_bad_marker(self):
        (self.root / 'widen_verified.tsv').write_text('bad\tbad\n')
        self.checker(1, '格式无效')

    def test_empty_marker(self):
        (self.root / 'widen_verified.tsv').write_text('')
        self.checker(1, '身份不符')

    def test_bad_nso(self):
        (self.root / 'exefs/main').write_bytes(b'NSO0')
        self.checker(1, 'NSO0')

    def test_bad_npdm(self):
        (self.root / 'exefs/main.npdm').write_bytes(b'bad')
        self.checker(1, 'NPDM')

    def test_out_of_bounds_npdm(self):
        path = self.root / 'exefs/main.npdm'
        data = bytearray(path.read_bytes())
        struct.pack_into('<I', data, 0x70, 0xfffffff0)
        path.write_bytes(data)
        self.checker(1, 'ACI0')

    def test_missing_table(self):
        self.table.unlink()
        self.checker(1, '缺失')

    def test_marker_symlink(self):
        (self.root / 'widen_verified.tsv').symlink_to(self.table)
        self.checker(1, '普通文件')

    def test_broken_marker_symlink(self):
        self.table.write_text('# 无该身份\n')
        (self.root / 'widen_verified.tsv').symlink_to(self.base / 'absent')
        self.checker(1, '遗留')

    def test_main_symlink(self):
        main = self.root / 'exefs/main'
        data = main.read_bytes()
        main.unlink()
        target = self.base / 'main'
        target.write_bytes(data)
        main.symlink_to(target)
        self.checker(1, '普通文件')

    def test_cached_package_valid_marker(self):
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n')
        result = self.entry(False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('现行已是包', result.stdout + result.stderr)

    def test_cached_package_unverified(self):
        self.table.write_text('# 无该身份\n')
        result = self.entry(False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('现行已是包', result.stdout + result.stderr)

    def test_unrelated_bad_table_rows_do_not_block_matching_identity(self):
        self.table.write_text('bad\tbad\n0100999988880000\tbroken\n' + ROW + '\n')
        (self.root / 'widen_verified.tsv').write_text(ROW + '\n')
        self.checker(message='一致')

    def test_unrelated_bad_table_rows_do_not_block_unverified_identity(self):
        self.table.write_text('bad\tbad\n0100999988880000\tbroken\n')
        self.checker(message='无已验证行且无标记')

    def test_explicit_caps_do_not_consume_marker(self):
        caps = self.root / 's2a_caps.tsv'
        for value in ['0', '1']:
            with self.subTest(value=value):
                caps.write_text(f'widen\t{value}\t# 合成能力清单\n')
                self.checker(caps=caps, message='能力清单')

    def test_caps_without_valid_widen_still_checks_marker(self):
        caps = self.root / 's2a_caps.tsv'
        for content in ['fps60\t1\n', 'widen\tinvalid\n', '# widen 1\n']:
            with self.subTest(content=content):
                caps.write_text(content)
                self.checker(1, '缺失', caps=caps)

    def test_caps_symlink_is_rejected(self):
        caps = self.root / 's2a_caps.tsv'
        caps.symlink_to(self.table)
        self.checker(1, '普通文件', caps=caps)

    def test_missing_caps_falls_back_to_marker(self):
        self.checker(1, '缺失', caps=self.root / 'absent-caps.tsv')

    def test_cached_package_release_caps_missing_marker(self):
        (self.root / 's2a_caps.tsv').write_text('widen\t1\n')
        result = self.entry(False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('现行已是包', result.stdout + result.stderr)

    def test_cached_package_all_caps_selects_actual_manifest(self):
        # Runtime consumes the first valid widen value. An invalid row is skipped.
        (self.root / 's2a_caps.tsv').write_text('fps60\t1\n')
        (self.root / 's2a_caps.all.tsv').write_text('widen invalid\nwiden 1 # 开\nwiden 0\n')
        result = self.entry(False, all_caps=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('能力清单', result.stdout + result.stderr)
        self.assertIn('现行已是包', result.stdout + result.stderr)

    def test_release_does_not_borrow_all_caps_bypass(self):
        (self.root / 's2a_caps.tsv').write_text('fps60\t1\n')
        (self.root / 's2a_caps.all.tsv').write_text('widen\t1\n')
        result = self.entry(False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('缺失', result.stdout + result.stderr)

    def test_all_caps_does_not_borrow_release_bypass(self):
        (self.root / 's2a_caps.tsv').write_text('widen\t1\n')
        (self.root / 's2a_caps.all.tsv').write_text('fps60\t1\n')
        result = self.entry(False, all_caps=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('缺失', result.stdout + result.stderr)

    def entry(self, app_only, all_caps=False):
        if sys.platform != "darwin":
            self.skipTest("真实 IPA 入口需要 macOS / Xcode；只读身份校验仍运行")
        tree = snapshot_tree()
        env = dict(os.environ, S2A_ROOTS=str(self.root.parent),
                   S2A_ROOTS_SHARED=str(self.base / 'shared'), S2A_ROOTS_NO_BOOT='1',
                   S2A_PACK_LOCKS=str(self.base / 'locks'), S2A_WIDEN_DIR=str(self.table.parent),
                   S2A_WIDEN_AUTO_RUN='0', S2A_SIGN='adhoc', S2A_DUAL='0',
                   S2A_DISK_GC='0',
                   S2A_RUN_ROOT=str(self.base / 'run'), S2A_ALL_CAPS='0')
        # Xcode 不在这里给缺省：外面设了 S2A_DEVELOPER_DIR 随 os.environ 带进去；没设交给 tools/toolchain.sh 统一解析（装着的最新 Xcode → xcode-select），
        #   原先写死 /Applications/Xcode.app，只装了带版本号 Xcode 的机器（如 Xcode-27.1.app）入车预检必红「目录不在」
        for name in ['S2A_BUNDLE_ID', 'S2A_DISPLAY_NAME', 'S2A_DISPLAY_SUFFIX', 'S2A_SAVE_IDENTITY', 'IOS_VAMM_LAYOUT', 'CFLAGS']:
            env.pop(name, None)
        if app_only:
            env['S2A_APP_ONLY_FROM'] = str(self.root)
        else:
            env.pop('S2A_APP_ONLY_FROM', None)
            env['S2A_REFRESHED'] = self.root.name
            commit = subprocess.check_output(['git', 'rev-parse', '--short=9', 'HEAD'], cwd=tree, text=True).strip()
            key = subprocess.check_output(['bash', '-c', 'source "$1"; ipa_pkg_key "$2" "$3" "$4"', '_',   # 与 ipa.sh 同参：带款名（随包表 / 图标进包键）
                                           str(tree / 'pack/ipa_key.sh'), commit + ' sign=adhoc dn=Fixture Game S2Arm 实验' + (' allcaps' if all_caps else ''), str(self.root), 'fixture'], env=env, text=True)
            (self.root / '.stage_pkg').write_text(key)
        command = ['bash', str(tree / 'pack/ipa.sh'), 'fixture']
        if all_caps:
            command.append('--all-caps')
        return self.run_until_gate(command, tree, env)

    def run_until_gate(self, command, tree, env):
        """跑 ipa.sh 到它自己出结论；一旦过了宽屏验证闸、开始出新包就停掉整组进程——这些用例只测闸前，回归时不在这里真编 iOS。
        「过了闸」认 ipa.sh 闸后、编译前第一件事（graphics/widen/scan/auto_pkg.sh copy 往出包根拷宽屏表）打的「宽屏表进包」行：
        只出程序与正常出包两条路都先走它。原先靠 30 秒墙钟上限兜底：满载时闸前那段（工具链 / 核数 / 算包键）本身就跑过 30 秒，
        假红（11-02 合入线：gate-host 全套 --all-caps 用例 TimeoutExpired）。按事件停，与负载无关"""
        out_path, err_path = self.base / 'ipa.out', self.base / 'ipa.err'
        with open(out_path, 'w') as out, open(err_path, 'w') as err:
            proc = subprocess.Popen(command, cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    text=True, start_new_session=True)
        stopped = False
        while True:
            try:
                proc.wait(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                if not stopped and '宽屏表进包' in out_path.read_text(errors='replace'):
                    stopped = True
                    # 进程组只经 safe_killpg 发信号（门禁 killpg_lint_test）；本测试进程不是 bash 助手的后代，按组长命令行字样认组
                    subprocess.run(['/bin/bash', '-c', 'source "$1"; safe_killpg KILL "$2" "$3"', '_',
                                    str(REPO / 'tools/safe_killpg.sh'), str(proc.pid), 'pack/ipa.sh'], check=False)
        out, err = out_path.read_text(errors='replace'), err_path.read_text(errors='replace')
        if stopped:
            err += '\n（单测：ipa.sh 过了宽屏验证闸、开始出新包，已停）'
        return subprocess.CompletedProcess(command, proc.returncode, out, err)

    def test_app_only_missing_marker(self):
        result = self.entry(True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('宽屏验证标记', result.stdout + result.stderr)
        self.assertIn('缺失', result.stdout + result.stderr)

    def test_cached_package_missing_marker(self):
        result = self.entry(False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('宽屏验证标记', result.stdout + result.stderr)
        self.assertNotIn('现行已是包', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
