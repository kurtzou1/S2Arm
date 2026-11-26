#!/usr/bin/env python3
"""测试包本机开发签名（底本旧库 tools/dev_sign.py；10-19 出包线，维护者定：测试装包不走 xcodebuild 导出 Ad Hoc，那一步 64 秒）：
dev_sign.py <NxIOS.app> <包名> <团队号> <基础权限 Gen/NxIOS.entitlements> [--extension]
  --extension：签的是 App 扩展（主屏小组件 PlugIns/*.appex，11-16）：只带它自己的权限（共享组），不核「提高内存上限」（那是主程序的）；主程序随后另签。
① 挑描述文件：~/Library/MobileDevice/Provisioning Profiles 与 Xcode UserData 里 application-identifier = <团队号>.<包名>、带 ProvisionedDevices、get-task-allow 真（开发描述文件），
   逐项核过（没过期、平台、含 S2A_PROFILE_NEED_UDIDS 的设备、本机有签名身份、权限都允许）的里面取到期最晚的；
② 挑签名身份：本机 codesigning 身份里，证书（DER 的 SHA-1）在该描述文件 DeveloperCertificates 中的；
③ 权限 = 基础权限 + application-identifier / team-identifier / get-task-allow，且每项必须被描述文件允许（否则装不上）；
④ 嵌入 embedded.mobileprovision → 先签内嵌 *.dylib / *.framework → 再带权限签 App → 核「提高内存上限」在签名里。
找不到合适的描述文件或身份、描述文件缺 S2A_PROFILE_NEED_UDIDS 里的测试设备，退出码 3（调用方退回 Xcode 导出）；本机描述文件解不出（安全服务不可用）退出码 4（调用方不申请、照报）；其余失败退出码 1。"""
import datetime, glob, hashlib, os, plistlib, shutil, subprocess, sys, tempfile
# 只签一个程序 dylib（通用壳程序包，pack/jobs/program_pack.py mac_signer，11-16）：dev_sign.py --dylib <文件> <包名> <团队>
#   挑描述文件与身份同签 App（这台手机上装的 S2Arm 用的那一个，库校验要同团队），只签这个文件、不嵌描述文件、不核权限；末行打印完整身份 SHA-1
# 只核不签（11-26 #1758 / D-2KTD）：dev_sign.py --check <包名> <团队>：挑描述文件同 --dylib（这个包名、平台、没过期、一天内不到期、本机有身份），
#   挑得出退 0、挑不出退 3，什么都不签。Apple TV 推游戏前问「电视上的壳还新不新」用它：壳签名还新、可签程序的描述文件已经一天内到期时，原先跳过重签重装、
#   签程序包时才退 3，推不进去
CHECK = sys.argv[1:2] == ['--check']
DYLIB = sys.argv[1:2] == ['--dylib'] or CHECK
if CHECK: (bid, team), app, base, dylib = sys.argv[2:4], None, None, None
elif DYLIB: (dylib, bid, team), app, base = sys.argv[2:5], None, None
else: app, bid, team, base = sys.argv[1:5]
EXTENSION = '--extension' in sys.argv[5:]
NEED = ['com.apple.developer.kernel.increased-memory-limit']   # 10-19 维护者定案（docs/研究/免费账号.md）：只带这一项就有整块 64 GB 窗口 + 6144 MB 内存上限；扩展寻址多余且免费账号签不了
# 平台（11-15 tvOS 版）：S2A_SIGN_PLATFORM=tvos（pack/jobs/tvos.py 传）或 App 的 CFBundleSupportedPlatforms 写着 AppleTVOS → 只挑 tvOS 的开发描述文件
#   （同一包名可能还有 iOS 的那份）。权限按款（pack/jobs/tvos.py entitlements_for）：「提高内存上限」照带，描述文件不允许就不带
#   （免费账号在 tvOS 上本来就会被系统丢掉，TVPort tvport/README.md「Memory」；游戏靠客体内存文件后备压在上限下），不挡签名；
#   「扩展虚拟寻址」只有 Switch 2 款带，带了就必须被描述文件允许、签进去（只有付费账号的描述文件有），缺了照实报
IML, EVA = 'com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'
try: _plats = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb')).get('CFBundleSupportedPlatforms') or [] if app else []
except Exception: _plats = []
TVOS = os.environ.get('S2A_SIGN_PLATFORM') == 'tvos' or 'AppleTVOS' in _plats
def cms(f):
    r = subprocess.run(['security', 'cms', '-D', '-i', f], capture_output=True)
    try: return plistlib.loads(r.stdout)
    except Exception: return None
# 挑描述文件（11-17 #1447 / #1448：0.5.2 起装机先用本机已有的，原先只取到期最晚的那份、再只核它缺不缺设备——到期最晚的不一定能用，
#   签得出来、手机报 0xe8008015「A valid provisioning profile for this executable was not found」）：本机每一份同包名的开发描述文件都逐项核，
#   全过的里面取到期最晚的；一项不过就不算这份（不是整个退 3），都不过才退 3 让调用方重申。逐项 = 没过期 / 一天内不到期、平台对（iOS / tvOS）、
#   含 S2A_PROFILE_NEED_UDIDS 里的设备、本机钥匙串有它 DeveloperCertificates 里的签名身份、要签的每项权限都被它允许
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
need_udids = set(os.environ.get('S2A_PROFILE_NEED_UDIDS', '').split())
ids = [l.split()[1] for l in subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout.split('\n') if len(l.split()) > 1 and len(l.split()[1]) == 40]
_base = []
def base_ents():
    """要签的基础权限（第一次用到才读：设备 / 身份不过的描述文件用不着它）"""
    if not _base:
        b = plistlib.load(open(base, 'rb'))
        b.update({'application-identifier': f'{team}.{bid}', 'com.apple.developer.team-identifier': team, 'get-task-allow': True})
        _base.append(b)
    return _base[0]
def entitlements_for(prof):
    """这份描述文件下要签的权限（tvOS：描述文件不允许「提高内存上限」就不带，见文件头）→ (权限, 不允许的项)"""
    ents = dict(base_ents())
    if TVOS and IML in ents and IML not in prof['Entitlements']: ents.pop(IML)
    return ents, [k for k in ents if k not in prof['Entitlements']]
best, unread, why = None, [], []
for f in glob.glob(os.path.join(glob.escape(os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles')), '*.mobileprovision')) + glob.glob(os.path.join(glob.escape(os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles')), '*.mobileprovision')):
    p = cms(f)
    if not p: unread.append(os.path.basename(f)); continue
    e = p.get('Entitlements', {})
    if e.get('application-identifier') != f'{team}.{bid}' or not p.get('ProvisionedDevices') or e.get('get-task-allow') is not True: continue
    name, plat = os.path.basename(f), p.get('Platform') or []
    if TVOS and 'tvOS' not in plat: continue
    if not TVOS and plat and 'iOS' not in plat: why.append(f'{name} 不是 iOS 的'); continue
    if p['ExpirationDate'] <= now + datetime.timedelta(days=1): why.append(f'{name} 已过期或一天内到期'); continue
    miss = sorted(need_udids - set(p['ProvisionedDevices']))
    if miss: why.append(f'{name} 不含测试设备 {" ".join(miss)}'); continue
    certs = {hashlib.sha1(c).hexdigest().upper() for c in p.get('DeveloperCertificates', [])}
    ident = next((i for i in ids if i in certs), None)
    if not ident: why.append(f'{name} 里的开发证书本机钥匙串没有'); continue
    if not DYLIB:
        ents, bad = entitlements_for(p)
        if bad: why.append(f'{name} 不允许权限 {bad}'); continue
    if best is None or p['ExpirationDate'] > best[1]['ExpirationDate']: best = (f, p, ident)
# 解不出的描述文件不等于没有（10-30 出包线：凌晨内存耗尽、trustd 等安全服务被 Jetsam 杀，security cms 全解不出，这里报「没有」，
#   调用方去申请新描述文件、原因空白，真因被盖住）：一个都没挑中且有解不出的 → 退出码 4、点名，调用方不申请、照原样报红
if not best and unread:
    print(f'【红】读不出本机描述文件 {len(unread)} 个（security cms -D 失败，系统安全服务 trustd / securityd 不可用或内存耗尽被杀？如 {unread[0]}）：不当作「没有描述文件」'); sys.exit(4)
if not best: print(f'没有能用的 {team}.{bid} 开发描述文件' + (f'（{"；".join(why[:4])}）' if why else '')); sys.exit(3)
pf, prof, ident = best
if CHECK: print(f'能用：{os.path.basename(pf)}（到期 {prof["ExpirationDate"]:%Y-%m-%d}）'); sys.exit(0)
if os.environ.get('S2A_DEV_SIGN_PICKED'):   # 调用方（install.sign_and_install）记下这次用了哪份：手机仍拒（0xe8008015）就把它挪开再重申
    with open(os.environ['S2A_DEV_SIGN_PICKED'], 'a', encoding='utf-8') as pk: pk.write(pf + '\n')
if DYLIB:
    r = subprocess.run(['codesign', '--force', '--sign', ident, '--timestamp=none', dylib], capture_output=True, text=True)
    if r.returncode: print(f'签名失败 {dylib}：{r.stderr.strip()[:300]}'); sys.exit(1)
    print(f'程序库签名：{os.path.basename(dylib)}，描述文件 {os.path.basename(pf)}，身份 {ident}'); sys.exit(0)
ents, _ = entitlements_for(prof)
if TVOS:
    NEED = [EVA] if EVA in ents else []
    if IML in base_ents() and IML not in ents: print('描述文件没有「提高内存上限」（免费账号常见）：tvOS 上照签不带这项，游戏靠客体内存文件后备压在单进程上限下')
shutil.copyfile(pf, os.path.join(app, 'embedded.mobileprovision'))
tf = tempfile.NamedTemporaryFile(suffix='.plist', delete=False); plistlib.dump(ents, tf); tf.close()
def sign(path, extra=()):
    r = subprocess.run(['codesign', '--force', '--sign', ident, '--timestamp=none', *extra, path], capture_output=True, text=True)
    if r.returncode: print(f'签名失败 {path}：{r.stderr.strip()[:300]}'); sys.exit(1)
# 已先签好的扩展（PlugIns/ 下）里的库不再动：重签会破坏扩展的封印，主程序签名随之报 nested code 无效
plugins = os.path.join(app, 'PlugIns') + os.sep
nested = sorted({p for p in glob.glob(os.path.join(glob.escape(app), '**', '*.dylib'), recursive=True)} | {p for p in glob.glob(os.path.join(glob.escape(app), '**', '*.framework'), recursive=True)}, key=len, reverse=True)
nested = [p for p in nested if EXTENSION or not p.startswith(plugins)]
for p in nested: sign(p)
sign(app, ('--entitlements', tf.name)); os.unlink(tf.name)
got = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', app], capture_output=True).stdout
miss = [] if EXTENSION else [k for k in NEED if k.encode() not in got]
if miss and TVOS: print(f'签名里没有 tvOS 版要的权限（{", ".join(miss)}）：Switch 2 款要「扩展虚拟寻址」，只有付费开发者账号的描述文件允许'); sys.exit(1)
if miss: print(f'签名里没有「提高内存上限」权限（{", ".join(miss)}）'); sys.exit(1)   # 与 adhoc_sign.sh、iml_check.py 同一句
print(f'开发签名：{os.path.basename(pf)}（{prof.get("Name")}，{len(prof["ProvisionedDevices"])} 台设备，到期 {prof["ExpirationDate"]:%Y-%m-%d}），身份 {ident[:8]}…，内嵌 {len(nested)} 个库')
