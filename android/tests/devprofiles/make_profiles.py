#!/usr/bin/env python3
# 门禁手动：一次性转换脚本——8E / 9000 两份的输入是 git 历史里形态档的物理读数（提交 007efcdcc 的 android/tests/caps_shape/phys/*.json），
#   不是每次门禁都要重算；入库的三份档案由 tools/devprofile_lint.py（lint_test.sh）和形态档测试（caps_shape/run.sh）守着。
"""生成 android/tests/devprofiles/ 下的三份设备档案（s2a-device-profile-v1，#1749 §4.1 / §5.1）。

  adreno-8xx-qcom.json   骁龙 8 至尊版 / Adreno 830：由现有两份数据转换
  mali-g710-r32p1.json   天玑 9000 / Mali-G710 MC10：同上
  minimal-1.1.json       Vulkan 1.1 保守档：手写（下面 MINIMAL_* 逐项注依据），限值 / 格式 / 内存取两台真机逐项更紧

转换的输入（与原形态档 shapes.py real_shape() 同一规则）：
  phys/<名>.json     同一台机器 `cmd gpu vkjson` 整理出的物理设备读数（核心特性、扩展表、逐格式特性、内存堆、队列族）
                     —— 默认从 git 历史 007efcdcc 取（--phys-rev 改），或 --phys-dir 指目录
  android/tests/vk/profiles/devices/<名>.json   应用直连层真机读数（s2a-device-caps-v1）：限值 / 描述符索引位 / 子组大小以它为准
来源没有的读数一律写 null（未知），不猜：model / system 整段、pipelineCacheUUID、vkjson 不给的扩展特性与扩展属性、队列时间戳位。
真机上导出的档案（android/tools/device_profile.py）到手后，直接替换这两份（形态档测试只读 vulkan / identity / api 三段）。

用法：python3 android/tests/devprofiles/make_profiles.py [--check] [--phys-rev REV | --phys-dir DIR]
  --check  只比对、不写：重算结果与入库文件逐字节相同才退 0
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools'))
import devprofile_lint as lint   # noqa: E402

DEVICES = os.path.join(REPO, 'android', 'tests', 'vk', 'profiles', 'devices')
VK_CORE = os.path.join(REPO, 'graphics', 'nvn', 'third_party', 'vulkan-headers', 'include', 'vulkan', 'vulkan_core.h')
REAL = (('adreno-8xx-qcom', '8e'), ('mali-g710-r32p1', '9000'))
A4B4G4R4 = 'VK_FORMAT_A4B4G4R4_UNORM_PACK16'

# ---- minimal-1.1 手写部分（依据逐项写在行尾）----
# 核心特性：只开 vk_device.c 建设备的硬性要求（required[] 表 + 其后的 shaderDrawParameters 检查），其余全 0
MINIMAL_FEATURES_ON = {
    'independentBlend': 'vk_device.c required[]',
    'fragmentStoresAndAtomics': 'vk_device.c required[]',
    'shaderStorageImageWriteWithoutFormat': 'vk_device.c required[]',
    'occlusionQueryPrecise': 'vk_device.c required[]',
    'shaderImageGatherExtended': 'vk_device.c required[]',
    'samplerAnisotropy': 'vk_device.c required[]',
    'depthClamp': 'vk_device.c required[]',
}
MINIMAL_EXT_FEATURES = {'shaderDrawParameters': 1}   # Vulkan 1.1 核心特性；vk_device.c「required feature missing: shaderDrawParameters」
MINIMAL_EXTENSIONS = {}                              # vk_device.c 建设备不要求任何设备扩展（交换链等都是有才开）
MINIMAL_IDENTITY = {                                  # 合成档：身份字段只作标签，推导不读（§3.2-2）
    # 1.1、不列任何扩展：驱动属性（1.2 核心 / VK_KHR_driver_properties）查不了，驱动身份按「不知道」写 null
    'vendorId': '0x0000', 'deviceId': '0x00000000', 'driverId': None, 'driverVersion': 1,
    'driverName': None, 'deviceName': 'minimal Vulkan 1.1 shape', 'pipelineCacheUUID': None,
}
MINIMAL_API = '1.1.0'                                 # 后端的最低版本（vk_device.c「Vulkan loader below 1.1」）
MINIMAL_PROPS = {
    'deviceType': 1,                                  # INTEGRATED_GPU：手机 GPU 的类型（两台真机都是 1）
    'maxPerSetDescriptors': 1024,                     # Vulkan 1.1 规范 maintenance3 要求的下限
    'subgroupSupportedStages': 0x20,                  # Vulkan 1.1 规范：至少含 VK_SHADER_STAGE_COMPUTE_BIT
    'subgroupSupportedOperations': 0x1,               # Vulkan 1.1 规范：至少含 VK_SUBGROUP_FEATURE_BASIC_BIT
    'subgroupQuadOperationsInAllStages': 0,           # 规范允许为假
}
MINIMAL_QUEUES = [{'count': 1, 'flags': 0x7, 'timestampValidBits': 0}]   # 只有一个图形 + 计算 + 传输族（vk_device.c 只要 GRAPHICS∧COMPUTE）；规范允许不支持时间戳
# 限值 / 格式 / 内存：两台真机逐项取更紧（tighter，下同原形态档的保守规则）——比任何一台已知真机都紧，不放宽
SPEC11 = 'https://registry.khronos.org/vulkan/specs/1.1/html/vkspec.html'
DERIVED = '派生：android/tests/devprofiles/adreno-8xx-qcom.json 与 mali-g710-r32p1.json 逐项取更紧（make_profiles.py tighter / 按位与 / 取小）'
# minimal-1.1 是 assembled 档：每个不是「不支持」（0 / null / 空）的值都要有出处（tools/devprofile_lint.py）；上级路径覆盖下级
MINIMAL_SOURCES = {
    'api.version': 'android/native/direct/vk_device.c「Vulkan loader below 1.1」：后端最低 Vulkan 1.1（%s）' % SPEC11,
    'identity': '合成档：身份字段只作标签，推导不读（#1749 §3.2-2）',
    'vulkan.features': 'android/native/direct/vk_device.c required[] 与 shaderDrawParameters 检查：建设备的硬性要求，其余全 0',
    'vulkan.properties.deviceType': '合成档：INTEGRATED_GPU，两台真机档都是 1',
    'vulkan.properties.maxPerSetDescriptors': 'Vulkan 1.1 规范 Required Limits 表（%s#limits-minmax）：maxPerSetDescriptors 最低 1024' % SPEC11,
    'vulkan.properties.subgroupSupportedStages': 'Vulkan 1.1 规范 Required Limits 表（%s#limits-minmax）：至少含 VK_SHADER_STAGE_COMPUTE_BIT' % SPEC11,
    'vulkan.properties.subgroupSupportedOperations': 'Vulkan 1.1 规范 Required Limits 表（%s#limits-minmax）：至少含 VK_SUBGROUP_FEATURE_BASIC_BIT' % SPEC11,
    'vulkan.properties.limits': DERIVED,
    'vulkan.properties.maxMemoryAllocationSize': DERIVED,
    'vulkan.properties.subgroupSize': DERIVED,
    'vulkan.formats': DERIVED,
    'vulkan.memory': DERIVED,
    'vulkan.queues': 'Vulkan 1.1 规范 Queue Family Properties（%s#devsandqueues-queueprops）：有图形队列就要有同时支持图形与计算的族；'
                     'vk_device.c 只要 GRAPHICS∧COMPUTE；timestampValidBits=0 = 不支持时间戳（规范允许）' % SPEC11,
}


def vk_formats():
    h = open(VK_CORE, encoding='utf-8').read()
    return {n: int(v) for n, v in re.findall(r'\n\s+(VK_FORMAT_[A-Za-z0-9_]+) = (\d+),', h)}


def read_phys(stem, args):
    if args.phys_dir: return json.load(open(os.path.join(args.phys_dir, stem + '.json')))
    text = subprocess.run(['git', '-C', REPO, 'show', '%s:android/tests/caps_shape/phys/%s.json' % (args.phys_rev, stem)],
                          capture_output=True, text=True, check=True).stdout
    return json.loads(text)


def f32(v):   # 设备侧把 float 按 %.9g 写；这里同口径，整值写整数
    v = float('%.9g' % v)
    return int(v) if v.is_integer() else v


def api_str(v): return '%d.%d.%d' % ((v >> 22) & 0x7f, (v >> 12) & 0x3ff, v & 0xfff)


def convert(stem, phys, dev, fmt_names, fmt_num):
    """phys + devices → 档案；规则与原 shapes.py real_shape() 一致（应用直连层读数为准，物理读数补其余）。"""
    assert dev.get('schema') == 's2a-device-caps-v1', stem
    ident = phys['identity']
    for a, b in (('vendorID', 'vendorId'), ('deviceID', 'deviceId'), ('deviceName', 'deviceName')):
        if dev[b] != ident[a]: sys.exit('【红】%s：身份对不上 %s=%r / %r' % (stem, a, dev[b], ident[a]))
    limits = dict(phys['limits'])
    for k, v in dev['limits'].items():
        if k in limits: limits[k] = v
    for k, v in dev['features'].items():
        if k != 'geometryShaderOcclusionQuery' and v and not phys['features'].get(k):
            sys.exit('【红】%s：devices 说 %s 已启用，物理读数却说不支持' % (stem, k))
    exts = set(phys['extensions'])
    api = ident['apiVersion']
    has_timeline = 'VK_KHR_timeline_semaphore' in exts or api >= (1 << 22 | 2 << 12)   # 同 dev_facts.c：列了扩展或设备 ≥ 1.2
    has_di = 'VK_EXT_descriptor_indexing' in exts or api >= (1 << 22 | 2 << 12)
    has_4444 = 'VK_EXT_4444_formats' in exts or api >= (1 << 22 | 3 << 12)           # 列了扩展或设备 ≥ 1.3
    ef = phys['extFeatures']
    # phys 的扩展特性：vkjson 没给该结构时旧脚本记 0（「unknown extension features = absent」）——0 分不清「不支持」和「不知道」，
    #   probed 档案不留猜的值：只有 1 是读数，0 一律写 null
    seen = lambda v: 1 if v == 1 else None
    feats = {k: int(v) for k, v in phys['features'].items()}   # 核心特性：vkjson 整组给出，是读数
    feats['shaderDrawParameters'] = seen(ef['shaderDrawParameters'])   # 1.1 设备：dev_facts.c 总查
    if has_timeline: feats['timelineSemaphore'] = seen(ef['timelineSemaphore'])
    if 'VK_EXT_index_type_uint8' in exts: feats['indexTypeUint8'] = seen(ef['indexTypeUint8'])
    if has_4444: feats.update(formatA4B4G4R4=None, formatA4R4G4B4=None)        # vkjson 不给该结构：未知
    if 'VK_EXT_depth_clip_control' in exts: feats['depthClipControl'] = None                       # 同上
    if 'VK_EXT_map_memory_placed' in exts: feats.update(memoryMapPlaced=None, memoryMapRangePlaced=None, memoryUnmapReserve=None)
    if 'VK_EXT_custom_border_color' in exts:
        feats.update(customBorderColors=seen(ef['customBorderColors']), customBorderColorWithoutFormat=seen(ef['customBorderColorWithoutFormat']))
    if has_di:   # 描述符索引的六位取应用直连层真机读数（device_caps.c 打出来的支持位），是读数
        di = dev['descriptorIndexing']
        feats.update(runtimeDescriptorArray=int(di['runtimeArray']), descriptorBindingPartiallyBound=int(di['partiallyBound']),
                     shaderSampledImageArrayNonUniformIndexing=int(di['sampledImageArrayNonUniformIndexing']),
                     shaderStorageImageArrayNonUniformIndexing=int(di['storageImageArrayNonUniformIndexing']),
                     descriptorBindingVariableDescriptorCount=int(di['variableDescriptorCount']),
                     descriptorBindingSampledImageUpdateAfterBind=int(di['sampledImageUpdateAfterBind']))
    if 'VK_EXT_vertex_attribute_divisor' in exts:
        feats.update(vertexAttributeInstanceRateDivisor=seen(ef['vertexAttributeInstanceRateDivisor']), vertexAttributeInstanceRateZeroDivisor=None)
    if 'VK_EXT_swapchain_maintenance1' in exts:
        # device_caps.c 只在特性也开着时把它写进 enabledExtensions：真机档里有 = 特性为真
        feats['swapchainMaintenance1'] = 1 if 'VK_EXT_swapchain_maintenance1' in dev.get('enabledExtensions', []) else None
    props = {'deviceType': ident['deviceType'], 'maxMemoryAllocationSize': phys['maxMemoryAllocationSize'], 'maxPerSetDescriptors': None,
             'subgroupSize': dev.get('subgroupSize', phys['subgroupSize']), 'subgroupSupportedStages': None,
             'subgroupSupportedOperations': None, 'subgroupQuadOperationsInAllStages': None,
             'limits': {k: ([f32(x) if isinstance(x, float) else x for x in v] if isinstance(v, list) else f32(v) if isinstance(v, float) else v)
                        for k, v in limits.items()}}
    if 'VK_EXT_custom_border_color' in exts: props['maxCustomBorderColorSamplers'] = None
    if 'VK_EXT_sampler_filter_minmax' in exts: props.update(filterMinmaxSingleComponentFormats=None, filterMinmaxImageComponentMapping=None)
    if 'VK_EXT_vertex_attribute_divisor' in exts: props['maxVertexAttribDivisor'] = None
    if 'VK_EXT_external_memory_host' in exts: props['minImportedHostPointerAlignment'] = None
    if 'VK_EXT_map_memory_placed' in exts: props['minPlacedMemoryMapAlignment'] = None
    formats = {}
    for name in fmt_names:
        if name == A4B4G4R4:
            if not has_4444: continue   # dev_facts.c：没列扩展且设备低于 1.3 不查
            # vkjson 的格式表只有核心格式；device_caps.c 的 r4g4b4a4 只说「五个必需位齐」，不是三组原始位——不知道，不按规范值补
            formats[name] = None
            continue
        # vkjson 没列的格式 = 不知道（9000 实测有反例：没列的格式其实支持），写 null，不按「全 0」猜
        formats[name] = phys['formats'].get(str(fmt_num[name]))
    return {
        # 转换档：读数来自真机（probed），但旧数据缺的项写了 null（partial）
        'provenance': 'probed', 'completeness': 'partial',
        'schema': lint.SCHEMA, 'platform': 'android', 'api': {'kind': 'vulkan', 'version': api_str(ident['apiVersion'])},
        'identity': {'vendorId': '0x%04x' % ident['vendorID'], 'deviceId': '0x%08x' % ident['deviceID'], 'driverId': ident['driverID'],
                     'driverVersion': ident['driverVersion'], 'driverName': ident['driverName'], 'deviceName': ident['deviceName'],
                     'pipelineCacheUUID': None},
        'model': {'manufacturer': None, 'model': None, 'socModel': None, 'androidRelease': None},
        'system': {'sdk': None, 'pageSize': None, 'cpu': {'capacity': None, 'maxKHz': None}, 'kgsl': None, 'adpf': None, 'vsyncApi': None},
        'vulkan': {'extensions': {e: 1 for e in sorted(exts)}, 'features': feats, 'properties': props, 'formats': formats,
                   'memory': {'heaps': [{'size': s, 'flags': f} for s, f in phys['memoryHeaps']],
                              'types': [{'flags': f, 'heap': h} for f, h in phys['memoryTypes']]},
                   'queues': [{'flags': f, 'count': c, 'timestampValidBits': None} for f, c in phys['queues']]},
    }


def tighter(key, a, b):   # 原 shapes.py tighter() 原样
    if isinstance(a, list):
        if key.endswith('Range') and len(a) == 2: return [max(a[0], b[0]), min(a[1], b[1])]
        return [min(x, y) for x, y in zip(a, b)]
    if key.endswith('SampleCounts'): return a & b
    if key in ('strictLines', 'standardSampleLocations', 'timestampComputeAndGraphics'): return a & b
    if key.startswith('max'): return min(a, b)
    if key.startswith('min') or key in ('bufferImageGranularity', 'nonCoherentAtomSize', 'optimalBufferCopyOffsetAlignment',
                                         'optimalBufferCopyRowPitchAlignment', 'lineWidthGranularity', 'pointSizeGranularity'):
        return max(a, b)
    return min(a, b)


def minimal(a, m, core_names):
    va, vm = a['vulkan'], m['vulkan']
    la, lm = va['properties']['limits'], vm['properties']['limits']
    feats = {k: int(k in MINIMAL_FEATURES_ON) for k in sorted(core_names)}
    feats.update(MINIMAL_EXT_FEATURES)
    props = dict(MINIMAL_PROPS)
    props['maxMemoryAllocationSize'] = min(va['properties']['maxMemoryAllocationSize'], vm['properties']['maxMemoryAllocationSize'])
    props['subgroupSize'] = min(va['properties']['subgroupSize'], vm['properties']['subgroupSize'])
    props['limits'] = {k: tighter(k, la[k], lm[k]) for k in la}
    # 保守档按位与；某台未知（null）的格式按「能力未知 = 不支持」当全 0 取与（结果仍是更紧的那一侧）
    z3 = lambda v: v if v is not None else [0, 0, 0]
    formats = {k: [x & y for x, y in zip(z3(va['formats'][k]), z3(vm['formats'].get(k)))] for k in va['formats'] if k != A4B4G4R4}
    heaps = lambda v: sum(h['size'] for h in v['memory']['heaps'])
    small = va if heaps(va) <= heaps(vm) else vm
    return {
        # 手写基线（assembled）；pipelineCacheUUID、model / system 段没有值（partial）
        'provenance': 'assembled', 'completeness': 'partial', 'sources': dict(MINIMAL_SOURCES),
        'schema': lint.SCHEMA, 'platform': 'android', 'api': {'kind': 'vulkan', 'version': MINIMAL_API},
        'identity': dict(MINIMAL_IDENTITY),
        'model': {'manufacturer': None, 'model': None, 'socModel': None, 'androidRelease': None},
        'system': {'sdk': None, 'pageSize': None, 'cpu': {'capacity': None, 'maxKHz': None}, 'kgsl': None, 'adpf': None, 'vsyncApi': None},
        'vulkan': {'extensions': dict(MINIMAL_EXTENSIONS), 'features': feats, 'properties': props, 'formats': formats,
                   'memory': json.loads(json.dumps(small['memory'])), 'queues': [dict(q) for q in MINIMAL_QUEUES]},
    }


def build(args):
    fmt_num = vk_formats()
    _, core, _, _, fmt_names = lint.names()
    out = {}
    for name, stem in REAL:
        dev = json.load(open(os.path.join(DEVICES, stem + '.json')))
        out[name] = convert(stem, read_phys(stem, args), dev, sorted(fmt_names), fmt_num)
    out['minimal-1.1'] = minimal(out['adreno-8xx-qcom'], out['mali-g710-r32p1'], core)
    for name, p in out.items():
        p['factsDigest'] = lint.digest(p)
        bad = lint.check(p)
        if bad: sys.exit('【红】%s 生成出来就不合格：\n  %s' % (name, '\n  '.join(bad)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--phys-rev', default='007efcdcc')
    ap.add_argument('--phys-dir')
    args = ap.parse_args()
    rc = 0
    for name, p in build(args).items():
        path = os.path.join(HERE, name + '.json')
        text = lint.dumps_pretty(p)
        if args.check:
            same = os.path.exists(path) and open(path, encoding='utf-8').read() == text
            print('%s: %s 与重算%s' % ('PASS' if same else 'FAIL', name, '一致' if same else '不一致'))
            rc |= not same
        else:
            open(path, 'w', encoding='utf-8').write(text)
            print('写 %s（%s）' % (os.path.relpath(path, REPO), p['factsDigest'][:23]))
    return rc


if __name__ == '__main__':
    sys.exit(main())
