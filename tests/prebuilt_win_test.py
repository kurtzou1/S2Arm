#!/usr/bin/env python3
"""Windows 启动器预编件（launchers/windows/bundle_prepare_win.py → S2A_PREBUILT_TOOLS）各使用方单测：python3 tests/prebuilt_win_test.py
不连Windows 出包机、不用真编译器：假预编目录 + 假可执行文件。期望按规则写：
  ① nx_unpack / gamedec（pack/orch/oneclick_win.py）：预编件在且 .src_digest = 源码身份（nx_unpack 身份按「*.cs + *.csproj 排序拼接的 sha256 前 12 位」在这里另算）
     → 直接用预编件、一次 dotnet build 都不调；身份不符 / 没设 → 照旧 dotnet build
  ② 直连库（oneclick_win.direct，按 Windows 走）：预编 dsx/dsx.dll 在 → 不编 dsx、DSX_LIB 指它；预编 glslangValidator 在 → GLSLANG 指它；没设 → 照旧编 dsx、不设 GLSLANG
  ③ RomFS 索引还原（oneclick_win.stages）：预编 romfs_index.dll 在 → 不调 dotnet restore
  ④ spirv-cross（translator/spvc_inproc.py）：预编库 / 命令行在且身份同 → lib_path / cli_path 回预编件、不问编译器版本（_build_id 不调）；身份不符 → 照旧走编译
  ⑤ Yaz0 解码库（graphics/tools/nxfmt.py）：预编 codecs/libyaz0dec_<yaz0dec.c sha256 前 12 位> 在 → 直接回它、不找 cc；没设 → 照旧找 cc
  ⑥ Yaz0 编码器（graphics/widen/scan/ui_lyt.py）：预编 codecs/yaz0enc-<yaz0enc.c sha1 前 12 位> 在 → 用它压（假编码器输出带记号）、CC 指不存在也不退回字面量；没设且编不了 → 照旧只写字面量
  ⑦ 布局阶段起单前核（pack/orch/stages.py _layout_tools）：PATH 上没有 clang、没给 CC：有预编编码器 → 过、交下去的环境不带 CC；没有 → 退 75「编译器未就绪」
  ⑩ CRI 解压库（graphics/tools/shbake/nxsh_extract.py）：预编 codecs/libcrilayla_<crilayla.c sha256 前 12 位>.dylib 在 → 加载它、一次 subprocess 都不调；没设 → 照旧调 clang
  ⑧ 改写器（pack/rewriter.py）：预编 rewriter/s2a-rewrite + .source = 源码指纹 → bundled / c_path 回它（不找 cmake）；指纹不符 → bundled 回 None
  ⑨ 环境自检（oneclick_win --check）：设了 S2A_PREBUILT_TOOLS → 不出 cmake / clang++ / rewriter-deps 项，clang / spirv-cross / rewriter / prebuilt-dotnet 项核预编件，
     dotnet 项核运行时 10.x；缺 dsx/dsx.dll → clang ❌（哪怕系统有 clang）；运行时只有 8.0 → dotnet ❌；没设 → 照旧有 cmake / clang++ 项"""
import hashlib, glob, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R)); sys.path.insert(0, str(R / 'translator')); sys.path.insert(0, str(R / 'graphics/tools')); sys.path.insert(0, str(R / 'graphics/widen/scan')); sys.path.insert(0, str(R / 'graphics/tools/shbake'))
from pack.orch import oneclick_win, stages   # noqa: E402
from pack import rewriter   # noqa: E402
import spvc_inproc, nxfmt, ui_lyt, dsh_batch, nxsh_extract   # noqa: E402

EXE = '.exe' if os.name == 'nt' else ''


def exe(p, body='#!/bin/sh\nexit 0\n'):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(body); p.chmod(0o755); return p


def nx_unpack_ident():   # 规则另算：pack/nx_unpack 下 *.cs、*.csproj 按路径排序拼接，sha256 前 12 位
    fs = sorted(glob.glob(str(R / 'pack/nx_unpack/*.cs')) + glob.glob(str(R / 'pack/nx_unpack/*.csproj')))
    return hashlib.sha256(b''.join(Path(f).read_bytes() for f in fs)).hexdigest()[:12]


class Recorder:
    def __init__(self): self.calls = []
    def __call__(self, args, log, env=None, ok=(0,), cwd=None): self.calls.append((list(map(str, args)), log, env)); return 0


def make_pre(d, skip=()):
    """完整的假预编目录（布局同 bundle_prepare_win.py）；skip 里的相对路径不建"""
    d = Path(d)
    def put(rel, ident=None, body='#!/bin/sh\nexit 0\n'):
        if rel in skip: return
        exe(d / rel, body)
        if ident is not None: (d / rel).parent.joinpath('.src_digest').write_text(ident + '\n')
    put('nx_unpack/nx_unpack' + EXE, nx_unpack_ident())
    put('gamedec/gamedec' + EXE, oneclick_win.gamedec_id())
    put('romfs/romfs_index.dll')
    put('dsh_batch/dsh_batch.dll', dsh_batch.src_digest(os.path.join(dsh_batch.DSH, 'batch', 'dsh_batch.csproj')))
    if 'dsh_batch/.xfp' not in skip and 'dsh_batch/dsh_batch.dll' not in skip: (d / 'dsh_batch/.xfp').write_text('0123456789abcdef\n')   # 形状对即可（值由发版脚本算）
    put('dsx/dsx.dll')
    put('codecs/' + ui_lyt.yaz0enc_name())
    put('codecs/libyaz0dec_' + hashlib.sha256((R / 'graphics/tools/yaz0dec.c').read_bytes()).hexdigest()[:12] + ('.dll' if os.name == 'nt' else '.dylib' if sys.platform == 'darwin' else '.so'))
    put('codecs/libcrilayla_' + hashlib.sha256((R / 'graphics/tools/shbake/crilayla.c').read_bytes()).hexdigest()[:12] + '.dylib')
    put('spvc/' + spvc_inproc.LIB, spvc_inproc.prebuilt_id())
    put('spvc/cli/bin/' + spvc_inproc.CLI)
    put('rewriter/s2a-rewrite' + EXE)
    if 'rewriter/s2a-rewrite' + EXE not in skip: (d / 'rewriter' / ('s2a-rewrite' + EXE + '.source')).write_text(rewriter.source_digest() + '\n')
    put('glslang/glslangValidator.exe', body='#!/bin/sh\necho "Glslang Version: 11:16.6.0"\n')
    return d


class Base(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix='prebuilt_win_')); self.addCleanup(shutil.rmtree, self.t, True)
        self.env = mock.patch.dict(os.environ); self.env.start(); self.addCleanup(self.env.stop)
        for k in ('S2A_PREBUILT_TOOLS', 'S2A_BIN', 'S2A_REWRITER_C', 'S2A_REWRITER_BUNDLED', 'GLSLANG', 'S2A_DIRECT_CACHE', 'S2A_DIRECT_CACHE_ROOT', 'S2A_PSO_SOURCES', 'S2A_PSO_KNOW'):
            os.environ.pop(k, None)

    def run_obj(self):
        run = oneclick_win.Run(self.t / 'out'); self.addCleanup(run.timing.close); rec = Recorder(); run.sh = rec; return run, rec


class CSharpTools(Base):   # ①
    def test_nx_unpack(self):
        pre = make_pre(self.t / 'pre')
        run, rec = self.run_obj()
        self.assertEqual(oneclick_win.nx_unpack(run), run.out / 'bin' / f'nx_unpack_{nx_unpack_ident()}' / ('nx_unpack' + EXE)); self.assertEqual(len(rec.calls), 1, '没设：照旧 dotnet build')
        os.environ['S2A_PREBUILT_TOOLS'] = str(pre); rec.calls.clear()
        self.assertEqual(oneclick_win.nx_unpack(run), pre / 'nx_unpack' / ('nx_unpack' + EXE)); self.assertEqual(rec.calls, [], '预编件在：不调 dotnet build')
        (pre / 'nx_unpack/.src_digest').write_text('000000000000\n')
        self.assertNotEqual(oneclick_win.nx_unpack(run), pre / 'nx_unpack' / ('nx_unpack' + EXE)); self.assertEqual(len(rec.calls), 1, '身份不符：照旧现编')

    def test_stages_nxu_prebuilt(self):
        # 轻阶段（nacp / 追加内容）要 nx_unpack：预编件身份相同就用，不现编（11-07 Windows 出包机作业层端到端：玩家机只有 .NET 运行时，--from-extract 跳过「编 nx_unpack」后这里 75）；
        #   身份不符、又没 SDK → 照旧 75，不拿旧件
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre); os.environ['S2A_RUN_ROOT'] = str(self.t / 'run'); os.environ.pop('DOTNET', None)
        self.assertEqual(stages.Stages._nxu(stages.Stages, self.t / 'w'), pre / 'nx_unpack' / ('nx_unpack' + EXE))
        (pre / 'nx_unpack/.src_digest').write_text('000000000000\n')
        with mock.patch.object(stages.shutil, 'which', return_value=None), self.assertRaises(stages.StageError) as e:
            stages.Stages._nxu(stages.Stages, self.t / 'w')
        self.assertEqual(e.exception.code, 75)

    def test_gamedec(self):
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        run, rec = self.run_obj()
        self.assertEqual(oneclick_win.gamedec(run), pre / 'gamedec' / ('gamedec' + EXE)); self.assertEqual(rec.calls, [])
        (pre / 'gamedec/.src_digest').write_text('nope\n')
        with mock.patch.object(Path, 'rename'): oneclick_win.gamedec(run)
        self.assertEqual([c[1] for c in rec.calls], ['gamedec_build.log'], '身份不符：照旧 dotnet build')


class Direct(Base):   # ② ③
    def direct_env(self, pre):
        if pre: os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        run, rec = self.run_obj(); cur = self.t / 'cur'; cur.mkdir(exist_ok=True)
        metal = self.t / 'metal' / 'metal.exe'; metal.parent.mkdir(exist_ok=True); metal.write_bytes(b'')   # 装着 Metal（没装时整步跳过，见 test_stage_budget_env）
        with mock.patch.object(oneclick_win, 'WIN', True), mock.patch.object(oneclick_win, 'bash_exe', lambda: 'bash'), \
             mock.patch.object(oneclick_win, 'metal_exe', lambda *a: metal):
            oneclick_win.direct(run, cur, 'ios', 4)
        return rec.calls

    def test_prebuilt_dsx_glslang(self):
        pre = make_pre(self.t / 'pre')
        calls = self.direct_env(pre)
        self.assertEqual([c[1] for c in calls], ['direct_lib.log'], '不编 dsx')
        env = calls[0][2]
        self.assertEqual((env['DSX_LIB'], env['GLSLANG']), (oneclick_win.mixed(pre / 'dsx/dsx.dll'), oneclick_win.mixed(pre / 'glslang/glslangValidator.exe')))

    def test_unset_unchanged(self):
        calls = self.direct_env(None)
        self.assertEqual([c[1] for c in calls], ['dsx_build.log', 'direct_lib.log'])
        self.assertTrue(calls[0][0][-2].endswith('dsx_win.py')); self.assertNotIn('GLSLANG', calls[1][2])
        self.assertEqual(calls[1][2]['DSX_LIB'], oneclick_win.mixed(R / 'build/dsx/win/dsx.dll'))

    def test_romfs_restore_skipped(self):
        os.environ['S2A_PREBUILT_TOOLS'] = str(make_pre(self.t / 'pre'))
        run, rec = self.run_obj()
        oneclick_win.stages(run, 'tx', self.t / 'x', self.t / 'src')
        self.assertEqual([c[1] for c in rec.calls], ['seed.log', 'light.log'], '预编 RomFS 索引在：不还原依赖')


class Spvc(Base):   # ④
    def test_prebuilt(self):
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        with mock.patch.object(spvc_inproc, '_build_id', side_effect=AssertionError('问了编译器')):
            self.assertEqual(spvc_inproc.lib_path(), str(pre / 'spvc' / spvc_inproc.LIB))
            self.assertEqual(spvc_inproc.cli_path(), str(pre / 'spvc/cli/bin' / spvc_inproc.CLI))
        (pre / 'spvc/.src_digest').write_text('other\n')
        with mock.patch.object(spvc_inproc, '_build_id', side_effect=RuntimeError('走编译')):
            with self.assertRaisesRegex(RuntimeError, '走编译'): spvc_inproc.lib_path()
            with self.assertRaisesRegex(RuntimeError, '走编译'): spvc_inproc.cli_path()


class Yaz0(Base):   # ⑤ ⑥ ⑦
    def test_decoder_lib(self):
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        name = 'libyaz0dec_' + hashlib.sha256((R / 'graphics/tools/yaz0dec.c').read_bytes()).hexdigest()[:12] + nxfmt._shared_suffix()
        with mock.patch.object(nxfmt.shutil, 'which', side_effect=AssertionError('找了编译器')):
            self.assertEqual(nxfmt._compile_lib(), str(pre / 'codecs' / name))
        del os.environ['S2A_PREBUILT_TOOLS']
        with mock.patch.object(nxfmt.shutil, 'which', return_value=None) as w:
            self.assertIsNone(nxfmt._compile_lib()); self.assertTrue(w.called, '没设：照旧找 cc')

    def test_encoder(self):
        raw = bytes(range(256)) * 4; hdr = b'Yaz0' + bytes(12)
        os.environ.update(HOME=str(self.t / 'home'), CC=str(self.t / 'no-cc'))   # 现编缓存指空处、编译器不存在
        ui_lyt._ENC = None; self.addCleanup(setattr, ui_lyt, '_ENC', None)
        self.assertEqual(ui_lyt.yaz0_pack(raw, hdr), ui_lyt.yaz0_enc(raw, hdr), '没设、编不了：只写字面量（行为不变）')
        pre = self.t / 'pre'; name = 'yaz0enc-' + hashlib.sha1((R / 'graphics/widen/scan/yaz0enc.c').read_bytes()).hexdigest()[:12] + EXE
        exe(pre / 'codecs' / name, '#!/bin/sh\n{ printf FAKE; cat "$1"; } > "$2"\n')
        os.environ['S2A_PREBUILT_TOOLS'] = str(pre); ui_lyt._ENC = None
        self.assertEqual(ui_lyt.yaz0_pack(raw, hdr), b'FAKE' + raw)
        self.assertEqual(ui_lyt._ENC, str(pre / 'codecs' / name))

    def test_layout_preflight(self):
        b = self.t / 'bin'; exe(b / 'zstd', f'#!/bin/sh\necho "*** Zstandard CLI (64-bit) v{stages.LAYOUT_ZSTD}, by Yann Collet ***"\n')
        os.environ.update(PATH=f'{b}:/bin', HOME=str(self.t / 'home')); os.environ.pop('CC', None)
        gen = R / 'graphics/widen/scan/ui_lyt.py'; work = self.t / 'w'; work.mkdir()
        which = stages.shutil.which   # Linux 的 /bin 可包含 clang；只在探测边界模拟缺编译器，zstd 仍实跑
        with mock.patch.object(stages.shutil, 'which', side_effect=lambda name: None if name == 'clang' else which(name)), \
                self.assertRaises(stages.StageError) as e: stages.Stages._layout_tools(gen, work)
        self.assertEqual(e.exception.code if hasattr(e.exception, 'code') else None, 75); self.assertIn('编译器未就绪', str(e.exception))
        pre = self.t / 'pre'; exe(pre / 'codecs' / ui_lyt.yaz0enc_name(), '#!/bin/sh\ncat "$1" > "$2"\n'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        env = stages.Stages._layout_tools(gen, work)
        self.assertNotIn('CC', env)


class Cri(Base):   # ⑩
    def load(self):
        nxsh_extract._cri = None; os.environ.pop('NXSH_CRILAYLA', None)
        loaded = mock.MagicMock()
        with mock.patch('ctypes.CDLL', loaded), mock.patch('subprocess.run', side_effect=FileNotFoundError(2, '系统找不到指定的文件')) as run:
            try: nxsh_extract._cri_lib(); err = None
            except FileNotFoundError as e: err = e
        nxsh_extract._cri = None
        return err, (loaded.call_args[0][0] if loaded.called else None), run.called

    def test_prebuilt(self):
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        name = 'libcrilayla_' + hashlib.sha256((R / 'graphics/tools/shbake/crilayla.c').read_bytes()).hexdigest()[:12] + '.dylib'
        self.assertEqual(self.load(), (None, str(pre / 'codecs' / name), False), '预编件在：加载它、不调编译器')

    def test_no_prebuilt_compiles(self):
        os.environ.pop('S2A_PREBUILT_TOOLS', None)
        with tempfile.TemporaryDirectory() as t, mock.patch.object(nxsh_extract, 'cri_lib_name', return_value='no-such-lib.dylib'), \
                mock.patch.object(nxsh_extract, '__file__', str(Path(t, 'a/b/c/nxsh_extract.py'))):
            Path(t, 'a/b/c').mkdir(parents=True)
            err, lib, ran = self.load()
        self.assertTrue(isinstance(err, FileNotFoundError) and ran and lib is None, '没设：照旧调 clang，缺 clang 就报错')


class Rewriter(Base):   # ⑧
    def test_bundled(self):
        pre = make_pre(self.t / 'pre'); os.environ['S2A_PREBUILT_TOOLS'] = str(pre)
        want = (pre / 'rewriter' / ('s2a-rewrite' + EXE)).resolve()
        with mock.patch.object(rewriter.shutil, 'which', side_effect=AssertionError('找了 cmake')):
            self.assertEqual((rewriter.bundled(), rewriter.c_path()), (want, want))
        (pre / 'rewriter' / ('s2a-rewrite' + EXE + '.source')).write_text('stale\n')
        self.assertIsNone(rewriter.bundled())


class Check(Base):   # ⑨
    def check(self, pre=None, runtimes='Microsoft.NETCore.App 10.0.1 [/x]'):
        b = self.t / 'bin'; shutil.rmtree(b, ignore_errors=True)
        exe(b / 'dotnet', f'#!/bin/sh\n[ "$1" = --list-runtimes ] && echo "{runtimes}"\nexit 0\n')
        env = dict(os.environ, PATH=f'{b}:/usr/bin:/bin', PYTHONUTF8='1', DOTNET=str(b / 'dotnet'))
        if pre: env['S2A_PREBUILT_TOOLS'] = str(pre)
        p = subprocess.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.oneclick_win', '--check', '--target', 'mac'], cwd=R, capture_output=True, text=True, env=env)
        return {l[2:].split('：', 1)[0]: l[:1] for l in p.stdout.splitlines() if l[:1] in '✅❌'}

    def test_prebuilt_items(self):
        got = self.check(make_pre(self.t / 'pre'))
        for k in ('cmake', 'clang++', 'rewriter-deps'): self.assertNotIn(k, got)
        self.assertEqual({k: got.get(k) for k in ('dotnet', 'prebuilt-dotnet', 'clang', 'rewriter', 'spirv-cross', 'glslang')},
                         dict.fromkeys(('dotnet', 'prebuilt-dotnet', 'clang', 'rewriter', 'spirv-cross', 'glslang'), '✅'))

    def test_missing_piece_red(self):
        got = self.check(make_pre(self.t / 'pre', skip=('dsx/dsx.dll',)))
        self.assertEqual(got['clang'], '❌', '系统有 clang 也不算：要预编 dsx.dll')
        cri = 'codecs/libcrilayla_' + hashlib.sha256((R / 'graphics/tools/shbake/crilayla.c').read_bytes()).hexdigest()[:12] + '.dylib'
        self.assertEqual(self.check(make_pre(self.t / 'pre4', skip=(cri,)))['clang'], '❌', '玩家机没有 clang：缺预编 CRI 库起单前就要红（#95）')
        got = self.check(make_pre(self.t / 'pre2'), runtimes='Microsoft.NETCore.App 8.0.11 [/x]')
        self.assertEqual(got['dotnet'], '❌')
        got = self.check(make_pre(self.t / 'pre3', skip=('dsh_batch/.xfp',)))
        self.assertEqual(got['prebuilt-dotnet'], '❌', '预编 dsh_batch 缺 .xfp：没 SDK 的玩家机出库后核不了库印章，起单前就要红（11-07 Windows 出包机运行时验收）')

    def test_unset_unchanged(self):
        got = self.check()
        for k in ('cmake', 'clang++', 'rewriter-deps', 'clang', 'dotnet'): self.assertIn(k, got)
        for k in ('prebuilt-dotnet', 'rewriter', 'spirv-cross'): self.assertNotIn(k, got)


if __name__ == '__main__':
    unittest.main(verbosity=2)
