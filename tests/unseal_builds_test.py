#!/usr/bin/env python3
"""启动时把旧版本留下的只读产物加回写权限（pack/jobs/library.py unseal_builds / unseal_tree）：python3 tests/unseal_builds_test.py，秒级
背景：旧版本把产物根里的 RomFS 共享存储整棵设只读，玩家在访达里手动删旧产物删不掉（11-12 玩家反馈）。期望（手算）：
  ① unseal_tree：整棵只读的树（目录 + 文件）→ 没有不可写的项；指向树外只读目录的软链不跟进去（树外仍只读）；之后普通 rm -rf 删干净
  ② unseal_builds：两款，一款产物目录只读、一款已有标记 → 前者修好并写标记；有标记的不动（仍只读）；没有产物目录的款跳过不报错"""
import os, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack/jobs'))
import library
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
def stuck(top):
    return sorted(str(p.relative_to(top)) for p in [Path(top), *Path(top).rglob('*')] if not p.is_symlink() and not os.lstat(p).st_mode & stat.S_IWUSR)
def ro_tree(d):
    (d / 'roots/.romfs_store/g/id1/Layout').mkdir(parents=True); (d / 'roots/.romfs_store/g/id1/a.bin').write_bytes(b'a'); (d / 'roots/.romfs_store/g/id1/Layout/x').write_bytes(b'x')
    subprocess.run(['chmod', '-R', 'a-w', str(d / 'roots/.romfs_store')], check=True)
with tempfile.TemporaryDirectory() as t:
    t = Path(t); b = t / 'build'; ro_tree(b)
    out = t / 'outside'; out.mkdir(); (out / 'f').write_bytes(b'o'); os.chmod(out / 'f', 0o444); os.chmod(out, 0o555)
    os.symlink(out, b / 'roots/link')
    library.unseal_tree(b)
    chk('① 树里没有不可写的项', [], stuck(b))
    chk('① 软链不跟进去：树外仍只读', ['.', 'f'], stuck(out))
    r = subprocess.run(['rm', '-rf', str(b)]); chk('① 普通 rm -rf 删干净', (0, False), (r.returncode, b.exists()))
    os.chmod(out, 0o755)
    games = t / 'lib'; d1, d2 = games / 'A/build', games / 'B/build'; ro_tree(d1); ro_tree(d2); (d2 / library.UNSEALED).write_text('')
    os.chmod(d2, 0o555)
    c = mock.Mock(); c.catalog.return_value = {'games': [{'id': 'A'}, {'id': 'B'}, {'id': 'C'}]}
    with mock.patch.object(library.layout, 'build_dir', side_effect=lambda c, gid, create=True: games / gid / 'build'):
        library.unseal_builds(c)
    chk('② 没标记的款修好并写标记', ([], True), (stuck(d1), (d1 / library.UNSEALED).exists()))
    chk('② 有标记的款不动（仍有只读项）', True, len(stuck(d2)) > 0)
    subprocess.run(['chmod', '-R', 'u+w', str(t)])
print(f'{"✓" if not bad else "✗"} unseal_builds：{bad} 不通'); sys.exit(1 if bad else 0)
