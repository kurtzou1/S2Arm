#!/usr/bin/env python3
# Vulkan games' SPIR-V shaders → one Metal library + a resource table for the host's Vulkan layer (dm/gfx/vk/hle_vk.m). Hades ships its 74 shaders as SPIR-V files
# (RomFS Content/EffectsForgeSwitch/*.vert / *.frag); the game hands the same words to vkCreateShaderModule, so a shader is found again by the hash of its SPIR-V.
# Per shader:
#   · key = sha256(SPIR-V words)[:16] (hex); the Metal function is vk_<key>
#   · its descriptor bindings are renumbered per kind (uniform / storage buffers → [[buffer(n)]], images → [[texture(n)]], samplers → [[sampler(n)]], n from 0 in binding order)
#     by rewriting the Binding decorations in a copy of the SPIR-V, then translated with spirv-cross --msl-decoration-binding: the slots stay below Metal's limits whatever the
#     game's set / binding numbers are (Hades uses set 1 bindings up to 49), and the table records which (set, binding) each slot came from
#   · vertex shaders get --flip-vert-y: Vulkan's clip space has y pointing down, Metal's up, and the viewports stay as the game gives them
#   · vertex buffers are bound by the host from slot 30 downwards (30 - Vulkan binding), above every shader's buffer slots
#   · only resources the translated entry point takes are listed (a declared but unused one has no Metal slot to bind)
#   · a push-constant block gets the buffer slot after the descriptor buffers (spirv-cross puts it at buffer(0), where the first uniform buffer goes), listed as p:0.0=slot;
#     the host sets the pushed bytes there (Super Mario Galaxy: 54 of its 56 built-in shaders have one)
#   · compute shaders become Metal kernels, with their workgroup size listed as w:x.y=z (the host dispatches with it); a size set by specialization constants is skipped
#   · other stages are skipped and counted: Metal has no geometry shaders (Super Mario Galaxy has 2)
#   · a fragment shader with an output at location 1 also gets a variant vk_<key>_d where that output is [[color(0), index(1)]]: Super Mario Galaxy's GX shaders write
#     the second blend source at location 1 (no Index decoration), which NVIDIA's hardware feeds to dual-source blending; the host picks the variant for pipelines
#     whose blend factors read source 1
# Super Mario Galaxy generates its GX shaders at run time; they come from a capture folder (the Mac host's DM_VK_CAPTURE), read like a RomFS: every input folder is
# searched for SPIR-V files by their magic
# Output: <out>/vk/vk_shaders.metallib and <out>/vk/vk_shaders.tsv; --ios <dir> also writes <dir>/vk/ with an iPhone library (same table)
# Table rows: key <TAB> stage (vert / frag / comp) <TAB> resources, space-separated kind:set.binding=slot[*count] (count: an array of descriptors in consecutive slots; u uniform buffer, b storage buffer, t image, s sampler, c combined image sampler = texture and sampler slot n,
#   p push constants; w:x.y=z the workgroup size of a compute shader)
# Usage: vk_shaders.py <SPIR-V dir>... <out dir> [--ios <dir>]   (SPIR-V dirs: the RomFS, capture folders)
#        vk_shaders.py --header-only <out dir> [--ios <dir>]   a game whose RomFS holds no SPIR-V (it generates them at run time): tables with the header only and no
#        library, every shader is compiled on the device the first time it is met (hle_vk.m → vk_rt.inc); packing never boots the game to capture them
import concurrent.futures as cf, os, shutil, subprocess, sys, tempfile

# GL / Vulkan share the resource remapping and MSL backend; defaults match main.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../graphics/tools')))
from spirv_msl import MAGIC, metal_cmd, metal_run, red, spirv_files, translate

VK_LIB_ABI = 3   # = graphics/nvn/gfx/vk/vk_lib.h S2A_VK_LIB_ABI（3：MSL 3.1）

def one(path, tmp, root):
    # 单支翻译失败（spirv_msl.red 退出）只剔这一支（v0.3.1 拿不准不停）：返回 ('failed', 原因)，main 计数、打 [RED]
    try: return translate(path, tmp, root, stages=('vert', 'frag', 'comp'))
    except SystemExit as e: return ('failed', f'{path}: {e}')

def metallib(msls, out, sdk, extra, work):
    """work：临时目录（msls 都在它下面）；编译器的输入输出都放在这里（Windows 按相对路径交给编译器，见 spirv_msl.metal_run），库编好再挪进 out"""
    os.makedirs(out, exist_ok=True)
    airs = []
    def comp(m):
        a = m[:-6] + f'.{sdk}.air'
        try: r = metal_run(metal_cmd(sdk, 'metal', '-c', '-fpreserve-invariance', *extra, m, '-o', a), work, capture_output=True, text=True)
        except ValueError as e: red(str(e))   # 工具链本身起不来：环境问题，照旧停
        if r.returncode: return None, f'{m}: metal compile failed: {r.stderr.strip()[:400]}'
        return a, None
    with cf.ThreadPoolExecutor(os.cpu_count()) as ex: res = list(ex.map(comp, msls))
    bad = {m: e for m, (a, e) in zip(msls, res) if e}
    airs = [a for a, e in res if not e]
    if not airs: return None, bad
    lib = os.path.join(work, f'vk_shaders.{sdk}.metallib')
    # .air 清单走响应文件（同 graphics/metal/tools/gal_offline.py link）：11-06 Windows 出包机银河 2 第二包 3795 支，路径全拼在命令行上超 Windows 32767 字符（WinError 206）。
    #   每行一个带引号的路径；Windows 上反斜杠换成正斜杠（响应文件按转义规则读，反斜杠会被吃掉；metallib.exe 认正斜杠，Windows 出包机实测 @响应文件 链出含两函数的库）
    #   Windows 上清单里的路径同样写成相对 work（工作目录 = work），理由同 metal_run
    rsp = os.path.join(work, f'vk_airs.{sdk}.rsp')
    with open(rsp, 'w', encoding='utf-8') as f: f.write(''.join('"' + (os.path.relpath(a, work).replace(os.sep, '/') if os.name == 'nt' else a) + '"\n' for a in airs))
    try:
        if os.name == 'nt': r = metal_run(metal_cmd(sdk, 'metallib', '@' + os.path.basename(rsp), '-o', lib), work)
        else: r = metal_run(metal_cmd(sdk, 'metallib', '@' + rsp, '-o', lib), work)
        if r.returncode: red(f'metallib failed (rc={r.returncode})')
    except ValueError as e: red(str(e))
    finally: os.remove(rsp)
    dst = os.path.join(out, 'vk_shaders.metallib'); shutil.move(lib, dst)
    return dst, bad

def main():
    a = sys.argv[1:]
    ios = None
    if '--ios' in a: i = a.index('--ios'); ios = a[i + 1]; del a[i:i + 2]
    header_only = '--header-only' in a
    if header_only: a.remove('--header-only')
    if len(a) < (1 if header_only else 2) or (header_only and len(a) != 1): sys.exit('usage: vk_shaders.py <SPIR-V dir>... <out dir> [--ios <dir>] | --header-only <out dir> [--ios <dir>]')
    roots, out = a[:-1], a[-1]
    files = [(p, r) for r in roots for p in spirv_files(r)]
    if not files and not header_only: red(f'no SPIR-V files in {" ".join(roots)}')
    with tempfile.TemporaryDirectory() as tmp:
        with cf.ThreadPoolExecutor(os.cpu_count()) as ex: rows = list(ex.map(lambda pr: one(pr[0], tmp, pr[1]), files))
        seen, skipped = {}, {}
        failed = []
        for row in rows:
            if isinstance(row, str): skipped[row] = skipped.get(row, 0) + 1; continue
            if row[0] == 'failed': failed.append(row[1]); print('[RED] ' + row[1]); continue
            key, stage, res, msl, src = row
            if key in seen: continue
            seen[key] = (stage, res, msl, src)
        if skipped: print('[RED] skipped shader stages Metal does not have: ' + ', '.join(f'{k} {v}' for k, v in sorted(skipped.items())))
        msls = [m for v in seen.values() for m in v[2]]
        tsv = [f'# s2arm-vk-lib {VK_LIB_ABI}', '# Vulkan shaders (dm/gfx/tools/vk_shaders.py): key = sha256(SPIR-V)[:16], Metal function vk_<key>; resources kind:set.binding=slot (u uniform buffer, b storage buffer, t image, s sampler, c combined, p push constants)',
               '# spirv-cross ' + ' '.join((lambda r: r.stdout + r.stderr)(subprocess.run(['spirv-cross', '--revision'], capture_output=True, text=True)).split())]
        tsv += [f'{k}\t{v[0]}\t{" ".join(v[1])}\t{v[3]}' for k, v in sorted(seen.items())]
        dirs = [(os.path.join(out, 'vk'), 'macosx', ['-mmacosx-version-min=15.0'])]   # Mac 目标写明最低版本号（同 gl_shaders.py / NVN 支 Build.cs；不写时 Mac 跟 SDK、Windows metal.exe 缺省 10.15）
        # The iPhone library is compiled with -fmetal-math-mode=relaxed, as the NVN chain's (dm/ios/tools/ios_metal.py): the default fast mode lets the GPU compiler assume there is
        # no NaN / Inf, which would let it drop the NaN handling of the precise:: functions above
        if ios: dirs.append((os.path.join(ios, 'vk'), 'iphoneos', ['-mios-version-min=18.0', '-fmetal-math-mode=relaxed']))
        anyok, anybad = set(), set()   # 至少一个目标编成 / 编不过的键（汇总行）
        for d, sdk, extra in dirs:
            if not header_only:   # Metal 编不过的支剔掉、其余照链（v0.3.1）；每个目标各剔各的（审计 P1-176：原先 Mac 剔掉的键 iOS 编得过也不收，Mac 全灭连 iOS 库一起删）
                lib, bad = metallib(msls, d, sdk, extra, tmp)
                own = dict(seen)
                for k in [k for k, v in own.items() if any(m in bad for m in v[2])]:
                    why = next(bad[m] for m in own[k][2] if m in bad); print(f'[RED] {sdk} {k}: {why}'); del own[k]
                    if k not in anybad: anybad.add(k); failed.append(f'{k}: {why}')
                anyok |= own.keys()
                rows = tsv[:3] + [f'{k}\t{v[0]}\t{" ".join(v[1])}\t{v[3]}' for k, v in sorted(own.items())]
                if lib is None or not own:   # 这个目标一支不剩：同 --header-only，只这个目标出表头、设备首遇现编（另一个目标已链好的库照出）
                    os.makedirs(d, exist_ok=True); stale = os.path.join(d, 'vk_shaders.metallib')
                    if os.path.exists(stale): os.remove(stale)
                    open(os.path.join(d, 'vk_shaders.tsv'), 'w', encoding='utf-8', newline='\n').write('\n'.join(tsv[:3]) + '\n')
                    print(f'{sdk}: 0 shaders after dropping the ones this target cannot compile, table header only → {d}/vk_shaders.tsv'); continue
                open(os.path.join(d, 'vk_shaders.tsv'), 'w', encoding='utf-8', newline='\n').write('\n'.join(rows) + '\n')
                print(f'{sdk}: {len(own)} shaders → {lib}'); continue
            if header_only:   # no library: a stale one left in the folder would be loaded against an empty table
                os.makedirs(d, exist_ok=True); lib = os.path.join(d, 'vk_shaders.metallib')
                if os.path.exists(lib): os.remove(lib)
                open(os.path.join(d, 'vk_shaders.tsv'), 'w', encoding='utf-8', newline='\n').write('\n'.join(tsv) + '\n')
                print(f'{sdk}: 0 shaders, table header only → {d}/vk_shaders.tsv'); continue
        if not header_only: print(f'Vulkan 汇总：成功 {len(anyok)}、失败 {len(failed)}')

if __name__ == '__main__': main()
