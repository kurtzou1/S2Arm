#!/usr/bin/env python3
# 游戏用哪种图形接口画主画面（出包分流的唯一判法：graphics/tools/direct/direct_lib.py 调；接口说明 docs/研究/GL前端接口.md 第 1 节）。
# 看 exefs/main（静态，零配置；只有「按名取 Vulkan」的候选才另读 ExeFS 其它模块的导出表）：
#   Vulkan：不导入 nvnBootstrapLoader，且下面两种形态之一（判法在 vulkan_why，profile_guess.py shader_sources 也调它，单一来源）：
#     静态：main 导入 vk*（哈迪斯：vk* 100 个、NVN 0）；
#     按名取：main 一个 vk* 都不导入，而是运行时 nn::ro::LookupSymbol("vkGetInstanceProcAddr") 从 NVIDIA Vulkan 驱动模块取入口、其余 vk* 经它取
#       （Minecraft 1.21.111：main 导入 LookupSymbol、映像里有 "vkGetInstanceProcAddr" 名字串，subsdk0 定义 249 个 vk*）。三条同时成立才算：
#       ① main 导入 nn::ro::LookupSymbol；② main 映像里有以 \0 隔开的 vkGetInstanceProcAddr 名字串；③ ExeFS 里另有模块定义 vkGetInstanceProcAddr。
#       只有串、没有模块定义它（取不到）不算；只认 LookupSymbol（全局查已装模块），不认 LookupModuleSymbol（只查 nn::ro::LoadModule 装进来的 NRO，
#       碰不到 ExeFS 模块：sdk 里它只读 Module 自己的 RoModule）。①② 都中才读其它模块（subsdk 解压几十 MB，别的款不付这份成本）。
#   OpenGL：三条同时成立——① 导入 eglCreateWindowSurface（GL 画进窗口必经 EGL 窗口表面）；② 有 glShaderSource（导入，或按名取的字符串：glad 一类加载器）；
#           ③ main 里有 GLSL 源码（#version 开头的字符串；main 里没有时看 romfs 明文里有没有）。
#     三条缺一不算，各自防一种误认：只为 SDL 导入 EGL 的 NVN 款没有 ② 或 ③（SDL 自带的 GLES 渲染器着色器不写 #version）；
#     用 glslc 现编 GLSL 的 NVN 款（马车8 main 里 5 个 #version）没有 ①。
#   OpenGL（GL 驱动在 ExeFS 别的模块）：main 不导入 nvnBootstrapLoader、导入 eglCreateWindowSurface，且有 GL 入口（eglGetProcAddress 导入，或 glShaderSource
#     名字），且 ExeFS 里另有模块定义 glShaderSource（NVIDIA GL 驱动，它自己导入 nvnBootstrapLoader），除它和 NVIDIA 多媒体库（导出 NvMMBufMgrInit，视频解码用 NVN）以外没有模块导入 nvnBootstrapLoader
#     （杀戮尖塔 10-30：MonoGame AOT，main 经 eglGetProcAddress 取 GL 入口、GLSL 是 romfs 里不写 #version 的 .vs / .fs，subsdk0 = GL 驱动；main 里没有 NVN 时 EGL 窗口只能给 GL 用）。
#     这条不看 GLSL、不读 romfs：配置推导阶段（pack/stage_direct_profile.sh 不传 romfs）与出库阶段判法一致。
#   NVN：main 导入 nvnBootstrapLoader；或 main 一个都不中（不导入 nvnBootstrapLoader、不是 Vulkan / GL）而 NVN 渲染器在别的模块（nvn_module，下面三条按序）：
#     ① ExeFS 里 main 以外的模块导入 nvnBootstrapLoader（NVIDIA 多媒体库除外：导出 NvMMBufMgrInit，视频解码用 NVN，不是主画面渲染器）——装载器起局重定位它，同名导入照样解析到直连图形层；
#     ② romfs 里的 NRO 导入 nvnBootstrapLoader，且 main 导入 nn::ro::LoadModule（装得上它）——游戏的 nn::ro 重定位 NRO 时先问 rtld 的 LookupGlobalAuto，
#        装载器给的那个（runtime/src/loader.c ro_lookup_auto）先查直连图形层，同样拿到宿主 NVN（11-02 EA SPORTS FC 26：main 只有 9 个 nvn::pfncpp_* 导入，
#        romfs/Engine.Render.Core2.PlatformNvn.nro 导入 nvnBootstrapLoader、定义 534 个 pfncpp_*，原先「main 不导入」判成 unknown、直连配置推导拒掉）。
#     这两条只在 main 判不出时才读（subsdk 解压几十 MB、NRO 可达几 MB，别的款不付这份成本）。
#   都没有 → unknown（报出来，不猜）。
#   NVN 款另带 GL（--gl-also，只供直连出库再出一份 GL 着色器库，主类别不变）：判成 nvn 的款，三条同时成立——① main 导入 eglCreateContext 与 eglMakeCurrent（真建 GL 上下文；
#     画进离屏帧缓冲的不必导入 eglCreateWindowSurface）；② 有 GL 入口（glShaderSource 导入或名字串，或导入 eglGetProcAddress）；③ 有 GLSL 源码（main 里 #version，或 romfs 明文里）。
#     11-03 火影忍者 终极风暴羁绊：主画面 NVN，界面中间件 Scaleform 走 GL（无表面上下文 + 帧缓冲对象），main 里 421 段 GLSL；原先只出 NVN 库，GL 程序全部链接失败、界面不画。
#     只为 SDL 导入 EGL 的 NVN 款没有 ③（SDL 的 GLES 渲染器着色器不写 #version）；glslc 现编的 NVN 款（马车8）没有 ①。
#   32 位（main.npdm 的 META 头 0xC 字节 bit0 = 0，AArch32）：先于一切判掉 → arm32，退出码 3（Apple 芯片没有 32 位 ARM 执行状态，这类游戏跑不了；
#     它的 NSO 动态段是 ELF32，原先按 ELF64 解析直接 KeyError 崩——10-26 285 款普查 5 款：二之国、奇诺比奥队长、怪猎XX、新超马U豪华版、模拟山羊）
# 用法：gfx_api.py <exefs 目录> [romfs 目录]   → 打印「nvn|vulkan|gl|unknown<TAB>依据」
import os, re, struct, sys

def features(exefs, romfs=None):
    try:
        with open(os.path.join(exefs, 'main.npdm'), 'rb') as h: npdm = h.read(0x10)
        if len(npdm) == 0x10 and npdm[:4] == b'META' and not npdm[0xC] & 1: return {'arm32': True}
    except OSError: pass   # 没有 main.npdm（出包单测的假产物根）：照旧按 main 判
    p = os.path.join(exefs, 'main')
    if not os.path.isfile(p): return None   # 没有 main / 不是 NSO（出包单测的假产物根）：判不了，按 unknown
    with open(p, 'rb') as h:
        if h.read(4) != b'NSO0': return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import nso_syms   # 用时才导（要 lz4）：只测判法的单测不需要它
    img = nso_syms.load(os.path.join(exefs, 'main'))
    imp = {s for s, d, _ in nso_syms.dynsyms(img) if not d}
    f = {'egl_window': 'eglCreateWindowSurface' in imp, 'egl_ctx': 'eglCreateContext' in imp and 'eglMakeCurrent' in imp, 'gl_source': 'glShaderSource' in imp or b'glShaderSource\0' in img,
         'egl_proc': 'eglGetProcAddress' in imp, 'gl_driver': None,
         'glsl_main': len(re.findall(rb'#version[ \t]+\d+', img)), 'glsl_romfs': 0,
         'nvn': 'nvnBootstrapLoader' in imp, 'vk': vk_imports(imp), 'vk_lookup': None,
         # 判不出时写进依据（11-20 D-Z6WZ：一款 Switch 2 第一方游戏判成 unknown，没原件，日志里得有能定因的读数）：main 导入总数、
         #   是否导入按名查找（nn::ro::LookupSymbol）、映像里有没有 nvnBootstrapLoader 名字串、导入里带 nvn 的名字、ExeFS 模块
         'evidence': dict(imports=len(imp), ro_lookup=RO_LOOKUP in imp, nvn_name=b'nvnBootstrapLoader\0' in img,
                          nvn_like=sorted(n for n in imp if 'nvn' in n.lower())[:6], mods=sorted(os.listdir(exefs)))}
    if not f['vk'] and not f['nvn']: f['vk_lookup'] = vk_lookup(imp, VK_NAME in img, lambda: exefs_defs(exefs))   # main 静态判不出才看按名取
    if f['egl_window'] and not f['nvn'] and (f['gl_source'] or f['egl_proc']):   # GL 驱动在别的模块的候选才读其它模块（subsdk 解压几十 MB）
        f['gl_driver'] = gl_driver(exefs_syms(exefs))
    if not f['nvn'] and not f['vk'] and not f['vk_lookup'] and not f['gl_driver'] and not (f['egl_window'] and f['gl_source'] and f['glsl_main']):
        f['nvn_module'] = nvn_module(exefs_syms(exefs), (lambda: romfs_nros(romfs)) if RO_LOAD & imp and romfs else None)   # main 判不出：NVN 渲染器在别的模块（模块头注释 NVN 第 ① ② 条）
    if (f['egl_window'] or f['egl_ctx']) and (f['gl_source'] or f['egl_proc']) and not f['glsl_main'] and romfs:   # 只给前两条都中的候选扫 romfs（贵）：碰到第一个就停（含 NVN 款另带 GL 的候选）
        f['glsl_romfs'] = romfs_glsl(romfs)
    return f

GLSL_VERSION = re.compile(rb'#version[ \t]+\d+')

def romfs_glsl(romfs):
    """romfs 明文里有没有 GLSL 源码（#version 开头的串）→ 1 / 0，碰到第一个就停。打不开的文件跳过、没碰到 GLSL 时打一行红（个数 + 前几个路径，标准错误）。
    逐文件 mmap 后搜，不整文件 read()（审计 #1534 P1-97）：RomFS 里几 GB 的资源文件整份读进内存，内存不够时抛的是 MemoryError、不是 OSError，
    冒出进程，判图形接口失败、刷新停在 direct；mmap 由页缓存按需换入、可回收，Python 堆不随文件大小涨，匹配语义与整串搜相同（不切块，不漏跨块的串）。
    空文件不映射（mmap 不收 0 长度，里面也不会有 #version）"""
    # romfs_list：仓库里唯一的 RomFS 遍历（walk 同 os.walk）
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import romfs_list
    unread = []   # 读不了的文件：没碰到 GLSL 时计红（个数 + 前几个路径）——它们里面有没有 GLSL 判不了，GL 类别 / 另带 GL 会漏判（原先静默跳过）
    for d, _, fs in romfs_list.walk(romfs):
        for n in fs:
            p = os.path.join(d, n)
            try:   # 按路径读经 romfs_list（romfs/ 不在、只有 romfs.std 时从镜像读；目录形态同 open + mmap）
                if romfs_list.file_size(p) == 0: continue
                with romfs_list.map_file(p) as m:
                    if GLSL_VERSION.search(m): return 1
            except OSError as e: unread.append(f'{os.path.relpath(p, romfs)}（{type(e).__name__}：{e}）')
    if unread: print(f'【红】判 GLSL：romfs 里 {len(unread)} 个文件读不了（前 {min(3, len(unread))} 个：{"；".join(unread[:3])}），其余没有 #version；读不了的这些里有没有 GLSL 判不了', file=sys.stderr, flush=True)
    return 0

RO_LOOKUP = '_ZN2nn2ro12LookupSymbolEPmPKc'   # nn::ro::LookupSymbol(uintptr_t *out, const char *name)：在已装模块里按名查（Horizon rtld 的自动装载链）
VK_ENTRY = 'vkGetInstanceProcAddr'            # Vulkan 加载器入口：拿到它，其余 vk* 都经它取
VK_NAME = b'\0' + VK_ENTRY.encode() + b'\0'    # main 里交给 LookupSymbol 的名字串（前后 \0：整串，不是别的名字的一段）

def exefs_syms(exefs):   # 惰性给出 ExeFS 里 main 以外每个 NSO 模块的 (模块名, 导出符号集, 导入符号集)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import nso_syms
    for n in sorted(os.listdir(exefs)):
        p = os.path.join(exefs, n)
        if n == 'main' or not os.path.isfile(p): continue
        with open(p, 'rb') as h:
            if h.read(4) != b'NSO0': continue
        syms = nso_syms.dynsyms(nso_syms.load(p))
        yield n, {s for s, d, b in syms if d and b in (1, 2)}, {s for s, d, _ in syms if not d}

NVMM_MARK = 'NvMMBufMgrInit'   # NVIDIA 多媒体框架（视频解码 / 播放）的导出：这类模块自己导入 nvnBootstrapLoader 承载视频画面，不是主画面的 NVN 渲染器
RO_LOAD = {'_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi', '_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmib'}   # nn::ro::LoadModule 两版签名（loader.c ro_local_init 同一对）

def romfs_nros(romfs):   # 惰性给出 romfs 里每个 NRO 的 (romfs 相对路径, 导入符号集)：任意深度、不分大小写（与出包 runtime/rewriter/nro_to_nso.py 同口径），解析不了的跳过、读不了的计红（标准错误）
    # romfs_list：仓库里唯一的 RomFS 遍历（walk 同 os.walk）
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import nso_syms, romfs_list
    for d, _, fs in sorted(romfs_list.walk(romfs)):
        for n in sorted(fs):
            if not n.lower().endswith('.nro'): continue
            p = os.path.join(d, n)
            try:
                img = romfs_list.read_file(p)   # romfs/ 不在、只有 romfs.std 时从镜像读
                if img[0x10:0x14] != b'NRO0': continue
                yield os.path.relpath(p, romfs), {s for s, df, _ in nso_syms.dynsyms(img) if not df}   # NRO 映像不压缩，文件偏移即模块内偏移
            except OSError as e:   # 读不了（不同于下面读到了但解析不了的坏 NRO）：计红，它导不导入 nvnBootstrapLoader 判不了
                print(f'【红】判 NVN 模块：romfs NRO 读不了：{os.path.relpath(p, romfs)}（{type(e).__name__}：{e}）', file=sys.stderr, flush=True); continue
            except (ValueError, KeyError, IndexError, struct.error): continue

def nvn_module(modules, nros):
    """main 判不出接口时 NVN 渲染器在哪：modules = (模块名, 导出集, 导入集)（ExeFS 里 main 以外）；nros = 惰性给出 romfs NRO 的 (路径, 导入集)，
    只在 main 导入 nn::ro::LoadModule 且给了 romfs 时才有（否则 None：装不上 NRO，它不算），且只在 ExeFS 模块里没找到时才调。
    → 'exefs/<模块名>' / 'romfs/<NRO 路径>'，没有 → None（模块头注释 NVN 第 ① ② 条）"""
    hit = next((n for n, e, i in modules if 'nvnBootstrapLoader' in i and NVMM_MARK not in e), None)
    if hit: return 'exefs/' + hit
    if nros: return next(('romfs/' + p for p, i in nros() if 'nvnBootstrapLoader' in i), None)
    return None

def gl_driver(modules):
    """modules：(模块名, 导出集, 导入集)。定义 glShaderSource 的模块（GL 驱动；没有就认定义 eglGetProcAddress 的）名；没有、或除它以外还有模块导入 nvnBootstrapLoader（另有 NVN 渲染器）→ None。
    导出 NVMM_MARK 的 NVIDIA 多媒体库导入 NVN 不算另有渲染器（FINAL FANTASY VII 11-01：main 走 GL、subsdk0 = GL 驱动，subsdk2 = NvMM 视频解码库也导入 nvnBootstrapLoader，
    原先判成 unknown、直连配置推导拒掉）"""
    mods = list(modules); drv = [n for n, e, _ in mods if 'glShaderSource' in e]
    # GL 函数只经 eglGetProcAddress 给出、不导出 gl* 的 NVIDIA EGL/GL 驱动（AM2R 11-01：subsdk0 导出 egl* 与 NvGlEglApiInit、0 个 gl*）：认导出 eglGetProcAddress 的模块
    if not drv: drv = [n for n, e, _ in mods if 'eglGetProcAddress' in e]
    if len(drv) != 1: return None
    return None if any('nvnBootstrapLoader' in i for n, e, i in mods if n != drv[0] and NVMM_MARK not in e) else drv[0]

def vk_imports(imp):   # main 静态导入的 Vulkan 函数个数（vk 后接大写：vkCreateInstance 一类）
    return sum(1 for s in imp if re.match(r'vk[A-Z]', s))

def exefs_defs(exefs):   # 惰性给出 ExeFS 里 main 以外每个 NSO 模块导出的符号（有定义、全局 / 弱绑定：LookupSymbol 查得到的那些）：(模块名, 符号集)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import nso_syms
    for n in sorted(os.listdir(exefs)):
        p = os.path.join(exefs, n)
        if n == 'main' or not os.path.isfile(p): continue
        with open(p, 'rb') as h:
            if h.read(4) != b'NSO0': continue
        yield n, {s for s, d, b in nso_syms.dynsyms(nso_syms.load(p)) if d and b in (1, 2)}

def vk_lookup(imp, has_name, modules):
    """按名取 Vulkan 的形态：main 导入 nn::ro::LookupSymbol、不导入 nvnBootstrapLoader、映像里有 vkGetInstanceProcAddr 名字串（has_name），
    且 modules()（可迭代的 (模块名, 定义的符号集)，前几条都中才调）里有模块定义 vkGetInstanceProcAddr → 那个模块名；否则 None"""
    if 'nvnBootstrapLoader' in imp or RO_LOOKUP not in imp or not has_name: return None
    return next((n for n, defs in modules() if VK_ENTRY in defs), None)

def vulkan_why(vk, nvn, lookup):
    """Vulkan 判法（出包分流与配置推导共用）：vk = main 静态导入的 vk* 个数，nvn = main 导入 nvnBootstrapLoader，lookup = vk_lookup 的结果 → 依据；不是 Vulkan 回 None"""
    if nvn: return None
    if vk: return f'main 导入 {vk} 个 vk*、不导入 nvnBootstrapLoader'
    if lookup: return f'main 不导入 vk* / nvnBootstrapLoader，经 nn::ro::LookupSymbol 按名取 {VK_ENTRY}（{lookup} 定义它）'
    return None

def classify(f):
    """f：features() 的结果（单测直接给）→ (接口, 依据)"""
    if f is None: return 'unknown', '没有 exefs/main 或它不是 NSO，判不了'
    if f.get('arm32'): return 'arm32', '32 位（AArch32）游戏，不支持：Apple 芯片没有 32 位 ARM 执行状态（main.npdm 未置 64 位指令集标志）'
    vk = vulkan_why(f['vk'], f['nvn'], f.get('vk_lookup'))
    if vk: return 'vulkan', vk
    glsl = f['glsl_main'] or f.get('glsl_romfs', 0)
    if f['egl_window'] and f['gl_source'] and glsl:
        return 'gl', f'main 导入 eglCreateWindowSurface、有 glShaderSource、带 GLSL 源码（main 里 {f["glsl_main"]} 处 #version）'
    if not f['nvn'] and f['egl_window'] and (f['gl_source'] or f.get('egl_proc')) and f.get('gl_driver'):
        return 'gl', f'main 不导入 nvnBootstrapLoader、导入 eglCreateWindowSurface 并{"按名取 GL 入口（eglGetProcAddress）" if f.get("egl_proc") else "有 glShaderSource 名字"}，GL 驱动是 {f["gl_driver"]}（定义 glShaderSource，除 NVIDIA 多媒体库外别的模块不导入 NVN）'
    if f['nvn']:
        miss = [] if not f['egl_window'] else ['没有 glShaderSource'] if not f['gl_source'] else ['没有 GLSL 源码'] if not glsl else []
        return 'nvn', 'main 导入 nvnBootstrapLoader' + (f'（另导入 EGL 但{miss[0]}，不算 OpenGL 款）' if miss else '')
    if f.get('nvn_module'):
        w = f['nvn_module']
        return 'nvn', (f'main 不导入 nvnBootstrapLoader，NVN 渲染器是 {w}（导入 nvnBootstrapLoader；' +
                       ('装载器起局重定位它）' if w.startswith('exefs/') else 'main 经 nn::ro::LoadModule 装它，NRO 的导入经 rtld LookupGlobalAuto 解析）'))
    e = f.get('evidence')
    tail = ('；依据：main 导入 %d 个、按名查找（nn::ro::LookupSymbol）%s、映像里 nvnBootstrapLoader 名字串%s、带 nvn 的导入 %s、ExeFS 模块 %s' %
            (e['imports'], '有' if e['ro_lookup'] else '无', '有' if e['nvn_name'] else '无', '、'.join(e['nvn_like']) or '无', ' '.join(e['mods']))) if e else ''
    return 'unknown', '没有 NVN / Vulkan / OpenGL 任一接口的证据' + tail

def gl_also(f):
    """f：features() 的结果 → (0 / 1, 依据)：判成 nvn 的款是否另带 GL（模块头注释「NVN 款另带 GL」三条）"""
    if classify(f)[0] != 'nvn': return 0, '主类别不是 nvn'
    glsl = f['glsl_main'] or f.get('glsl_romfs', 0)
    if not f.get('egl_ctx'): return 0, 'main 不同时导入 eglCreateContext 与 eglMakeCurrent'
    if not (f['gl_source'] or f.get('egl_proc')): return 0, '没有 GL 入口（glShaderSource / eglGetProcAddress）'
    if not glsl: return 0, '没有 GLSL 源码（main 与 romfs 都没有 #version）'
    return 1, f'main 导入 eglCreateContext / eglMakeCurrent、有 GL 入口、带 GLSL 源码（main 里 {f["glsl_main"]} 处 #version）'

if __name__ == '__main__':
    a = [x for x in sys.argv[1:] if x != '--gl-also']
    if not a: sys.exit('用法：gfx_api.py [--gl-also] <exefs 目录> [romfs 目录]')
    f = features(a[0], a[1] if len(a) > 1 else None)
    if '--gl-also' in sys.argv[1:]:   # 另带 GL 判断（只给直连出库用）：打印「0|1<TAB>依据」，32 位等判不了的按 0
        if f and f.get('arm32'): print('0\t32 位'); sys.exit(0)
        g, why = gl_also(f) if f else (0, '判不了'); print(f'{g}\t{why}'); sys.exit(0)
    api, why = classify(f)
    print(f'{api}\t{why}')
    if api == 'arm32': sys.exit(3)   # 调用方按「判图形接口失败」停，红行里带这句原因
