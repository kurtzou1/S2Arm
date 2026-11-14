#!/usr/bin/env python3
# 合成系统数据：sysdata_synth.py <号> <输出目录>
# 玩家没有主机固件导出的系统数据时，造一份「空但格式合法」的替代内容放进包（维护者 10-25 批准：「能让玩家不要面对这个问题」）。
# 只按 Ryujinx 的公开实现推格式，不含任何任天堂数据。同输入逐字节同输出（gzip 头 mtime=0、无文件名）。
#   0100000000000823 屏蔽词表 NgWord：每张词典都是「零个词条」，游戏检查名字永远判不含屏蔽词。
#   0100000000000806 旧版屏蔽词表 NgWord（早期 SDK 的游戏自己挂、自己读）：每张表一条永远匹配不上的式子，同样判不含屏蔽词。
#   0100000000000802 Mii 资源 MiiModel：形状零面积、贴图 1×1 全 0（pack/sysdata_mii.py，含格式校验 check）。
#   0400000000000849 Switch 2 Mii 资源：同 0802 的结构，另加 6 个 OunceTexture 贴图（见 mii_ounce）。
# iOS / 安卓共用打包层：pack/stage_sysdata.sh 经 pack/sysdata_need.py 的 SYNTH 行调本脚本；--ids 打会合成的号（sysdata_need.py 对每款都提供这些号：没有真的就合成）。
# 扩展：在 GEN 里登记 号 → 生成函数（函数返回 {文件名: 字节}）。
import gzip, io, os, struct, sys

u8 = lambda v: struct.pack('<B', v)
u32 = lambda v: struct.pack('<I', v)
u64 = lambda v: struct.pack('<Q', v)


# ---------- nn::ngc 词典结构（布局 = compat/tree/src/Ryujinx.Horizon/Sdk/Ngc/Detail/ 各 Import 的读取顺序，小端） ----------

def words_of(bits):
    # 位串（下标 = 位号）→ 32 位字数组
    w = [0] * ((len(bits) + 31) // 32)
    for i, b in enumerate(bits):
        if b:
            w[i // 32] |= 1 << (i % 32)
    return w


def bitvector(bits):
    # BitVector32.Import：i32 位长 + ⌈位长/32⌉ 个 u32
    return u32(len(bits)) + b''.join(u32(x) for x in words_of(bits))


def sbv_rank(bits):
    # SbvRank.Import(容量 = 位长)：容量 0 时什么都不读；否则 rank0 u32 × (容量/256+1)、rank1 u8 × (容量/32+1)。
    # 取值照 SbvRank.BuildRankDictionary：rank0 = 每 8 字之前的累计 1 数，rank1 = 字之前、本组内的累计 1 数
    n = len(bits)
    if n == 0:
        return b''
    w = words_of(bits)
    r0 = [0] * (n // 256 + 1)
    r1 = [0] * (n // 32 + 1)
    acc = 0
    for i, x in enumerate(w):
        if i % 8 == 0:
            r0[i // 8] = acc
        r1[i] = acc - r0[i // 8]
        acc += bin(x).count('1')
    return b''.join(u32(x) for x in r0) + bytes(r1)


def set_(bits):
    # Set.Import：BitVector32 + SbvRank
    return bitvector(bits) + sbv_rank(bits)


def sbv_select(bits):
    # SbvSelect.Import：i32 数组长 + u32 数组、bv1、bv2、bv1 的 SbvRank、bv2 的 SbvRank。
    # 内容照 SbvSelect.Build：bv1 标每段连续非零字的起点，数组记该段之前的全零字数；bv2 标每个非零字之前的累计 1 数位置
    w = words_of(bits)
    nz = [x for x in w if x]
    bv1 = [0] * len(nz)
    bv2 = [0] * sum(bin(x).count('1') for x in nz)
    arr, seq, zeros, k, ones = [], False, 0, 0, 0
    for x in w:
        if x:
            if not seq:
                bv1[k] = 1
                arr.append(zeros)
                seq = True
            bv2[ones] = 1
            k += 1
            ones += bin(x).count('1')
        else:
            zeros += 1
            seq = False
    return u32(len(arr)) + b''.join(u32(x) for x in arr) + bitvector(bv1) + bitvector(bv2) + sbv_rank(bv1) + sbv_rank(bv2)


def sbv(bits):
    # Sbv.Import：Set + SbvSelect
    return set_(bits) + sbv_select(bits)


def sparse_set_empty():
    # SparseSet.Import：u64 值个数、u64 区间起、u64 区间止、u32 元素数、u32 低位位宽、i32 低位数组长 + u32 数组、Sbv。
    # 空集 = 元素数 0：Rank1 / Has / Select1Ex 头一句就按元素数 0 返回（Ryujinx SparseSet.cs；游戏 SDK 的 SparseSet::Rank1、Select1Ex 同样先判元素数），
    # 后面的数组一个都不碰。区间起取全 1：游戏 SDK 的 SparseSet 初始状态就是「起 = ~0、止 = 0」（构造 / Reset 里写的），空集导出即此值
    return u64(0) + u64(0xFFFFFFFFFFFFFFFF) + u64(0) + u32(0) + u32(0) + u32(0) + sbv([])


def compressed_array_empty():
    # CompressedArray.Import：i32 区段数 + u32 × 数、i32 位域字数 + u32 × 数、u8 未压缩个数 + i32 × 数（< 64）。
    # 零个元素：只在词条命中后按下标取，空词典不会走到
    return u32(0) + u32(0) + u8(0)


def bp_root_only():
    # Bp.Import：BpNode（Set + u8 有无下一层，0 = 无）+ SbvSelect。
    # 只有根的树 = 括号串「()」：位 0 = 开（1）、位 1 = 闭（0）。ToPos(0) = 0、Enclose(0) = -1（根无父），即「失配回根」
    bits = [1, 0]
    return set_(bits) + u8(0) + sbv_select(bits)


def aho_corasick_empty():
    # AhoCorasick.Import 顺序：词长表、词集、多词下标表、多词集、u32 每字符节点数、节点集、Bp（失配树）。
    # 只有根节点 0：节点集空 → 匹配时每个字节都查不到子节点，停在根（nodeId == 0 直接下一个字节），回调一次都不触发
    return (compressed_array_empty() + sparse_set_empty()
            + compressed_array_empty() + sparse_set_empty()
            + u32(1) + sparse_set_empty() + bp_root_only())


def similar_form_table_empty():
    # SimilarFormTable.Import：i32 相似串长、i32 规范串长、i32 条数，之后每条两串。0 条：
    # 查表（FindCanonicalString）只在相似形词典命中后调用，相似形词典空则不会调
    return u32(0) + u32(0) + u32(0)


def gz(data):
    # 读取方一律先 gzip 解压（Ryujinx ContentsReader.ReadGZipCompressedArchive；游戏 SDK 经 nn::util::DecompressGzip）
    # gzip.compress(mtime=0) 在部分 Python 版本借用 zlib，OS 头字节随平台变；GzipFile 固定写 ff。
    out = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=out, compresslevel=9, mtime=0) as stream:
        stream.write(data)
    return out.getvalue()


# ---------- 0100000000000823 NgWord ----------

REGIONS = 18   # 真机数据的区域号 0–17（Ryujinx 只查 0–15，游戏 SDK 按区域位换算号，多给不碍事）
VERSION = 1    # version.dat：u32 大端（Ryujinx GetContentVersion；游戏 SDK 同样只读出来交给游戏，不据此选格式）


def ngword():
    ac = gz(aho_corasick_empty())
    out = {}
    for r in [str(i) for i in range(REGIONS)] + ['common']:
        for kind in ('b1', 'b2', 'not_b'):
            out[f'ac_{r}_{kind}_nx'] = ac
        # trie_*_allow_*：Ryujinx 与游戏 SDK 都不读（源码 / 字符串里无此名），格式无从推；放同一份空词典占位，保持与真机文件清单一致
        for kind in ('fwd', 'back'):
            out[f'trie_{r}_allow_{kind}'] = ac
    out['ac_similar_form_nx'] = ac
    out['table_similar_form_nx'] = gz(similar_form_table_empty())
    out['version.dat'] = struct.pack('>I', VERSION)
    return out


# ---------- 0100000000000806 旧版 NgWord ----------
# 早期 SDK 的游戏（如 #886：输完名字点确定 → OpenDataStorageByDataId(0806)，没有这份就 Break）不走 ngc 服务，自己挂这份读。
# 布局按公开模拟器实现推：0.txt–15.txt（按区域号）+ common.txt，每份是 UTF-16 大端、带 BOM 的文本，一行一条正则；version.dat 为 u32 大端。
# 每份只放一条匹配不上任何名字的式子（不放零条：早期 SDK 对空文件的处理没有资料可核）
NGWORD1_REGIONS = 16
NGWORD1_VERSION = 0x20
NGWORD1_LINE = '^s2arm0no0banned0words0placeholder$\n'


def ngword1():
    txt = b'\xfe\xff' + NGWORD1_LINE.encode('utf-16-be')
    out = {f'{i}.txt': txt for i in range(NGWORD1_REGIONS)}
    out['common.txt'] = txt
    out['version.dat'] = struct.pack('>I', NGWORD1_VERSION)
    return out


def mii():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import sysdata_mii
    s, t = sysdata_mii.shape_file(), sysdata_mii.tex_file()
    return {**{n: s for n in sysdata_mii.SHAPES}, **{n: t for n in sysdata_mii.TEXTURES}}


# Switch 2 的 Mii 资源（0400000000000849）：Switch Sports Resort 在 main+0x320040 按一个标志选 0x849 或 0x849 − 0x47 = 0802 挂成 MiiResource，
#   游戏里的文件名除 0802 那 6 个外多了 OunceTexture{High,Mid,Low}{Linear,SRGB}.dat（Ounce = Switch 2）。真数据的格式没有核对过：
#   这里沿用 0802 的形状 / 贴图结构（贴图文件同一份），目的只是「挂得上、按名字打得开、读到的是合法的空资源」
OUNCE_TEXTURES = tuple(f'OunceTexture{q}{c}.dat' for q in ('High', 'Mid', 'Low') for c in ('Linear', 'SRGB'))


def mii_ounce():
    files = mii()
    return {**files, **{n: files['NXTextureLowLinear.dat'] for n in OUNCE_TEXTURES}}


GEN = {'0100000000000802': mii, '0100000000000806': ngword1, '0100000000000823': ngword, '0400000000000849': mii_ounce}


def main():
    if sys.argv[1:] == ['--ids']:
        print('\n'.join(sorted(GEN)))
        return
    if len(sys.argv) != 3:
        sys.exit('用法：sysdata_synth.py <号> <输出目录>（已支持：' + '、'.join(GEN) + '）')
    tid, out = sys.argv[1].upper(), sys.argv[2]
    if tid not in GEN:
        sys.exit(f'【红】{tid} 没有合成器（已支持：' + '、'.join(GEN) + '）')
    files = GEN[tid]()
    os.makedirs(out, exist_ok=True)
    for name, data in sorted(files.items()):
        with open(os.path.join(out, name), 'wb') as f:
            f.write(data)
    print(f'{tid}：{len(files)} 个文件 → {out}')


if __name__ == '__main__':
    main()
