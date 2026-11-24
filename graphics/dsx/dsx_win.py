#!/usr/bin/env python3
"""Windows 出包机的直连翻译库 dsx.dll（#1100 W6，11-04 Windows 出包线；11-08 随 libdsx 从 graphics/metal/tools/nxgal_win.py 搬来）：dsx_win.py <输出 dsx.dll>
源码集合同 graphics/dsx/Makefile：本目录全部 .c（颜色出口 / 加固 / 溢出 / 曲面翻译 / 顶点自取纯 C 部分 / 直连 XC dsx_xc.c）+ 仓库内置 SPIRV-Cross（SPVC_SRC / SPVC_DEF / -std=c++17 -O2），
  导出与 Mac / iOS / Linux 的 libdsx 一致（11-05 Windows 出包机巫师3：旧小库缺 nxgal_dmsh_xc_tess，22 支外壳 / 域着色器每支翻译失败、只记成缺键；11-08 前也缺 nxgal_dmsh_xc）。
宏开关、告警即错同 Makefile，C 源另预包含本目录 win_posix.h 补 Windows 没有的 asprintf / memmem；Windows 没有 make，这里用 PATH 上的 LLVM clang / clang++（或 S2A_CC / S2A_CXX）直接编。
COFF 不认 dsx_abi.h 的 visibility("default")，导出表按 C 源码里标 NXGAL_API 的函数名生成（/EXPORT），不改 dsx_abi.h（改它会换 ABI 指纹与 Mac 库字节）。
输出已存在且比全部输入新就不重编；编在同目录的临时子目录里、用最终文件名链接，再改名过去（并发两路只会有一份完整产物）。
字节可复现：库整文件哈希进翻译键（graphics/tools/direct/dsh/batch/Store.cs ToolLib.Fp，PE 不拆节），lld-link 缺省把链接时刻写进文件头与导出表、
  导出表还记链接时的文件名，原先每编一次字节都不同，Windows 出包机每换一份代码检出全部着色器翻译缓存作废（shader cache: hit 0）。
  /Brepro 让时间戳取内容哈希；在临时子目录里按最终文件名链接，导出表记的名字不带进程号；SPIRV-Cross 的 assert 把 __FILE__（宽字符）编进库，
  -fmacro-prefix-map 把仓库根换成「.」，库里不带检出路径（Windows 出包机按提交号各一份检出）。
"""
import os as _pw_os, sys as _pw_sys; _pw_sys.path.append(_pw_os.path.join(_pw_os.path.dirname(_pw_os.path.abspath(__file__)), '..', '..', 'tools')); from pool_workers import cores  # noqa: E402  核数 / 进程池路数唯一来源（tools/pool_workers.py，#1332）
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SPVC_DIR = os.path.join(ROOT, 'graphics', 'third_party', 'spirv_cross')
# 「._」开头的是 macOS 在 exFAT 等盘上给文件配的 AppleDouble 附属文件（引擎副本可以在玩家的外置盘上），不是源码；make 的 $(wildcard *.c) 也不匹配点开头的名字
SRCS = sorted(f for f in os.listdir(HERE) if f.endswith('.c') and not f.startswith('._'))   # = Makefile SRCS（本目录全部 *.c）
HDRS = sorted(f for f in os.listdir(HERE) if f.endswith('.h') and not f.startswith('._'))   # = Makefile HDRS
SPVC_UNITS = ['spirv_cfg', 'spirv_cross', 'spirv_cross_c', 'spirv_cross_parsed_ir', 'spirv_glsl', 'spirv_msl', 'spirv_parser']   # = Makefile SPVC_SRC
SPVC_DEF = ['-DSPIRV_CROSS_C_API_MSL=1', '-DSPIRV_CROSS_C_API_GLSL=1']   # = Makefile SPVC_DEF
COMPAT = os.path.join(HERE, 'win_posix.h')   # Windows C 运行库缺的 asprintf / memmem
DEFS = []
PMAP = '-fmacro-prefix-map=' + ROOT + '=.'   # __FILE__ 去掉检出路径（字节可复现，见头注）
EXPORT = re.compile(r'^NXGAL_API\b[^(]*?\b(nxgal_\w+)\s*\(', re.M)


def exports():
    names = []
    for s in SRCS:
        names += EXPORT.findall(open(os.path.join(HERE, s), encoding='utf-8').read())
    return sorted(set(names))


def link_cmd(cxx, lib, objs, names):
    """链接命令：/Brepro = 文件头 / 导出表时间戳取内容哈希（字节可复现，见头注）"""
    return [cxx, '-shared', '-o', lib, *objs, '-Wl,/Brepro', *['-Wl,/EXPORT:' + n for n in names]]


def build(out):
    spvc = [os.path.join(SPVC_DIR, f) for f in sorted(os.listdir(SPVC_DIR)) if f.endswith(('.cpp', '.hpp', '.h')) and not f.startswith('._')]
    ins = [os.path.join(HERE, f) for f in SRCS + HDRS] + spvc + [os.path.abspath(__file__)]
    if os.path.exists(out) and os.path.getmtime(out) >= max(os.path.getmtime(p) for p in ins): return 0
    names = exports()
    if not names: print('【红】C 源码里找不到 NXGAL_API 导出函数', file=sys.stderr); return 1
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    cc, cxx = os.environ.get('S2A_CC') or 'clang', os.environ.get('S2A_CXX') or 'clang++'
    with tempfile.TemporaryDirectory(prefix='dsx-', dir=os.path.dirname(os.path.abspath(out))) as od:
        jobs = [[cc, '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', PMAP, *DEFS, '-include', COMPAT, '-I' + SPVC_DIR,
                 '-c', os.path.join(HERE, s), '-o', os.path.join(od, s + '.o')] for s in SRCS]
        jobs += [[cxx, '-std=c++17', '-O2', PMAP, *SPVC_DEF, '-c', os.path.join(SPVC_DIR, u + '.cpp'), '-o', os.path.join(od, u + '.o')] for u in SPVC_UNITS]
        with concurrent.futures.ThreadPoolExecutor(cores()) as ex: rcs = list(ex.map(lambda c: subprocess.run(c).returncode, jobs))
        bad = [os.path.basename(c[c.index('-c') + 1]) for c, r in zip(jobs, rcs) if r]
        if bad: print(f'【红】dsx.dll 编不出：{" ".join(bad)}', file=sys.stderr); return 1
        lib = os.path.join(od, os.path.basename(out))   # 链接器顺带出的导入库 .lib / .exp 也落在临时子目录，随它删
        # 只链接上面这些编译命令各自 -o 出来的目标文件（显式清单）。原先列临时目录收全部 .o：目录在 exFAT 盘上时 macOS 另写的 AppleDouble「._<名>.o」也被交给链接器
        r = subprocess.run(link_cmd(cxx, lib, sorted(c[c.index('-o') + 1] for c in jobs), names))
        if r.returncode: print(f'【红】dsx.dll 链接失败（退出 {r.returncode}）', file=sys.stderr); return 1
        os.replace(lib, out)
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    sys.exit(build(sys.argv[1]))
