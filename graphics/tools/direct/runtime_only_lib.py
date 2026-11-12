#!/usr/bin/env python3
"""运行时现编空直连库（runtime_only_lib.sh 的实现；抽取缺口时用）：一个进程里做完，不再起子进程。
  runtime_only_lib.py <输出目录> <链号> <程序号> <inputs 标签> <缺口原因文件> [配置档 game.tsv] [--gap-from <抽取日志>] [--swap-to <正式输出目录> --logs-from <工作目录> --logs-to <缓存目录>]
  --gap-from：缺口原因从抽取日志里取（最后一行「直连库失败：…」），写进缺口原因文件
出：<输出目录>/b-<链号>/lib.idx 空容器（48 字节头、0 条 0 分片，graphics/nvn/lib_pack.inc）+ b-<链号>/inputs.tsv 戳 + 空 shader_map.tsv / keys.tsv + 空答案表 / 配对表
  + game.tsv（给了配置档才拷）+ runtime_only.txt（原因）。标签写 auto：按缺口原因文件内容算（x + sha256 前 11 位）。
--swap-to：输出目录先清空重建，做完换进正式输出目录（同 direct_lib.sh swap_out：没有就改名；有就三步改名，换下的旧版本落在输出目录名）、
  工作目录里的 *.log 拷进 <缓存目录>/logs。
为什么不用 bash（v0.3.0 Windows 8 GB 机：直连抽取 MemoryError 后走这条兜底，bash 起 rm 时 cygwin fork 失败 Win32 299，兜底一起倒、整单失败）：
  兜底必须在内存吃紧时也做得完，只起这一个进程"""
import hashlib, os, shutil, stat, struct, sys


def rmtree(p):
    def unlock(fn, q, _):
        os.chmod(q, stat.S_IWRITE | stat.S_IREAD); fn(q)
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p, onerror=unlock)
    elif os.path.lexists(p): os.unlink(p)


def build(d, cv, tid, tag, why, gt):
    c = cv.encode()
    if not 0 < len(c) <= 12: sys.exit(f'链号长度不对：{cv!r}')
    os.makedirs(os.path.join(d, f'b-{cv}'), exist_ok=True)
    with open(os.path.join(d, f'b-{cv}', 'lib.idx'), 'wb') as f: f.write(b'S2ALIB\0\0' + struct.pack('<IIII', 1, 0, 0, 0) + c.ljust(12, b'\0') + bytes(12))
    def put(rel, text):
        with open(os.path.join(d, rel), 'w', encoding='utf-8', newline='\n') as f: f.write(text)
    put(os.path.join(f'b-{cv}', 'inputs.tsv'), f'game\t{tid}\ninputs\truntime-only-{tag}\n')
    put('shader_map.tsv', ''); put('keys.tsv', '')
    put('shader_facts.tsv', '# 运行时现编空库：空答案表 = 全部按缺省答（graphics/tools/direct/dsh/Tables.cs）\n')
    put('shader_pairs.tsv', '# 运行时现编空库：空配对表\n')
    if gt and os.path.isfile(gt): shutil.copyfile(gt, os.path.join(d, 'game.tsv'))
    with open(why, encoding='utf-8', errors='replace') as f: reason = f.read()
    put('runtime_only.txt', '本款离线直连库为空（离线 0 支），运行时首遇现编\n' + reason)


def swap(a, b):
    if not os.path.lexists(b): os.rename(a, b); return
    os.rename(b, a + '.old'); os.rename(a, b); os.rename(a + '.old', a)   # 换下的旧版本落在输出目录名，由调用方的退出钩子删


def main(argv):
    opts = {}
    for k in ('--gap-from', '--swap-to', '--logs-from', '--logs-to'):
        if k in argv: i = argv.index(k); opts[k] = argv[i + 1]; del argv[i:i + 2]
    if len(argv) not in (5, 6): sys.exit(__doc__)
    d, cv, tid, tag, why = argv[:5]; gt = argv[5] if len(argv) == 6 else ''
    if '--gap-from' in opts:   # 缺口原因：抽取日志里最后一行「直连库失败：…」从这几个字起、最多 260 字（原 grep | tail | sed | cut）
        try:
            with open(opts['--gap-from'], encoding='utf-8', errors='replace') as f: hits = [l for l in f if '直连库失败：' in l]
        except OSError: hits = []
        gap = hits[-1][hits[-1].index('直连库失败：'):].rstrip('\n')[:260] if hits else '直连库失败：extract.sh 退 3 没写原因'
        with open(why, 'w', encoding='utf-8', newline='\n') as f: f.write(gap + '\n')
    if tag == 'auto':
        with open(why, 'rb') as f: tag = 'x' + hashlib.sha256(f.read()).hexdigest()[:11]
    if '--swap-to' in opts: rmtree(d)
    build(d, cv, tid, tag, why, gt)
    if '--swap-to' in opts:
        swap(d, opts['--swap-to'])
        if '--logs-from' in opts and '--logs-to' in opts:
            new, logs = os.path.join(opts['--logs-to'], 'logs.new'), os.path.join(opts['--logs-to'], 'logs')
            rmtree(new); os.makedirs(new)
            for n in os.listdir(opts['--logs-from']):
                p = os.path.join(opts['--logs-from'], n)
                if n.endswith('.log') and os.path.isfile(p): shutil.copyfile(p, os.path.join(new, n))
            rmtree(logs); os.rename(new, logs)


if __name__ == '__main__':
    main(sys.argv[1:])
