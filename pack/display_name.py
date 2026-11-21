#!/usr/bin/env python3
"""装机 App 显示名的唯一来源（11-04 维护者：「装到手机上的 app 都命名成 游戏名 S2Arm 的格式」「应该在游戏自带信息里找」）。

  display_name.py <control.nacp | 解包目录 | 产物根> [--suffix 后缀] [--title]
      打印「<游戏名> S2Arm[ <后缀>]」（--title 只打印游戏名）。取不到游戏名 → stderr 打【红】原因、退出 1：
      不退回对照表、不退回程序号 / 款名。

游戏名 = control.nacp 的 ApplicationTitle 名字（每项 0x300：名字 0x200 + 发行商 0x100，UTF-8，\\0 结尾）。
  旧格式：文件头 0x3000 字节就是 16 项；新格式（固件 19 起）：头 2 字节是长度、其后 raw DEFLATE 压缩的 32 项（0x6000 字节）。
  语言序号同 Ryujinx TitleLanguage：0 美式英语、1 英式英语、2 日语 …… 13 繁体中文、14 简体中文、15 巴西葡语（16 起只在新格式）。
    本机 33 份解包实测（11-04）：动森 13「集合啦！動物森友會」、14「集合啦！动物森友会」——14 是简中。
  优先级：简中 14 → 繁中 13 → 美式英语 0 → 英式英语 1 → 其余按序号（只有日文等标题的款照样有名字，仍是游戏自带信息）。
目录参数按出包各处的同一位置找：<目录>/ctl/control.nacp（NSP / XCI 解包、产物根、Switch 2 导出经 pack/ns2_dump.py 整理后），
  再 <目录>/control.nacp。合成的 nacp（ns2_dump 没有控制分区时按导出文件夹名合成，维护者 11-04 定）照常读、不另判。
"""
import argparse
import os
import sys
import unicodedata
import zlib

BRAND = 'S2Arm'
ENTRY, NAME = 0x300, 0x200
ORDER = (14, 13, 0, 1)   # 简中、繁中、美式英语、英式英语；其余按序号接在后面


class NoTitle(Exception):
    """取不到游戏名（带原因）"""


def nacp_path(path):
    """参数 → control.nacp 文件路径；目录按 ctl/control.nacp、control.nacp 顺序找"""
    if os.path.isdir(path):
        for rel in ('ctl/control.nacp', 'control.nacp'):
            p = os.path.join(path, rel)
            if os.path.isfile(p):
                return p
        raise NoTitle(f'{path} 下没有 ctl/control.nacp（也没有 control.nacp）')
    if not os.path.isfile(path):
        raise NoTitle(f'{path} 不存在')
    return path


def _table(nacp):
    """名字表与项数：新格式解压出 32 项，否则旧格式 16 项"""
    n = int.from_bytes(nacp[:2], 'little')
    if 0 < n <= 0x2ffe:
        try:
            d = zlib.decompressobj(-15)
            raw = d.decompress(nacp[2:2 + n], 0x6001)
            if len(raw) == 0x6000 and d.eof and not d.unused_data and not d.unconsumed_tail:
                return raw, 32
        except zlib.error:
            pass
    if len(nacp) < 16 * ENTRY:
        raise NoTitle(f'control.nacp 只有 {len(nacp)} 字节，装不下 16 项标题（0x3000）')
    return nacp, 16


def titles(nacp):
    """{语言序号: 名字}，只收非空、UTF-8 合法、无控制字符的项；坏项记进 bad 列表一并返回"""
    table, count = _table(nacp)
    out, bad = {}, []
    for i in range(count):
        raw = table[i * ENTRY:i * ENTRY + NAME].split(b'\0')[0]
        try:
            t = raw.decode('utf-8')
        except UnicodeDecodeError:
            bad.append(f'{i} 号不是合法 UTF-8')
            continue
        if any(ord(c) < 32 for c in t):
            bad.append(f'{i} 号含控制字符')
            continue
        t = t.strip()
        if t:
            out[i] = t
    return out, bad


def title(path):
    """游戏名：按 ORDER 取第一个有名字的语言"""
    p = nacp_path(path)
    with open(p, 'rb') as f:
        got, bad = titles(f.read())
    for i in ORDER + tuple(sorted(set(got) - set(ORDER))):
        if i in got:
            return got[i]
    raise NoTitle(f'{p} 的 ApplicationTitle 全是空的' + (f'（{"；".join(bad)}）' if bad else ''))


def compose(game, suffix='', brand=True):
    """「<游戏名> S2Arm[ <后缀>]」：游戏名必须在最前面，后缀只用来区分实验 / 满屏等包。brand=False（独立 App，一 App 一游戏，11-20 维护者：主屏名就是游戏名）不带「 S2Arm」"""
    game, suffix = (game or '').strip(), (suffix or '').strip()
    if not game:
        raise NoTitle('游戏名是空的')
    if any(ord(c) < 32 for c in game + suffix):
        raise NoTitle('游戏名 / 后缀含控制字符')
    return ' '.join(x for x in (game, BRAND if brand else '', suffix) if x)


def display_name(path, suffix=''):
    return compose(title(path), suffix)


def _ascii(s):   # 苹果 App ID 名字只收英文字母、数字、空格：重音字母先拆成「字母 + 附加符」只留字母（é → e），其余字符去掉、空白并成一个
    s = ''.join(c for c in unicodedata.normalize('NFKD', s) if not unicodedata.combining(c))
    return ' '.join(''.join(c if (c.isascii() and c.isalnum()) else ' ' for c in s).split())


def _latin(s):   # 整个标题是拉丁字母写的（字母都是 ASCII 或 Unicode 名带 LATIN）：中日韩 / 西里尔等文字的标题删字后只剩残片，不算
    return all(not c.isalpha() or c.isascii() or 'LATIN' in unicodedata.name(c, '') for c in s)


def ascii_title(path):
    """侧载工具建 App ID 用的游戏名（11-04 S0-5：AltServer 1.8.1 取 CFBundleDisplayName 建 App ID，中文名报「The name for this app is invalid」）：
    游戏自带标题按 美式英语 → 英式英语 → 其余语言 取第一个整个用拉丁字母写的（重音字母去掉附加符）；没有拉丁标题 → 取不到，调用方退回品牌名。
    不拿中文 / 韩文等标题删字凑名字：11-05 脑锻炼中文版只有韩 / 繁 / 简三个标题，删字得到「Nintendo Switch」，英文系统上显示成「Nintendo Switch S2Arm」"""
    p = nacp_path(path)
    with open(p, 'rb') as f:
        got, _ = titles(f.read())
    for i in (0, 1) + tuple(sorted(set(got) - {0, 1})):
        if i in got and _latin(got[i]) and _ascii(got[i]):
            return _ascii(got[i])
    return ''


# nacp ApplicationTitle 语言槽 → 苹果 .lproj 语言代码（Switch 固件语言顺序）
LPROJ = {0: 'en', 1: 'en-GB', 2: 'ja', 3: 'fr', 4: 'de', 5: 'es-419', 6: 'es', 7: 'it', 8: 'nl', 9: 'fr-CA',
         10: 'pt-PT', 11: 'ru', 12: 'ko', 13: 'zh-Hant', 14: 'zh-Hans', 15: 'pt-BR'}


def localized_names(path, suffix='', brand=True):
    """各系统语言的桌面名（11-05 维护者「手机上 App 都叫游戏名 S2Arm」）：nacp 每个有标题的语言槽 → {<lproj>: 「<该语言标题> S2Arm[ 后缀]」}；
    简 / 繁中文槽和开发区域 en 是空的时用 title() 选出的名字（中文系统、以及没有对应标题的系统语言都能看到游戏名）。Info.plist 本体的 CFBundleDisplayName 另走 ascii_display_name"""
    p = nacp_path(path)
    with open(p, 'rb') as f:
        got, _ = titles(f.read())
    out = {LPROJ[i]: compose(t, suffix, brand) for i, t in sorted(got.items()) if i in LPROJ and t.strip()}
    for zh in ('zh-Hans', 'zh-Hant'):
        out.setdefault(zh, compose(title(path), suffix, brand))
    # 开发区域 en（Info.plist CFBundleDevelopmentRegion）也总要有：系统语言没有对应 .lproj 时 iOS 退到开发区域，开发区域也没有才用 Info.plist 本体的 ASCII 名。
    #   11-07 DQ10（只有日文标题）在英文系统的 Duo 上桌面只显示「S2Arm」：ASCII 名删光日文只剩品牌、en.lproj 又没有；补上后任何没有对应标题的系统语言都显示游戏自带名
    out.setdefault('en', compose(title(path), suffix, brand))
    return out


def ascii_display_name(path, suffix='', brand=True):
    """Info.plist 的 CFBundleDisplayName（侧载工具拿它建 App ID）：「<英文游戏名> S2Arm[ <后缀>]」全 ASCII；中文名另放 zh-Hans / zh-Hant 本地化，
    中文系统的手机桌面照样显示中文（pack/ship_ext.py build）。英文名取不到 → 「S2Arm」"""
    game, suf = ascii_title(path), _ascii(suffix or '')
    return ' '.join(x for x in (game, BRAND if brand or not game else '', suf) if x)   # 不带品牌（独立 App）时英文名取不到也退回「S2Arm」


def main(argv=None):
    ap = argparse.ArgumentParser(description='装机 App 显示名（游戏自带 control.nacp 标题 + S2Arm）')
    ap.add_argument('path', help='control.nacp 文件，或含 ctl/control.nacp 的解包目录 / 产物根')
    ap.add_argument('--suffix', default='', help='附在「S2Arm」后面的区分字样（如「实验」）')
    ap.add_argument('--title', action='store_true', help='只打印游戏名')
    a = ap.parse_args(argv)
    try:
        print(title(a.path) if a.title else display_name(a.path, a.suffix))
    except (NoTitle, OSError) as e:
        print(f'【红】取不到游戏自带名字：{e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
