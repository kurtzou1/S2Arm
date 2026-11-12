#!/usr/bin/env python3
"""Windows 一键出包（pack/orch/oneclick_win.py）与选款模块（pack/source_pick.py）单测：python3 tests/oneclick_win_test.py
期望按规则写（不跑被测实现推）：
  ① 选款：一个本体 + 更新 + DLC → 程序号、取最新更新的显示版本、选中这三个文件；两个本体大小悬殊（≥4 倍）→ 认大的、黄字点名小的；
     差不多大 → 退 1 报红；32 位 → 退 1；S2A_WANT_TID 指定不在其中 → 退 1
  ② 环境自检：--check 一行一项；缺件时退 75、该项打 ❌（这里用不存在的字体目录造缺件）；glslangValidator 版本 = glslang/build.sh 钉的才 ✅（假程序报 16.6.0 / 16.5.0 / 不在 PATH）
  ③ 工作根：不要求现行版本有旧 shaders/；只在 shaders/direct 联接本次直连库，不带旧通用着色器；早期包允许没有直连库
  ④ 播种 / 轻阶段带 S2A_SEED_AOC=1（Switch 2 导出的 DLC 只在解包目录里；11-05 Windows 出包机金刚漏播）
  ⑤ 子步骤退出码：3（内容缺口）/ 75（环境缺件，如 gamedec 编不出）原样上交，其余非 0 一律 1
  ⑥ --events（契约同 Mac 一键出包）：--from-extract 一个合成解包目录、各步打桩 → 每步一对 stage / stage_end（k 递增、ok 真）；最后一条 result：ok、ipa、pack、files（资源包文件数 2）、
     build_id / graphics_mode 取 IPA 的 Info.plist、aoc_missing 取产物根 aoc.log「追加内容缺」行；pack/jobs/ipa.py oneclick_result() 读到同一条
  ⑦ --from-extract 目录缺 unpack.tsv → 退 1、result ok 假、msg 点名，不调解包
  ⑧ 某步退 3（内容缺口）→ 该步 stage_end ok 假、result ok 假、退 3
  ⑨ 签名装机（pack/orch/install_win.py）：同一台手机 USB 与 Wi-Fi 都在 → 取 USB 的设备编号；找不到 plumesign → 退 75；
     假 plumesign 打「Installation complete」并按 -o 写出包名 a.b.TEAM 的 ipa → 推资源包用 a.b.TEAM、参数里 --udid 是设备编号不是 UDID；
     ⑨c 出包重叠：带 --install 时轻阶段后起早装、正式 ipa 出完先等早装再正式装（事件 early）；早装失败照常正式装；
         早装线程出不含着色器库的早期包（工作根不联直连库），结果带包名与文件数
     --install 的包 ipa 收尾传后缀 Win（显示名「… S2Arm Win」），不带 --install 传空；
     假 plumesign 打 -80046 退 1 → 共用错误码 login_identity_rejected、不推包
  ⑩ 推包：规则搬到两端共用的 tools/push_pack.py，单测在 tests/push_pack_test.py（11-06 合一；下面两行是原口径，仍由那边核）：
     机上待解批按完整性分：推到一半的盖掉，推完整的留着、其中文件（.pushed）不重推；没有待解批时 .pushed 不算数；机上 .incoming 有 <时刻>_<序号>.tar 残留 → 逐个用 1024 字节全零同名包覆盖、别的名字不碰；
     盖过残留或 unpack.log 末行是截短包 → 不认机上 index.tsv（上次推上去、没落地），按已应用索引（没有 = 全推）
反证：选款逻辑内嵌在 oneclick.sh 时没有 pack/source_pick.py（① 全红）。"""
import contextlib, json, os, re, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
from pack.orch import oneclick_win, install_win   # noqa: E402


def pkg(t, base, name, ver=0, isa='aarch64', size=1, disp='1.0'):
    return {'type': t, 'baseId': base, 'name': name, 'version': ver, 'guestIsa': isa, 'contentBytes': size, 'display': disp}


def pick(rows, want=''):
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, 'idx'), 'w') as idx:
            for i, (f, packages) in enumerate(rows, 1):
                idx.write(f'{i}\t{f}\n'); Path(d, f'i{i}.json').write_text(json.dumps({'packages': packages}))
        p = subprocess.run([sys.executable, str(R / 'pack/source_pick.py'), d], capture_output=True, text=True, env=dict(os.environ, S2A_WANT_TID=want))
    return p.returncode, p.stdout.splitlines(), p.stderr


class Pick(unittest.TestCase):
    def test_base_update_dlc(self):
        rc, out, _ = pick([('/g/b.xci', [pkg('base', 'A' * 16, 'Game', size=10)]), ('/g/u.nsp', [pkg('update', 'A' * 16, 'Game', ver=65536, disp='1.2')]),
                           ('/g/d.nsp', [pkg('dlc', 'A' * 16, 'Game')])])
        self.assertEqual(rc, 0); self.assertEqual(out[:3], ['A' * 16, 'Game', '1.2']); self.assertEqual(sorted(out[4:]), ['/g/b.xci', '/g/d.nsp', '/g/u.nsp'])

    def test_two_bases(self):
        rc, out, err = pick([('/g/big.xci', [pkg('base', 'A' * 16, 'Main', size=100)]), ('/g/tool.nsp', [pkg('base', 'B' * 16, 'Tool', size=10)])])
        self.assertEqual((rc, out[0]), (0, 'A' * 16)); self.assertIn('Tool', err)
        rc, _, err = pick([('/g/a.xci', [pkg('base', 'A' * 16, 'A', size=10)]), ('/g/b.xci', [pkg('base', 'B' * 16, 'B', size=9)])])
        self.assertEqual(rc, 1); self.assertIn('--title-id', err)
        rc, out, _ = pick([('/g/a.xci', [pkg('base', 'A' * 16, 'A', size=10)]), ('/g/b.xci', [pkg('base', 'B' * 16, 'B', size=9)])], want='B' * 16)
        self.assertEqual((rc, out[0]), (0, 'B' * 16))

    def test_refuse(self):
        self.assertEqual(pick([('/g/a.xci', [pkg('base', 'A' * 16, 'A', isa='aarch32')])])[0], 1)
        self.assertEqual(pick([('/g/a.xci', [pkg('base', 'A' * 16, 'A')])], want='C' * 16)[0], 1)


class Check(unittest.TestCase):
    def test_missing_fonts_is_75(self):
        env = dict(os.environ, S2A_FONTS='/nonexistent/fonts', PYTHONUTF8='1')
        p = subprocess.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.oneclick_win', '--check', '--target', 'mac'], cwd=R, capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 75)
        self.assertIn('❌ fonts', p.stdout)
        self.assertGreaterEqual(len([l for l in p.stdout.splitlines() if l[:1] in '✅❌']), 9)

    def test_glslang_version(self):
        want = re.search(r'^VER=([^;\s]+)', (R / 'graphics/third_party/glslang/build.sh').read_text(encoding='utf-8'), re.M).group(1)
        self.assertEqual(want, '16.6.0')   # 手写期望：Mac Homebrew glslangValidator 11-05 是 16.6.0
        with tempfile.TemporaryDirectory() as d:
            for ver, ok in (('16.6.0', True), ('16.5.0', False), (None, False)):
                b = Path(d, ver or 'none'); b.mkdir()
                if ver:
                    f = b / 'glslangValidator'; f.write_text(f'#!/bin/sh\necho "Glslang Version: 11:{ver}"\n'); f.chmod(0o755)
                env = dict(os.environ, PATH=f'{b}:/usr/bin:/bin', PYTHONUTF8='1')
                p = subprocess.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.oneclick_win', '--check', '--target', 'mac'], cwd=R, capture_output=True, text=True, env=env)
                line = [l for l in p.stdout.splitlines() if l[2:].startswith('glslang：')]
                self.assertEqual([l[:1] for l in line], ['✅' if ok else '❌'], f'{ver}：{line}')

    def test_zstd_cli_version(self):   # 布局阶段钉 1.5.7（手写期望，同 Mac Homebrew）：假 zstd 报 1.5.7 → ✅、1.5.6 → ❌（11-05 Windows 出包机 ARMS 轻阶段才报缺）
        with tempfile.TemporaryDirectory() as d:
            for ver, ok in (('1.5.7', True), ('1.5.6', False)):
                b = Path(d, ver); b.mkdir(); f = b / 'zstd'
                f.write_text(f'#!/bin/sh\necho "*** Zstandard CLI (64-bit) v{ver}, by Yann Collet ***"\n'); f.chmod(0o755)
                env = dict(os.environ, PATH=f'{b}:/usr/bin:/bin', PYTHONUTF8='1')
                p = subprocess.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.oneclick_win', '--check', '--target', 'mac'], cwd=R, capture_output=True, text=True, env=env)
                line = [l for l in p.stdout.splitlines() if l[2:].startswith('zstd-cli：')]
                self.assertEqual([l[:1] for l in line], ['✅' if ok else '❌'], f'{ver}：{line}')


class MetalPath(unittest.TestCase):
    """#120：目录选择与编译子进程必须一致；工具是原创合成脚本，不编游戏。"""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='metal 中文 空格 ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / 'PATH 工具'
        self.tools.mkdir()
        for tool in ('metal', 'metallib'):
            path = self.tools / (tool + '.exe')
            path.write_text(f'#!/bin/sh\nprintf "%s\\n" "fixture {tool}"\n', encoding='utf-8')
            path.chmod(0o755)
        decoy = self.root / 'other-install'
        decoy.mkdir()
        (decoy / 'metallib.exe').write_text('#!/bin/sh\nexit 99\n', encoding='utf-8')
        (decoy / 'metallib.exe').chmod(0o755)
        env = patch.dict(os.environ, {'PATH': os.pathsep.join((str(decoy), str(self.tools))), 'PATHEXT': '.EXE'}, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def test_bin_from_path(self):
        self.assertEqual(oneclick_win.metal_bin(), self.tools)

    def test_relative_path_is_fixed_before_changing_working_directory(self):
        with contextlib.chdir(self.root), patch.dict(os.environ, {'PATH': self.tools.name}):
            self.assertEqual(oneclick_win.metal_bin(), self.tools)

    def test_explicit_bin_wins_path(self):
        explicit = self.root / '显式目录'
        with patch.dict(os.environ, {'S2A_METAL_BIN': str(explicit)}):
            self.assertEqual(oneclick_win.metal_bin(), explicit)

    def test_player_path_wins_bundled_job_path(self):
        # 随包 s2arm_env.cmd 把作业 PATH 换成只含随包工具、换前存进 S2A_USER_PATH（11-09 Windows 出包机：只设 PATH 的自定义安装在启动器里被忽略）
        bundled = self.root / '随包运行时'; bundled.mkdir()
        with patch.dict(os.environ, {'PATH': str(bundled), 'S2A_USER_PATH': str(self.tools)}):
            self.assertEqual(oneclick_win.metal_bin(), self.tools)

    def test_given_environ_is_used_instead_of_process_env(self):
        # 作业层在父进程按玩家环境选（core.win_metal_dir），不读当前进程环境
        explicit = self.root / '玩家显式目录'
        with patch.dict(os.environ, {'S2A_METAL_BIN': str(self.root / '进程里的')}):
            self.assertEqual(oneclick_win.metal_exe({'S2A_METAL_BIN': str(explicit)}).parent, explicit)
            self.assertEqual(oneclick_win.metal_exe({'PATH': '', 'S2A_USER_PATH': str(self.tools)}).parent, self.tools)

    def test_no_tools_uses_official_default(self):
        with patch.dict(os.environ, {'PATH': ''}):
            self.assertEqual(oneclick_win.metal_bin(), Path(r'C:\Program Files\Metal Developer Tools\bin'))

    def test_path_directory_is_not_a_compiler(self):
        (self.tools / 'metal.exe').unlink()
        (self.tools / 'metal.exe').mkdir()
        self.assertEqual(oneclick_win.metal_bin(), Path(r'C:\Program Files\Metal Developer Tools\bin'))

    def test_env_items_reports_path_install(self):
        with patch.object(oneclick_win, 'WIN', True):
            item = next(row for row in oneclick_win.env_items('mac', None) if row[0] == 'metal')
        self.assertTrue(item[1], item[2])
        self.assertIn(str(self.tools), item[2])

    @unittest.skipIf(os.name == 'nt', '合成 .exe 为 POSIX 脚本；Windows 原生编译未覆盖')
    def test_direct_exports_selected_directory_to_both_tools(self):
        repo = self.root / 'repo'
        script = repo / 'graphics/tools/direct/direct_lib.sh'
        script.parent.mkdir(parents=True)
        script.write_text('''set -eu
: "${S2A_METAL_BIN:?S2A_METAL_BIN missing from build environment}"
test "$S2A_METAL_BIN" = "$S2A_EXPECT_METAL_BIN"
"$S2A_METAL_BIN/metal.exe" --version
"$S2A_METAL_BIN/metallib.exe" --version
''', encoding='utf-8')
        explicit = self.root / '显式安装'
        explicit.mkdir()
        for tool in ('metal', 'metallib'):
            path = explicit / (tool + '.exe')
            path.write_text(f'#!/bin/sh\nprintf "%s\\n" "explicit {tool}"\n', encoding='utf-8')
            path.chmod(0o755)
        cur = self.root / 'cur'
        cur.mkdir()
        for source, selected, label in (('path', self.tools, 'fixture'), ('explicit', explicit, 'explicit')):
            with self.subTest(source=source), patch.dict(os.environ, {
                'S2A_EXPECT_METAL_BIN': str(selected),
                **({'S2A_METAL_BIN': str(explicit)} if source == 'explicit' else {}),
            }), patch.object(oneclick_win, 'R', repo), patch.object(oneclick_win, 'WIN', True), \
                 patch.object(oneclick_win, 'prebuilt', return_value=self.root / 'unused.dll'), \
                 patch.object(oneclick_win, 'bash_exe', return_value='/bin/sh'):
                run = oneclick_win.Run(self.root / source)
                try:
                    oneclick_win.direct(run, cur, 'ios', 1)
                    self.assertEqual((run.out / 'direct_lib.log').read_text().splitlines(),
                                     [f'{label} metal', f'{label} metallib'])
                finally:
                    run.timing.close()
        self.assertNotIn('S2A_METAL_BIN', os.environ, '目录只传给本次编译，不改调用者环境')

    @unittest.skipIf(os.name == 'nt', 'Mac 子进程环境回归仅在 POSIX 宿主运行')
    def test_mac_does_not_export_windows_directory(self):
        repo = self.root / 'mac-repo'
        script = repo / 'graphics/tools/direct/direct_lib.sh'
        script.parent.mkdir(parents=True)
        script.write_text('test "${S2A_METAL_BIN+set}" != set\n', encoding='utf-8')
        cur = self.root / 'cur'
        cur.mkdir()
        with patch.object(oneclick_win, 'R', repo), patch.object(oneclick_win, 'WIN', False), \
             patch.object(oneclick_win, 'prebuilt', return_value=None), \
             patch.object(oneclick_win, 'bash_exe', return_value='/bin/sh'):
            run = oneclick_win.Run(self.root / 'mac-out')
            try:
                oneclick_win.direct(run, cur, 'mac', 1)
            finally:
                run.timing.close()


class StepRc(unittest.TestCase):
    def test_passthrough(self):
        with tempfile.TemporaryDirectory() as d:
            run = oneclick_win.Run(d)
            for rc, want in ((75, 75), (3, 3), (2, 1), (1, 1)):
                with self.assertRaises(oneclick_win.Fail) as e:
                    run.sh([sys.executable, '-c', f'import sys; print("桩"); sys.exit({rc})'], 'x.log')
                self.assertEqual(e.exception.code, want, f'子步骤退 {rc}')
            run.timing.close()


class LogReason(unittest.TestCase):
    # #754：子步骤失败时原因以 Python 异常那一行开头、保住它；后面的附注（清理也失败）放得下就带上。原先取末 3 行末 300 字，附注把原异常挤掉
    def test_exception_line_kept_before_notes(self):
        tb = ('Traceback (most recent call last):\n  File "x.py", line 1, in <module>\n'
              "OSError: [WinError 145] 目录不是空的。: 'C:\\w\\v.tmp\\.romfs.intern\\arc'\n"
              + ''.join(f"（随后的清理 rename_dir(a, b) 也失败：FileExistsError(17, '当文件已存在时，无法创建该文件。')；以上面的原错误为准）\n" for _ in range(3)))
        got = oneclick_win.log_reason(tb)
        self.assertTrue(got.startswith("OSError: [WinError 145] 目录不是空的。"), got)
        self.assertIn("也失败：FileExistsError", got)

    def test_no_exception_keeps_last_three_lines(self):
        self.assertEqual(oneclick_win.log_reason("a\nb\nc\nd\n"), "b / c / d")


class Product(unittest.TestCase):
    def test_links_not_copies(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); cur = t / 'ver'; (cur / 'romfs').mkdir(parents=True)
            (cur / 'pkg').mkdir(); (cur / 'romfs/a.bin').write_bytes(b'x'); (cur / 'aoc.tsv').write_text('1\n'); dl = t / 'dlib'; dl.mkdir()
            run = oneclick_win.Run(t / 'out')
            try: w = oneclick_win.product(run, cur, dl)
            finally: run.timing.close()
            self.assertTrue(os.path.islink(w / 'romfs') or os.path.isjunction(w / 'romfs'))
            self.assertEqual(os.path.realpath(w / 'shaders/direct'), os.path.realpath(dl))
            self.assertEqual(sorted(p.name for p in (w / 'shaders').iterdir()), ['direct'])
            self.assertFalse((w / 'pkg').exists()); self.assertEqual((w / 'aoc.tsv').read_text(), '1\n')
            self.assertEqual((w / 'romfs/a.bin').read_bytes(), b'x')

    def test_stale_generic_shaders_not_shipped(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); cur = t / 'ver'; (cur / 'shaders/gal').mkdir(parents=True)
            (cur / 'shaders/direct').mkdir(); (cur / 'shaders/old.bin').write_bytes(b'legacy')
            dl = t / 'dlib'; dl.mkdir(); (dl / 'lib.idx').write_bytes(b'direct')
            run = oneclick_win.Run(t / 'out')
            try: w = oneclick_win.product(run, cur, dl)
            finally: run.timing.close()
            self.assertEqual(sorted(p.name for p in (w / 'shaders').iterdir()), ['direct'])
            self.assertEqual((w / 'shaders/direct/lib.idx').read_bytes(), b'direct')
            self.assertTrue((cur / 'shaders/old.bin').is_file())

    def test_early_product_without_shader_directory(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); cur = t / 'ver'; (cur / 'exefs').mkdir(parents=True)
            (cur / 'exefs/main').write_bytes(b'synthetic')
            run = oneclick_win.Run(t / 'out')
            try: w = oneclick_win.product(run, cur, None)
            finally: run.timing.close()
            self.assertEqual(list((w / 'shaders').iterdir()), [])
            self.assertEqual((w / 'exefs/main').read_bytes(), b'synthetic')


class MultiProgram(unittest.TestCase):   # 多程序合集（11-06 索尼克×夏特 世代重启 ExecuteProgram(1)）：序号 1..n-1 各走完整出包、组到 <工作根>/programs/<序号>
    #   期望手写：支数 2 + Mac 目标 → 解包序号 [0, 1]、款 [t…000, t…001]、直连库输出 [direct, direct_p1]、第 2 次组根落 product/programs/1；
    #   单程序（unpack.tsv 没有 programs 行）→ 只解序号 0；iOS 目标 → 同 Mac 出全部序号、到出 ipa 为止、不打【红】
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.calls = []
        self.saved = {n: getattr(oneclick_win, n) for n in ('env_items', 'unpack', 'host_decoder_gate', 'glslc_gate', 'stages', 'direct', 'product', 'ipa')}
        oneclick_win.env_items = lambda target, shell: [('python', True, '')]
        def unpack(run, sources, title_id, program_index=0):
            self.calls.append(('unpack', program_index)); x = self.t / f'x{program_index}'; x.mkdir(exist_ok=True)
            (x / 'unpack.tsv').write_text(f'title_id\t0100abcd0000000{program_index}\n' + (self.multi if program_index == 0 else ''), encoding='utf-8')
            return x, f'0100ABCD0000000{program_index}', self.t / 'src'
        oneclick_win.unpack = unpack
        oneclick_win.host_decoder_gate = lambda run, x: None; oneclick_win.glslc_gate = lambda run, x: None
        def stages(run, game, x, src, own=False): self.calls.append(('stages', game)); return self.t / game
        oneclick_win.stages = stages
        def direct(run, cur, target, jobs, tid=None, name='direct'): self.calls.append(('direct', name)); return self.t / name
        oneclick_win.direct = direct
        def product(run, cur, dlib, w=None):
            w = w or self.t / 'out/pkg/product'; w.mkdir(parents=True, exist_ok=True); self.calls.append(('product', os.path.relpath(w, self.t / 'out/pkg'))); return w
        oneclick_win.product = product
        oneclick_win.ipa = lambda run, w, game, shell, bundle_id, suffix='': (_ for _ in ()).throw(AssertionError('Mac 目标不该出 ipa'))
    def tearDown(self):
        for n, f in self.saved.items(): setattr(oneclick_win, n, f)
    def test_mac_two_programs(self):
        self.multi = 'programs\t2\nprogram_index\t0\n'
        rc = oneclick_win.main(['src', '--out', str(self.t / 'out'), '--target', 'mac'])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls, [('unpack', 0), ('stages', 't0100abcd00000000'), ('direct', 'direct'), ('product', 'product'),
                                      ('unpack', 1), ('stages', 't0100abcd00000001'), ('direct', 'direct_p1'), ('product', os.path.join('product', 'programs', '1'))])
    def test_single_program(self):
        self.multi = ''
        rc = oneclick_win.main(['src', '--out', str(self.t / 'out'), '--target', 'mac'])
        self.assertEqual(rc, 0); self.assertEqual([c for c in self.calls if c[0] == 'unpack'], [('unpack', 0)])
    def test_ios_all_programs(self):   # 11-06 维护者：iPhone 是主平台，iOS 包同 Mac 带全部序号（外置镜像包 p<n>/、App programs/<n>/、资源包 programs/<n>/ 由 ship_ext / pkg_srcs 组）
        self.multi = 'programs\t2\nprogram_index\t0\n'
        oneclick_win.ipa = lambda run, w, game, shell, bundle_id, suffix='': (_ for _ in ()).throw(RuntimeError('到 ipa 为止'))
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), self.assertRaises(RuntimeError): oneclick_win.main(['src', '--out', str(self.t / 'out'), '--target', 'ios'])
        self.assertEqual([c for c in self.calls if c[0] in ('unpack', 'direct', 'product')],
                         [('unpack', 0), ('direct', 'direct'), ('product', 'product'), ('unpack', 1), ('direct', 'direct_p1'), ('product', os.path.join('product', 'programs', '1'))])
        self.assertNotIn('【红】多程序合集', buf.getvalue())
    def from_extract_run(self, argv):   # 共用解包目录（作业层 --from-extract）里只有序号 0
        x0 = self.t / 'shared'; x0.mkdir(exist_ok=True)
        (x0 / 'unpack.tsv').write_text('title_id\t0100abcd00000000\nprograms\t2\nprogram_index\t0\n', encoding='utf-8')
        saved, seen = oneclick_win.from_extract, {}
        oneclick_win.from_extract = lambda run, d: (x0, '0100ABCD00000000', self.t / 'nosrc')
        real_unpack = oneclick_win.unpack
        def unpack(run, sources, title_id, program_index=0): seen[program_index] = (list(sources), title_id); return real_unpack(run, sources, title_id, program_index)
        oneclick_win.unpack = unpack
        import io, contextlib
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf): rc = oneclick_win.main(['--from-extract', str(x0), '--out', str(self.t / 'out'), '--target', 'mac', *argv])
        finally: oneclick_win.from_extract = saved
        return rc, seen, buf.getvalue()
    def test_from_extract_with_sources(self):   # #613：作业层把原件跟在 --from-extract 后面给 → 序号 1 从这些原件解（期望手写：序号 1 收到给的原件与游戏号、不打【红】）
        rc, seen, out = self.from_extract_run(['--title-id', '0100ABCD00000000', 'a.xci', 'b.nsp'])
        self.assertEqual((rc, seen), (0, {1: (['a.xci', 'b.nsp'], '0100ABCD00000000')}))
        self.assertNotIn('【红】', out)
    def test_from_extract_without_sources(self):   # 没给原件：照旧报红说清缺什么，不解
        rc, seen, out = self.from_extract_run([])
        self.assertNotEqual(rc, 0); self.assertEqual(seen, {}); self.assertIn('原件没一起给', out)

class SeedAoc(unittest.TestCase):   # ④ 播种与轻阶段带 S2A_SEED_AOC=1（同 oneclick.sh 私有产物根）：Switch 2 导出的 DLC 只在解包目录里
    def test_seed_env(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); run = oneclick_win.Run(t / 'out'); seen = {}
            def sh(args, log, env=None, ok=(0,), cwd=None): seen[log] = ((env or {}).get('S2A_SEED_AOC'), (env or {}).get('S2A_NX_UNPACK')); return 0
            run.sh = sh
            (t / 'out/roots').mkdir(parents=True); (t / 'ver').mkdir(); os.symlink(t / 'ver', t / 'out/roots/tx@现行')
            tool = t / 'out/bin/nx_unpack_abc/nx_unpack.exe'
            with patch.object(oneclick_win, "nx_unpack", lambda r: tool):
                oneclick_win.stages(run, 'tx', t / 'x', t / 'src')
            # ⑤ 轻阶段（追加内容解包 stages._nxu）拿本单选定的同一份 nx_unpack（11-09 Windows 出包机：两处各认各的 bin 目录，身份一变轻阶段退 75）
            self.assertEqual(seen.get('seed.log'), ('1', str(tool))); self.assertEqual(seen.get('light.log'), ('1', str(tool)))


class Events(unittest.TestCase):   # ⑥ ⑦ ⑧ 机器读事件流与 --from-extract（满屏补丁线启动器后端 pack/jobs/ipa.py 直接读 result）
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); x = self.t / 'ex'; (x / 'exefs').mkdir(parents=True); (x / 'exefs/main').write_bytes(b'm')
        (x / 'unpack.tsv').write_text('title_id\t0100abcd00000000\n'); self.x = x
        cur = self.t / 'cur'; cur.mkdir(); (cur / 'aoc.log').write_text('追加内容缺\tdlc 乙.nsp\n追加内容缺\t\n其它\tx\n', encoding='utf-8'); self.cur = cur
        self.saved = {n: getattr(oneclick_win, n) for n in ('env_items', 'unpack', 'host_decoder_gate', 'stages', 'direct', 'product', 'ipa')}
        oneclick_win.env_items = lambda target, shell: [('python', True, '')]
        oneclick_win.unpack = lambda *a: self.fail('--from-extract 不该调解包')
        oneclick_win.host_decoder_gate = lambda run, x: run.step('判游戏解码器', lambda: None)
        self.own = []   # 播种搬不搬 RomFS（11-06）：--from-extract 是别人的目录，必须 own=False
        oneclick_win.stages = lambda run, game, x, src, own=False: (self.own.append(own), run.step('八个轻阶段', lambda: self.cur))[1]
        oneclick_win.direct = lambda run, cur, target, jobs, tid=None, name='direct': run.step('抽取 + 直连库', lambda: self.t / 'dlib')
        def product(run, cur, dlib, w=None):
            w = self.t / 'w'; (w / 'pkg/pack/sub').mkdir(parents=True, exist_ok=True); (w / 'pkg/pack/a.pak').write_bytes(b'1'); (w / 'pkg/pack/sub/b.pak').write_bytes(b'2'); return w
        oneclick_win.product = product
        def ipa(run, w, game, shell, bundle_id, suffix=''):
            import plistlib, zipfile
            self.suffix = suffix
            p = w / 'pkg' / f'{game}.ipa'
            with zipfile.ZipFile(p, 'w') as z: z.writestr('Payload/S2Arm.app/Info.plist', plistlib.dumps({'S2ABuildID': 'abc-12345678', 'S2AGraphicsMode': 'direct'}))
            return run.step('ipa 收尾', lambda: (p, '测试游戏'))
        oneclick_win.ipa = ipa
    def tearDown(self):
        for n, f in self.saved.items(): setattr(oneclick_win, n, f)
    def evs(self, f): return [json.loads(l) for l in open(f, encoding='utf-8')]
    def test_events_ok(self):
        ef = self.t / 'ev.jsonl'
        rc = oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'out'), '--events', str(ef)])
        e = self.evs(ef); st = [x for x in e if x['ev'] == 'stage']; en = [x for x in e if x['ev'] == 'stage_end']; r = e[-1]
        self.assertEqual(rc, 0)
        self.assertEqual([x['name'] for x in st], ['判游戏解码器', '八个轻阶段', '抽取 + 直连库', '组工作根', 'ipa 收尾'][:len(st)] if oneclick_win.WIN else ['八个轻阶段', '抽取 + 直连库', '组工作根', 'ipa 收尾'])
        self.assertEqual([x['k'] for x in st], list(range(1, len(st) + 1))); self.assertTrue(all(x['ok'] for x in en)); self.assertEqual(len(st), len(en))
        self.assertTrue(all('t' in x for x in e))
        self.assertEqual((r['ev'], r['ok'], r['ipa'], r['pack'], r['files'], r['build_id'], r['graphics_mode'], r['aoc_missing']),
                         ('result', True, str(self.t / 'w/pkg/t0100abcd00000000.ipa'), str(self.t / 'w/pkg/pack'), 2, 'abc-12345678', 'direct', ['dlc 乙.nsp']))
        self.assertNotIn('graphics_reason', r)   # 只有直连（11-07）：不再有「仅通用」的原因
        sys.path.insert(0, str(R / 'pack/jobs')); import ipa as jobs_ipa
        self.assertEqual(jobs_ipa.oneclick_result(str(ef)), r)
        self.assertEqual(self.own, [False])   # --from-extract：别人的解包目录，播种不搬 RomFS
    def test_suffix(self):   # ⑨b 纯 Windows 签装（--install）的包桌面名缺省带「Win」；不签装（Windows 出包机替 Mac 出）不带；--suffix 显式给照给
        saved = oneclick_win.install; oneclick_win.install = lambda run, a, p, pk: None
        class NoEarly:
            def __init__(s, *a): pass
            def start(s): return s
            def finish(s): return ({'files': 0, 'elapsed': 0}, None)
        se = oneclick_win.Early; oneclick_win.Early = NoEarly
        try:
            oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'o1')]); self.assertEqual(self.suffix, '')
            oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'o2'), '--install', 'U1']); self.assertEqual(self.suffix, 'Win')
            oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'o3'), '--install', 'U1', '--suffix', '']); self.assertEqual(self.suffix, '')
        finally: oneclick_win.install = saved; oneclick_win.Early = se
    def test_early_wiring(self):
        order = []
        class FakeEarly:
            def __init__(s, run, a, cur, game): order.append(('early_new', game))
            def start(s): order.append('early_start'); return s
            def finish(s): order.append('early_finish'); return (dict(bundle_id='b.T', files=7, elapsed=3), None)
        saved = oneclick_win.Early, oneclick_win.install
        oneclick_win.Early = FakeEarly; oneclick_win.install = lambda run, a, p, pk: order.append('install')
        try:
            ef = self.t / 'ev_early.jsonl'
            rc = oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'oe'), '--install', 'U1', '--events', str(ef)])
        finally: oneclick_win.Early, oneclick_win.install = saved
        self.assertEqual(rc, 0)
        self.assertEqual(order, [('early_new', 't0100abcd00000000'), 'early_start', 'early_finish', 'install'])
        self.assertTrue(any(e['ev'] == 'early' and e['ok'] and e['files'] == 7 for e in self.evs(ef)))

    def test_early_fail_still_installs(self):
        order = []
        class FakeEarly:
            def __init__(s, *a): pass
            def start(s): return s
            def finish(s): return ({}, 'RuntimeError: 早期包没出成')
        saved = oneclick_win.Early, oneclick_win.install
        oneclick_win.Early = FakeEarly; oneclick_win.install = lambda run, a, p, pk: order.append('install')
        try: rc = oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'of'), '--install', 'U1'])
        finally: oneclick_win.Early, oneclick_win.install = saved
        self.assertEqual((rc, order), (0, ['install']))

    def test_early_thread_builds_without_direct(self):
        import argparse as ap
        from pack.orch import install_win
        seen = {}
        cur = self.t / 'cur2'; (cur / 'shaders' / 'direct').mkdir(parents=True); (cur / 'exefs').mkdir(); (cur / 'shaders' / 'x.bin').write_bytes(b'1')
        def fake_sub(cmd, **kw):
            import subprocess as sp
            if 'ipa_tail.py' in ' '.join(map(str, cmd)):
                w = Path(cmd[cmd.index('--work') + 1]); seen['dual'] = kw['env'].get('S2A_DUAL'); seen['direct'] = (w / 'shaders' / 'direct').exists()
                (w / 'pkg' / 'pack').mkdir(parents=True); (w / 'pkg' / 'pack' / 'a.pak').write_bytes(b'1'); (w / 'pkg' / 't1.ipa').write_bytes(b'ipa')
                return sp.CompletedProcess(cmd, 0, '', '')
            return sp.CompletedProcess(cmd, 0, 'T', '')
        saved = oneclick_win.subprocess.run, install_win.run, oneclick_win.junction
        oneclick_win.product = self.saved['product']   # setUp 换了桩；早装要真的组根逻辑（不联直连库）
        oneclick_win.subprocess.run = fake_sub; install_win.run = lambda ns, say=None: seen.setdefault('ns', ns) and 'b.T'
        oneclick_win.junction = lambda dst, src: Path(dst).mkdir(parents=True, exist_ok=True)
        try:
            run = oneclick_win.Run(self.t / 'oe2')
            a = ap.Namespace(install='U1', name=None, plumesign=None, devpush=None, suffix=None, shell='S', bundle_id=None)
            r, e = oneclick_win.Early(run, a, cur, 't1').start().finish()
        finally: oneclick_win.subprocess.run, install_win.run, oneclick_win.junction = saved
        self.assertIsNone(e); self.assertEqual((seen['dual'], seen['direct']), (None, False))   # 早装件靠工作根不联直连库，不再借 S2A_DUAL=0（11-07 删）
        self.assertEqual((r['bundle_id'], r['files'], seen['ns'].udid), ('b.T', 1, 'U1'))

    def test_from_extract_bad(self):
        os.remove(self.x / 'unpack.tsv'); ef = self.t / 'ev.jsonl'
        rc = oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'out'), '--events', str(ef)])
        r = self.evs(ef)[-1]
        self.assertEqual((rc, r['ev'], r['ok']), (1, 'result', False)); self.assertIn('unpack.tsv', r['msg'])
    def test_step_fail(self):
        def bad(run, cur, target, jobs, tid=None): return run.step('抽取 + 直连库', lambda: (_ for _ in ()).throw(oneclick_win.Fail('直连库出不了', 3)))
        oneclick_win.direct = bad; ef = self.t / 'ev.jsonl'
        rc = oneclick_win.main(['--from-extract', str(self.x), '--out', str(self.t / 'out'), '--events', str(ef)])
        e = self.evs(ef); end = [x for x in e if x['ev'] == 'stage_end' and x['name'] == '抽取 + 直连库']
        self.assertEqual((rc, end[0]['ok'], e[-1]['ok']), (3, False, False)); self.assertIn('直连库出不了', e[-1]['msg'])

    def test_temp_follows_work_dir(self):   # 11-06：临时文件跟工作目录走，不落系统盘 Temp。走一遍主流程，在直连库那步看子进程拿到的临时目录
        seen = {}
        def peek(run, cur, target, jobs, tid=None):
            seen['env'] = os.environ.get('TMP'); seen['py'] = tempfile.gettempdir()
            seen['child'] = subprocess.run([sys.executable, '-c', 'import tempfile; print(tempfile.gettempdir())'], capture_output=True, text=True).stdout.strip()
            raise oneclick_win.Fail('停在这', 3)
        oneclick_win.direct = peek; out = self.t / 'out_tmp'
        old = {k: os.environ.get(k) for k in ('TMP', 'TEMP', 'TMPDIR')}
        try: oneclick_win.main(['--from-extract', str(self.x), '--out', str(out)])
        finally:
            for k, v in old.items(): (os.environ.__setitem__(k, v) if v is not None else os.environ.pop(k, None))
            tempfile.tempdir = None
        want = str((out / 'tmp').resolve())
        self.assertEqual((seen['env'], os.path.realpath(seen['py']), os.path.realpath(seen['child'])), (want, os.path.realpath(want), os.path.realpath(want)))

    def test_keep_system_temp(self):   # 排查开关：S2A_KEEP_SYSTEM_TEMP=1 不改环境
        old = os.environ.get('TMP'); os.environ['S2A_KEEP_SYSTEM_TEMP'] = '1'
        try: self.assertIsNone(oneclick_win.work_temp(self.t / 'k')); self.assertEqual(os.environ.get('TMP'), old)
        finally: os.environ.pop('S2A_KEEP_SYSTEM_TEMP', None)


class InstallWin(unittest.TestCase):
    def fake(self, d, body):
        f = Path(d, 'plumesign'); f.write_text('#!/usr/bin/env python3\nimport sys, zipfile\na = sys.argv[1:]\n' + body); f.chmod(0o755); return str(f)

    def ns(self, d, exe):
        import argparse
        return argparse.Namespace(ipa=str(Path(d, 'x.ipa')), pack=str(Path(d, 'pack')), udid='U1', name='N', plumesign=exe, devpush=None, full=False,
                                  log=str(Path(d, 'p.log')))

    def test_usb_first(self):
        self.assertEqual(install_win.device_id('U1', [('U1', 'Network', 7), ('U2', 'USB', 3), ('U1', 'USB', 9)]), 9)
        self.assertEqual(install_win.device_id('U1', [('U1', 'Network', 7)]), 7)
        self.assertIsNone(install_win.device_id('U3', [('U1', 'USB', 9)]))

    def test_plumesign_is_never_taken_from_desktop_or_downloads(self):
        # 11-11 审查：桌面 / 下载里叫 plumesign* 的任意程序不能被拿来执行；其他档都没有时就是找不到（发版随包那份由调用方传）
        with tempfile.TemporaryDirectory() as home:
            for d in ('Desktop', 'Downloads', os.path.join('OneDrive', 'Desktop')):
                Path(home, d).mkdir(parents=True); f = Path(home, d, 'plumesign.exe' if os.name == 'nt' else 'plumesign'); f.write_text('x'); f.chmod(0o755)
            with patch.dict(os.environ, {'HOME': home, 'USERPROFILE': home, 'PATH': '', 'S2A_PLUMESIGN': ''}), \
                 patch.object(install_win.impactor, 'status', return_value={}):
                self.assertIsNone(install_win.plumesign_path())

    def test_missing_plumesign(self):
        with tempfile.TemporaryDirectory() as d:
            old = install_win.plumesign_path; install_win.plumesign_path = lambda g=None: None
            try:
                with self.assertRaises(install_win.Fail) as c: install_win.run(self.ns(d, None), say=lambda m: None)
                self.assertEqual(c.exception.code, 75)
            finally: install_win.plumesign_path = old

    def test_inherited_rust_log_does_not_hide_completion(self):
        # #585：玩家环境里 RUST_LOG=warn → info 级的「Installation complete」被压掉，装好了也判失败。假 plumesign 按 RUST_LOG 决定打不打这行
        with tempfile.TemporaryDirectory() as d:
            exe = self.fake(d, "import os\nif os.environ.get('RUST_LOG') in ('info', 'debug', 'trace'): print('INFO Installation complete')\n")
            with patch.dict(os.environ, {'RUST_LOG': 'warn'}):
                install_win.sign_install(exe, Path(d, 'x.ipa'), 7, None, Path(d, 'p.log'), Path(d, 'o.ipa'))   # 不抛 = 判成功
            self.assertIn('Installation complete', Path(d, 'p.log').read_text(encoding='utf-8'))

    def run_fake(self, body):
        with tempfile.TemporaryDirectory() as d:
            exe = self.fake(d, body); got = {}
            olds = install_win.mux_devices, install_win.push_pack
            install_win.mux_devices = lambda: [('U1', 'USB', 42)]
            install_win.push_pack = lambda udid, bid, pack, devpush=None, full=False, say=None: got.setdefault('push', [udid, bid, pack])   # 推包规则本身在 tests/push_pack_test.py
            try:
                try: return install_win.run(self.ns(d, exe), say=lambda m: None), got, Path(d, 'p.log').read_text()
                except install_win.Fail as e: return e, got, None
            finally: install_win.mux_devices, install_win.push_pack = olds

    def test_ok(self):
        body = ("print('args', a)\nprint('Installation complete!')\nz = zipfile.ZipFile(a[a.index('-o') + 1], 'w')\n"
                "z.writestr('Payload/S2Arm.app/Info.plist', b'<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>a.b.TEAM</string></dict></plist>')\nz.close()\n")
        bid, got, log = self.run_fake(body)
        self.assertEqual(bid, 'a.b.TEAM')
        self.assertEqual(got['push'][:2], ['U1', 'a.b.TEAM'])
        self.assertIn("'--udid', '42'", log); self.assertIn("'--custom-name', 'N'", log)
        self.assertNotIn("--custom-identifier", log)   # 没给包名：照旧由 plumesign 定

    def test_given_bundle_is_passed_as_custom_identifier(self):
        # 9401：调用方定的包名（和 Mac 一致的小写团队号）原样交给 plumesign，它就不再自己接大写团队号
        body = ("print('args', a)\nprint('Installation complete!')\nz = zipfile.ZipFile(a[a.index('-o') + 1], 'w')\n"
                "z.writestr('Payload/S2Arm.app/Info.plist', b'<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>io.s2arm.games.abcde12345</string></dict></plist>')\nz.close()\n")
        old_ns = self.ns
        self.ns = lambda d, exe: __import__("argparse").Namespace(**dict(vars(old_ns(d, exe)), bundle="io.s2arm.games.abcde12345"))
        try:
            bid, got, log = self.run_fake(body)
        finally:
            self.ns = old_ns
        self.assertEqual(bid, 'io.s2arm.games.abcde12345')
        self.assertIn("'--custom-identifier', 'io.s2arm.games.abcde12345'", log)

    def test_9401_retries_once_with_the_old_uppercase_spelling(self):
        # #408：Apple 包名不分大小写。这个 Apple ID 早先（0.2.1 及以前 Windows）注册过 io.s2arm.games.<大写团队号>，本机却没记录 →
        #   小写的被拒 9401 → 换大写重试一次，成功就返回大写包名；两次输出都在日志里。假 plumesign：只收大写那个
        body = ("ident = a[a.index('--custom-identifier') + 1]\nprint('try', ident)\n"
                "if ident != 'io.s2arm.games.ABCDE12345':\n"
                "    print(\"Error: Developer API error 9401 (HTTP Some(200)): An App ID with Identifier '\" + ident + \"' is not available.\"); sys.exit(1)\n"
                "print('Installation complete!')\nz = zipfile.ZipFile(a[a.index('-o') + 1], 'w')\n"
                "z.writestr('Payload/S2Arm.app/Info.plist', ('<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>' + ident + '</string></dict></plist>').encode())\nz.close()\n")
        old_ns = self.ns
        self.ns = lambda d, exe: __import__("argparse").Namespace(**dict(vars(old_ns(d, exe)), bundle="io.s2arm.games.abcde12345"))
        try:
            bid, got, log = self.run_fake(body)
        finally:
            self.ns = old_ns
        self.assertEqual(bid, 'io.s2arm.games.ABCDE12345')
        self.assertEqual(got['push'][1], 'io.s2arm.games.ABCDE12345')
        self.assertIn('try io.s2arm.games.abcde12345', log); self.assertIn('try io.s2arm.games.ABCDE12345', log)

    def test_9401_on_both_spellings_reports_app_id_taken(self):
        body = "print(\"Error: Developer API error 9401: An App ID with Identifier 'x' is not available.\")\nsys.exit(1)\n"
        old_ns = self.ns
        self.ns = lambda d, exe: __import__("argparse").Namespace(**dict(vars(old_ns(d, exe)), bundle="io.s2arm.games.abcde12345"))
        try:
            e, got, _ = self.run_fake(body)
        finally:
            self.ns = old_ns
        self.assertIsInstance(e, install_win.Fail); self.assertEqual(e.err, 'app_id_taken'); self.assertNotIn('push', got)

    def test_already_registered_device_signs_then_installs(self):
        # #800：Windows 设备号不带横线、苹果存的带横线，plumesign 精确比较认不出已登记的这台 → 再登记被拒 35「already exists on this team」。
        #   期望（手写）：认出这句改成只签名（命令里没有 --register-and-install / --udid）、再 device --install 装签好的包，照常推资源、回包名；
        #   两段输出都在日志里。假 plumesign：带登记参数就报 35；只签名时写出 -o；device --install 打装好
        body = ("print('args', a)\n"
                "if a[0] == 'device': print('INFO Installation complete!'); sys.exit(0)\n"
                "if '--register-and-install' in a:\n"
                "    print(\"Error: Developer API error 35 (HTTP Some(200)): A device with number '00000000-0000000000000000' already exists on this team.\"); sys.exit(1)\n"
                "z = zipfile.ZipFile(a[a.index('-o') + 1], 'w')\n"
                "z.writestr('Payload/S2Arm.app/Info.plist', b'<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>a.b.TEAM</string></dict></plist>')\nz.close()\n")
        bid, got, log = self.run_fake(body)
        self.assertEqual(bid, 'a.b.TEAM')
        self.assertEqual(got['push'][:2], ['U1', 'a.b.TEAM'])
        self.assertIn('already exists on this team', log)
        self.assertIn("'device', '--udid', '42', '--install'", log)
        second = log.split('只签名再装', 1)[1]
        self.assertIn("'sign'", second); self.assertNotIn('--register-and-install', second.split("'device'")[0])

    def test_other_sign_failure_is_not_retried(self):
        body = "print('Error: Developer API error 1100: Your session has expired.')\nsys.exit(1)\n"
        e, got, _ = self.run_fake(body)
        self.assertIsInstance(e, install_win.Fail); self.assertEqual(e.err, 'apple_session_expired'); self.assertNotIn('push', got)

    def test_legacy_case_bundle(self):
        self.assertEqual(install_win.legacy_case_bundle('io.s2arm.games.abcde12345'), 'io.s2arm.games.ABCDE12345')
        for other in (None, 'io.s2arm.games.ABCDE12345', 'io.s2arm.games.0123456789', 'io.s2arm.games.abcde12345.dev', 'a.b.c'):
            self.assertIsNone(install_win.legacy_case_bundle(other))   # 已是大写 / 纯数字没有大小写之分 / 开发后缀 / 不是容器包名：不重试

    def test_login_rejected(self):
        e, got, _ = self.run_fake("print('Error: Apple rejected -80046')\nsys.exit(1)\n")
        self.assertIsInstance(e, install_win.Fail); self.assertEqual(e.err, 'login_identity_rejected'); self.assertNotIn('push', got)




class GlslcGate(unittest.TestCase):
    """要离线编 GLSLC 而 Windows 跑不了：不再退 75，设 S2A_GLSLC_RUNTIME_ONLY 让 extract.sh 跳过（运行时现编）；不需要 / 有宿主时不设（11-08 DQB2）"""
    class Run:
        def step(self, name, f): return f()
    def go(self, why, host=None):
        env = {k: v for k, v in os.environ.items() if k not in ('S2A_GLSLC_RUNTIME_ONLY', 'DM_GLSLC_HOST')}
        if host: env['DM_GLSLC_HOST'] = host
        saved = oneclick_win.glslc_need; oneclick_win.glslc_need = lambda x: why
        try:
            with patch.dict(os.environ, env, clear=True):
                oneclick_win.glslc_gate(self.Run(), Path('.'))
                return os.environ.get('S2A_GLSLC_RUNTIME_ONLY')
        finally: oneclick_win.glslc_need = saved
    def test_need_sets_runtime_only(self): self.assertEqual(self.go('subsdk0 带 glslcCompile，认出 6 支'), '1')
    def test_not_needed(self): self.assertIsNone(self.go(None))
    def test_host_given(self): self.assertIsNone(self.go('x', host='h'))


if __name__ == '__main__':
    unittest.main()
