#!/usr/bin/env python3
"""共享位置扫描（10-20 共性根因 B 类：s2a_flags 撞位、Mac 局共用数据 / 缓存目录、门禁抢锁、产物根互相覆盖，根子都是「共享资源没归属」）。
在仓库根跑：python3 tools/shared_path_lint.py [--list]
扫：tools/ pack/ tests/ 的脚本、各 <目录>/gate.sh、runtime/run_mac.sh、compat/truth/ 脚本，以及宿主 / 渲染器 / 服务层源码里的缺省路径。
认作「共享位置」的写法：~ 或 $HOME 下的路径（Documents、Library/Caches、.s2arm/run/s2arm/<名> …）、/tmp 与 /private/tmp 下的固定名。
私有写法不报：局目录 / 临时目录变量下（$D $O $T $J $W …）、mktemp、带 $$ 或 XXXXXX 的临时名、仓库内 build/（每棵工作树各一份）。
每个共享位置必须在 tools/shared_paths.tsv 登记（路径前缀、归属线、用途、并发规则），没登记的 → 退出 1（门禁红），并列出 文件:行 与路径。
--list：打印全部共享位置与登记情况（清单用），不判红。
文档根规则（11-07 Mac 新前端 Hades 白屏根修）：C / ObjC / C# 源码里自己拼 $HOME/Documents（"%s/Documents"、"%@/Documents"、"Documents" 作路径段）一律红，
  改调唯一取法 runtime/include/s2a_docs.h（S2A_DOCS，否则 $HOME/Documents）。Mac 宿主不在沙盒，$HOME/Documents 是用户真实文稿夹（隐私保护，新签名程序首次 open 被授权框挡住）。
  白名单 DOCS_ROOT_OK 只放有理由的；测试文件（t_*、*_test.*、tests/ 目录，tests/autoplay 的宿主源码除外）与外来源码不扫。"""
import os, re, subprocess, sys

SCOPE = re.compile(r'^(tools|pack|tests)/[^/]+\.(sh|py)$|^tests/[^/]+/[^/]+\.(sh|py|c|h)$|^[^/]+(/[^/]+)?/gate\.sh$|^runtime/run_mac\.sh$|^compat/truth/[^/]+\.sh$'
                   r'|^(runtime/src|graphics/metal|graphics/metal/cs|services/S2A\.Services)/[^/]+\.(c|h|m|cs)$')
# 家目录写法按文件类型认：脚本 ~/ $HOME/ ${HOME}/；Python 引号里的 '~/…'；C / C# 里 ~ 是按位取反，只认下面 DOCS_C 那几种拼法
PAT_SH = re.compile(r'(\$HOME/|\$\{HOME\}/|(?<![\w}])~/)([A-Za-z0-9_.@%$/{}-]*)|((?:/private)?/tmp/[A-Za-z0-9_.@${}-]+)')
PAT_PY = re.compile(r'([\'"]~/)([A-Za-z0-9_.@%$/{}-]*)|((?:/private)?/tmp/[A-Za-z0-9_.@${}-]+)')
PAT_C = re.compile(r'(\$HOME/)([A-Za-z0-9_./-]*)|((?:/private)?/tmp/[A-Za-z0-9_.@${}-]+)')
DOCS_C = re.compile(r'"%s/Documents|"Documents"|"Library", "Caches"|SpecialFolder\.Personal\), "S2A"')   # 源码里拼 HOME 的写法


DOCS_ROOT = re.compile(r'%[s@]/Documents|@?"Documents"')
DOCS_ROOT_EXT = ('.c', '.h', '.m', '.mm', '.inc', '.cpp', '.cs', '.swift')
DOCS_ROOT_OK = {   # 文件 → 理由（只放有理由的）
    'runtime/include/s2a_docs.h': '唯一取法本身',
    'runtime/src/launchctx.c': '启动上下文按传入的 HOME 推 iOS 容器布局（兼容 / 多款容器，单测直接喂 home），S2A_DOCS 的来源',
    'graphics/loop/ShaderPack.cs': 'C# 调不到 C 头：DocsRoot() 是本程序集同口径的唯一一份',
    'graphics/metal/gal_core.m': '渲染器自成一体不含原生头，且 graphics/metal 改动即冷（tools/coldcheck.py ③）；只在显式设诊断变量 NXGAL_PASS_LOG 为相对名时走，下一笔 graphics/metal 冷改动顺带归位',
    'graphics/metal/gal_present.m': '同 gal_core.m；只在显式设诊断变量 NXGAL_FRAME_CAP 时走',
    'shell/Sources/S2ArmShellHost/S2ArmStorage.swift': '存储总览（只读）：扫到的相对路径首段与 Documents 比对来分类，不拼文档根、不按它开文件；扫描根由调用方给沙盒根',
}
DOCS_ROOT_TEST = re.compile(r'(^|/)t_[^/]*$|_test\.[^/]*$|(^|/)[^/]*[Tt]ests?/|/third_party/|^compat/tree/src/Ryujinx(?!\.Audio\.Backends\.Apple)')


def docs_root_bad(files):
    """→ [文件:行]：源码里自己拼 $HOME/Documents、不在白名单的行"""
    bad = []
    for f in files:
        if not f.endswith(DOCS_ROOT_EXT) or f in DOCS_ROOT_OK: continue
        if DOCS_ROOT_TEST.search(f) and not (f.startswith('tests/autoplay/') and not os.path.basename(f).startswith('t_')): continue
        try: lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
        except OSError: continue
        for i, l in enumerate(lines, 1):
            if l.strip().startswith(('//', '*', '/*')): continue
            if DOCS_ROOT.search(re.sub(r'\s//\s.*$', '', l)): bad.append(f'{f}:{i}')
    return bad


def norm(m):
    if m.group(3):   # /tmp 固定名
        t = m.group(3)
        if '$$' in t or 'XXXXXX' in t or '${' in t and '}' not in t: return None
        return t.replace('/private/tmp', '/tmp')
    p = (m.group(2) or '').strip('/')
    if '}' in p:
        before, after = p.split('}', 1)
        before = re.split(r'[\'"\s;)|&}]|\$', before)[0].rstrip('/.@_')
        after = re.split(r'[\'"\s;)|&}]|\$', after.lstrip('/'))[0].rstrip('/.@_')
        p = before + ('/' + after if after else '')
    else:
        p = re.split(r'[\'"\s;)|&}]|\$', p)[0].rstrip('/.@_')   # 只取变量 / 花括号之前的固定前缀
    return '~/' + p if p else '~'


def load_reg(path='tools/shared_paths.tsv'):
    # 表配了 merge=union（.gitattributes，10-30 列车线）：两支各加一行直接并起来；两支都改同一行时并集合并会留下同一路径的新旧两行——
    #   内容完全相同的重复行无害（去重），同一路径两行内容不一致 → 红，要人留下对的那一行（不让并集静默保留两种说法）
    reg, seen = [], {}
    for l in open(path, encoding='utf-8'):
        l = l.rstrip('\n')
        if not l or l.startswith('#'): continue
        c = l.split('\t')
        if len(c) < 4 or not all(x.strip() for x in c[:4]): sys.exit(f'🔴 登记表行缺列（要 4 列：路径前缀 归属线 用途 并发规则）：{l[:80]}')
        if c[0] in seen:
            if seen[c[0]] != l: sys.exit(f'🔴 登记表同一路径两行内容不一致（并集合并时两支都改了这一行）：{c[0]}——留下对的那一行、删掉另一行')
            continue
        seen[c[0]] = l; reg.append(c[0])
    return reg


def covered(p, reg):
    return any(p == r or p.startswith(r.rstrip('/') + '/') or (r.endswith('*') and p.startswith(r[:-1])) for r in reg)


def main():
    tracked = subprocess.run(['git', 'ls-files'], capture_output=True, text=True, check=True).stdout.split('\n')
    files = [f for f in tracked if SCOPE.match(f) and f != 'tests/shared_path_test.sh']   # 本扫描器单测里的反例夹具不算
    docs_bad = docs_root_bad(tracked)
    reg = load_reg(); found = {}
    for f in files:
        try: lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
        except OSError: continue
        for i, l in enumerate(lines, 1):
            s = l.strip()
            if s.startswith(('#', '//', '*', '<!--')): continue
            code = re.sub(r'\s(#|//)\s.*$', '', l)   # 行尾注释
            pat = PAT_SH if f.endswith('.sh') else PAT_PY if f.endswith('.py') else PAT_C
            for m in pat.finditer(code):
                p = norm(m)
                if p and p not in ('~', '~/.s2arm', '~/.s2arm/run', '~/.s2arm/run/s2arm'): found.setdefault(p, []).append(f'{f}:{i}')
            if DOCS_C.search(code): found.setdefault('~/Documents', []).append(f'{f}:{i}')
    bad = {p: w for p, w in found.items() if not covered(p, reg)}
    if '--list' in sys.argv:
        for p in sorted(found): print(f'{"登记" if p not in bad else "未登记"}\t{p}\t{len(found[p])}\t{" ".join(found[p][:4])}')
        return
    for p in sorted(bad): print(f'未登记的共享位置 {p}：{" ".join(bad[p][:6])}')
    for w in docs_bad: print(f'自己拼 $HOME/Documents（改调 runtime/include/s2a_docs.h 的 s2a_docs_root / s2a_docs_path）：{w}')
    print(f'期望 共享位置全部登记（tools/shared_paths.tsv）→ 真结果 {len(found)} 处共享位置、未登记 {len(bad)} 处（扫 {len(files)} 个文件）')
    print(f'期望 源码不自己拼 $HOME/Documents → 真结果 {len(docs_bad)} 处（扫 {sum(f.endswith(DOCS_ROOT_EXT) for f in tracked)} 个源码文件，白名单 {len(DOCS_ROOT_OK)} 个）')
    sys.exit(1 if bad or docs_bad else 0)


if __name__ == '__main__':
    main()
