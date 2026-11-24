#!/usr/bin/env python3
# 把一份 MSL 源文件嵌成 C 字符串常量（gal_tess.m 用：细分器 gal_tess_d3d.h 同一份源码既在宿主单测里按 C++ 编，又作运行时辅助 MSL）
# 用法：embed_msl.py <源文件> <变量名> <输出 .h>
import os, sys
src, name, out = sys.argv[1:4]
text = open(src, encoding='utf-8').read()
esc = text.replace('\\', '\\\\').replace('"', '\\"').replace('?', '\\?')
lines = ['"' + ln + '\\n"' for ln in esc.split('\n')]
tmp = f'{out}.{os.getpid()}.tmp'   # 进程号进临时名（11-24：并行两组同时生成同一个头，共用 .tmp 一边改名时被另一边挪走，FileNotFoundError 后 make 删掉了头）
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(f'// 由 tools/embed_msl.py 从 {src.split("/")[-1]} 生成，勿手改\nstatic const char {name}[] =\n' + '\n'.join(lines) + ';\n')
os.replace(tmp, out)
