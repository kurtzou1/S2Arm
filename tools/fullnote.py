"""写满（ENOSPC）当场量一次、打一行「【写满】」事实，pack/jobs/errors.py 认它定 disk_full、给玩家带数字的两句
（「X 空间不够：这一步还要约 N GB，盘上只剩 M GB」「在 X 上腾出至少 K GB 后重试」）。
失败后临时文件一删空间就回来，事后再量会误判成「还有空间」（#1725 诊断 D-K82N），所以必须写满那一刻量。
pack/img.py（写单一 IMG，#2164）用；行格式与 tools/clonedir.py full_note 打的同一种。clonedir.py 要单文件独立跑
（单测和直连库阶段把它单独拷走），所以不 import 本文件，volume_name 两边各一份，改一处要同改另一处。"""
import os
import shutil
import sys


def volume_name(path):
    """玩家认得出的盘名：Windows 盘符（C:）；Mac /Volumes/<卷名> 下取卷名，系统盘问 diskutil 的卷名（读不到写 Macintosh HD）；其余系统给挂载点"""
    if sys.platform == 'win32':
        return os.path.splitdrive(os.path.abspath(path))[0] or path
    parts = os.path.abspath(path).split(os.sep)
    if sys.platform == 'darwin' and len(parts) > 2 and parts[1] == 'Volumes':
        return parts[2]
    if sys.platform == 'darwin':
        import plistlib, subprocess
        try:
            return plistlib.loads(subprocess.run(['diskutil', 'info', '-plist', '/'], capture_output=True, timeout=10).stdout).get('VolumeName') or 'Macintosh HD'
        except Exception:
            return 'Macintosh HD'
    p = os.path.abspath(path)
    while not os.path.ismount(p):
        p = os.path.dirname(p)
    return p


def note(dest_dir, what=None, need_bytes=None, out=None):
    """dest_dir 所在盘此刻剩多少；what / need_bytes 给了就带上「what 要 N GB」（这一步还要写的量）。量不出就不打"""
    try:
        free = shutil.disk_usage(dest_dir).free
    except OSError:
        return
    need = f'，{what} 要 {need_bytes / (1 << 30):.1f} GB' if what and need_bytes is not None else ''
    print(f'【写满】{dest_dir}（盘「{volume_name(dest_dir)}」）所在盘剩 {free / (1 << 30):.1f} GB{need}', file=out or sys.stderr, flush=True)
