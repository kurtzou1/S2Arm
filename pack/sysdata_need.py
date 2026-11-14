#!/usr/bin/env python3
# 出包·系统数据：sysdata_need.py <产物根> [玩家系统数据目录]
# 系统数据缺省对每款都提供，不再按款判断要不要（10-25 维护者：数码宝贝港版没登记 0823 起局就 Break，同直连手写档是一类问题——逐款手写表卡死零配置）：
#   对已知的系统数据号（NAMES + pack/sysdata_synth.py 会合成的号）逐个：产物根已有真的 → 过；玩家系统数据目录（S2A_SYSDATA / 一键出包 --sysdata）里有非空的 <号>/
#   → 打「COPY<TAB>号<TAB>目录」交给 stage_sysdata.sh 拷进新版本（产物根里是合成的也换成真的）；都没有、能合成（0802 Mii、0806 / 0823 屏蔽词，几 KB）→ 打「SYNTH<TAB>号<TAB>用途」合成「空但格式合法」的一份；
#   拿不到也合成不了的号（0801 / 0809）不提供、不报红——游戏真要时服务层日志「[S2A 系统数据] <号> 缺」写明，给 --sysdata 或加合成器。
#   pack/sysdata_need.tsv 只作统计（各款实际要了哪些号的普查记录），出包不读它做判断。
# 系统数据是主机固件里的任天堂数据，不随仓库 / 应用分发：真数据只认玩家自己的目录；合成的是不含任天堂内容的最小合法结构
#   （10-25 维护者 拍板：「我同意，能让玩家不要面对这个问题」）。iOS / 安卓共用。
import hashlib, os, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))

# 号 → 玩家看得懂的名字（提示用；表里的「用途」列优先）
NAMES = {
    '0100000000000802': 'Mii 资源（MiiModel / MiiTexture，游戏画 Mii 头像与角色用）',
    '0100000000000806': '旧版屏蔽词表 NgWord（早期游戏检查玩家输入的名字 / 文字）',
    '0100000000000823': '屏蔽词表 NgWord（检查玩家输入的名字 / 文字）',
    '0400000000000849': 'Switch 2 Mii 资源（MiiResource，Switch 2 游戏画 Mii 用）',
    '0100000000000801': '错误信息文本 ErrorMessage',
    '0100000000000809': '系统版本 SystemVersion',
}


def synth_ids():
    # pack/sysdata_synth.py --ids：会合成的号（每行一个）
    try:
        return set(subprocess.run([sys.executable, os.path.join(H, 'sysdata_synth.py'), '--ids'], capture_output=True, text=True, check=True).stdout.split())
    except (OSError, subprocess.CalledProcessError):
        return set()


def have_real(have, sid):
    # 产物根已有真的（合成的旁边有 <号>.synth，不算真的，玩家目录有真的就换）
    return nonempty_dir(os.path.join(have, sid)) and not os.path.exists(os.path.join(have, sid + '.synth'))


# 系统自动生成的文件（exFAT / FAT 上 macOS 的 ._<名>、访达 .DS_Store、Windows desktop.ini / Thumbs.db）不是系统数据：不算「有内容」、不进内容身份。
#   同 pack/jobs/layout.py OS_JUNK / OS_JUNK_PREFIX（tests/os_junk_sync_test.sh 核一致）；不 import 作业层：本脚本单独跑，sys.path 里没有 pack/jobs
OS_JUNK = frozenset({".DS_Store", "desktop.ini", "Thumbs.db"})


def os_junk(name):
    return name in OS_JUNK or name.startswith("._")


def nonempty_dir(p):
    try:
        return os.path.isdir(p) and any(not os_junk(e.name) for e in os.scandir(p))
    except OSError:
        return False


def tree_digest(d):
    # 目录内容身份：普通文件按相对路径排序，逐个「路径 + 整份内容」喂 sha256（0802 / 0823 只有几 MB，整读；读不了 → None，按不同处理）
    h = hashlib.sha256()
    try:
        files = sorted(os.path.relpath(os.path.join(a, f), d).replace(os.sep, '/') for a, _, fs in os.walk(d) for f in fs if not os_junk(f))
        for rel in files:
            h.update(rel.encode() + b'\0')
            with open(os.path.join(d, rel), 'rb') as f:
                for b in iter(lambda: f.read(1 << 20), b''):
                    h.update(b)
            h.update(b'\0')
    except OSError:
        return None
    return h.hexdigest()


def player_dir(src, sid):
    # 玩家目录里的 <号>/：大小写都认（Windows / 工具导出常见小写）
    if not src:
        return None
    for name in (sid, sid.lower()):
        p = os.path.join(src, name)
        if nonempty_dir(p):
            return os.path.abspath(p)
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit('用法：sysdata_need.py <产物根> [玩家系统数据目录]')
    root = sys.argv[1]
    src = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ''
    have, can = os.path.join(root, 'systemdata'), synth_ids()
    for sid in sorted(set(NAMES) | can):
        use = NAMES.get(sid, '系统数据')
        p = player_dir(src, sid)
        # 产物根已有真的：玩家目录没给这一号、或内容与产物根那份相同才留（审计 #1534 P1-54：原先有真的就不再看玩家目录，玩家换了新转储照用上次拷的）
        if have_real(have, sid) and (not p or tree_digest(p) == tree_digest(os.path.join(have, sid))):
            print(f'🟢 {sid} 已在产物根（{use}）')
            continue
        if p:
            print(f'COPY\t{sid}\t{p}')
            print(f'🟢 {sid} 从 {p} 拷进（{use}）')
        elif sid in can:
            if nonempty_dir(os.path.join(have, sid)):
                print(f'🟢 {sid} 已在产物根（合成的空数据；{use}）')
            else:
                print(f'SYNTH\t{sid}\t{use}')
                print(f'🟢 {sid} 合成空但格式合法的一份（{use}；给了真数据下次出包换成真的）')
    return 0

if __name__ == '__main__':
    sys.exit(main())
