#!/usr/bin/env python3
"""tools/stage_deps.py + tools/stage_deps_hook/sitecustomize.py 单测（10-30 改写阶段缓存键漏输入的根修）。
临时「仓库」里放一个生成器 gen.py：函数里才导入 helper（延迟导入，同 fps_generic 导 ue_cvar_loc）、helper 读表 table.tsv、列目录 data/、
写一个输出文件再读回来。在钩子下跑两遍（第二遍走 .pyc，导入不打开 .py），期望（按规则手写，不用被测函数算）：
  ① 清单含 gen.py、helper.py、table.tsv（f）与 data/（d），路径写 R:<相对路径>；不含 __pycache__、不含自己写的输出、不含排除前缀下的文件
  ② 两遍的清单相同（走 .pyc 不漏 helper.py）
  ③ 改 helper.py / 改 table.tsv / data/ 里多一个文件 / 原先读不到的文件出现 → rehash 结果变；改一个没被读的文件、data/ 里多一个被忽略的 obj/ → 不变
  ⑤ pack/ 下每个用 root_stage_done 的阶段都接了实际读入（或在豁免表写明理由）
  ④ 不算输入的读：被 .gitignore 挡掉的（build/ 缓存）、仓库外没登记的、S2A_DEPS_KEYED 里的 → 不记；仓库外登记过的数据根（S2A_DEPS_EXTERNAL）→ 记
"""
import os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import stage_deps  # noqa: E402

GEN = '''import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
def run(out):
    import helper
    v = helper.table() + str(sorted(os.listdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "data"))))
    try: open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "maybe.tsv")).read()
    except OSError: pass
    for extra in ("build/cache.bin", os.environ["T_EXT_OK"], os.environ["T_EXT_NO"], "keyed.tsv"):
        p = extra if os.path.isabs(extra) else os.path.join(os.path.dirname(os.path.abspath(__file__)), extra)
        open(p).read()
    open(out, "w").write(v); return open(out).read()
run(sys.argv[1]); run(sys.argv[2] + "/in_root.tsv")
'''
HELPER = '''import os
def table(): return open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "table.tsv")).read()
'''


class StageDeps(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(prefix='stage-deps-'); b = Path(self.t.name)
        self.repo = b / 'repo'; (self.repo / 'data').mkdir(parents=True); self.excl = b / 'roots'; self.excl.mkdir()
        (self.repo / 'gen.py').write_text(GEN); (self.repo / 'helper.py').write_text(HELPER)
        (self.repo / 'table.tsv').write_text('a\t1\n'); (self.repo / 'data/x').write_text('x'); (self.repo / 'unread.py').write_text('# 没人读\n')
        (self.repo / '.gitignore').write_text('build/\nobj/\n'); (self.repo / 'build').mkdir(); (self.repo / 'build/cache.bin').write_text('缓存\n')
        (self.repo / 'keyed.tsv').write_text('按行进键\n')
        self.ext_ok = b / 'community'; self.ext_ok.mkdir(); (self.ext_ok / 'INDEX.tsv').write_text('补丁\n')
        self.ext_no = b / 'elsewhere'; self.ext_no.mkdir(); (self.ext_no / 'cache.tsv').write_text('别处\n')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.n = 0

    def tearDown(self): self.t.cleanup()

    def run_gen(self):
        self.n += 1; raw = Path(self.t.name) / f'raw{self.n}'; raw.mkdir()
        env = dict(os.environ, S2A_DEPS_OUT=str(raw), PYTHONPATH=str(ROOT / 'tools/stage_deps_hook'),
                   T_EXT_OK=str(self.ext_ok / 'INDEX.tsv'), T_EXT_NO=str(self.ext_no / 'cache.tsv'))
        env.pop('PYTHONDONTWRITEBYTECODE', None); env.pop('PYTHONPYCACHEPREFIX', None)   # 第二遍要真走 .pyc（导入不打开 .py）
        out = self.repo / 'out.tsv'   # 生成器自己写的输出在仓库里：写过的不算输入
        subprocess.run([sys.executable, str(self.repo / 'gen.py'), str(out), str(self.excl)], env=env, check=True)
        os.environ['S2A_DEPS_EXTERNAL'] = str(self.ext_ok); os.environ['S2A_DEPS_KEYED'] = 'keyed.tsv'
        try: rows = stage_deps.collect(str(raw), str(self.repo), [str(self.excl)])
        finally: os.environ.pop('S2A_DEPS_EXTERNAL'); os.environ.pop('S2A_DEPS_KEYED')
        return rows, ''.join(f'{k}\t{n}\t{h}\n' for k, n, h in rows)

    def rehash(self, text):
        m = Path(self.t.name) / 'm.tsv'; m.write_text(text)
        return ''.join(f'{k}\t{n}\t{h}\n' for k, n, h in stage_deps.rehash(str(m), str(self.repo)))

    def test_records_and_tracks(self):
        rows, text = self.run_gen()
        names = {(k, n) for k, n, _ in rows}
        for want in [('f', 'R:gen.py'), ('f', 'R:helper.py'), ('f', 'R:table.tsv'), ('d', 'R:data'), ('f', 'R:maybe.tsv')]:
            self.assertIn(want, names, text)
        self.assertEqual(dict(((k, n), h) for k, n, h in rows)[('f', 'R:maybe.tsv')], '缺', text)
        self.assertNotIn('__pycache__', text); self.assertNotIn('out.tsv', text); self.assertNotIn('in_root', text); self.assertNotIn('unread', text)
        self.assertNotIn('stage_deps_hook', text)
        self.assertIn(('f', os.path.realpath(self.ext_ok / 'INDEX.tsv')), names, '登记过的仓库外数据根要记')
        for no in ('build/cache.bin', 'elsewhere', 'keyed.tsv'): self.assertNotIn(no, text)
        _, text2 = self.run_gen()
        self.assertTrue((self.repo / '__pycache__').is_dir(), '第二遍应走 .pyc')
        self.assertEqual(text, text2, '走 .pyc 的第二遍清单应与第一遍相同')
        self.assertEqual(self.rehash(text), text, '没改任何文件：rehash 逐字相同')
        (self.repo / 'unread.py').write_text('# 改了也没人读\n')
        self.assertEqual(self.rehash(text), text, '改没被读的文件：不变')
        (self.repo / 'data/obj').mkdir(); (self.repo / 'data/obj/x.dll').write_text('编译中间产物\n')   # 11-05：编过的树多出 obj/（被 .gitignore 挡）
        self.assertEqual(self.rehash(text), text, '被忽略的编译中间目录出现：目录项不变（新检出的树与编过的树同键）')
        for change in (lambda: (self.repo / 'helper.py').write_text(HELPER + '# 改生成器\n'),
                       lambda: (self.repo / 'table.tsv').write_text('a\t2\n'),
                       lambda: (self.repo / 'data/y').write_text('y'),
                       lambda: (self.repo / 'maybe.tsv').write_text('出现了\n')):
            change(); self.assertNotEqual(self.rehash(text), text); text = self.rehash(text)

    def test_records_survive_tmpdir_purge(self):
        # #265：macOS 盘紧时会清系统临时目录。阶段开头 stage_deps_on、阶段跑着时把 $TMPDIR 清空，收尾 stage_deps_save 仍要成功：
        #   记录放在产物根（$S2A_ROOTS/.stage_deps/<pid>）而不是 $TMPDIR；期望按规则手写——save 退 0、打出基础键、写出清单
        b = Path(self.t.name); tmp = b / 'tmp'; tmp.mkdir(); roots = b / 'stage-roots'; roots.mkdir(); w = roots / 'k@x'; w.mkdir()
        script = (f'source {ROOT}/pack/stage_keyfiles.sh; stage_deps_on || exit 9; '
                  f'case $_SD_DIR in {roots}/.stage_deps/*) ;; *) echo "记录目录不在产物根：$_SD_DIR"; exit 8;; esac; '
                  f'rm -rf {tmp}/* {tmp}/.[!.]*; stage_deps_save {w} t BASEKEY {ROOT}/pack/stage_keyfiles.sh')
        r = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                           env=dict(os.environ, TMPDIR=str(tmp), S2A_ROOTS=str(roots), S2A_DEPS_EXTERNAL=''))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'BASEKEY'), r.stdout + r.stderr)
        self.assertTrue((w / '.stage_t.deps').is_file())
        # 作业临时目录 S2A_JOB_TMP（游戏库 v3 接口）有就用它：记录在 $S2A_JOB_TMP/stage_deps/<pid>
        job = b / 'job-tmp'; job.mkdir()
        script = (f'source {ROOT}/pack/stage_keyfiles.sh; stage_deps_on || exit 9; '
                  f'case $_SD_DIR in {job}/stage_deps/*) ;; *) echo "记录目录不在作业临时目录：$_SD_DIR"; exit 8;; esac; '
                  f'rm -rf {tmp}/*; stage_deps_save {w} t BASEKEY {ROOT}/pack/stage_keyfiles.sh')
        r = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                           env=dict(os.environ, TMPDIR=str(tmp), S2A_ROOTS=str(roots), S2A_JOB_TMP=str(job), S2A_DEPS_EXTERNAL=''))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'BASEKEY'), r.stdout + r.stderr)

    def test_skips_macos_metadata_in_records(self):
        """#812：记录目录在游戏库卷上；exFAT / FAT 上 macOS 把扩展属性存成旁边的 ._<名>（AppleDouble 二进制，头里有 0x09 后跟 NUL），
        还可能有 .DS_Store。期望：collect 只读本机制写的记录，清单只有真实记录里那一行；修前读到 ._ 文件报 ValueError: embedded null character"""
        raw = Path(self.t.name) / 'raw_exfat'; raw.mkdir()
        (raw / '1-2.tsv').write_text(f'f\t{self.repo}/table.tsv\n')
        apple_double = bytes.fromhex('00051607000200004d6163204f53205820202020202020200002000000090000'
                                     '00320000 0eb0000000020000 0ee20000 011e0000'.replace(' ', '')) + bytes(4096 - 0x30)
        (raw / '._1-2.tsv').write_bytes(apple_double)   # 真实 exFAT 卷上 xattr -w 后系统生成的头（11-13 本机 hdiutil exFAT 镜像实录）
        (raw / '.DS_Store').write_bytes(b'\x00\x00\x00\x01Bud1\t\x00')
        import hashlib
        want = [('f', 'R:table.tsv', hashlib.sha256(b'a\t1\n').hexdigest()[:16])]
        self.assertEqual(stage_deps.collect(str(raw), str(self.repo), [str(self.excl)]), want)

    def test_hook_off_without_env(self):
        env = {k: v for k, v in os.environ.items() if k != 'S2A_DEPS_OUT'}; env['PYTHONPATH'] = str(ROOT / 'tools/stage_deps_hook')
        r = subprocess.run([sys.executable, '-c', 'import sys; print(sys.audit is not None)'], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.strip(), 'True')
        self.assertEqual(list(Path(self.t.name).glob('raw*')), [])


    def test_chains_shadowed_sitecustomize(self):
        # 11-05：本钩子排在 PYTHONPATH 最前会遮住解释器自带的 sitecustomize（Homebrew Python 靠它把 site-packages 加进 sys.path，遮住后 meson 导入失败）。
        #   造一个排在后面的 sitecustomize（写环境标记），开 / 不开依赖记录两种都要执行到；旧钩子不接续 → 标记缺、必红
        other = Path(self.t.name) / 'interp_site'; other.mkdir()
        (other / 'sitecustomize.py').write_text("import os\nos.environ['S2A_T_CHAINED'] = '1'\n")
        for deps in (True, False):
            env = {k: v for k, v in os.environ.items() if k != 'S2A_DEPS_OUT'}
            env['PYTHONPATH'] = str(ROOT / 'tools/stage_deps_hook') + os.pathsep + str(other)
            if deps:
                raw = Path(self.t.name) / 'raw_chain'; raw.mkdir(exist_ok=True); env['S2A_DEPS_OUT'] = str(raw)
            r = subprocess.run([sys.executable, '-c', 'import os; print(os.environ.get("S2A_T_CHAINED", "缺"))'], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(r.stdout.strip(), '1', f'记依赖={deps}：排在后面的 sitecustomize 应被接续执行')


class EveryStageWired(unittest.TestCase):
    """⑤ 各阶段都接了实际读入（10-30 维护者：所有阶段的缓存键按实际读过的文件算）：pack/ 下凡是用 root_stage_done 判跳过的阶段脚本，
    要么开头 stage_deps_on、判跳过前 stage_deps_key、写阶段键前 stage_deps_save，且每个带 .stage_<阶段> 的 ROOT_REPLAY 也带 .stage_<阶段>.deps；
    要么在豁免表里写明为什么不用。新加阶段忘了接 → 这里红"""
    EXEMPT = {'uilayout': '先生成再按产出内容算键（产出变了键就变），不会漏输入',
              'sysdata': '键是钉版时区来源号（make_tzdata.sh --source-id），生成器离线、只读钉版归档',
              'pkg': '包键（pack/ipa.sh）按各阶段键 + 程序源码树算，各阶段键已含实际读入'}
    def test_wired(self):
        import re
        seen = {}
        for f in sorted((ROOT / 'pack').rglob('*.sh')):
            t = f.read_text(encoding='utf-8', errors='replace')
            for st in sorted(set(re.findall(r'root_stage_done "\$\{?CUR\}?" ([a-z_]+) ', t))):
                seen.setdefault(st, []).append((f, t))
        self.assertIn('rewrite', seen)
        for st, fs in seen.items():
            if st in self.EXEMPT: continue
            for f, t in fs:
                rel = f.relative_to(ROOT)
                with self.subTest(stage=st, file=str(rel)):
                    self.assertIn('stage_deps_on', t, f'{rel}：{st} 阶段没开实际读入记录')
                    self.assertRegex(t, rf'stage_deps_key "\$CUR" {st} ', f'{rel}：{st} 判跳过前没把实际读入折进键')
                    self.assertRegex(t, rf'stage_deps_save "\$W" {st} ', f'{rel}：{st} 写阶段键前没存实际读入清单')
                    lines = t.split('\n'); on = next(i for i, l in enumerate(lines) if 'stage_deps_on' in l and not l.lstrip().startswith('#'))
                    call = re.compile(r'(?:^|[;&|({]\s*|\$\()\s*(?:"\$V?PY"|python3)\s+(?!-m pip)')   # 真调用：行首 / ; && | ( { $( 之后的 "$PY" 或 python3（不算 PY=… 赋值与注释）
                    first = next((i for i, l in enumerate(lines) if not l.lstrip().startswith('#') and call.search(l.split(' #')[0])), None)
                    self.assertTrue(first is None or on <= first, f'{rel}：stage_deps_on（第 {on + 1} 行）要在第一个 Python 调用（第 {(first or 0) + 1} 行）之前')
                    for rp in re.findall(r"ROOT_REPLAY='([^']*)'", t):
                        if f'.stage_{st}' in rp.split(): self.assertIn(f'.stage_{st}.deps', rp.split(), f'{rel}：ROOT_REPLAY 带 .stage_{st} 没带清单')


if __name__ == '__main__':
    unittest.main()
