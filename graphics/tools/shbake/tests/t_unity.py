#!/usr/bin/env python3
# unity_res 单测（10-21 pair）：手搓 UnityFS 资源包（块 LZ4）+ 带类型树的序列化文件（一个 Shader：platforms / offsets / 各长度 / compressedBlob）
# + 一个不带类型树的序列化文件（借前者的类型树），期望条目手算。旧代码反证：没有 unity_res.py（导入失败 = 红）。用法：t_unity.py [shbake 目录]
import sys, os, struct
D = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, D)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
try:
    import unity_res as U, lz4.block, collections
except Exception as e:
    print(f'✗ 导入 unity_res 失败：{e}'); print('期望 Unity 资源 全过 → 真结果 失败 1 / 1'); sys.exit(1)
# 代码块：2 个条目（各 3 / 5 字节）
ent = [b'AAA', b'BBBBB']; hdr = struct.pack('<I', 2); off = 4 + 12 * 2; tab = b''; data = b''
for e in ent: tab += struct.pack('<III', off + len(data), len(e), 0); data += e
blob = hdr + tab + data; cblob = lz4.block.compress(blob, store_size=False)
# 类型树（小端节点表）：根 Shader → platforms(vector<uint>) / offsets(vector<vector<uint>>) / compressedLengths / decompressedLengths / compressedBlob(vector<UInt8>)
S = b''; so = {}
def s(x):
    global S
    if x not in so: so[x] = len(S); S += x.encode() + b'\0'
    return so[x]
nodes = []
def node(lvl, name, size, flags=0, meta=0): nodes.append(struct.pack('<HBBIIiiiQ', 1, lvl, flags, s('t'), s(name), size, len(nodes), meta, 0))
def vec_uint(lvl, name):
    node(lvl, name, -1); node(lvl + 1, 'Array', -1, 1, 0x4000); node(lvl + 2, 'size', 4); node(lvl + 2, 'data', 4)
node(0, 'Base', -1)
vec_uint(1, 'platforms')
for nm in ('offsets', 'compressedLengths', 'decompressedLengths'):
    node(1, nm, -1); node(2, 'Array', -1, 1, 0x4000); node(3, 'size', 4); vec_uint(3, 'data')
node(1, 'compressedBlob', -1); node(2, 'Array', -1, 1, 0x4000); node(3, 'size', 4); node(3, 'data', 1)
def vu(xs): return struct.pack('<i', len(xs)) + b''.join(struct.pack('<I', x) for x in xs)
obj = vu([19]) + b''.join(struct.pack('<i', 1) + vu([v]) for v in (0, len(cblob), len(blob))) + struct.pack('<i', len(cblob)) + cblob
obj += bytes((-len(obj)) % 4)
def serialized(with_tt):
    meta = b'2022.3.1f1\0' + struct.pack('<i', 38) + bytes([1 if with_tt else 0]) + struct.pack('<i', 1) + struct.pack('<iBh', 48, 0, -1) + bytes(16)
    if with_tt: meta += struct.pack('<ii', len(nodes), len(S)) + b''.join(nodes) + S + struct.pack('<i', 0)
    meta += struct.pack('<i', 1)
    head_len = 48
    pre = head_len + len(meta); pre += (-pre) % 4; meta += bytes(pre - head_len - len(meta))
    meta += struct.pack('<qqIi', 7, 0, len(obj), 0)
    do = head_len + len(meta); do += (-do) % 16
    body = bytearray(do) + obj
    struct.pack_into('>IIII', body, 0, 0, 0, 22, 0); body[16] = 0
    struct.pack_into('>IQQQ', body, 20, len(meta), len(body), do, 0)
    body[48:48 + len(meta)] = meta
    return bytes(body)
ser_tt, ser_no = serialized(True), serialized(False)
# UnityFS：块信息（未压缩，flags=0x40）+ 一个 LZ4 数据块
data_c = lz4.block.compress(ser_tt, store_size=False)
bi = bytes(16) + struct.pack('>I', 1) + struct.pack('>IIH', len(ser_tt), len(data_c), 2) + struct.pack('>I', 1) + struct.pack('>QQI', 0, len(ser_tt), 4) + b'CAB-test\0'
h = b'UnityFS\0' + struct.pack('>I', 8) + b'5.x.x\0' + b'0.0.0\0'
h2 = struct.pack('>QIII', 0, len(bi), len(bi), 0x40)
pre = h + h2; pre += bytes((-len(pre)) % 16)
bundle = pre + bi + data_c
inner = U.read_bundle(bundle)
check(list(inner) == ['CAB-test'] and inner['CAB-test'] == ser_tt, f'UnityFS：解出 CAB-test、内容与原序列化文件逐字节相同 → 真结果 {list(inner)}')
tt = [None]; st = collections.Counter()
got = [(pid, plat, si, i, e) for pid, plat, si, i, e in U.shader_entries(ser_tt, tt, st)]
check(got == [(7, 19, 0, 0, b'AAA'), (7, 19, 0, 1, b'BBBBB')], f'带类型树的 Shader：代码块 2 个条目（对象 7、平台 19）→ 真结果 {got}')
got2 = [(pid, i, e) for pid, plat, si, i, e in U.shader_entries(ser_no, tt, st)]
check(got2 == [(7, 0, b'AAA'), (7, 1, b'BBBBB')] and st['Unity Shader 借类型树'] == 1, f'不带类型树的 Shader 借前者类型树读出同样 2 条 → 真结果 {got2}，借用 {st["Unity Shader 借类型树"]}')
st2 = collections.Counter(); got3 = list(U.shader_entries(ser_no, [None], st2))
check(got3 == [] and st2['Unity Shader 没有类型树可用（跳过）'] == 1, '没有类型树可借 → 跳过并计数，不猜')
# T83：这些原创建包数据由公开格式构造，不从被测读取器反推期望。
# v17/18 节点24字节、v19+32字节；v21+类型依赖数组；旧对象起点u32。
# 旧 Shader 是每平台一段、每条8字节(offset,length)，新段表每条12字节。
def legacy_fixture(version, endian='<', with_tree=True, flat=None):
    if flat is None: flat = version < 21
    def pk(fmt, *xs): return struct.pack(endian + fmt, *xs)
    strings, offsets, records = bytearray(), {}, []
    def word(name):
        if name not in offsets:
            offsets[name] = len(strings); strings.extend(name.encode() + b'\0')
        return offsets[name]
    def nd(level, name, size, flags=0, meta=0):
        record = pk('HBBIIiii', 1, level, flags, word('t'), word(name), size, len(records), meta)
        records.append(record + (pk('Q', 0x12345678) if version >= 19 else b''))
    def vector(level, name, width=4):
        nd(level, name, -1); nd(level + 1, 'Array', -1, 1, 0x4000)
        nd(level + 2, 'size', 4); nd(level + 2, 'data', width)
    nd(0, 'Base', -1); vector(1, 'platforms')
    for name in ('offsets', 'compressedLengths', 'decompressedLengths'):
        if flat: vector(1, name)
        else:
            nd(1, name, -1); nd(2, 'Array', -1, 1, 0x4000)
            nd(3, 'size', 4); vector(3, 'data')
    vector(1, 'compressedBlob', 1)
    # 两个平台的载荷、条目偏移完全由下列字面构造决定：旧表20/12，新表28/16。
    entries = ([b'FIRST', b'next'], [b'DDS'])
    payloads = []
    for es in entries:
        header_size = 4 + (8 if flat else 12) * len(es)
        table, content = bytearray(), bytearray()
        for e in es:
            table.extend(struct.pack('<II', header_size + len(content), len(e)))
            if not flat: table.extend(struct.pack('<I', 0))
            content.extend(e)
        payloads.append(struct.pack('<I', len(es)) + table + content)
    compressed = [lz4.block.compress(x, store_size=False) for x in payloads]
    def arr(xs): return pk('i', len(xs)) + b''.join(pk('I', x) for x in xs)
    arrays = ([0, len(compressed[0])], [len(x) for x in compressed], [len(x) for x in payloads])
    data = arr([19, 18])
    for xs in arrays: data += arr(xs) if flat else pk('i', len(xs)) + b''.join(arr([x]) for x in xs)
    packed = b''.join(compressed); data += pk('i', len(packed)) + packed
    data += bytes(-len(data) % 4)
    # MonoBehaviour 在前（带script ID），Shader在后（type index=1，不带script ID）。
    meta = b'2018.4.0f1\0' + pk('iB', 38, int(with_tree)) + pk('i', 2)
    for cid in (114, 48):
        meta += pk('iBh', cid, 0, -1) + (bytes(16) if cid == 114 else b'') + bytes(16)
        if with_tree:
            meta += pk('ii', len(records), len(strings)) + b''.join(records) + strings
            if version >= 21: meta += pk('ii', 1, 0)  # 非空依赖表，不能漏读
    meta += pk('i', 1)
    head_size = 48 if version >= 22 else 20
    meta += bytes(-(head_size + len(meta)) % 4)
    table_start = head_size + len(meta)
    pid, relative = 0x100000007, 16
    meta += pk('qqIi' if version >= 22 else 'qIIi', pid, relative, len(data), 1)
    # 其余元数据：脚本/外部表空；20+有引用类型表；末尾用户信息空。
    meta += pk('ii', 0, 0) + (pk('i', 0) if version >= 20 else b'') + b'\0'
    data_start = (head_size + len(meta) + 15) & ~15
    buf = bytearray(data_start + relative) + data
    struct.pack_into('>IIII', buf, 0, len(meta), len(buf), version, data_start)
    buf[16] = int(endian == '>')
    if version >= 22: struct.pack_into('>IQQQ', buf, 20, len(meta), len(buf), data_start, 0)
    buf[head_size:head_size + len(meta)] = meta
    return bytes(buf), (pid, 48, data_start + relative, len(data)), table_start

for version in (17, 18, 19, 20, 21, 22):
    for endian in ('<', '>'):
        sample, expected, object_table = legacy_fixture(version, endian)
        label = f'v{version} {endian}'
        try:
            objects, actual_endian = U.parse_serialized(sample)
            got_meta = [(pid, cid, start, size) for pid, cid, tree, start, size in objects]
            check(got_meta == [expected] and actual_endian == endian and objects[0][2] is not None,
                  f'{label} 对象64位ID/类型索引/非零起点/长度逐项一致 → {got_meta}')
            out = list(U.shader_entries(sample, [None], collections.Counter()))
            wanted = [(0x100000007, 19, 0, 0, b'FIRST'), (0x100000007, 19, 0, 1, b'next'),
                      (0x100000007, 18, 0, 0, b'DDS')]
            check(out == wanted, f'{label} 两平台三条目与手造字节逐字相同 → {out}')
        except Exception as error:
            check(False, f'{label} 应解析并抽出三条，实际 {type(error).__name__}: {error}')

# 明确不支持的版本不是空成功，也不能被降级成任意旧版本。
for version in (16, 41):
    malformed = bytearray(ser_tt); struct.pack_into('>I', malformed, 8, version)
    try:
        U.parse_serialized(malformed); check(False, f'v{version} 应拒绝，实际接受')
    except ValueError as error:
        check(str(error) == f'序列化文件版本 {version}', f'v{version} 拒绝且保留版本原因')

# 无树旧文件不能猜结构；明确缺树时保留现有计数边界。
no_tree, _, _ = legacy_fixture(17, with_tree=False)
counter = collections.Counter()
try:
    out = list(U.shader_entries(no_tree, [None], counter))
    check(out == [] and counter['Unity Shader 没有类型树可用（跳过）'] == 1, 'v17 缺树不自动套已知hash/版本布局')
except Exception as error: check(False, f'v17 无树边界意外失败：{error}')

# 旧格式边界：不得用负类型索引借末项，也不得把截断对象当完整条目。
for version in (17, 21):
    sample, expected, object_table = legacy_fixture(version)
    cases = []
    for index in (-1, 2):
        bad_data = bytearray(sample); struct.pack_into('<i', bad_data, object_table + 16, index)
        cases.append((bad_data, '对象类型索引越界'))
    bad_data = bytearray(sample); struct.pack_into('<I', bad_data, object_table + 8, 0xffffffff)
    cases.extend([(bad_data, '对象数据越界'), (sample[:-1], '对象数据越界')])
    bad_data = bytearray(sample); struct.pack_into('>I', bad_data, 12, 19)
    cases.append((bad_data, '数据偏移越界'))
    for data, reason in cases:
        try:
            U.parse_serialized(data); check(False, f'v{version} {reason} 应拒绝，实际接受')
        except ValueError as error:
            check(str(error) == reason, f'v{version} 坏表/截断明确拒绝：{reason}')

# 走未改动的生产 scan_unity：包内版本错误必须进传入 Counter，而不是只剩泛称。
# 占位载荷不是GPU代码，rows应为空；对象/条目字节已在上面的真读取器测试核对。
import importlib.util, pathlib, tempfile
from unittest.mock import patch
extract_path = pathlib.Path(__file__).resolve().parent.parent / 'nxsh_extract.py'
spec = importlib.util.spec_from_file_location('t83_extract', extract_path)
extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)
def bundle_with(content):
    encoded = lz4.block.compress(content, store_size=False)
    info = bytes(16) + struct.pack('>IIIH', 1, len(content), len(encoded), 2)
    info += struct.pack('>IQQI', 1, 0, len(content), 4) + b'CAB-synthetic\0'
    prefix = b'UnityFS\0' + struct.pack('>I', 8) + b'5.x.x\0' + b'0.0.0\0'
    prefix += struct.pack('>QIII', 0, len(info), len(info), 0x40)
    prefix += bytes(-len(prefix) % 16)
    return prefix + info + encoded
with tempfile.TemporaryDirectory(prefix='t83-scan-') as directory:
    for version in (17, 21, 16, 41):
        content, _, _ = legacy_fixture(17 if version == 17 else 21)
        if version in (16, 41):
            content = bytearray(content); struct.pack_into('>I', content, 8, version)
        path = pathlib.Path(directory, f'v{version}.bundle'); path.write_bytes(bundle_with(content))
        counter = collections.Counter(); rows, blobs = extract.scan_unity(directory, [str(path)], counter)
        if version in (16, 41):
            check(not rows and not blobs and counter[f'序列化文件版本 {version}'] == 1
                  and counter['UnityFS 包内文件不是序列化文件'] == 1,
                  f'真实 scan_unity 保留 v{version} 拒绝原因及原失败计数 → {dict(counter)}')
        else:
            check(not rows and not blobs and counter['Unity Shader'] == 1
                  and not counter['UnityFS 包内文件不是序列化文件'],
                  f'真实 scan_unity 读到 v{version} Shader；占位载荷不假称GPU代码')

# 裸文件走生产发现入口，核对交给着色器扫描器的解压字节。
with tempfile.TemporaryDirectory(prefix='unity-assets-') as directory:
    path = pathlib.Path(directory, 'sharedassets0.assets')
    for version, endian in ((17, '<'), (21, '>'), (22, '<')):
        sample = bytearray(legacy_fixture(version, endian)[0])
        if version == 22:
            struct.pack_into('>I', sample, 4, 0)  # 扩展头的长度才有效
        path.write_bytes(sample)
        counter = collections.Counter()
        with patch.object(extract, '_scan_blob') as scan:
            extract.scan_unity(directory, [str(path)], counter)
        got = [call.args[1] for call in scan.call_args_list]
        check(got == [b'FIRST', b'next', b'DDS'] and counter['Unity Shader'] == 1,
              f'裸 v{version} 向扫描器交付三个条目 → {got}')

    for version, fmt, offset, delta in ((17, '>I', 4, -1), (17, '>I', 4, 1), (22, '>Q', 24, 1)):
        sample = bytearray(legacy_fixture(version)[0])
        struct.pack_into(fmt, sample, offset, len(sample) + delta)
        path.write_bytes(sample)
        with patch.object(U, 'shader_entries') as read:
            extract.scan_unity(directory, [str(path)], collections.Counter())
        check(not read.called, f'裸 v{version} 声明长度偏差 {delta:+d}，在解析前拒绝')


# T84：原创合成载荷，手算节点[0,9)、[9,20)；无游戏资源。
import lzma
def raw_lzma(data):
    # 属性0x5d = (pb=2)*45 + (lp=0)*9 + (lc=3)，后4字节为小端字典大小。
    stream = lzma.compress(data, format=lzma.FORMAT_RAW,
                           filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 4096, 'lc': 3, 'lp': 0, 'pb': 2}])
    return b'\x5d' + struct.pack('<I', 4096) + stream

def encoded(data, mode):
    if mode == 0: return data
    if mode == 1: return raw_lzma(data)
    if mode in (2, 3): return lz4.block.compress(data, store_size=False, mode="high_compression" if mode == 3 else "default")
    return b'not-supported-compression'

def lzma_fixture(info_mode=2, data_mode=1, wrong_size=False, info_delta=0, raw_override=None, tail=False):
    # 节点1 [0,9)，节点2 [9,20)；长度/字节期望写死，不读被测实现生成答案。
    content = b'FIRST-LZM' + b'A\x00next-node'
    assert len(content) == 20
    data = encoded(content, data_mode) if raw_override is None else raw_override
    info = bytes(16) + struct.pack('>IIIH', 1, 21 if wrong_size else 20, len(data), data_mode)
    info += struct.pack('>I', 2)
    info += struct.pack('>QQI', 0, 9, 4) + b'one\0'
    info += struct.pack('>QQI', 9, 11, 4) + b'two\0'
    compressed_info = encoded(info, info_mode)
    prefix = b'UnityFS\0' + struct.pack('>I', 8) + b'5.x.x\0' + b'2019.4.0f1\0'
    prefix += struct.pack('>QIII', 0, len(compressed_info), len(info) + info_delta, 0x40 | info_mode | (0x80 if tail else 0))
    prefix += bytes(-len(prefix) % 16)
    data = bytearray(prefix + (data + compressed_info if tail else compressed_info + data))
    struct.pack_into('>Q', data, 8 + 4 + len(b'5.x.x\0') + len(b'2019.4.0f1\0'), len(data))
    return bytes(data)

for im, dm, tail in ((2, 1, False), (1, 2, False), (1, 1, True), (0, 1, False), (1, 3, False)):
    try:
        actual = U.read_bundle(lzma_fixture(im, dm, tail=tail))
        check(actual == {'one': b'FIRST-LZM', 'two': b'A\0next-node'},
              f'LZMA bundle info={im} data={dm} tail={tail} 节点名与20字节逐字相同')
    except Exception as error: check(False, f'LZMA bundle意外失败：{error}')

def bundle_reject(sample, text, label):
    try:
        U.read_bundle(sample); check(False, label + ' 应拒绝却接受')
    except ValueError as error: check(text in str(error), label + f' → {error}')
    except Exception as error: check(False, label + f' 错误类型不符：{error}')

bundle_reject(lzma_fixture(wrong_size=True), '长度', '数据块原长+1')
for delta in (-1, 1):
    bundle_reject(lzma_fixture(1, 2, info_delta=delta), '长度', f'块信息原长{delta:+}')
for im, dm in ((4, 0), (0, 4), (63, 0), (0, 63)):
    bundle_reject(lzma_fixture(im, dm), 'LZHAM' if 4 in (im, dm) else '未知',
                  f'不支持方式点名 info={im} data={dm}')
for raw, text, label in (
        (b'\x5d\x00', '属性截断', '属性不足5字节'),
        (b'\xff' + bytes(4), '属性不支持', '非法属性pb'),
        (b'\x08' + bytes(4), '属性不支持', 'liblzma不支持lc+lp'),
        (raw_lzma(b'FIRST-LZMA\0next-node')[:10], '长度', '数据流截断'),
        (raw_lzma(b'FIRST-LZMA\0next-node') + b'extra', '尾随数据', 'EOS之后多余字节'),
        (raw_lzma(b'FIRST-LZMA\0next-node!'), '长度', '输出比声明多1')):
    bundle_reject(lzma_fixture(raw_override=raw), text, label)
# 不是固定0x5d属性：lc=2/lp=1/pb=1 → 56；字典小端8192。
other = lzma.compress(b'FIRST-LZMA\0next-node', format=lzma.FORMAT_RAW,
                     filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 8192, 'lc': 2, 'lp': 1, 'pb': 1}])
check(U.read_bundle(lzma_fixture(raw_override=b'\x38' + struct.pack('<I', 8192) + other))
      == {'one': b'FIRST-LZM', 'two': b'A\0next-node'}, '非默认lc/lp/pb属性独立拆出')
# 大字典声明不能迫使20字节输出分配4GiB；距离不超过原长。
raw = raw_lzma(b'FIRST-LZMA\0next-node')
check(U.read_bundle(lzma_fixture(raw_override=raw[:1] + b'\xff'*4 + raw[5:]))
      == {'one': b'FIRST-LZM', 'two': b'A\0next-node'}, '字典内存受声明输出范围约束')

# T84 收尾：真实 scan_unity 的失败分类；合成包，不替换 read_bundle。
with tempfile.TemporaryDirectory(prefix='t84-scan-') as directory:
    cases = (
        ('info-lzham', lzma_fixture(4, 0), 'LZHAM'),
        ('data-lzham', lzma_fixture(0, 4), 'LZHAM'),
        ('info-unknown', lzma_fixture(63, 0), '未知'),
        ('data-unknown', lzma_fixture(0, 63), '未知'),
        ('truncated', b'UnityFS\0', '其他'),
        ('length', lzma_fixture(wrong_size=True), '其他'),
        ('lz4', lzma_fixture(2, 2), None),
        ('lz4hc', lzma_fixture(3, 3), None),
    )
    paths = []
    for label, sample, reason in cases:
        path = pathlib.Path(directory, label + '.bundle'); path.write_bytes(sample)
        paths.append(str(path))
        counter = collections.Counter()
        rows, blobs = extract.scan_unity(directory, [str(path)], counter)
        failures = {key: value for key, value in counter.items() if key.startswith('UnityFS 解不开')}
        expected = {} if reason is None else {f'UnityFS 解不开（{reason}）': 1}
        check(not rows and not blobs and failures == expected
              and counter['UnityFS 资源包'] == (1 if reason is None else 0),
              f'scan_unity {label}：分类={expected}、继续扫描 → {dict(counter)}')
    counter = collections.Counter()
    rows, blobs = extract.scan_unity(directory, paths, counter)
    check(not rows and not blobs and counter['UnityFS 解不开（LZHAM）'] == 2
          and counter['UnityFS 解不开（未知）'] == 2 and counter['UnityFS 解不开（其他）'] == 2
          and counter['UnityFS 资源包'] == 2 and 'UnityFS 解不开' not in counter,
          f'scan_unity 混合8包：失败分项2+2+2，后续2个正常包仍读取 → {dict(counter)}')

# 逐个节点解（v0.3.0 Windows 8 GB 机：3.45 GB 的 Unity 游戏 data.unity3d 整包解开再每个节点复制一份，第一个文件就 MemoryError）：
#   手拼一个 UnityFS（48 个 LZ4 块各 128 KiB 原文、4 个节点，第二个跨块边界，末一个是贴图流 .resS、占大头）。期望：两个读包模块（S2Arm 抽取 unity_res.iter_bundle、
#   直连抽取 translator/unityfs.bundle_files）逐个产出的节点 = 整包解开后按偏移切的（测试里独立算），默认跳过 .resS；read_bundle 照旧给全部节点；
#   从只读映射读也一样；逐个读时 Python 内存峰值 < 2 × 最大普通节点 + 4 块（手算上界，与整包大小无关），远小于整包原文 6 MiB
import mmap, tracemalloc, random
rnd = random.Random(7); plain = bytes(rnd.getrandbits(8) for _ in range(1 << 16)) * 96   # 6 MiB、可压缩但不是全零
BS = 1 << 17; blocks = [plain[i:i + BS] for i in range(0, len(plain), BS)]   # Unity 的 LZ4 分块 128 KiB
comp = [lz4.block.compress(b, store_size=False) for b in blocks]
nodes = [(0, 300000, 'globalgamemanagers'), (300000, 900_000, 'sharedassets0.assets'), (1_200_000, 300_000, 'resources.assets'), (1_500_000, len(plain) - 1_500_000, 'sharedassets0.assets.resS')]   # 第二个跨块边界；贴图流占大头（同真实 data.unity3d）
info = bytes(16) + struct.pack('>i', len(blocks)) + b''.join(struct.pack('>IIH', len(b), len(c), 2) for b, c in zip(blocks, comp)) \
    + struct.pack('>i', len(nodes)) + b''.join(struct.pack('>qqI', o, z, 4) + n.encode() + b'\0' for o, z, n in nodes)
head = b'UnityFS\0' + struct.pack('>I', 6) + b'5.x.x\0' + b'2019.4.31f1\0'
big = head + struct.pack('>qIII', 0, len(info), len(info), 0) + info + b''.join(comp)
want = {n: plain[o:o + z] for o, z, n in nodes}
sys.path.insert(0, os.path.join(D, '..', '..', '..', 'translator')); import unityfs
for name, it in (('unity_res.iter_bundle', lambda d: U.iter_bundle(d)), ('unityfs.bundle_files', lambda d: unityfs.bundle_files(d))):
    got = dict(it(big))
    check(got == {n: b for n, b in want.items() if not n.endswith('.resS')}, f'{name}：逐个节点 = 整包解开按偏移切的，.resS 跳过（{sorted(got)}）')
    with tempfile.TemporaryDirectory() as td:
        bp = os.path.join(td, 'data.unity3d'); open(bp, 'wb').write(big)
        with open(bp, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
            tracemalloc.start(); peak_names = [n for n, _ in it(mm)]; _, peak = tracemalloc.get_traced_memory(); tracemalloc.stop()
    bound = 2 * max(z for _, z, n in nodes if not n.endswith('.resS')) + 4 * BS   # 一个节点（拼装中 + 交出的一份）+ 几块（压缩块读出、解开、交接）；与整包大小无关
    check(peak_names == [n for _, _, n in nodes if not n.endswith('.resS')] and peak < bound < len(plain),
          f'{name}：从只读映射逐个读，内存峰值 {peak / (1 << 20):.1f} MiB < 上界 {bound / (1 << 20):.1f} MiB < 整包原文 {len(plain) / (1 << 20):.0f} MiB')
check(U.read_bundle(big) == want, 'read_bundle 照旧给全部节点（含 .resS）')

print(f'期望 Unity 资源 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
