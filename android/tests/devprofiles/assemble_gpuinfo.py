#!/usr/bin/env python3
# 门禁手动：一次性转换脚本——把 vulkan.gpuinfo.org 的公开报告拼成 assembled 设备档案（#1749：还没有真机档的芯片先用公开数据占位）
"""gpuinfo 报告 → s2a-device-profile-v1（provenance = assembled、completeness = partial）。

输入（不进仓库，--raw 指目录）：每份报告两个文件，都是 vulkan.gpuinfo.org 的公开页面
  report-<编号>.html   https://vulkan.gpuinfo.org/displayreport.php?id=<编号>：身份（deviceID / driverVersion / deviceType / deviceName）、
                       内存堆与内存类型、厂商与机型（android.ProductManufacturer / ProductModel）
  profile-<编号>.json  https://vulkan.gpuinfo.org/api/v3/getprofile.php?id=<编号>（报告页的 Profile JSON）：特性、限值、扩展、格式、队列族
取值规则（宁可保守，不猜）：
  - 哪些键出现，与 android/native/direct/dev_facts.c 在同一台设备上会写的完全一样（扩展特性 / 扩展属性只在它会挂查询结构时出现）；
  - 报告里没有的读数一律写 null（未知）。包括：报告没列的格式（gpuinfo 导出不写全 0 的格式，「没列」分不清「不支持」和「没导出」）、
    报告里没有该扩展结构的扩展特性 / 扩展属性、系统段整段（gpuinfo 不采集）、androidRelease、socModel；
  - 浮点限值按 float32 再 %.9g（设备侧同口径）；driverVersion 报告页只给解码后的 a.b.c，按 VK_MAKE_VERSION 还原
    （高通 / ARM / 三星驱动都按这个编码，见 adreno-8xx-qcom.json / mali-g710-r32p1.json 的真机读数）；
  - 内存类型：报告页按堆分组列出，组内次序保留，各堆按堆号先后拼接——全局类型号的次序是重建的，未必等于设备真实次序（sources 里注明）。
每份档案的 sources 按段写到报告链接；拼装档案只作宿主形态测试的输入，不作「这台设备一定能跑」的依据（#1749 定案）。

用法：python3 android/tests/devprofiles/assemble_gpuinfo.py --raw <目录> [--check]
  --check：只比对，不写；入库档案与本脚本按同一输入重算的结果不一致就退出 1。
"""
import argparse, html, json, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools'))
import devprofile_lint as lint   # noqa: E402

VK_CORE = os.path.join(REPO, 'graphics', 'nvn', 'third_party', 'vulkan-headers', 'include', 'vulkan', 'vulkan_core.h')
GPUINFO = 'https://vulkan.gpuinfo.org/displayreport.php?id=%d'
GPUINFO_PROFILE = 'https://vulkan.gpuinfo.org/api/v3/getprofile.php?id=%d'
# 规范推出的值（报告里没有该结构时才用）：Vulkan 1.1 的 Feature requirements——列了 VK_KHR_shader_draw_parameters 就必须支持 shaderDrawParameters
VK_XML_DRAW_PARAMS = ('https://github.com/KhronosGroup/Vulkan-Docs/blob/33d3353757d83d6aca683120114fe74cc4eaf8fb/xml/vk.xml'
                      '（VK_VERSION_1_1「Feature requirements」：<require depends="VK_KHR_shader_draw_parameters"> shaderDrawParameters）'
                      '——gpuinfo 的 1.1 设备报告没有 VkPhysicalDeviceShaderDrawParametersFeatures，按设备列出的该扩展由规范推出')

# 档名 → (报告编号, 芯片)。选报告口径：原厂驱动、Android 14 及以上、OEM 机型；避开同一机型多个 512.8xx 驱动的报告（疑似模拟器用户自装驱动）
#   gpuinfo 上没有报告、不造档（待真机导出）：骁龙 8 Elite Gen 6（Adreno 845）、玄戒 O1（Mali-G925-Immortalis MC16）、
#   玄戒 O3（G2-Ultra NX MC16）、Tensor G6（PowerVR C-Series）
#   同一 gpuinfo GPU 名对应多颗芯片时（Adreno 730、Mali-G710 MC10、Mali-G78、Mali-G715 …）按机型型号挑报告
TARGETS = (
    # 骁龙（8 Elite 有真机 probed 档 adreno-8xx-qcom，不拼；8 Elite Gen 6 的 Adreno 845 在 gpuinfo 上没有报告）
    ('adreno-730-sd8g1', 52726, '骁龙 8 Gen 1'),                 # SM-S906U（Galaxy S22+ 美版）
    ('adreno-730-sd8pg1', 51035, '骁龙 8+ Gen 1'),               # SM-F936U1（Galaxy Z Fold4）
    ('adreno-740-sd8g2', 53287, '骁龙 8 Gen 2'),
    ('adreno-750-sd8g3', 49630, '骁龙 8 Gen 3'),
    ('adreno-840-sd8eg5', 52150, '骁龙 8 Elite Gen 5'),          # SM-S948B（Galaxy S26 Ultra）
    ('adreno-850-sd8exg6', 52618, '骁龙 8 Elite Extreme Gen 6'),  # OnePlus PYB110；Adreno 850 = Extreme 档（Qualcomm 命名）
    # 天玑（9000 有真机 probed 档 mali-g710-r32p1、9400 等真机导出，都不拼）
    ('mali-g710-d9000p', 50347, '天玑 9000+'),                   # vivo V2231A
    ('mali-g715-d9200', 49866, '天玑 9200'),
    ('mali-g715-d9200p', 45760, '天玑 9200+'),                   # vivo V2302A
    ('mali-g720-d9300', 45060, '天玑 9300'),
    ('mali-g720-d9300p', 42339, '天玑 9300+'),                   # vivo V2359A
    ('mali-g925-d9400p', 45836, '天玑 9400+'),                   # vivo V2458A
    ('mali-g1ultra-d9500', 52556, '天玑 9500'),                  # OPPO PLG110
    ('mali-g2ultra-d9600pro', 52183, '天玑 9600 Pro'),           # OPPO PMX110
    # 猎户座
    ('mali-g78-e2100', 40572, 'Exynos 2100'),                    # SM-G998B（Galaxy S21 Ultra），最新报告是 Android 15
    ('xclipse-920-e2200', 45599, 'Exynos 2200（Xclipse 一代）'),
    ('xclipse-940-e2400', 52490, 'Exynos 2400'),                 # SM-S926B（Galaxy S24+）
    ('xclipse-950-e2500', 43405, 'Exynos 2500'),                 # SM-F766B（Galaxy Z Flip7）
    ('xclipse-960-e2600', 52499, 'Exynos 2600'),                 # SM-S942B
    # Google Tensor（G5 起换成 Imagination PowerVR；G6 的 PowerVR C-Series 在 gpuinfo 上没有报告）
    ('mali-g78-tg1', 53386, 'Tensor G1'),                        # Pixel 6
    ('mali-g710-tg2', 47341, 'Tensor G2'),                       # Pixel 7
    ('mali-g715-tg3', 47617, 'Tensor G3'),                       # Pixel 8
    ('mali-g715-tg4', 51222, 'Tensor G4'),                       # Pixel 9
    ('powervr-dxt-tg5', 51806, 'Tensor G5'),                     # Pixel 10
)


def vk_enums():
    """vulkan_core.h 里的 枚举名 → 数值（含别名）。"""
    src = open(VK_CORE, encoding='utf-8').read()
    raw = dict(re.findall(r'\n\s+(VK_[A-Za-z0-9_]+) = ((?:0x[0-9A-Fa-f]+|-?\d+)|VK_[A-Za-z0-9_]+),', src))
    out = {}
    def val(n, depth=0):
        v = raw[n]
        if v.startswith('VK_'): return val(v, depth + 1) if depth < 8 else None
        return int(v, 0)
    for n in raw:
        v = val(n)
        if v is not None: out[n] = v
    return out


def app_api_version():
    path = os.path.join(REPO, 'android', 'native', 'direct', 'vk_device.h')
    with open(path, encoding='utf-8') as header:
        m = re.search(r'^#define S2A_VK_APP_API_VERSION VK_API_VERSION_(\d+)_(\d+)\b', header.read(), re.M)
    if not m:
        sys.exit('【红】assemble_gpuinfo：无法从 vk_device.h 读取应用申请的 Vulkan 版本')
    return (int(m[1]) << 22) | (int(m[2]) << 12)


ENUM = vk_enums()
APP_API_VERSION = app_api_version()


def bits(names, prefix=''):
    v = 0
    for n in names:
        n = n if n.startswith('VK_') else prefix + n
        if n not in ENUM: sys.exit('【红】assemble_gpuinfo：vulkan_core.h 里没有 %s' % n)
        v |= ENUM[n]
    return v


def f32(v):   # 设备侧（dev_facts.c）把 float 按 %.9g 写；这里先截成 float32 再同口径
    v = float('%.9g' % struct.unpack('f', struct.pack('f', float(v)))[0])
    return int(v) if v.is_integer() else v


def api_str(v): return '%d.%d.%d' % ((v >> 22) & 0x7f, (v >> 12) & 0x3ff, v & 0xfff)


def report_rows(path):
    """报告页的表格行：[名, 值, 分组]。"""
    s = re.sub(r'<script.*?</script>', '', open(path, encoding='utf-8', errors='replace').read(), flags=re.S)
    out = []
    for r in re.findall(r'<tr[^>]*>(.*?)</tr>', s, flags=re.S):
        c = [re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', x))).strip() for x in re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', r, flags=re.S)]
        if len(c) >= 3: out.append(c[:3])
    return out


def one(rows, name, group):
    hit = [r[1] for r in rows if r[0] == name and r[2] == group]
    if len(hit) != 1: sys.exit('【红】assemble_gpuinfo：报告页里 %s（%s）有 %d 处，期望 1 处' % (name, group, len(hit)))
    return hit[0]


def memory(rows):
    heaps, types = {}, {}
    for name, value, group in rows:
        m = re.fullmatch(r'Memory heap (\d+)', group)
        if not m: continue
        h = int(m.group(1))
        if name == 'Flags': heaps.setdefault(h, {})['flags'] = bits(value.split(), 'VK_MEMORY_HEAP_') if value else 0
        elif name == 'Size': heaps.setdefault(h, {})['size'] = int(re.fullmatch(r'([\d,]+) bytes', value).group(1).replace(',', ''))
        elif re.fullmatch(r'Memory type \d+', name):
            types.setdefault(h, []).append({'flags': bits(value.split(), 'VK_MEMORY_PROPERTY_') if value else 0, 'heap': h})
    if not heaps or sorted(heaps) != list(range(len(heaps))) or any(set(x) != {'flags', 'size'} for x in heaps.values()):
        sys.exit('【红】assemble_gpuinfo：报告页的内存堆不完整：%r' % heaps)
    return {'heaps': [heaps[h] for h in sorted(heaps)], 'types': [t for h in sorted(heaps) for t in types.get(h, [])]}


def convert(name, rid, chip, raw):
    rows = report_rows(os.path.join(raw, 'report-%d.html' % rid))
    dev = json.load(open(os.path.join(raw, 'profile-%d.json' % rid), encoding='utf-8'))['capabilities']['device']
    feats, props = dev['features'], dev['properties']
    P = props['VkPhysicalDeviceProperties']

    def st(group, *names):   # 第一个在报告里的结构
        for n in names:
            if n in group: return group[n]
        return None

    api = P['apiVersion']
    if api_str(api) != one(rows, 'apiVersion', 'Properties'): sys.exit('【红】%s：profile 与报告页的 apiVersion 不一致' % name)
    exts = set(dev['extensions'])
    listed = exts.__contains__
    effective_api = min(api, APP_API_VERSION)
    core11 = effective_api >= (1 << 22 | 1 << 12)
    core12 = effective_api >= (1 << 22 | 2 << 12)
    core13 = effective_api >= (1 << 22 | 3 << 12)
    # 与 dev_facts.c query_vulkan 同一组「挂不挂查询结构」的条件（只在 ≥ 1.1 时挂）
    have = {
        'timeline': core11 and (listed('VK_KHR_timeline_semaphore') or core12),
        'index_u8': core11 and (listed('VK_EXT_index_type_uint8') or listed('VK_KHR_index_type_uint8')),
        '4444': core11 and listed('VK_EXT_4444_formats'),
        '4444_fmt': listed('VK_EXT_4444_formats') or core13,
        'driver': core11 and (listed('VK_KHR_driver_properties') or core12),
        'dcc': core11 and listed('VK_EXT_depth_clip_control'),
        'placed': core11 and listed('VK_EXT_map_memory_placed'),
        'border': core11 and listed('VK_EXT_custom_border_color'),
        'di': core11 and (listed('VK_EXT_descriptor_indexing') or core12),
        'vdiv': core11 and listed('VK_EXT_vertex_attribute_divisor'),
        'swm1': core11 and (listed('VK_EXT_swapchain_maintenance1') or listed('VK_KHR_swapchain_maintenance1')),
        'minmax': core11 and listed('VK_EXT_sampler_filter_minmax'),
        'host': core11 and listed('VK_EXT_external_memory_host'),
    }

    def b(s, k):   # 结构不在报告里 = null
        return None if s is None or k not in s else int(bool(s[k]))

    f = {k: int(bool(feats['VkPhysicalDeviceFeatures'][k])) for k in sorted(lint.names()[1])}
    v11 = st(feats, 'VkPhysicalDeviceVulkan11Features')
    v12 = st(feats, 'VkPhysicalDeviceVulkan12Features')
    derived = {}   # 字段路径 → 出处（规范推出的值）
    if core11:
        f['shaderDrawParameters'] = b(st(feats, 'VkPhysicalDeviceShaderDrawParametersFeatures') or v11, 'shaderDrawParameters')
        if f['shaderDrawParameters'] is None and listed('VK_KHR_shader_draw_parameters'):
            f['shaderDrawParameters'] = 1; derived['vulkan.features.shaderDrawParameters'] = VK_XML_DRAW_PARAMS
    if have['timeline']: f['timelineSemaphore'] = b(st(feats, 'VkPhysicalDeviceTimelineSemaphoreFeatures', 'VkPhysicalDeviceTimelineSemaphoreFeaturesKHR') or v12, 'timelineSemaphore')
    if have['index_u8']: f['indexTypeUint8'] = b(st(feats, 'VkPhysicalDeviceIndexTypeUint8FeaturesEXT', 'VkPhysicalDeviceIndexTypeUint8FeaturesKHR', 'VkPhysicalDeviceIndexTypeUint8Features', 'VkPhysicalDeviceVulkan14Features'), 'indexTypeUint8')
    if have['4444']:
        s4 = st(feats, 'VkPhysicalDevice4444FormatsFeaturesEXT')
        f['formatA4B4G4R4'], f['formatA4R4G4B4'] = b(s4, 'formatA4B4G4R4'), b(s4, 'formatA4R4G4B4')
    if have['dcc']: f['depthClipControl'] = b(st(feats, 'VkPhysicalDeviceDepthClipControlFeaturesEXT'), 'depthClipControl')
    if have['placed']:
        sp = st(feats, 'VkPhysicalDeviceMapMemoryPlacedFeaturesEXT')
        for k in ('memoryMapPlaced', 'memoryMapRangePlaced', 'memoryUnmapReserve'): f[k] = b(sp, k)
    if have['border']:
        sb = st(feats, 'VkPhysicalDeviceCustomBorderColorFeaturesEXT')
        for k in ('customBorderColors', 'customBorderColorWithoutFormat'): f[k] = b(sb, k)
    if have['di']:
        sd = st(feats, 'VkPhysicalDeviceDescriptorIndexingFeatures', 'VkPhysicalDeviceDescriptorIndexingFeaturesEXT') or v12
        for k in ('runtimeDescriptorArray', 'descriptorBindingPartiallyBound', 'shaderSampledImageArrayNonUniformIndexing',
                  'shaderStorageImageArrayNonUniformIndexing', 'descriptorBindingVariableDescriptorCount', 'descriptorBindingSampledImageUpdateAfterBind'):
            f[k] = b(sd, k)
    if have['vdiv']:
        sv = st(feats, 'VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT', 'VkPhysicalDeviceVertexAttributeDivisorFeaturesKHR')
        for k in ('vertexAttributeInstanceRateDivisor', 'vertexAttributeInstanceRateZeroDivisor'): f[k] = b(sv, k)
    if have['swm1']: f['swapchainMaintenance1'] = b(st(feats, 'VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT', 'VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR'), 'swapchainMaintenance1')

    limits_kind = lint.names()[0]
    L = P['limits']; limits = {}
    for k, kind in limits_kind.items():
        x = L.get(k)
        if x is None: limits[k] = None; continue
        if isinstance(x, list) and x and isinstance(x[0], str): x = bits(x)          # 采样数位
        if kind == 'F32': x = f32(x)
        elif kind == 'F32x2': x = [f32(y) for y in x]
        elif isinstance(x, bool): x = int(x)
        limits[k] = x

    def u(s, k):
        if s is None or k not in s: return None
        x = s[k]
        return bits(x) if isinstance(x, list) else int(x)

    v11p = st(props, 'VkPhysicalDeviceVulkan11Properties')
    pr = {'deviceType': ENUM['VK_PHYSICAL_DEVICE_TYPE_' + one(rows, 'deviceType', 'Properties')], 'limits': limits}
    if core11:
        m3 = st(props, 'VkPhysicalDeviceMaintenance3Properties', 'VkPhysicalDeviceMaintenance3PropertiesKHR') or v11p
        sg = st(props, 'VkPhysicalDeviceSubgroupProperties') or v11p
        pr['maxMemoryAllocationSize'], pr['maxPerSetDescriptors'] = u(m3, 'maxMemoryAllocationSize'), u(m3, 'maxPerSetDescriptors')
        pr['subgroupSize'] = u(sg, 'subgroupSize')
        pr['subgroupSupportedStages'] = u(sg, 'subgroupSupportedStages' if sg is v11p else 'supportedStages')
        pr['subgroupSupportedOperations'] = u(sg, 'subgroupSupportedOperations' if sg is v11p else 'supportedOperations')
        pr['subgroupQuadOperationsInAllStages'] = u(sg, 'subgroupQuadOperationsInAllStages' if sg is v11p else 'quadOperationsInAllStages')
    if have['border']: pr['maxCustomBorderColorSamplers'] = u(st(props, 'VkPhysicalDeviceCustomBorderColorPropertiesEXT'), 'maxCustomBorderColorSamplers')
    if have['minmax']:
        sm = st(props, 'VkPhysicalDeviceSamplerFilterMinmaxPropertiesEXT', 'VkPhysicalDeviceSamplerFilterMinmaxProperties')
        pr['filterMinmaxSingleComponentFormats'] = u(sm, 'filterMinmaxSingleComponentFormats')
        pr['filterMinmaxImageComponentMapping'] = u(sm, 'filterMinmaxImageComponentMapping')
    if have['vdiv']: pr['maxVertexAttribDivisor'] = u(st(props, 'VkPhysicalDeviceVertexAttributeDivisorPropertiesEXT'), 'maxVertexAttribDivisor')
    if have['host']: pr['minImportedHostPointerAlignment'] = u(st(props, 'VkPhysicalDeviceExternalMemoryHostPropertiesEXT'), 'minImportedHostPointerAlignment')
    if have['placed']: pr['minPlacedMemoryMapAlignment'] = u(st(props, 'VkPhysicalDeviceMapMemoryPlacedPropertiesEXT'), 'minPlacedMemoryMapAlignment')

    formats = {}
    for k in sorted(lint.names()[4]):
        if k == 'VK_FORMAT_A4B4G4R4_UNORM_PACK16' and not have['4444_fmt']: continue   # dev_facts.c 同一条件才查
        fp = next((x.get('VkFormatProperties') for n, x in dev['formats'].items() if ENUM.get(n) == ENUM[k]), None)   # 按枚举值认（报告可能写别名）
        formats[k] = None if fp is None else [bits(fp.get('linearTilingFeatures', [])), bits(fp.get('optimalTilingFeatures', [])),
                                              bits(fp.get('bufferFeatures', []))]

    queues = [{'count': q['VkQueueFamilyProperties']['queueCount'], 'flags': bits(q['VkQueueFamilyProperties']['queueFlags']),
               'timestampValidBits': q['VkQueueFamilyProperties'].get('timestampValidBits')} for q in dev['queueFamiliesProperties']]

    drv = st(props, 'VkPhysicalDeviceDriverProperties', 'VkPhysicalDeviceDriverPropertiesKHR', 'VkPhysicalDeviceVulkan12Properties') if have['driver'] else None
    a, b_, c = (int(x) for x in one(rows, 'driverVersion', 'Properties').split('.'))
    uuid = P.get('pipelineCacheUUID')
    p = {
        'schema': lint.SCHEMA, 'platform': 'android', 'provenance': 'assembled', 'completeness': 'partial',
        'label': '拼装档：%s（%s），vulkan.gpuinfo.org 报告 %d' % (chip, one(rows, 'deviceName', 'Properties'), rid),
        'api': {'kind': 'vulkan', 'version': api_str(api)},
        'identity': {'vendorId': '0x%04x' % int(one(rows, 'vendorID', 'Properties'), 16), 'deviceId': '0x%08x' % int(one(rows, 'deviceID', 'Properties'), 16),
                     'driverId': ENUM[drv['driverID']] if drv and 'driverID' in drv else None,
                     'driverName': drv.get('driverName') if drv else None,
                     'driverVersion': (a << 22) | (b_ << 12) | c, 'deviceName': one(rows, 'deviceName', 'Properties'),
                     'pipelineCacheUUID': bytes(uuid).hex() if uuid else None},
        'model': {'manufacturer': one(rows, 'android.ProductManufacturer', 'Platform details'), 'model': one(rows, 'android.ProductModel', 'Platform details'),
                  'socModel': None, 'androidRelease': None},
        'system': {'sdk': None, 'pageSize': None, 'cpu': {'capacity': None, 'maxKHz': None}, 'kgsl': None, 'adpf': None, 'vsyncApi': None},
        'vulkan': {'extensions': {e: 1 for e in sorted(exts)}, 'features': f, 'properties': pr, 'formats': formats,
                   'memory': memory(rows), 'queues': queues},
    }
    url, purl = GPUINFO % rid, GPUINFO_PROFILE % rid
    p['sources'] = {
        'api.version': '%s（apiVersion）' % url,
        'identity': '%s（Properties：vendorID / deviceID / deviceName / driverVersion，后者按 VK_MAKE_VERSION 由解码值还原；driverProperties；pipelineCacheUUID 取自 %s）' % (url, purl),
        'model': '%s（Platform details：android.ProductManufacturer / ProductModel）' % url,
        'vulkan.extensions': '%s（扩展表）' % purl,
        'vulkan.features': '%s（核心与扩展特性结构；报告里没有的结构写 null）' % purl,
        'vulkan.properties': '%s（VkPhysicalDeviceProperties.limits 与扩展属性；deviceType 取自 %s）' % (purl, url),
        'vulkan.formats': '%s（逐格式 VkFormatProperties；报告没列的格式写 null）' % purl,
        'vulkan.memory': '%s（内存堆与类型；报告页按堆分组，全局类型次序按堆号重建，未必等于设备真实次序）' % url,
        'vulkan.queues': '%s（queueFamiliesProperties）' % purl,
    }
    p['sources'].update(derived)
    p['factsDigest'] = lint.digest(p)
    bad = lint.check(p)
    if bad: sys.exit('【红】%s 不合格：\n  %s' % (name, '\n  '.join(bad)))
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--raw', required=True, help='report-<编号>.html 与 profile-<编号>.json 所在目录')
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    rc = 0
    for name, rid, chip in TARGETS:
        text = lint.dumps_pretty(convert(name, rid, chip, args.raw))
        path = os.path.join(HERE, name + '.json')
        if args.check:
            same = os.path.exists(path) and open(path, encoding='utf-8').read() == text
            print('%s: %s' % ('PASS' if same else '【红】', path)); rc |= not same
        else:
            open(path, 'w', encoding='utf-8').write(text); print('写 %s' % path)
    return rc


if __name__ == '__main__':
    sys.exit(main())
