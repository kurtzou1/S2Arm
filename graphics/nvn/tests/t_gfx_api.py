#!/usr/bin/env python3
# 图形接口判法单测（graphics/nvn/tools/gfx_api.py classify）：特征按真实游戏的形态手写，期望按判法规则手写，不由实现推出。
# 真实样本（10-25 实测）：我方 10 款 main 都不导入 EGL；马车8 main 5 处 #version + glslc 导入；哈迪斯 vk* 导入、无 NVN。
# 用法：python3 graphics/nvn/tests/t_gfx_api.py
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from gfx_api import classify, features, vk_lookup, gl_driver, nvn_module, gl_also, romfs_glsl, RO_LOOKUP
import struct, tempfile

def F(**k):
    f = {'egl_window': False, 'egl_ctx': False, 'gl_source': False, 'glsl_main': 0, 'glsl_romfs': 0, 'nvn': False, 'vk': 0, 'vk_lookup': None, 'egl_proc': False, 'gl_driver': None}; f.update(k); return f

CASES = [
    ('NVN 款（动森形态）', F(nvn=True), 'nvn'),
    ('glslc 现编 GLSL 的 NVN 款（马车8 形态：5 处 #version、不建 EGL 窗口）', F(nvn=True, glsl_main=5), 'nvn'),
    ('为 SDL 导入 EGL 的 NVN 款：带 SDL GLES 渲染器（有 glShaderSource 字串），着色器不写 #version', F(nvn=True, egl_window=True, gl_source=True), 'nvn'),
    ('为 SDL 导入 EGL 的 NVN 款：没有 GL 渲染器', F(nvn=True, egl_window=True), 'nvn'),
    ('OpenGL 款（数码宝贝形态：EGL 窗口 + glad 取 glShaderSource + main 里有 GLSL，同时导入 NVN）', F(nvn=True, egl_window=True, gl_source=True, glsl_main=12), 'gl'),
    ('OpenGL 款：GLSL 只在 romfs 明文里', F(egl_window=True, gl_source=True, glsl_romfs=1), 'gl'),
    ('有 glShaderSource 和 GLSL 但不建 EGL 窗口：不算 GL', F(nvn=True, gl_source=True, glsl_main=3), 'nvn'),
    ('GL 驱动在别的模块（杀戮尖塔形态：main 无 NVN、EGL 窗口 + eglGetProcAddress，subsdk0 定义 glShaderSource）', F(egl_window=True, egl_proc=True, gl_driver='subsdk0'), 'gl'),
    ('同样形态但没有可认的 GL 驱动模块（gl_driver 为空）', F(egl_window=True, egl_proc=True), 'unknown'),
    ('同样形态但 main 导入 NVN（为 SDL 建 EGL 窗口的 NVN 款）', F(nvn=True, egl_window=True, egl_proc=True, gl_driver='subsdk0'), 'nvn'),
    ('有 GL 驱动、EGL 窗口，但没有 GL 入口（无 eglGetProcAddress、无 glShaderSource）', F(egl_window=True, gl_driver='subsdk0'), 'unknown'),
    ('有 GL 驱动、GL 入口，但不建 EGL 窗口', F(egl_proc=True, gl_driver='subsdk0'), 'unknown'),
    ('Vulkan 款（哈迪斯形态）', F(vk=100), 'vulkan'),
    ('同时导入 vk* 与 NVN：按 NVN（Vulkan 判法要求没有 NVN）', F(vk=100, nvn=True), 'nvn'),
    ('按名取 Vulkan 款（Minecraft 形态：main 无 vk* 导入，经 LookupSymbol 取 subsdk0 的 vkGetInstanceProcAddr）', F(vk_lookup='subsdk0'), 'vulkan'),
    ('按名取形态但 main 导入 nvnBootstrapLoader：按 NVN', F(vk_lookup='subsdk0', nvn=True), 'nvn'),
    ('什么接口都没有', F(), 'unknown'),
    ('NVN 渲染器在 romfs NRO（EA SPORTS FC 26 形态：main 不导入 nvnBootstrapLoader，NRO 导入）', F(nvn_module='romfs/Engine.Render.Core2.PlatformNvn.nro'), 'nvn'),
    ('NVN 渲染器在 ExeFS subsdk（main 不导入，subsdk1 导入）', F(nvn_module='exefs/subsdk1'), 'nvn'),
    ('GL 判法先于别的模块的 NVN：AM2R 形态（GL 驱动在 subsdk0）即便给了 nvn_module 也按 GL', F(egl_window=True, egl_proc=True, gl_driver='subsdk0', nvn_module='exefs/subsdk0'), 'gl'),
    ('Vulkan 判法先于别的模块的 NVN', F(vk=100, nvn_module='exefs/subsdk1'), 'vulkan'),
    ('main 不是 NSO（出包单测的假产物根）', None, 'unknown'),
    ('32 位游戏（二之国形态）', {'arm32': True}, 'arm32'),
]
fails = 0
for name, f, want in CASES:
    got, why = classify(f)
    ok = got == want; fails += not ok
    print(f'  {"过" if ok else "败"} {name}：期望 {want}，判 {got}（{why}）')
# 判不出时依据写进结果（D-Z6WZ 形态：main 不导入 nvnBootstrapLoader、导入按名查找、映像里有名字串、只有 main rtld sdk）：期望按字段手写
got, why = classify(F(evidence=dict(imports=812, ro_lookup=True, nvn_name=True, nvn_like=['nvnPrivate0'], mods=['main', 'main.npdm', 'rtld', 'sdk'])))
want_why = '没有 NVN / Vulkan / OpenGL 任一接口的证据；依据：main 导入 812 个、按名查找（nn::ro::LookupSymbol）有、映像里 nvnBootstrapLoader 名字串有、带 nvn 的导入 nvnPrivate0、ExeFS 模块 main main.npdm rtld sdk'
ok = (got, why) == ('unknown', want_why); fails += not ok; CASES.append(None)
# D-TW4Z：判不出时再打 nn:: 命名空间个数与其余导入（期望手写）；旧依据（没有这两项）照上一条原样
got2, why2 = classify(F(evidence=dict(imports=253, ro_lookup=False, nvn_name=False, nvn_like=[], mods=['main', 'main.npdm', 'rtld', 'sdk'],
                                      ns=[('os', 40), ('vi', 3)], others=['vkFoo', 'glBar'])))
want2 = '没有 NVN / Vulkan / OpenGL 任一接口的证据；依据：main 导入 253 个、按名查找（nn::ro::LookupSymbol）无、映像里 nvnBootstrapLoader 名字串无、带 nvn 的导入 无、ExeFS 模块 main main.npdm rtld sdk、nn 命名空间 os×40 vi×3、其余导入（前 30）vkFoo glBar'
ok2 = (got2, why2) == ('unknown', want2); fails += not ok2; CASES.append(None)
print(('  过 ' if ok2 else '  ✗ ') + '判不出时打 nn 命名空间与其余导入' + ('' if ok2 else f'：{why2!r}'))
from gfx_api import nn_namespaces, other_imports
ns = nn_namespaces({'_ZN2nn2os10SleepThreadE', '_ZN2nn2os9LockMutexE', '_ZN2nn2vi11OpenDisplayE', 'memcpy', '_ZNSt3__14coutE'})
oi = other_imports({'_ZN2nn2os10SleepThreadE', 'memcpy', '_ZNSt3__14coutE', 'nvnFoo', 'vkCreateInstance'})
ok3 = ns == [('os', 2), ('vi', 1)] and oi == ['nvnFoo', 'vkCreateInstance']; fails += not ok3; CASES.append(None)
print(('  过 ' if ok3 else '  ✗ ') + f'命名空间计数 {ns}、其余导入 {oi}')
print(f'  {"过" if ok else "败"} 判不出时依据写进结果：{why}')
# features 读 main.npdm 判位宽（META 头 0xC 字节 bit0 = 64 位指令集）：flags 0 → 32 位，不碰 main；flags 1 → 照旧看 main（这里 main 不是 NSO → None）
for flags, want in ((0x00, {'arm32': True}), (0x01, None), (0x3F, None)):
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, 'main.npdm'), 'wb').write(b'META' + bytes(8) + struct.pack('<I', flags) + bytes(0x70))
        open(os.path.join(d, 'main'), 'wb').write(b'not an NSO')
        got = features(d); ok = got == want; fails += not ok; CASES.append(None)
        print(f'  {"过" if ok else "败"} main.npdm flags {flags:#x}：期望 {want}，得 {got}')
# vk_lookup（按名取 Vulkan 的三条）：特征按 Minecraft 1.21.111 实测形态手写——main 导入 1065 个、无 vk* / nvn* / egl / gl，导入 nn::ro::LookupSymbol 与 LookupModuleSymbol，
# 映像里有 "vkGetInstanceProcAddr\0"；subsdk0（NVIDIA Vulkan 驱动）导出 vkGetInstanceProcAddr 等 249 个 vk*，sdk 导出 nvnBootstrapLoader（所有款的 sdk 都带，不算证据）
MC_IMP = {RO_LOOKUP, '_ZN2nn2ro18LookupModuleSymbolEPmPKNS0_6ModuleEPKc', '_ZN2nn2fs9MountRomEPKcPvm', 'malloc'}
MODS = [('rtld', set()), ('sdk', {'nvnBootstrapLoader', '_ZN2nn2ro12LookupSymbolEPmPKc'}), ('subsdk0', {'vkGetInstanceProcAddr', 'vkCreateInstance', 'vkQueuePresentKHR'})]
asked = []
def mods(defs=MODS):
    def it(): asked.append(1); return iter(defs)
    return it
LCASES = [
    ('Minecraft 形态：LookupSymbol + 名字串 + subsdk0 导出 vkGetInstanceProcAddr', MC_IMP, True, mods(), 'subsdk0', True),
    ('同样有名字串、LookupSymbol，但没有模块导出 vkGetInstanceProcAddr（取不到）', MC_IMP, True, mods([('rtld', set()), ('sdk', {'nvnBootstrapLoader'})]), None, True),
    ('同样形态但 main 导入 nvnBootstrapLoader：是 NVN 款，不看别的模块', MC_IMP | {'nvnBootstrapLoader'}, True, mods(), None, False),
    ('有名字串、有模块导出，但 main 只导入 LookupModuleSymbol（只查 NRO，碰不到 ExeFS 模块）', MC_IMP - {RO_LOOKUP}, True, mods(), None, False),
    ('导入 LookupSymbol、有模块导出，但 main 里没有名字串', MC_IMP, False, mods(), None, False),
]
for name, imp, has_name, m, want, want_read in LCASES:
    asked.clear(); got = vk_lookup(imp, has_name, m); read = bool(asked)
    ok = got == want and read == want_read; fails += not ok; CASES.append(None)
    print(f'  {"过" if ok else "败"} vk_lookup {name}：期望 {want}（读其它模块 {want_read}），得 {got}（读 {read}）')
# gl_driver（模块名, 导出, 导入）：杀戮尖塔实测——sdk 导出 nvnBootstrapLoader（所有款都带，不算）、subsdk0 导出 2985 个（含 glShaderSource）并导入 nvnBootstrapLoader
STS = [('rtld', set(), set()), ('sdk', {'nvnBootstrapLoader'}, set()), ('subsdk0', {'glShaderSource', 'eglGetProcAddress'}, {'nvnBootstrapLoader'})]
DCASES = [
    ('杀戮尖塔形态：只有 GL 驱动导入 NVN', STS, 'subsdk0'),
    ('另有模块导入 NVN（自带 NVN 渲染器）', STS + [('subsdk1', set(), {'nvnBootstrapLoader'})], None),
    ('没有模块定义 glShaderSource', STS[:2], None),
    ('两个模块都定义 glShaderSource（认不准）', STS + [('subsdk1', {'glShaderSource'}, set())], None),
    ('FF7 形态：另一个导入 NVN 的模块是 NvMM 视频解码库（导出 NvMMBufMgrInit）', STS + [('subsdk2', {'NvMMBufMgrInit', 'NvMMOpenBlock'}, {'nvnBootstrapLoader'})], 'subsdk0'),
    ('反证：导入 NVN 的另一模块只导出别的 NvMM 名、没有 NvMMBufMgrInit（不认作多媒体库）', STS + [('subsdk2', {'NvMMOpenBlock'}, {'nvnBootstrapLoader'})], None),
    ('AM2R 形态（11-01）：GL 驱动只导出 egl*（gl* 经 eglGetProcAddress 给），另有 NvMM 库导入 NVN', STS[:2] + [('subsdk0', {'eglGetProcAddress', 'eglCreateContext', 'NvGlEglApiInit'}, {'nvnBootstrapLoader'}),
     ('subsdk1', {'NvMMBufMgrInit'}, {'nvnBootstrapLoader'})], 'subsdk0'),
    ('反证：两个模块都只导出 eglGetProcAddress（认不准）', STS[:2] + [('subsdk0', {'eglGetProcAddress'}, set()), ('subsdk1', {'eglGetProcAddress'}, set())], None),
]
for name, mods_, want in DCASES:
    got = gl_driver(iter(mods_)); ok = got == want; fails += not ok; CASES.append(None)
    print(f'  {"过" if ok else "败"} gl_driver {name}：期望 {want}，得 {got}')
# nvn_module（main 判不出时 NVN 渲染器在哪）：FC 26 实测——ExeFS 只有 main / sdk / rtld（sdk 导出 nvnBootstrapLoader，不算），
#   romfs/Engine.Render.Core2.PlatformNvn.nro 导入 nvnBootstrapLoader、nvnPrivate0；main 导入 nn::ro::LoadModule
FC_MODS = [('rtld', set(), set()), ('sdk', {'nvnBootstrapLoader', 'nvnPrivate0'}, set())]
FC_NRO = [('Engine.Render.Core2.PlatformNvn.nro', {'nvnBootstrapLoader', 'nvnPrivate0', 'sem_destroy'})]
nro_read = []
def nros(lst):
    def it(): nro_read.append(1); return iter(lst)
    return it
NCASES = [
    ('FC 26 形态：ExeFS 没有、main 能装 NRO、NRO 导入 NVN', FC_MODS, nros(FC_NRO), 'romfs/Engine.Render.Core2.PlatformNvn.nro', True),
    ('同样的 NRO，但 main 不导入 nn::ro::LoadModule（nros 为 None：装不上，不算）', FC_MODS, None, None, False),
    ('NRO 都不导入 NVN', FC_MODS, nros([('a.nro', {'malloc'})]), None, True),
    ('ExeFS subsdk1 导入 NVN：直接认它、不读 NRO', FC_MODS + [('subsdk1', set(), {'nvnBootstrapLoader'})], nros(FC_NRO), 'exefs/subsdk1', False),
    ('ExeFS 里导入 NVN 的只有 NvMM 视频解码库：不认，接着看 NRO', FC_MODS + [('subsdk2', {'NvMMBufMgrInit'}, {'nvnBootstrapLoader'})], nros(FC_NRO), 'romfs/Engine.Render.Core2.PlatformNvn.nro', True),
]
for name, mods_, nr, want, want_read in NCASES:
    nro_read.clear(); got = nvn_module(iter(mods_), nr); read = bool(nro_read)
    ok = got == want and read == want_read; fails += not ok; CASES.append(None)
    print(f'  {"过" if ok else "败"} nvn_module {name}：期望 {want}（读 NRO {want_read}），得 {got}（读 {read}）')
# gl_also（NVN 款另带 GL，直连出库再出一份 GL 着色器库）：火影忍者 终极风暴羁绊 11-03 实测——main 导入 nvnBootstrapLoader、eglCreateContext、eglMakeCurrent、eglGetProcAddress，
#   有 glShaderSource 名字串，421 处 #version，不导入 eglCreateWindowSurface（Scaleform 画进帧缓冲对象）。期望按三条判据手写
NARUTO = F(nvn=True, egl_ctx=True, egl_proc=True, gl_source=True, glsl_main=421)
GCASES = [
    ('火影羁绊形态：NVN 主画面 + GL 上下文 + GL 入口 + GLSL', NARUTO, 1),
    ('同样形态但 GLSL 只在 romfs 明文里', F(nvn=True, egl_ctx=True, egl_proc=True, glsl_romfs=1), 1),
    ('为 SDL 建 GL 上下文的 NVN 款：有上下文与入口，着色器不写 #version', F(nvn=True, egl_ctx=True, egl_proc=True, gl_source=True), 0),
    ('glslc 现编 GLSL 的 NVN 款（马车8 形态）：有 #version、不建 GL 上下文', F(nvn=True, gl_source=True, glsl_main=5), 0),
    ('有上下文与 GLSL 但没有 GL 入口', F(nvn=True, egl_ctx=True, glsl_main=10), 0),
    ('主类别是 gl（数码宝贝形态）：不另出，GL 分支本来就出', F(nvn=True, egl_window=True, egl_ctx=True, gl_source=True, glsl_main=12), 0),
    ('主类别是 vulkan', F(vk=100, egl_ctx=True, egl_proc=True, glsl_main=3), 0),
    ('纯 NVN 款（动森形态）', F(nvn=True), 0),
]
for name, f, want in GCASES:
    got, why = gl_also(f); ok = got == want; fails += not ok; CASES.append(None)
    print(f'  {"过" if ok else "败"} gl_also {name}：期望 {want}，得 {got}（{why}）')
# romfs_glsl（审计 #1534 P1-97）：romfs 明文里找 #version 不把整文件读进 Python 堆（原先 h.read()：几 GB 的资源文件抛 MemoryError、判法进程退出、刷新停在 direct）。
#   造 64 MiB 的两个文件：一个全 0（没有 GLSL），一个只在最末尾写「#version 330」；期望：前者 0、后者 1，且两次扫描 Python 堆峰值都 < 8 MiB
#   （整文件读至少 64 MiB；8 MiB 由文件大小定，不由实现推出）；另有空文件夹在里面，不抛错
import tracemalloc
BIG = 64 << 20
with tempfile.TemporaryDirectory() as td:
    for sub, tail in (('none', b''), ('tail', b'#version 330\n')):
        os.makedirs(os.path.join(td, sub, 'Shader'))
        open(os.path.join(td, sub, 'Shader', 'empty.bin'), 'wb').close()
        with open(os.path.join(td, sub, 'Shader', 'big.bin'), 'wb') as h: h.truncate(BIG - len(tail)); h.seek(0, 2); h.write(tail)
    for sub, want in (('none', 0), ('tail', 1)):
        tracemalloc.start(); got = romfs_glsl(os.path.join(td, sub)); peak = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
        ok = got == want and peak < (8 << 20); fails += not ok; CASES.append(None)
        print(f'  {"过" if ok else "败"} romfs_glsl {sub}：期望 {want}、Python 堆峰值 < 8 MiB，得 {got}、峰值 {peak >> 20} MiB')
# 读不了的 RomFS 文件不静默跳过：romfs 里 a.bin（没有 GLSL）+ locked.bin、x.nro（读时抛 PermissionError，romfs_list 读法换成抛错的替身）。
#   期望（手写）：romfs_glsl 得 0，标准错误恰一行「【红】判 GLSL：romfs 里 2 个文件读不了」且带 locked.bin 与 x.nro；romfs_nros 什么都不给，标准错误一行「【红】判 NVN 模块」带 x.nro
import contextlib, io
import romfs_list
with tempfile.TemporaryDirectory() as td:
    for n in ('a.bin', 'locked.bin', 'x.nro'): open(os.path.join(td, n), 'wb').write(b'no shader here')
    def deny(real):
        def f(p, *a, **k):
            if os.path.basename(p) in ('locked.bin', 'x.nro'): raise PermissionError(13, 'Permission denied', p)
            return real(p, *a, **k)
        return f
    keep = romfs_list.map_file, romfs_list.read_file
    romfs_list.map_file, romfs_list.read_file = deny(keep[0]), deny(keep[1])
    try:
        err = io.StringIO()
        with contextlib.redirect_stderr(err): got = romfs_glsl(td)
        red = [l for l in err.getvalue().splitlines() if l.startswith('【红】')]
        ok = got == 0 and len(red) == 1 and red[0].startswith('【红】判 GLSL：romfs 里 2 个文件读不了') and 'locked.bin' in red[0] and 'x.nro' in red[0]; fails += not ok; CASES.append(None)
        print(f'  {"过" if ok else "败"} romfs_glsl 读不了的文件计红：期望 0 + 一行红（2 个、带 locked.bin 与 x.nro），得 {got}、红行 {red}')
        from gfx_api import romfs_nros
        err = io.StringIO()
        with contextlib.redirect_stderr(err): got = list(romfs_nros(td))
        red = [l for l in err.getvalue().splitlines() if l.startswith('【红】')]
        ok = got == [] and len(red) == 1 and red[0].startswith('【红】判 NVN 模块：romfs NRO 读不了：x.nro'); fails += not ok; CASES.append(None)
        print(f'  {"过" if ok else "败"} romfs_nros 读不了的 NRO 计红：期望 [] + 一行红（x.nro），得 {got}、红行 {red}')
    finally:
        romfs_list.map_file, romfs_list.read_file = keep
print(f'✓ t_gfx_api：{len(CASES)} 例全过' if not fails else f'✗ t_gfx_api：{fails} 例不符')
sys.exit(1 if fails else 0)
