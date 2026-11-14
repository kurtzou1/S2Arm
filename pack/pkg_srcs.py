#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""资源包与包外进 App 文件的清单、iOS 包键：唯一实现（#1100 Windows 出包，11-04 Windows 出包线；原 pack/ipa_key.sh 的三个 bash 函数，那里改成调本文件）。
Mac 出包（pack/ipa.sh 经 ipa_key.sh）与 Windows 的 Python 编排调同一份，不用 xxd / shasum / make。

  pkg_srcs.py srcs <产物根>                 资源包源清单：一行「包内路径=源路径」（pack.py 打的、包键算的都是这一份）；产物根有直连库就带上
  pkg_srcs.py app-files <款> <产物根>       包外进 App 的文件：一行「名=路径」（宽屏表、随包表、图标）
  pkg_srcs.py app-tables                    随包表清单（宿主源码里「随包表：<文件名>」的声明；runtime/build.mk 的 ios 目标拷进 App 的同一份）
  pkg_srcs.py widen-list <款> <构建号>      宽屏表选表（graphics/widen/scan/auto_pkg.sh list 调这里）：每行一个路径
  pkg_srcs.py key <前缀> <产物根> [<款>]    包键串（ipa.sh 的 PK）：前缀（提交与签名 / 包名等）+ 各阶段戳 + 资源抽样键 + 进包输入内容键
"""
import glob
import hashlib
import os
import re
import subprocess
import sys

H = os.path.dirname(os.path.abspath(__file__)); R = os.path.dirname(H)
WIDEN_NAMES = ('widen_enable.handheld.tsv', 'widen_enable.docked.tsv', 'widen_full.handheld.tsv', 'widen_full.docked.tsv')
DECL_GLOBS = ('runtime/src/*.c', 'ios/*.m', 'graphics/nvn/gfx/*/*.m', 'graphics/nvn/gfx/*/*.c', 'tests/autoplay/*.c')   # = runtime/build.mk S2A_DECL_SRCS（不含安卓目录：iOS 出壳会读这些源码，见 tools/weak_link_decl.py 头注）
DECL = re.compile(r'.*随包表：([^ （，]*)')


def run_root():
    return os.environ.get('S2A_RUN_ROOT') or os.path.join(os.path.expanduser('~'), '.s2arm', 'run')


def cat(p):   # = bash "$(cat p 2>/dev/null)"：没有就空，去掉末尾换行
    try:
        with open(p, encoding='utf-8', newline='') as f: return f.read().rstrip('\n')
    except OSError: return ''


def nonempty(p): return os.path.isfile(p) and os.path.getsize(p) > 0   # = [ -s p ]


def ls(d):   # = bash 的 "$d"/* "$d"/.[!.]*（按字节序；隐藏项排在一起）
    try: return sorted((n for n in os.listdir(d) if n not in ('.', '..')), key=lambda n: (n.startswith('.'), n.encode()))
    except OSError: return []


def srcs(w, sub=False):
    """资源包源（包内路径, 来源）。sub=True：多程序合集序号 n 的目录——系统数据、追加内容、补丁表各序号共用根上的，不重复带"""
    out = [('exefs/main.npdm', f'{w}/exefs/main.npdm'), ('romfs', f'{w}/romfs')]
    if os.path.isdir(f'{w}/ui_overlay/romfs'): out.append(('romfs', f'{w}/ui_overlay/romfs'))   # 界面布局覆盖层（pack/orch/stages.py _uilayout）：同包内路径后者优先（pack.py / verify.py）
    if nonempty(f'{w}/romfs.s2aidx'): out.append(('romfs.s2aidx', f'{w}/romfs.s2aidx'))   # RomFS 预建索引（pack/stage_romfsidx.sh），起局直接读
    if os.path.isfile(f'{w}/ctl/control.nacp'): out.append(('ctl/control.nacp', f'{w}/ctl/control.nacp'))
    if not sub and os.path.isdir(f'{w}/systemdata'): out.append(('systemdata', f'{w}/systemdata'))   # 共享字体、时区、0802 / 0823 等系统数据
    if not sub and nonempty(f'{w}/patch.tsv'): out.append(('patch.tsv', f'{w}/patch.tsv'))   # 真机验过的补丁随包（宿主 runtime/src/patch.c 在 Documents 没有时读这份）
    if not sub and nonempty(f'{w}/aoc.tsv'):   # 追加内容（pack/stage_aoc.sh）：清单 + 各 DLC 数据分区
        out.append(('aoc.tsv', f'{w}/aoc.tsv'))
        if os.path.isdir(f'{w}/aoc'): out.append(('aoc', f'{w}/aoc'))
    sd = f'{w}/shaders/direct'   # 直连着色器库（只有直连，11-07 拆通用模式：shaders/ 下别的通用产物不进包）；不带 link/（直连链接版已删）
    out += [(f'shaders/direct/{n}', f'{sd}/{n}') for n in ls(sd) if n != 'link']
    if not sub:   # 多程序合集（runtime/include/s2a_programs.h）：序号 n ≥ 1 在 programs/<n>/（游戏数据与直连库同根结构），从 1 起连续存在 exefs/main.npdm 的都带
        for n in range(1, 16):
            d = f'{w}/programs/{n}'
            if not os.path.isfile(f'{d}/exefs/main.npdm'): break
            out += [(f'programs/{n}/{x}', y) for x, y in srcs(d, sub=True)]
    return out


def build_id(w):   # = xxd -s 0x40 -l 16 -p exefs/main（NSO 头里的构建号）；读不了就空
    try:
        with open(f'{w}/exefs/main', 'rb') as f: f.seek(0x40); return f.read(16).hex()
    except OSError: return ''


def repo_table_dir(tb, g, b):
    """仓库人工验过的宽屏表目录：<款>_<构建号> 有就用它；没有按 main 构建号找唯一的 *_<构建号>（11-05 旷野之息：Windows / 一键出包包名是 t<程序号>，
    老表按款名 botw_de0b6ac4… 起，按包名找不到 → 启用 0 点退到整套放宽 → SIGBUS 闪退）。构建号 = main 的 Build ID，一款一版唯一，不靠包名。
    同一构建号有多个目录（不该有）→ 不猜、返回 None"""
    exact = os.path.join(tb, f'{g}_{b}')
    if os.path.isdir(exact): return exact
    try: hits = [d for d in os.listdir(tb) if d.lower().endswith('_' + b.lower()) and os.path.isdir(os.path.join(tb, d))]
    except OSError: return None
    return os.path.join(tb, hits[0]) if len(hits) == 1 else None


def widen_list(g, b):
    """宽屏表选表（规则只在这一处，pack/orch/stages.py selected_tables 也调这里）：仓库 graphics/widen/tables/<款>_<构建号>/ 或唯一的 *_<构建号>/（repo_table_dir；人工验过，优先）> 自动表 ${S2A_WIDEN_AUTO}/<款>_<构建号>/；自动表只在这一档位
    最近一条结论（<档位>.status 里第一条态为过 / 不过的行）是「过」时选"""
    tb = os.environ.get('S2A_WIDEN_DIR') or os.path.join(R, 'graphics', 'widen', 'tables')
    auto = os.environ.get('S2A_WIDEN_AUTO') or os.path.join(run_root(), 's2arm', 'widen', 'auto')
    out = []
    for n in WIDEN_NAMES:
        m = n[:-4].rsplit('.', 1)[1]
        rd = repo_table_dir(tb, g, b)
        a, b2 = os.path.join(rd, n) if rd else '', os.path.join(auto, f'{g}_{b}', n)
        if os.path.isfile(a): out.append(a)
        elif os.path.isfile(b2) and auto_ok(os.path.join(auto, f'{g}_{b}'), m): out.append(b2)
    return out


def auto_ok(d, m):
    try:
        with open(os.path.join(d, f'{m}.status'), encoding='utf-8') as f:
            for line in f:
                s = line.rstrip('\n').split('\t')[0]
                if s in ('过', '不过'): return s == '过'
    except OSError: pass
    return False


def app_tables():
    if os.environ.get('IPA_APP_TABLES') is not None: return os.environ['IPA_APP_TABLES'].split()   # 调用方已取过这份清单时直接给（单测逐项算键用）
    names = set()
    for pat in DECL_GLOBS:
        for p in glob.glob(os.path.join(glob.escape(R), pat)):
            with open(p, encoding='utf-8', errors='surrogateescape') as f:
                for line in f:
                    m = DECL.match(line.rstrip('\n'))
                    if m: names.add(m.group(1))
    return sorted(names, key=lambda s: s.encode())


def app_files(g, w):
    auto = widen_list(g, build_id(w))
    out = [(f'table:{os.path.basename(f)}', f) for f in auto]
    have = {os.path.basename(f) for f in auto}
    for t in app_tables():
        for f in sorted(glob.glob(os.path.join(glob.escape(w), t)), key=lambda s: s.encode()):
            if os.path.basename(f) in have: continue   # 宽屏自动表同名时以它为准
            out.append((f'table:{os.path.basename(f)}', f))
    icons = os.environ.get('S2A_ICONS') or os.path.join(run_root(), 's2arm', 'icons')
    ic = os.path.join(icons, f'{g}.jpg')   # 重抽的中文优先图标（tools/game_icons.sh），没有退回产物根的
    out.append(('icon', ic if nonempty(ic) else f'{w}/icon.jpg'))
    return out


def key(prefix, cur, g=None):
    py = os.environ.get('S2A_PY') or sys.executable
    r = subprocess.run([py, os.path.join(H, 'resource_input_key.py'), cur], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f'算进包资源输入键失败（pack/resource_input_key.py {cur}）')
    res = r.stdout.rstrip('\n')
    fa = [x for n, p in (app_files(g, cur) if g else []) for x in ('--file', f'{n}={p}')]
    r = subprocess.run([py, os.path.join(H, 'pkg_inputs_key.py'), *fa], input=''.join(f'{a}={b}\n' for a, b in srcs(cur)), capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f'算进包输入内容键失败（pack/pkg_inputs_key.py {cur}）')
    inp = r.stdout.rstrip('\n')
    vk = ''
    if os.path.isfile(f'{cur}/addr_need.tsv'):
        with open(f'{cur}/addr_need.tsv', 'rb') as f: vk = ' memory-v2=' + hashlib.sha256(f.read()).hexdigest()
    if os.environ.get('CFLAGS'): vk += ' cflags=' + os.environ['CFLAGS']
    s = lambda n: cat(f'{cur}/{n}')
    rew = s('.stage_rewrite') + (f' caps={s(".stage_caps")}' if nonempty(f'{cur}/.stage_caps') else '')
    idx = s('.stage_romfsidx')
    idx += f' dual={s(".stage_direct")}' + (f'+seed={s(".stage_direct_seed")}' if nonempty(f'{cur}/.stage_direct_seed') else '')   # 种子表在 shaders/ 下（进包内容键不读），靠阶段键带进包键
    return f'{prefix}{vk} {rew} {s(".stage_uilayout")} {idx} res={res} sys={s(".stage_sysdata")} in={inp}'


def main(a):
    out = sys.stdout
    if len(a) == 2 and a[0] == 'srcs': out.write(''.join(f'{x}={y}\n' for x, y in srcs(a[1])))
    elif len(a) == 3 and a[0] == 'app-files': out.write(''.join(f'{x}={y}\n' for x, y in app_files(a[1], a[2])))
    elif a == ['app-tables']: out.write(' '.join(app_tables()) + '\n')
    elif len(a) == 3 and a[0] == 'widen-list': out.write(''.join(f + '\n' for f in widen_list(a[1], a[2])))
    elif len(a) in (3, 4) and a[0] == 'key':
        try: out.write(key(a[1], a[2], a[3] if len(a) == 4 else None) + '\n')
        except RuntimeError as e: print(f'【红】{e}', file=sys.stderr); return 1
    else: print(__doc__, file=sys.stderr); return 2
    return 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8', newline='\n')   # Windows：清单里有中文路径，按 UTF-8、\n 写
    sys.exit(main(sys.argv[1:]))
