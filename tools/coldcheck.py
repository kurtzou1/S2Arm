#!/usr/bin/env python3
# 冷改动核查（11-05 合入运维线把运行区 cmdr/coldcheck.py 收进仓库，列车入队时打「冷」标用）：python3 tools/coldcheck.py <git 目录> <main 提交> <分支提交>
#   冷 = 合入后要整批重出的改动，三类任一即算：
#   ① 翻译指纹：取 main 与「main 合进分支」两版树，各跑一次 dmsh_chain.xlate_fp()（生产翻译缓存键里的 C# Xfp，S2A.Dsh.csproj DshXfpInput 单一来源），值变了才算
#      （只看文件名会误判，如 DshVk.cs 早已剔出指纹）；树里没有 dmsh_chain.py / 着色器翻译器目录时两边都记「无」，不算变
#   ② 直连 / 抽取阶段键：pack/stage_inputs/{direct,extract}.tsv「入」列的文件在合并前后有改动
#   ③ libnxgal / spirv-cross 源码（graphics/metal/、graphics/third_party/spirv_cross/）：库内容（ToolLib.Fp）进翻译缓存键
#   shell.tsv 只决定重出壳，不算冷。
#   ④ 宿主 ↔ 库接口号：translator/dmsh_chain.py 的 `ABI = N` 合并前后不同（按该文件头的约定，宿主读库方式一变就只升它）→ 冷且 ABI，
#      列车强制归三级（ABI）、只在手动 cold-open 时合（11-06 维护者 批：冷窗口分级）
# 输出一行：「🧊 冷改动：…」或「不冷（…）」；退出码 10 = 冷、11 = 冷且宿主 ↔ 库接口号（ABI）变、0 = 不冷、2 = 核不了（合并冲突等，列车照热处理并在说明里写原因）
import os, re, sys, subprocess, tempfile, fnmatch, tarfile, io

def main(git, base, br):
    run = lambda *a: subprocess.run(['git', '-C', git] + list(a), capture_output=True, check=True).stdout
    try:
        merged = run('merge-tree', '--write-tree', base, br).split()[0].decode()
    except subprocess.CalledProcessError:
        print('核不了：与 main 合并有冲突'); return 2

    def fp(tree):
        paths = [p for p in ('graphics', 'translator', 'compat/tree/src/Ryujinx.Graphics.Shader', 'compat/tree/src/Spv.Generator')
                 if subprocess.run(['git', '-C', git, 'cat-file', '-e', f'{tree}:{p}'], capture_output=True).returncode == 0]
        if 'graphics' not in paths: return '无'
        d = tempfile.mkdtemp()
        try:
            tarfile.open(fileobj=io.BytesIO(run('archive', tree, *paths))).extractall(d, filter='data')
            tools = os.path.join(d, 'translator')
            if not os.path.exists(os.path.join(tools, 'dmsh_chain.py')): return '无'
            out = subprocess.run([sys.executable, '-c', 'import dmsh_chain as d; print(d.xlate_fp())'], cwd=tools, capture_output=True, text=True)
            return out.stdout.strip() or ('取不到：' + (out.stderr.strip().splitlines() or ['?'])[-1])
        finally:
            subprocess.run(['rm', '-rf', d])

    a, b = fp(base), fp(merged)
    # 任一侧取不到指纹（缺 .NET SDK 等）= 判不了翻译缓存键变没变：走「核不了」退出码 2（审计 P1-130：原先两边同一句错误比相等就判不冷）
    bad = [f'{n} {v}' for n, v in (('main', a), ('合并后', b)) if v == '无' or v.startswith('取不到')]
    if bad: print('核不了：翻译指纹 ' + '；'.join(bad)); return 2
    files = run('diff', '--name-only', base, merged).decode().split()
    stage = []
    for t in ('direct', 'extract'):
        try: tsv = run('show', f'{base}:pack/stage_inputs/{t}.tsv').decode()
        except subprocess.CalledProcessError: continue
        for line in tsv.splitlines():
            c = line.split('\t')
            if len(c) >= 2 and c[0] == '入':
                stage += [f'{t}阶段键 {f}' for f in files if f == c[1] or fnmatch.fnmatch(f, c[1]) or (c[1].endswith('/') and f.startswith(c[1]))]
    libs = [f for f in files if f.startswith(('graphics/metal/', 'graphics/third_party/spirv_cross/'))]
    hits = ([f'翻译指纹 {a} → {b}'] if a != b else []) + stage + ([f'库源码（libnxgal / spirv-cross，内容变则翻译缓存键变）{len(libs)} 个：{" ".join(libs[:4])}'] if libs else [])
    def abi(tree):
        try: src = run('show', f'{tree}:translator/dmsh_chain.py').decode('utf-8', 'replace')
        except subprocess.CalledProcessError: return None
        m = re.search(r'^ABI\s*=\s*(\d+)', src, re.M); return m.group(1) if m else None
    ab, am = abi(base), abi(merged)
    if ab != am: hits = [f'宿主 ↔ 库接口号 ABI {ab or "无"} → {am or "无"}'] + hits
    print(('🧊 冷改动：' + '；'.join(hits)) if hits else f'不冷（翻译指纹 {a} 不变；{len(files)} 个文件，未碰阶段键）')
    return (11 if ab != am else 10) if hits else 0

if __name__ == '__main__':
    if len(sys.argv) != 4: sys.exit('用法：coldcheck.py <git 目录> <main 提交> <分支提交>')
    sys.exit(main(*sys.argv[1:4]))
