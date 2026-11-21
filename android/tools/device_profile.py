#!/usr/bin/env python3
"""从安卓设备取出设备档案（s2a-device-profile-v1，#1749 §5.1），白名单校验后写成可入库的形态档。

档案由 App 每次建 Vulkan 设备时写在私有目录 files/devprofile/<事实摘要前 16 位>.json（android/native/direct/dev_facts.c）。
两条取法，产物相同：
  debug 包：   python3 android/tools/device_profile.py --out <目录> [--serial <序列号>] [--package <包名>]
               （adb run-as 读私有目录；包名缺省 org.s2arm.android）
  release 包： 先在游戏库里点「导出诊断包…」（LibraryActivity → DiagnosticExport，包里带 devprofile/<名>.json），再
               python3 android/tools/device_profile.py --out <目录> --bundle <诊断包.zip>
               或 --bundle-on-device <手机上诊断包的路径>（先 adb pull 到临时目录）
取到后过 tools/devprofile_lint.py（白名单外的键 / factsDigest 不符都拒绝、不写），写 <目录>/<名>.json（--name 指定，
缺省 = GPU 名 + 事实摘要前 8 位）。要放进 android/tests/devprofiles/ 当形态档，就把 --out 指过去。
环境变量 ADB 可换 adb 路径（宿主测试用替身）。
"""
import argparse, json, os, re, subprocess, sys, tempfile, zipfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools'))
import devprofile_lint as lint   # noqa: E402

GEN = re.compile(r'[0-9a-f]{16}\.json')


def adb(args, serial):
    cmd = [os.environ.get('ADB', 'adb')] + (['-s', serial] if serial else []) + args
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode: sys.exit('【红】%s 失败（rc=%d）：%s' % (' '.join(cmd), r.returncode, r.stderr.decode('utf-8', 'replace').strip()))
    return r.stdout


def from_debug(serial, package):
    listing = adb(['shell', 'run-as', package, 'ls', '-t', 'files/devprofile'], serial).decode('utf-8', 'replace').split()
    names = [n for n in listing if GEN.fullmatch(n)]   # ls -t：最新在前
    if not names: sys.exit('【红】%s 的 files/devprofile 里没有档案（进一次游戏、建过 Vulkan 设备才会写）' % package)
    return adb(['exec-out', 'run-as', package, 'cat', 'files/devprofile/' + names[0]], serial), names[0]


def from_bundle(path):
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.startswith('devprofile/') and GEN.fullmatch(n[len('devprofile/'):])]
        if not names: sys.exit('【红】诊断包 %s 里没有 devprofile/<名>.json（App 版本不带设备档案，或还没建过 Vulkan 设备）' % path)
        return z.read(names[0]), names[0]


def slug(text): return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-') or 'device'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', required=True)
    ap.add_argument('--serial')
    ap.add_argument('--package', default='org.s2arm.android')
    src = ap.add_mutually_exclusive_group()
    src.add_argument('--bundle')
    src.add_argument('--bundle-on-device')
    ap.add_argument('--name')
    a = ap.parse_args()
    if a.bundle:
        raw, where = from_bundle(a.bundle)
    elif a.bundle_on_device:
        with tempfile.TemporaryDirectory() as tmp:
            local = os.path.join(tmp, 'bundle.zip')
            adb(['pull', a.bundle_on_device, local], a.serial)
            raw, where = from_bundle(local)
    else:
        raw, where = from_debug(a.serial, a.package)
    try:
        profile = json.loads(raw.decode('utf-8'))
    except ValueError as e:
        sys.exit('【红】%s 不是 JSON：%s' % (where, e))
    bad = lint.check(profile)
    if bad:
        for b in bad: print('【红】%s %s' % (where, b))
        sys.exit('【红】档案没过白名单校验，不写')
    name = a.name or '%s-%s' % (slug(profile['identity']['deviceName']), profile['factsDigest'][7:15])
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name): sys.exit('【红】--name 只能用字母、数字、. _ -')
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, name + '.json')
    with open(path, 'w', encoding='utf-8') as f: f.write(lint.dumps_pretty(profile))
    print('PASS: 写 %s（GPU %s，驱动 %s，%s；来源 %s）' % (path, profile['identity']['deviceName'], profile['identity']['driverVersion'],
                                                    profile['factsDigest'][:23], where))
    return 0


if __name__ == '__main__':
    sys.exit(main())
