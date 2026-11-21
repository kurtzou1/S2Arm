#!/usr/bin/env python3
# 辅助脚本：android/tests/caps_shape/run.sh 用它出三档形态头文件、核对真机设备档；随 run.sh 在 android/test.sh 里跑
"""整台设备能力形态档（#1749：不读厂商号，只看能力）。

三档：
  adreno       = 骁龙 8 至尊版 / Adreno 830（android/tests/vk/profiles/devices/8e.json）
  mali         = 天玑 9000 / Mali-G710 MC10（android/tests/vk/profiles/devices/9000.json）
  conservative = 前两档逐项取更紧的值，再关掉所有可选特性 / 扩展（只留后端建设备必需的特性）

数据两层：
  devices/<名>.json   应用直连层真机读数（s2a-device-caps-v1，device_caps.c 打出来的那份）：limits / 描述符索引支持位 / 身份以它为准；
  phys/<名>.json      同一台机器的物理设备读数（安卓 `cmd gpu vkjson` 整理出的紧凑版，regen 子命令生成）：
                      完整核心特性、设备扩展表、逐格式特性、内存堆、队列族——devices/*.json 没有的部分从这里补。
  devices/*.json 的 features 是「已启用」口径（例：Mali 上几何着色器被 capprobe 关了写 false），所以只校验
  「已启用为真 ⇒ 物理支持为真」，不拿它覆盖物理支持位。

子命令：
  regen <8e vkjson> <9000 vkjson>   从 vkjson 重出 phys/8e.json、phys/9000.json
  header <out.h>                    出三档的 C 头（假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 选档）
  names                             列档名
  oracle <档名> <设备打出的 caps JSON>  真机档：本构建在该形态下打出的 caps 和 devices/*.json 逐项比（几何着色器两位除外：取决于 capprobe 判定）
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
DEVICES = os.path.join(REPO, 'android', 'tests', 'vk', 'profiles', 'devices')
PHYS = os.path.join(HERE, 'phys')
REAL = (('adreno', '8e'), ('mali', '9000'))
NAMES = ('adreno', 'mali', 'conservative')

# 后端建设备的必需特性（android/native/direct/vk_device.c 的 required[] + shaderDrawParameters）：保守档关可选特性时留下它们。
#   vk_device.c 加了新的必需项而这里没跟上时，保守档建设备失败、run.sh 当场红（报缺哪一项），不会悄悄放过。
REQUIRED_FEATURES = ('independentBlend', 'fragmentStoresAndAtomics', 'shaderStorageImageWriteWithoutFormat',
                     'occlusionQueryPrecise', 'shaderImageGatherExtended', 'samplerAnisotropy', 'depthClamp')
# 实例扩展不是设备能力：三档一样（假驱动给全）
INSTANCE_EXTS = ('VK_KHR_get_physical_device_properties2', 'VK_KHR_surface', 'VK_KHR_android_surface',
                 'VK_KHR_get_surface_capabilities2', 'VK_EXT_surface_maintenance1')
EXT_FEATURES = ('shaderDrawParameters', 'timelineSemaphore', 'indexTypeUint8', 'customBorderColors',
                'customBorderColorWithoutFormat', 'vertexAttributeInstanceRateDivisor', 'formatA4B4G4R4', 'depthClipControl',
                'diRuntimeArray', 'diPartiallyBound', 'diSampledNonUniform', 'diStorageNonUniform',
                'diVariableCount', 'diSampledUpdateAfterBind')
DI_MAP = (('diRuntimeArray', 'runtimeArray'), ('diPartiallyBound', 'partiallyBound'),
          ('diSampledNonUniform', 'sampledImageArrayNonUniformIndexing'),
          ('diStorageNonUniform', 'storageImageArrayNonUniformIndexing'),
          ('diVariableCount', 'variableDescriptorCount'), ('diSampledUpdateAfterBind', 'sampledImageUpdateAfterBind'))


def num(v):
    if isinstance(v, str) and v.startswith('0x'): return int(v, 16)
    if isinstance(v, float) and v.is_integer(): return int(v)
    return v


def regen(src8e, src9000):
    for stem, src in (('8e', src8e), ('9000', src9000)):
        d = json.load(open(src))['devices'][0]
        p = d['properties']
        drv = d.get('VK_KHR_driver_properties', {}).get('driverPropertiesKHR', {})
        def ext_feat(ext, struct, field):
            return int(num(d.get(ext, {}).get(struct, {}).get(field, 0)) == 1)
        core11 = d.get('core11', {}).get('features', {})
        core12 = d.get('core12', {}).get('features', {})
        ef = {
            'shaderDrawParameters': int(num(d.get('shaderDrawParameterFeatures', {}).get('shaderDrawParameters', core11.get('shaderDrawParameters', 0))) == 1),
            # vkjson 只在 1.2 设备上给 core12；没给的（9000 是 1.1）按「未知 = 无」
            'timelineSemaphore': int(num(core12.get('timelineSemaphore', 0)) == 1),
            'indexTypeUint8': ext_feat('VK_EXT_index_type_uint8', 'indexTypeUint8FeaturesEXT', 'indexTypeUint8'),
            'customBorderColors': ext_feat('VK_EXT_custom_border_color', 'customBorderColorFeaturesEXT', 'customBorderColors'),
            'customBorderColorWithoutFormat': ext_feat('VK_EXT_custom_border_color', 'customBorderColorFeaturesEXT', 'customBorderColorWithoutFormat'),
            'vertexAttributeInstanceRateDivisor': ext_feat('VK_EXT_vertex_attribute_divisor', 'vertexAttributeDivisorFeaturesEXT', 'vertexAttributeInstanceRateDivisor'),
            # vkjson 不给这两个扩展的特性结构：未知 = 无
            'formatA4B4G4R4': 0, 'depthClipControl': 0,
        }
        rec = {
            'source': 'android cmd gpu vkjson of the same device as ../../vk/profiles/devices/%s.json (unknown extension features = absent)' % stem,
            'identity': {'apiVersion': num(p['apiVersion']), 'driverVersion': num(p['driverVersion']), 'vendorID': num(p['vendorID']),
                         'deviceID': num(p['deviceID']), 'deviceType': num(p['deviceType']), 'deviceName': p['deviceName'],
                         'driverID': num(drv.get('driverID', 0)), 'driverName': drv.get('driverName', '')},
            'limits': {k: ([num(x) for x in v] if isinstance(v, list) else num(v)) for k, v in sorted(p['limits'].items())},
            'features': {k: int(num(v) == 1) for k, v in sorted(d['features'].items())},
            'extFeatures': ef,
            'extensions': sorted(e['extensionName'] for e in d['extensions']),
            'maxMemoryAllocationSize': num(d['maintenance3Properties']['maxMemoryAllocationSize']),
            'subgroupSize': num(d['subgroupProperties']['subgroupSize']),
            'formats': {str(num(f)): [num(v['linearTilingFeatures']), num(v['optimalTilingFeatures']), num(v['bufferFeatures'])]
                        for f, v in sorted(d['formats'], key=lambda x: x[0])},
            'memoryHeaps': [[num(h['size']), num(h['flags'])] for h in d['memory']['memoryHeaps']],
            'memoryTypes': [[num(t['propertyFlags']), num(t['heapIndex'])] for t in d['memory']['memoryTypes']],
            'queues': [[num(q['queueFlags']), num(q['queueCount'])] for q in d['queues']],
        }
        os.makedirs(PHYS, exist_ok=True)
        with open(os.path.join(PHYS, stem + '.json'), 'w') as f:   # 一个键一行（逐格式一行），diff 看得清
            body = []
            for k in sorted(rec):
                v = rec[k]
                if isinstance(v, dict) and k in ('formats', 'limits', 'features'):
                    inner = ',\n'.join('  %s: %s' % (json.dumps(a), json.dumps(b, separators=(',', ':'))) for a, b in v.items())
                    body.append('%s: {\n%s\n }' % (json.dumps(k), inner))
                else:
                    body.append('%s: %s' % (json.dumps(k), json.dumps(v, ensure_ascii=False, separators=(',', ':'))))
            f.write('{\n ' + ',\n '.join(body) + '\n}\n')


def real_shape(stem):
    s = json.load(open(os.path.join(PHYS, stem + '.json')))
    dev = json.load(open(os.path.join(DEVICES, stem + '.json')))
    assert dev.get('schema') == 's2a-device-caps-v1', stem
    for k, v in dev['limits'].items():
        if k in s['limits']: s['limits'][k] = v          # 应用直连层读数为准
    s['subgroupSize'] = dev.get('subgroupSize', s['subgroupSize'])
    for k, v in dev['features'].items():
        if k == 'geometryShaderOcclusionQuery': continue
        if v and not s['features'].get(k):
            sys.exit('【红】%s：devices/%s.json 说 %s 已启用，物理读数却说不支持——两份数据不是同一台机器？' % (stem, stem, k))
    for ours, theirs in DI_MAP:
        s['extFeatures'][ours] = int(bool(dev['descriptorIndexing'][theirs]))
    # vkjson 的格式表只列核心格式；A4B4G4R4（VK_EXT_4444_formats，1000340001）真机档说 device_caps.c 查到了整套采样 / 过滤 / 位块传送 / 传输位，按读数补上
    if dev['formats'].get('r4g4b4a4') and '1000340001' not in s['formats']:
        s['formats']['1000340001'] = [0, 0x1 | 0x1000 | 0x400 | 0x4000 | 0x8000, 0]
    for a, b in (('apiVersion', None), ('vendorID', 'vendorId'), ('deviceID', 'deviceId'), ('deviceName', 'deviceName')):
        if b and dev[b] != s['identity'][a]:
            sys.exit('【红】%s：身份对不上 %s=%r / %r' % (stem, a, dev[b], s['identity'][a]))
    return s


def tighter(key, a, b):
    if isinstance(a, list):   # 范围：[下限, 上限] 取交集；三维上限逐项取小
        if key.endswith('Range') and len(a) == 2: return [max(a[0], b[0]), min(a[1], b[1])]
        return [min(x, y) for x, y in zip(a, b)]
    if key.endswith('SampleCounts'): return a & b   # 采样数位掩码：两台都支持的才算
    if key in ('strictLines', 'standardSampleLocations', 'timestampComputeAndGraphics'): return a & b
    if key.startswith('max'): return min(a, b)
    if key.startswith('min') or key in ('bufferImageGranularity', 'nonCoherentAtomSize', 'optimalBufferCopyOffsetAlignment',
                                         'optimalBufferCopyRowPitchAlignment', 'lineWidthGranularity', 'pointSizeGranularity'):
        return max(a, b)   # 对齐 / 粒度 / 下限：大的更紧（minTexelOffset 这类负数下限也是靠近 0 更紧）
    return min(a, b)


def conservative(a, m):
    s = {'source': 'derived: per-field tighter of adreno and mali, every optional feature / extension off'}
    s['identity'] = {'apiVersion': min(a['identity']['apiVersion'], m['identity']['apiVersion']), 'driverVersion': 1, 'vendorID': 0,
                     'deviceID': 0, 'deviceType': 1, 'deviceName': 'conservative shape', 'driverID': 0, 'driverName': 'conservative'}
    s['limits'] = {k: tighter(k, a['limits'][k], m['limits'][k]) for k in a['limits']}
    s['features'] = {k: int(a['features'][k] and m['features'][k] and k in REQUIRED_FEATURES) for k in a['features']}
    s['extFeatures'] = {k: int(k == 'shaderDrawParameters') for k in EXT_FEATURES}   # DrawParameters 是 1.1 核心、后端必需
    s['extensions'] = []
    s['maxMemoryAllocationSize'] = min(a['maxMemoryAllocationSize'], m['maxMemoryAllocationSize'])
    s['subgroupSize'] = min(a['subgroupSize'], m['subgroupSize'])
    s['formats'] = {f: [x & y for x, y in zip(a['formats'][f], m['formats'][f])] for f in a['formats'] if f in m['formats']}
    small = a if sum(h[0] for h in a['memoryHeaps']) <= sum(h[0] for h in m['memoryHeaps']) else m   # 内存取小的那台
    s['memoryHeaps'], s['memoryTypes'] = small['memoryHeaps'], small['memoryTypes']
    s['queues'] = [[0x7, 1]]   # 只有一个图形 + 计算 + 传输队列
    return s


def shapes():
    a, m = real_shape('8e'), real_shape('9000')
    return {'adreno': a, 'mali': m, 'conservative': conservative(a, m)}


def c_str(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def c_val(v):
    if isinstance(v, list): return '{' + ', '.join(c_val(x) for x in v) + '}'
    if isinstance(v, float): return repr(v) + 'f'
    return str(v) + ('ull' if isinstance(v, int) and v > 0x7fffffff else '')


def header(out):
    sh = shapes()
    lines = ['// 生成文件（android/tests/caps_shape/shapes.py header），不进仓库', '#pragma once']
    for name in NAMES:
        s = sh[name]; i = s['identity']
        lines.append('static const char *const cs_ext_%s[] = { %s };' % (name, ', '.join(c_str(e) for e in s['extensions']) or 'NULL'))
        lines.append('static const struct cs_fmt cs_fmt_%s[] = { %s };' % (name, ', '.join(
            '{%s, %d, %d, %d}' % (f, *v) for f, v in sorted(s['formats'].items(), key=lambda x: int(x[0])))))
        lines.append('static const struct cs_shape cs_%s = {' % name)
        lines.append('  .name = %s, .n_ext = %d, .ext = %s, .n_fmt = %d, .fmt = cs_fmt_%s,' % (
            c_str(name), len(s['extensions']), 'cs_ext_' + name if s['extensions'] else 'NULL', len(s['formats']), name))
        lines.append('  .props = { .apiVersion = %d, .driverVersion = %du, .vendorID = %du, .deviceID = %du, .deviceType = %d, .deviceName = %s,' % (
            i['apiVersion'], i['driverVersion'], i['vendorID'], i['deviceID'], i['deviceType'], c_str(i['deviceName'])))
        lines.append('    .limits = { ' + ', '.join('.%s = %s' % (k, c_val(v)) for k, v in s['limits'].items()) + ' } },')
        lines.append('  .features = { ' + ', '.join('.%s = %d' % (k, v) for k, v in s['features'].items()) + ' },')
        lines.append('  ' + ', '.join('.%s = %d' % (k, s['extFeatures'][k]) for k in EXT_FEATURES) + ',')
        lines.append('  .driver_id = %d, .driver_name = %s, .max_alloc = %dull, .subgroup_size = %d,' % (
            i['driverID'], c_str(i['driverName']), s['maxMemoryAllocationSize'], s['subgroupSize']))
        lines.append('  .n_heap = %d, .heaps = { %s }, .n_type = %d, .types = { %s },' % (
            len(s['memoryHeaps']), ', '.join('{%dull, %d}' % tuple(h) for h in s['memoryHeaps']),
            len(s['memoryTypes']), ', '.join('{%d, %d}' % tuple(t) for t in s['memoryTypes'])))
        lines.append('  .n_queue = %d, .queues = { %s },' % (len(s['queues']), ', '.join('{%d, %d}' % tuple(q) for q in s['queues'])))
        lines.append('};')
    lines.append('static const struct cs_shape *const cs_all[] = { %s };' % ', '.join('&cs_' + n for n in NAMES))
    feats = sorted(sh['adreno']['features'])
    lines.append('static const char *cs_feature_name(size_t i) {')
    lines.append('    static const struct { size_t i; const char *n; } t[] = { %s };' % ', '.join(
        '{offsetof(VkPhysicalDeviceFeatures, %s) / sizeof(VkBool32), "%s"}' % (f, f) for f in feats))
    lines.append('    for (size_t k = 0; k < sizeof t / sizeof *t; k++) if (t[k].i == i) return t[k].n;')
    lines.append('    return "?";')
    lines.append('}')
    lines.append('static const char *const cs_instance_ext[] = { %s };' % ', '.join(c_str(e) for e in INSTANCE_EXTS))
    open(out, 'w').write('\n'.join(lines) + '\n')


def oracle(name, got_path):
    stem = dict(REAL)[name]
    want = json.load(open(os.path.join(DEVICES, stem + '.json')))
    got = json.load(open(got_path))
    bad = []
    for sect in ('limits', 'features', 'formats', 'memory'):
        for k, v in want[sect].items():
            if sect == 'features' and k in ('geometryShader', 'geometryShaderOcclusionQuery'): continue   # capprobe 判定，不是能力形态
            g = got.get(sect, {}).get(k)
            if (abs(g - v) > 1e-6 if isinstance(v, float) else g != v): bad.append('%s.%s：真机 %r / 本构建 %r' % (sect, k, v, g))
    for k in ('vendorId', 'deviceId', 'deviceName', 'driverName', 'subgroupSize'):
        if got.get(k) != want.get(k): bad.append('%s：真机 %r / 本构建 %r' % (k, want.get(k), got.get(k)))
    if bad:
        print('FAIL: %s 档打出的设备 caps 和真机档 devices/%s.json 不一致（%d 处）：\n  %s' % (name, stem, len(bad), '\n  '.join(bad)))
        return 1
    n = sum(len(want[s]) for s in ('limits', 'features', 'formats', 'memory')) - 2 + 5
    print('PASS: %s 档打出的设备 caps 与真机档 devices/%s.json 一致（比了 %d 项）' % (name, stem, n))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'regen' and len(sys.argv) == 4: regen(sys.argv[2], sys.argv[3])
    elif cmd == 'header' and len(sys.argv) == 3: header(sys.argv[2])
    elif cmd == 'names': print(' '.join(NAMES))
    elif cmd == 'oracle' and len(sys.argv) == 4: sys.exit(oracle(sys.argv[2], sys.argv[3]))
    else: sys.exit(__doc__)
