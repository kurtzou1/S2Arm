#!/usr/bin/env python3
# 辅助脚本：设备档案（s2a-device-profile-v1，#1749 §5.1）白名单校验；android/tests/devprofiles/lint_test.sh 测它、android/tools/device_profile.py 导出时调它
"""设备档案 s2a-device-profile-v1 的白名单校验 + factsDigest 复算。

用法：python3 tools/devprofile_lint.py 档案.json…   退出 0 = 全过；1 = 有档案不合格（逐条【红】点名）

规则：
  - 字段白名单（#1749 §5.1）：白名单外的键一律拒绝（隐私：序列号 / IMEI / 账号 / ro.serialno / 完整 ro.build.fingerprint /
    安装路径 / 游戏与存档信息都没有对应的键，塞进来就红）。叶子值类型逐个核。
  - 限值 / 核心特性 / 扩展特性 / 扩展属性 / 格式的名字表不在这里另抄：从 android/native/direct/dev_facts.c 的表里读（档案的写入方是它）。
  - null = 来源没有这项读数（只在由旧数据转换来的档案里出现；设备上导出的档案只有系统段读不到的项是 null）。
  - 元数据（不是事实）：provenance = probed（App 在设备上现查）| assembled（手工按资料拼的）；completeness = complete | partial（有 null / 未知项）。
    assembled 档案必须带 sources：{字段路径: 出处}（gpuinfo 报告编号 / 规范章节 / 文档链接），凡值不是「不支持」（0 / null / 空）的叶子，
    它自己或某个上级路径（如 vulkan.properties.limits）在 sources 里要有出处，缺了红；sources 的键必须指向档案里真有的字段。probed 档案不许带 sources。
  - factsDigest = sha256(规范串)，规范串 = 去掉 factsDigest、label 与元数据 provenance / completeness / sources 后
    json.dumps(sort_keys=True, separators=(',', ':'), ensure_ascii=False)，整值浮点写成整数。dev_facts.c 按同一写法逐字节输出。
"""
import hashlib, json, os, re, sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
FACTS_C = os.path.join(REPO, 'android', 'native', 'direct', 'dev_facts.c')
SCHEMA = 's2a-device-profile-v1'


def _block(src, macro):
    """取 `#define 宏(X) \\` 起、以 \\ 续行的宏体。"""
    lines = src.splitlines()
    for i, l in enumerate(lines):
        if re.match(r'#define %s\([A-Z]\) \\$' % macro, l):
            out = []
            for l2 in lines[i + 1:]:
                out.append(l2)
                if not l2.rstrip().endswith('\\'): break
            return '\n'.join(out)
    sys.exit('【红】devprofile_lint：dev_facts.c 里找不到 %s 表' % macro)


def names():
    """dev_facts.c 的名字表：limits {名: 类型}、核心特性、扩展特性、扩展属性、格式名。"""
    src = open(FACTS_C, encoding='utf-8').read()
    limits = dict((n, k) for k, n in re.findall(r'L\((U32|I32|U64|F32|U32x2|U32x3|F32x2), (\w+)\)', _block(src, 'S2A_FACT_LIMITS')))
    core = re.findall(r'F\((\w+)\)', _block(src, 'S2A_FACT_FEATURES'))
    ext_feat = re.findall(r'\bB\("(\w+)"', src)
    props = set(re.findall(r'kv_add\(t, &n, "(\w+)"', src[src.index('jw_key(w, &first, "properties")'):])) - {'limits'}
    formats = re.findall(r'V\((VK_FORMAT_\w+)\)', _block(src, 'S2A_FACT_FORMATS'))
    if len(limits) != 106 or len(core) != 55 or not ext_feat or not props or not formats:
        sys.exit('【红】devprofile_lint：dev_facts.c 的表解析不完整（限值 %d / 核心特性 %d / 扩展特性 %d / 扩展属性 %d / 格式 %d）'
                 % (len(limits), len(core), len(ext_feat), len(props), len(formats)))
    return limits, set(core), set(ext_feat), props, set(formats)


def _norm(v):
    if isinstance(v, float) and v.is_integer() and abs(v) < 2 ** 53: return int(v)
    if isinstance(v, dict): return {k: _norm(x) for k, x in v.items()}
    if isinstance(v, list): return [_norm(x) for x in v]
    return v


META = ('factsDigest', 'label', 'provenance', 'completeness', 'sources')   # 不进摘要（dev_facts.c 同口径）
SOURCED = ('api', 'identity', 'model', 'system', 'vulkan', 'probes', 'bench')   # assembled 档案要出处的段（api.kind 除外）


def _leaves(v, path):
    if isinstance(v, dict) and v:
        for k in v: yield from _leaves(v[k], path + '.' + k)
    elif isinstance(v, list) and v and any(isinstance(x, (dict, list)) for x in v):
        for i, x in enumerate(v): yield from _leaves(x, '%s[%d]' % (path, i))
    else:
        yield path, v


def _unsupported(v):   # 「不支持」：0 / null / 空串 / 空表；有出处要求的是其余的值
    return v is None or v == 0 or v == '' or v == [] or v == {} or (isinstance(v, list) and all(x == 0 for x in v))


def canonical(profile):
    body = {k: v for k, v in profile.items() if k not in META}
    return json.dumps(_norm(body), sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def digest(profile):
    return 'sha256-' + hashlib.sha256(canonical(profile)).hexdigest()


def dumps_pretty(profile):
    """入库 / 导出用的可读写法：对象一键一行、键字典序，标量数组与小对象写在一行；摘要与写法无关。"""
    def one(v): return json.dumps(v, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    def flat(v): return not isinstance(v, (dict, list)) or (isinstance(v, list) and all(not isinstance(x, (dict, list)) for x in v)) \
        or (isinstance(v, dict) and len(v) <= 4 and all(not isinstance(x, (dict, list)) for x in v.values()))
    def go(v, ind):
        if flat(v): return one(v)
        pad = ' ' * (ind + 1)
        if isinstance(v, list): return '[\n' + ',\n'.join(pad + go(x, ind + 1) for x in v) + '\n' + ' ' * ind + ']'
        return '{\n' + ',\n'.join(pad + json.dumps(k, ensure_ascii=False) + ': ' + go(v[k], ind + 1) for k in sorted(v)) + '\n' + ' ' * ind + '}'
    return go(_norm(profile), 0) + '\n'


class Lint:
    def __init__(self):
        self.limits, self.core, self.ext_feat, self.props, self.formats = names()
        self.bad = []

    def red(self, path, msg): self.bad.append('%s：%s' % (path, msg))

    def keys(self, obj, path, required, optional=()):
        if not isinstance(obj, dict): self.red(path, '应为对象，实为 %s' % type(obj).__name__); return False
        for k in obj:
            if k not in required and k not in optional: self.red(path + '.' + k, '白名单外的键（拒绝）')
        for k in required:
            if k not in obj: self.red(path + '.' + k, '缺必填键')
        return True

    def int_(self, v, path, null=True, lo=None, hi=None, choices=None):
        if v is None and null: return
        if isinstance(v, bool) or not isinstance(v, int): self.red(path, '应为整数%s，实为 %r' % ('或 null' if null else '', v)); return
        if lo is not None and v < lo or hi is not None and v > hi: self.red(path, '越界 %r（%s..%s）' % (v, lo, hi))
        if choices is not None and v not in choices: self.red(path, '取值 %r 不在 %r 里' % (v, choices))

    def num(self, v, path):
        if v is None: return
        if isinstance(v, bool) or not isinstance(v, (int, float)): self.red(path, '应为数，实为 %r' % (v,))

    def str_(self, v, path, null=True, pattern=None, maxlen=256):
        if v is None and null: return
        if not isinstance(v, str): self.red(path, '应为字符串%s，实为 %r' % ('或 null' if null else '', v)); return
        if len(v) > maxlen: self.red(path, '过长（%d 字符）' % len(v))
        if pattern and not re.fullmatch(pattern, v): self.red(path, '格式不对：%r' % v)

    def run(self, p):
        self.keys(p, '$', ('schema', 'platform', 'api', 'identity', 'model', 'system', 'vulkan', 'factsDigest', 'provenance', 'completeness'),
                  ('label', 'probes', 'bench', 'sources'))
        self.str_(p.get('provenance'), '$.provenance', null=False, pattern='probed|assembled')
        self.str_(p.get('completeness'), '$.completeness', null=False, pattern='complete|partial')
        if p.get('schema') != SCHEMA: self.red('$.schema', '应为 %s' % SCHEMA)
        self.str_(p.get('platform'), '$.platform', null=False, pattern='android|ohos')
        if self.keys(p.get('api'), '$.api', ('kind', 'version')):
            if p['api'].get('kind') != 'vulkan': self.red('$.api.kind', '应为 vulkan')
            self.str_(p['api'].get('version'), '$.api.version', null=False, pattern=r'\d+\.\d+\.\d+')
        i = p.get('identity')
        if self.keys(i, '$.identity', ('vendorId', 'deviceId', 'driverId', 'driverVersion', 'driverName', 'deviceName', 'pipelineCacheUUID')):
            self.str_(i.get('vendorId'), '$.identity.vendorId', null=False, pattern='0x[0-9a-f]{4,8}')
            self.str_(i.get('deviceId'), '$.identity.deviceId', null=False, pattern='0x[0-9a-f]{8}')
            self.int_(i.get('driverId'), '$.identity.driverId', lo=0)
            self.int_(i.get('driverVersion'), '$.identity.driverVersion', null=False, lo=0, hi=2 ** 32 - 1)
            self.str_(i.get('driverName'), '$.identity.driverName')
            self.str_(i.get('deviceName'), '$.identity.deviceName', null=False)
            self.str_(i.get('pipelineCacheUUID'), '$.identity.pipelineCacheUUID', pattern='[0-9a-f]{32}')
        m = p.get('model')
        if self.keys(m, '$.model', ('manufacturer', 'model', 'socModel', 'androidRelease')):
            for k in m: self.str_(m[k], '$.model.' + k, maxlen=96)
        s = p.get('system')
        if self.keys(s, '$.system', ('sdk', 'pageSize', 'cpu', 'kgsl', 'adpf', 'vsyncApi'), ('powerRails',)):
            self.int_(s.get('sdk'), '$.system.sdk', lo=1)
            self.int_(s.get('pageSize'), '$.system.pageSize', lo=1)
            self.int_(s.get('kgsl'), '$.system.kgsl', choices=(-1, 0, 1))
            self.int_(s.get('adpf'), '$.system.adpf', choices=(0, 1))
            self.int_(s.get('vsyncApi'), '$.system.vsyncApi', choices=(0, 24, 29, 33))
            if 'powerRails' in s: self.int_(s['powerRails'], '$.system.powerRails', choices=(0, 1))
            c = s.get('cpu')
            if self.keys(c, '$.system.cpu', ('capacity', 'maxKHz')):
                for k in ('capacity', 'maxKHz'):
                    v = c.get(k)
                    if v is None: continue
                    if not isinstance(v, list) or len(v) > 64: self.red('$.system.cpu.' + k, '应为至多 64 项的数组或 null'); continue
                    for n, x in enumerate(v): self.int_(x, '$.system.cpu.%s[%d]' % (k, n), null=False, lo=0)
                if isinstance(c.get('capacity'), list) and isinstance(c.get('maxKHz'), list) and len(c['capacity']) != len(c['maxKHz']):
                    self.red('$.system.cpu', 'capacity 与 maxKHz 项数不同')
        self.vulkan(p.get('vulkan'))
        if 'label' in p: self.str_(p['label'], '$.label', null=False, maxlen=200)
        if 'probes' in p: self.probes(p['probes'])
        if 'bench' in p: self.bench(p['bench'])
        self.sources(p)
        self.str_(p.get('factsDigest'), '$.factsDigest', null=False, pattern='sha256-[0-9a-f]{64}')
        if isinstance(p.get('factsDigest'), str) and not self.bad:
            want = digest(p)
            if p['factsDigest'] != want: self.red('$.factsDigest', '与内容不符（复算 %s）' % want)

    def vulkan(self, v):
        if not self.keys(v, '$.vulkan', ('extensions', 'features', 'properties', 'formats', 'memory', 'queues'), ('extensionsWhy', 'timeDomains')): return
        e = v.get('extensions')
        if isinstance(e, dict):
            for k, x in e.items():
                self.str_(k, '$.vulkan.extensions 的键', null=False, pattern=r'VK_[A-Za-z0-9_]+', maxlen=255)
                self.int_(x, '$.vulkan.extensions.' + k, null=False, choices=(-1, 0, 1))
        else: self.red('$.vulkan.extensions', '应为对象')
        if 'extensionsWhy' in v: self.str_(v['extensionsWhy'], '$.vulkan.extensionsWhy', null=False)
        f = v.get('features')
        if self.keys(f, '$.vulkan.features', sorted(self.core), sorted(self.ext_feat)):
            for k, x in f.items(): self.int_(x, '$.vulkan.features.' + k, choices=(0, 1))
        pr = v.get('properties')
        if self.keys(pr, '$.vulkan.properties', ('limits', 'deviceType'), sorted(self.props - {'deviceType'})):
            for k, x in pr.items():
                if k != 'limits': self.int_(x, '$.vulkan.properties.' + k, lo=0)
            L = pr.get('limits')
            if self.keys(L, '$.vulkan.properties.limits', sorted(self.limits)):
                for k, x in L.items():
                    kind = self.limits.get(k, '')
                    path = '$.vulkan.properties.limits.' + k
                    if 'x' in kind:
                        n = int(kind[-1])
                        if x is not None and (not isinstance(x, list) or len(x) != n): self.red(path, '应为 %d 项数组' % n); continue
                        for j, y in enumerate(x or []): (self.num if kind.startswith('F') else self.int_)(y, '%s[%d]' % (path, j))
                    elif kind == 'F32': self.num(x, path)
                    elif kind: self.int_(x, path, lo=None if kind == 'I32' else 0)
        fm = v.get('formats')
        if self.keys(fm, '$.vulkan.formats', (), sorted(self.formats)):
            for k, x in fm.items():
                if x is None: continue
                if not isinstance(x, list) or len(x) != 3: self.red('$.vulkan.formats.' + k, '应为 [linear, optimal, buffer]'); continue
                for j, y in enumerate(x): self.int_(y, '$.vulkan.formats.%s[%d]' % (k, j), null=False, lo=0, hi=2 ** 32 - 1)
        mem = v.get('memory')
        if self.keys(mem, '$.vulkan.memory', ('heaps', 'types')):
            for sect, fields in (('heaps', ('flags', 'size')), ('types', ('flags', 'heap'))):
                arr = mem.get(sect)
                if not isinstance(arr, list) or len(arr) > 32: self.red('$.vulkan.memory.' + sect, '应为至多 32 项的数组'); continue
                for n, h in enumerate(arr):
                    if self.keys(h, '$.vulkan.memory.%s[%d]' % (sect, n), fields):
                        for k in fields: self.int_(h.get(k), '$.vulkan.memory.%s[%d].%s' % (sect, n, k), null=False, lo=0)
        q = v.get('queues')
        if not isinstance(q, list) or len(q) > 16: self.red('$.vulkan.queues', '应为至多 16 项的数组')
        else:
            for n, x in enumerate(q):
                if self.keys(x, '$.vulkan.queues[%d]' % n, ('count', 'flags', 'timestampValidBits')):
                    self.int_(x.get('count'), '$.vulkan.queues[%d].count' % n, null=False, lo=0)
                    self.int_(x.get('flags'), '$.vulkan.queues[%d].flags' % n, null=False, lo=0)
                    self.int_(x.get('timestampValidBits'), '$.vulkan.queues[%d].timestampValidBits' % n, lo=0, hi=64)
        if 'timeDomains' in v:
            if not isinstance(v['timeDomains'], list): self.red('$.vulkan.timeDomains', '应为数组')
            else:
                for n, x in enumerate(v['timeDomains']): self.int_(x, '$.vulkan.timeDomains[%d]' % n, null=False, lo=0)

    def sources(self, p):
        prov, src = p.get('provenance'), p.get('sources')
        if prov == 'probed':
            if 'sources' in p: self.red('$.sources', 'probed 档案不许带 sources（现查的就是出处）')
            return
        if prov != 'assembled': return
        if not isinstance(src, dict) or not src: self.red('$.sources', 'assembled 档案必须带 sources（字段路径 → 出处）'); return
        leaves = [(k, v) for sect in SOURCED if sect in p for k, v in _leaves(p[sect], sect) if k != 'api.kind']
        paths = {k for k, _ in leaves}
        for k, v in src.items():
            self.str_(v, '$.sources.' + k, null=False, maxlen=300)
            if isinstance(v, str) and not v.strip(): self.red('$.sources.' + k, '出处是空的')
            if not any(x == k or x.startswith(k + '.') or x.startswith(k + '[') for x in paths):
                self.red('$.sources.' + k, '出处指向档案里没有的字段')
        for k, v in leaves:
            if _unsupported(v): continue
            if not any(k == s or k.startswith(s + '.') or k.startswith(s + '[') for s in src):
                self.red('$.' + k, '值 %r 不是「不支持」，assembled 档案里缺出处（sources 里写它或上级路径）' % (v,))

    # §5.1 的 F1 / F2 段（M0b 起才写；这里先按稿里的形状收紧，免得成为塞任意键的口子）
    def probes(self, pr):
        if not self.keys(pr, '$.probes', (), ('gs_occlusion', 'fb_compression')): return
        if 'gs_occlusion' in pr: self.str_(pr['gs_occlusion'], '$.probes.gs_occlusion', null=False, pattern='[a-z-]+', maxlen=32)
        fb = pr.get('fb_compression', {})
        if not isinstance(fb, dict): self.red('$.probes.fb_compression', '应为对象'); return
        for fmt, modes in fb.items():
            self.str_(fmt, '$.probes.fb_compression 的键', null=False, pattern='[A-Z0-9_]+', maxlen=64)
            if self.keys(modes, '$.probes.fb_compression.' + fmt, (), ('plain', 'mutable', 'fmt_list')):
                for k, x in modes.items(): self.str_(x, '$.probes.fb_compression.%s.%s' % (fmt, k), null=False, pattern='[a-z_-]+', maxlen=32)

    def bench(self, b):
        if not isinstance(b, dict): self.red('$.bench', '应为对象'); return
        for arm, r in b.items():
            self.str_(arm, '$.bench 的键', null=False, pattern='[a-z_]+', maxlen=32)
            if not self.keys(r, '$.bench.' + arm, (), ('a_us', 'b_us', 'aa_noise', 'gain', 'thermal', 'confidence')): continue
            for k in ('a_us', 'b_us'):
                if k in r:
                    if not isinstance(r[k], list) or len(r[k]) > 64: self.red('$.bench.%s.%s' % (arm, k), '应为至多 64 项的数组'); continue
                    for n, x in enumerate(r[k]): self.num(x, '$.bench.%s.%s[%d]' % (arm, k, n))
            for k in ('aa_noise', 'gain'):
                if k in r: self.num(r[k], '$.bench.%s.%s' % (arm, k))
            for k in ('thermal', 'confidence'):
                if k in r: self.str_(r[k], '$.bench.%s.%s' % (arm, k), null=False, pattern='[a-z]+', maxlen=16)


def check(profile):
    """返回红因列表（空 = 合格）。"""
    l = Lint()
    l.run(profile)
    return l.bad


def main(argv):
    if not argv: sys.exit(__doc__)
    bad_files = 0
    for path in argv:
        try:
            p = json.load(open(path, encoding='utf-8'))
        except (OSError, ValueError) as e:
            print('【红】%s：读不了 / 不是 JSON（%s）' % (path, e)); bad_files += 1; continue
        bad = check(p)
        if bad:
            bad_files += 1
            for b in bad: print('【红】%s %s' % (path, b))
        else:
            print('PASS: %s（%s，%s）' % (path, p['identity']['deviceName'], p['factsDigest'][:23]))
    return 1 if bad_files else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
