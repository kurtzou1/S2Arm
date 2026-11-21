#!/usr/bin/env python3
"""门禁声明：路由、本机子项、手动单测都写在各自文件的文件头里，不再有中央登记表（10-30 维护者批：公用登记表就是文件锁）。
用法：python3 tools/gate_decl.py route|local|manual|indirect|layer|inputs [仓库根]   按原表格式打到标准输出（制表符分隔）：
  route  <钩子或 ios>\t<前缀…空格分隔>        钩子 <目录>/gate.sh 头里「# 门禁路由：<前缀…>」（可多行，取并集）；tools/gate_ios.sh 头里的记作 ios
  local  <步>\t<键>\t<原因>                  钩子头里「# 门禁本机：<键> <原因>」（键 * = 整步本机跑，其余 = 该子项本机另跑）；
                                              tests/*_test.sh 头里「# 门禁本机：<原因>」= 单测 <名> 整步本机；tools/public_repo_scan.py 头里的 = 公开仓扫描
  manual <单测文件>\t<原因>                   任一单测文件头里「门禁手动：<原因>」（# / // / <!-- --> 注释）= 不进门禁、手动跑（tools/test_wired_lint.py 白名单）
  indirect <单测文件>\t<调用方>\t<说明>       单测文件头里「门禁间接：<调用方路径> <说明>」= 由调用方按通配 / 在进程内拼路径调到，静态引用追不到（tools/test_wired_lint.py：调用方接线了它才算接线）
  layer  <步>\t合入后[\t路由]                钩子 / tools/gate_ios.sh（步名「iOS 全量编译」）/ tests/*_test.sh（步名「单测 <名>」）头里「# 门禁层：合入后」= 列车合入前不跑、合入后跑（tools/gate.sh GATE_LAYER）；
                                              不写 = 合入前；只认「合入前 / 合入后」，写错报红退出 1（10-30 维护者：合入前门禁只证明这次改动没弄坏它影响到的东西）
  inputs <单测文件>\t<目录或通配…>            tests/ 下单测头里「# 门禁输入：<目录或通配…>」（可多行，取并集）= 单测结果缓存（tools/test_cache.py）在路由覆盖面之外还要算进键的输入
只读每个文件开头 HEAD 行；声明必须写在文件头（注释），不跟业务代码混。"""
import os, re, subprocess, sys

HEAD = 40
DECL = re.compile(r'^\s*(?:#|//|<!--)\s*门禁(路由|本机|手动|间接|层|输入)：\s*(.*?)\s*(?:-->)?\s*$')   # 注释写法：# / // / <!-- -->（.csproj 等 XML）


def files(root):
    r = subprocess.run(['git', '-C', root, 'ls-files', '-z'], capture_output=True)
    if r.returncode == 0: return [f for f in r.stdout.decode('utf-8', 'surrogateescape').split('\0') if f]
    out = []   # 不是 git 仓库（单测的合成目录）：按目录走
    for d, ds, fs in os.walk(root):
        ds[:] = [x for x in ds if x != '.git']
        out += [os.path.relpath(os.path.join(d, f), root) for f in fs]
    return out


def decls(root, path):
    try:
        with open(os.path.join(root, path), encoding='utf-8', errors='replace') as fh:
            for i, l in enumerate(fh):
                if i >= HEAD: break
                m = DECL.match(l)
                if m: yield m.group(1), m.group(2)
    except (OSError, IsADirectoryError):
        return


def hook(f):
    return f.endswith('/gate.sh') and f != 'tools/gate.sh' and f.count('/') <= 3


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    root = sys.argv[2] if len(sys.argv) > 2 else '.'
    if mode not in ('route', 'local', 'manual', 'indirect', 'layer', 'inputs'): sys.exit(__doc__)
    fs = files(root)
    if mode == 'route':
        rows, at = [], {}
        for f in sorted(fs):
            key = 'ios' if f == 'tools/gate_ios.sh' else f if hook(f) else None
            if not key: continue
            for k, v in decls(root, f):
                if k != '路由': continue
                if key not in at: at[key] = len(rows); rows.append((key, []))
                q = rows[at[key]][1]; q += [p for p in v.split() if p not in q]
        for k, q in rows: print(f'{k}\t{" ".join(q)}')
    elif mode == 'local':
        for f in sorted(fs):
            if hook(f): step = f'钩子 {f}'
            elif re.match(r'^tests/[^/]+_test\.sh$', f): step = f'单测 {os.path.basename(f)[:-3]}'
            elif f == 'tools/public_repo_scan.py': step = '公开仓扫描'
            else: continue
            for k, v in decls(root, f):
                if k != '本机': continue
                if step.startswith('钩子 '):
                    key, _, why = v.partition(' ')
                    print(f'{step}\t{key}\t{why.strip()}')
                else: print(f'{step}\t*\t{v}')
    elif mode == 'layer':
        for f in sorted(fs):
            step = ('iOS 全量编译' if f == 'tools/gate_ios.sh' else f'钩子 {f}' if hook(f)
                    else f'单测 {os.path.basename(f)[:-3]}' if re.match(r'^tests/[^/]+_test\.sh$', f) else None)
            if not step: continue
            for k, v in decls(root, f):
                if k != '层': continue
                if v == '合入后（路由命中时合入前也跑）': print(f'{step}\t合入后\t路由'); continue   # 11-10：安卓支 / ios 头改动合入前不跑对应钩子，一天叠多处 main 红
                if v not in ('合入前', '合入后'): sys.exit(f'【红】gate_decl：{f} 的「门禁层：{v}」只认 合入前 / 合入后 / 合入后（路由命中时合入前也跑）')
                if v == '合入后': print(f'{step}\t合入后')
    elif mode == 'inputs':
        rows = {}
        for f in sorted(fs):
            if not (f.startswith('tests/') and f.endswith(('.sh', '.py'))): continue
            for k, v in decls(root, f):
                if k == '输入': q = rows.setdefault(f, []); q += [p for p in v.split() if p not in q]
        for f, q in rows.items(): print(f'{f}\t{" ".join(q)}')
    else:
        for f in sorted(fs):
            if not re.search(r'\.(sh|py|m|mm|c|cs|csproj)$', f): continue
            for k, v in decls(root, f):
                if k == ('手动' if mode == 'manual' else '间接'):
                    if mode == 'manual': print(f'{f}\t{v}')
                    else: caller, _, why = v.partition(' '); print(f'{f}\t{caller}\t{why.strip()}')


if __name__ == '__main__':
    main()
