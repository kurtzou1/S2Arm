#!/usr/bin/env python3
"""Windows 签名装机交给玩家自己装的 Impactor（11-04 维护者：「让玩家自己装 impactor，做好引导和体验」）：启动器与命令行共用的这一层。
我们不自己做签名、不改苹果组件；11-07 起发版启动器随包带官方原版 Impactor + plumesign（BUNDLED，不改不重签），玩家零跳转；源码树 / 命令行仍找玩家自己放的。
这一层：找到 / 核对 Impactor、出包后在资源管理器里选中 ipa、分步引导、把 Impactor 报错翻成共用错误码。

  python -m pack.jobs.impactor status [--online]   装没装、版本对不对（--online 再问 GitHub 最新版）；一行 JSON
  python -m pack.jobs.impactor download             用缺省浏览器打开实测版本的官方发布页
  python -m pack.jobs.impactor reveal <ipa>         资源管理器里选中出好的 ipa（Mac：访达）
  python -m pack.jobs.impactor guide [--ipa <ipa>]  生成并打开分步引导页（pack/jobs/impactor_guide.json → 本机临时 HTML）
  python -m pack.jobs.impactor explain "<报错原文>"  Impactor / 侧载工具报错 → 共用错误码 + 处理办法（pack/jobs/errors.py）

实测口径（11-04 Windows 出包机 + 测试设备2）：Impactor v2.7.2 缺省设置签装，可用内存 8177 MB（保住「提高内存上限」）；同版本经 Wi-Fi 自动续签后仍 8177 MB。"""
import glob, json, os, re, subprocess, sys, tempfile, urllib.request, webbrowser

H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H)
from errors import recovery   # noqa: E402

TESTED = '2.7.2'
RELEASE_PAGE = f'https://github.com/claration/impactor/releases/tag/v{TESTED}'
LATEST_API = 'https://api.github.com/repos/claration/impactor/releases/latest'
PRODUCT = 'plumeimpactor'
# 随 Windows 启动器下发的原版 Impactor 与 plumesign（11-07 维护者：「能不能随咱们安装包下发，而不是让玩家再去跳转一次下载」，取代 11-04「不内置」）：
#   官方发布页原文件、不改不重签，版本钉 TESTED，SHA-256 与 GitHub 发布页 digest 一致（11-07 核）；launchers/windows/bundle_win.py 打包时核哈希、不符拒打。
#   放在启动器目录（作业请求 resources）下 BUNDLE_DIR；许可（MIT + 内嵌 apple-codesign 的 MPL-2.0）与来源说明同目录。升级走我们发版
BUNDLE_DIR = 'ThirdParty/Impactor'
IMPACTOR_EXE = 'Impactor-windows-x86_64-portable.exe'
PLUMESIGN_EXE = 'plumesign-windows-x86_64.exe'
BUNDLED = {IMPACTOR_EXE: 'f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef',
           PLUMESIGN_EXE: 'b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0'}
DOWNLOAD = f'https://github.com/claration/impactor/releases/download/v{TESTED}/'


def bundled(resources):
    """启动器随包的 Impactor / plumesign → {'impactor': 路径, 'plumesign': 路径}；没给启动器目录（源码树开发、命令行）→ None；给了但缺件 → {}（安装包不完整）"""
    if not resources: return None
    d = os.path.join(resources, *BUNDLE_DIR.split('/'))
    got = {k: os.path.join(d, n) for k, n in (('impactor', IMPACTOR_EXE), ('plumesign', PLUMESIGN_EXE))}
    return got if all(os.path.isfile(v) for v in got.values()) else {}


def logged_in(appdata=None):
    """Impactor / plumesign 共用的账号存档（%APPDATA%\\PlumeImpactor\\accounts.json，Impactor 源码 plume_store AccountStore）里有没有 Apple ID"""
    base = appdata or os.environ.get('APPDATA') or os.path.join(os.path.expanduser('~'), '.config')
    try:
        with open(os.path.join(base, 'PlumeImpactor', 'accounts.json'), encoding='utf-8') as f: return bool(json.load(f).get('accounts'))
    except (OSError, ValueError, AttributeError): return False

def _store(appdata=None):
    base = appdata or os.environ.get('APPDATA') or os.path.join(os.path.expanduser('~'), '.config')
    try:
        with open(os.path.join(base, 'PlumeImpactor', 'accounts.json'), encoding='utf-8') as f: store = json.load(f)
        return store if isinstance(store, dict) and isinstance(store.get('accounts') or {}, dict) else {}
    except (OSError, ValueError): return {}


def unselected_accounts(appdata=None):
    """存了 Apple ID、却没有选中的那个（selected_account 空或指向已删的账号）→ 存着的邮箱列表；选中正常 / 没存账号 → []。
    同版 v2.7.2 源码 plume_store AccountStore::accounts_remove：删掉的正是选中的那个时只把 selected_account 置空、不改选别的，
    plumesign 签名就报「No account selected」（D-ZM37）。我们自己的过期处理也教玩家「移除账号再添加」，多账号时就会落到这里"""
    store = _store(appdata)
    accounts = store.get('accounts') or {}
    return [] if not accounts or store.get('selected_account') in accounts else sorted(accounts)


def select_only_account(exe, appdata=None):
    """账号存档里只存了一个 Apple ID 却没选中：用官方 plumesign account switch <邮箱>（同版 v2.7.2 commands/account.rs）替玩家选上，
    不自己改 Impactor 的存档。只有一个 = 没有歧义、选它就是玩家要的；存了多个不替玩家挑（装机前清单与失败原因让玩家在 Impactor 里选）。
    → 选上的邮箱；不需要 / 选不上 → None（照旧往下签，plumesign 失败按原文归码）"""
    left = unselected_accounts(appdata)
    if len(left) != 1 or not exe: return None
    try: subprocess.run([exe, 'account', 'switch', left[0]], capture_output=True, timeout=60, env=dict(os.environ, RUST_LOG='info'))
    except (OSError, subprocess.SubprocessError): return None
    return left[0] if not unselected_accounts(appdata) else None


def selected_team(appdata=None):
    """账号存档里当前选中账号的团队号（accounts.json 的 selected_account → accounts[账号].team_id）；读不到 → None"""
    base = appdata or os.environ.get('APPDATA') or os.path.join(os.path.expanduser('~'), '.config')
    try:
        with open(os.path.join(base, 'PlumeImpactor', 'accounts.json'), encoding='utf-8') as f: store = json.load(f)
        team = (store.get('accounts') or {}).get(store.get('selected_account') or '', {}).get('team_id')
        return team if isinstance(team, str) and re.fullmatch(r'[A-Za-z0-9]{10}', team) else None
    except (OSError, ValueError, AttributeError): return None

# Impactor / 侧载工具界面上的报错原文 → 共用错误码（顺序即优先级；处理办法在 pack/jobs/errors.py RECOVERY）
EXPLAIN = (
    (r'-80046', 'login_identity_rejected'),
    # 连不上签名要用的 anisette 服务器（#3fc02b，Windows 玩家 3 次上传：「Anisette error … dns error … 不知道这样的主机。 (os error 11001)」）：
    #   Impactor v2.7.2 的 omnisette 本机取不到就走远程 v3，地址写死 mac-ani.jkcoxson.com（3rdparty/omnisette/src/lib.rs DEFAULT_ANISETTE_URL_V3）。原先落到 device_install_failed，建议写「检查设备连接」，方向全错
    (r'anisette error[\s\S]{0,600}?(?:dns error|os error 1100[1-4]|client error \(connect\)|error sending request|connection (?:refused|reset)|timed out)', 'signing_server_unreachable'),
    # 保存的 Apple ID 会话过期（Apple 开发者接口 1100「Your session has expired. Please log in.」，plumesign 恢复会话时报，玩家反馈 v0.2.7）：
    #   要在 Impactor 里重新登录；原先落到 device_install_failed，建议写「检查设备连接与包的有效性」，把玩家往错的方向引
    (r'developer api error 1100\b|\b1100\b[^\n]{0,40}session|session has expired|please log ?in again|not logged in', 'apple_session_expired'),
    # 存了账号却没选中（D-ZM37 plumesign 原文「No account selected. Please login first」）：处理办法同过期——在 Impactor 里移除再添加，
    #   添加即选中（v2.7.2 accounts_add 设 selected_account）；只存了一个的在签名前已替玩家选上（select_only_account），到这里的是存了多个
    (r'no account selected', 'apple_session_expired'),
    (r'-2097\d|-20101|incorrect|entered incorrectly', 'apple_id_wrong'),
    (r'-21669|verification code|two.?factor|2fa', 'two_factor_wrong'),
    (r'unknown error occured while reading the file|unknown error occurred while reading the file|zip64', 'ipa_needs_repack'),
    (r'name for this app is invalid', 'ipa_needs_repack'),
    # 免费 Apple ID 两个上限分开报（依据同 pack/jobs/install.py SIGN_ERRORS 注释）：说「App ID」/ 9120 的是 7 天 10 个包名额度，
    #   删 App 不退；说「apps」装满的是设备同时 3 个自签 App，删一个就行。前者先判，后者的「apps」不吃「app id(s)」。
    (r'app id limit|\b10 app ids\b|maximum number of app ids|(?:error|code)\D{0,20}\b9120\b', 'free_appid_limit'),
    (r'maximum number of (installed )?apps\b|\b3 apps\b', 'free_app_limit'),   # 11-06 plumesign 原文是「maximum number of installed apps」
    (r'(?:error|code)\D{0,20}\b9401\b|app id with identifier[^\n]{0,120}is not available', 'app_id_taken'),
    (r'mismatchedapplicationidentifierentitlement|application-identifier entitlement string[^\n]{0,240}does not match', 'app_other_signer'),   # 同 install.SIGN_ERRORS（文本已转小写）
    (r'developer mode', 'developer_mode_required'),
    (r'device is locked|passcode|unlock', 'device_locked'),
    (r'pairing|not paired|invalidhostid|trust', 'device_pairing_required'),
    (r'no device|not connected|usbmux', 'device_not_connected'),
)


def explain(text):
    t = (text or '').lower()
    for pat, code in EXPLAIN:
        if re.search(pat, t): return code
    return 'device_install_failed'


def exe_version(path):
    """→ (产品名, 版本)；读不了 → (None, None)。Windows 读 PE 版本资源；其它平台不读。"""
    if os.name != 'nt' or not os.path.isfile(path): return None, None
    import ctypes
    from ctypes import wintypes as w
    v = ctypes.WinDLL('version')
    n = v.GetFileVersionInfoSizeW(path, None)
    if not n: return None, None
    buf = ctypes.create_string_buffer(n)
    if not v.GetFileVersionInfoW(path, 0, n, buf): return None, None
    p, ln = ctypes.c_void_p(), w.UINT()
    if not v.VerQueryValueW(buf, '\\VarFileInfo\\Translation', ctypes.byref(p), ctypes.byref(ln)) or ln.value < 4: return None, None
    lang, cp = ctypes.cast(p, ctypes.POINTER(ctypes.c_ushort * 2)).contents
    out = {}
    for k in ('ProductName', 'ProductVersion'):
        if v.VerQueryValueW(buf, f'\\StringFileInfo\\{lang:04x}{cp:04x}\\{k}', ctypes.byref(p), ctypes.byref(ln)) and ln.value:
            out[k] = ctypes.wstring_at(p.value, ln.value).rstrip('\0')
    return out.get('ProductName'), out.get('ProductVersion')


def candidates():
    """可能的 Impactor 位置：S2A_IMPACTOR 指定 > 安装版（卸载登记）> 桌面 / 下载里的免安装版"""
    if os.environ.get('S2A_IMPACTOR'): yield os.environ['S2A_IMPACTOR']
    if os.name == 'nt':
        import winreg
        for root, sub in ((winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Uninstall'),
                          (winreg.HKEY_LOCAL_MACHINE, r'Software\Microsoft\Windows\CurrentVersion\Uninstall')):
            try: k = winreg.OpenKey(root, sub)
            except OSError: continue
            for i in range(winreg.QueryInfoKey(k)[0]):
                try:
                    s = winreg.OpenKey(k, winreg.EnumKey(k, i))
                    if 'impactor' not in str(winreg.QueryValueEx(s, 'DisplayName')[0]).lower(): continue
                    for name in ('DisplayIcon', 'InstallLocation'):
                        try:
                            val = str(winreg.QueryValueEx(s, name)[0]).split(',')[0].strip('"')
                            yield from (glob.glob(os.path.join(val, '*.exe')) if os.path.isdir(val) else [val])
                        except OSError: pass
                except OSError: continue
    home = os.path.expanduser('~')
    for d in ('Desktop', 'Downloads', os.path.join('OneDrive', 'Desktop')):
        yield from sorted(glob.glob(os.path.join(home, d, '*mpactor*.exe')), reverse=True)


def status(online=False, resources=None):
    """resources = 启动器目录（发版）：只认随包那份——在 = 实测版本就绪；缺 = 安装包不完整（impactor_missing，给重装，不再给下载页）。
    没给（源码树 / 命令行）：照旧找玩家自己放的 Impactor"""
    b = bundled(resources)
    if b:   # 随包那份不在就接着找玩家自己装的，都认
        return {'tested': TESTED, 'download': None, 'path': b['impactor'], 'version': TESTED, 'bundled': True, 'verdict': 'ok', 'code': None}
    found = None
    for c in candidates():
        name, ver = exe_version(c)
        if name and name.lower() == PRODUCT: found = (c, ver); break
    r = {'tested': TESTED, 'download': RELEASE_PAGE, 'path': None, 'version': None}
    if not found:
        r.update(verdict='missing', code='impactor_missing')
    else:
        r.update(path=found[0], version=found[1])
        r.update(verdict='ok', code=None) if found[1] == TESTED else r.update(verdict='untested', code='impactor_version_untested')
    if online:
        try:
            with urllib.request.urlopen(urllib.request.Request(LATEST_API, headers={'Accept': 'application/vnd.github+json'}), timeout=10) as f:
                r['latest'] = json.load(f).get('tag_name', '').lstrip('v') or None
        except Exception as e:   # 查不到最新版不影响判定（判定只看实测版本）
            r['latest'] = None; r['latest_error'] = type(e).__name__
    if r['code']: r['next'] = recovery(r['code'], packaged=False)   # 不随包：源码树 / 命令行的说法（自己放 Impactor）
    return r


def reveal(ipa):
    ipa = os.path.abspath(ipa)
    if not os.path.isfile(ipa): raise FileNotFoundError(ipa)
    if os.name == 'nt': subprocess.Popen(['explorer', '/select,', ipa])
    elif sys.platform == 'darwin': subprocess.Popen(['open', '-R', ipa])
    else: subprocess.Popen(['xdg-open', os.path.dirname(ipa)])


def guide_html(ipa=None, st=None, lang='zh-Hans'):
    """分步引导页（单文件、无外链脚本）：步骤与文案取 impactor_guide.json，状态行按当前机器填"""
    with open(os.path.join(H, 'impactor_guide.json'), encoding='utf-8') as f: g = json.load(f)
    esc = lambda s: (s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    st = st or status()
    head = {'ok': g['status']['ok'], 'untested': g['status']['untested'], 'missing': g['status']['missing']}[st['verdict']][lang]
    head = head.format(version=st.get('version') or '', tested=TESTED)
    rows = []
    for i, s in enumerate(g['steps'], 1):
        items = ''.join(f'<li>{esc(x)}</li>' for x in s['do'][lang])
        note = f'<p class="note">{esc(s["note"][lang])}</p>' if s.get('note') else ''
        rows.append(f'<section><h2>{i}. {esc(s["title"][lang])}</h2><ol>{items}</ol>{note}</section>')
    errs = ''.join(f'<tr><td><code>{esc(e["match"])}</code></td><td>{esc(e["means"][lang])}</td><td>{esc(recovery(e["code"], packaged=True))}</td></tr>' for e in g['errors'])
    ipa_line = f'<p>本次出好的包：<code>{esc(os.path.abspath(ipa))}</code>（已在资源管理器里选中）</p>' if ipa else ''
    return f'''<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(g["title"][lang])}</title>
<style>:root{{--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--card:#f5f5f7;--acc:#0a66d6;--warn:#b25000}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111;--fg:#f2f2f2;--mut:#a1a1a6;--card:#1c1c1e;--acc:#4ea1ff;--warn:#ffb15c}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,"Microsoft YaHei",sans-serif;max-width:860px;margin:0 auto;padding:16px}}
section{{background:var(--card);border-radius:12px;padding:12px 18px;margin:14px 0}} h2{{font-size:18px;margin:6px 0}}
.st{{padding:10px 14px;border-radius:10px;background:var(--card);border-left:4px solid var(--acc)}} .note{{color:var(--warn)}}
a{{color:var(--acc)}} code{{word-break:break-all}} table{{border-collapse:collapse;width:100%}} td{{border-top:1px solid var(--mut);padding:6px;vertical-align:top}}</style>
<h1>{esc(g["title"][lang])}</h1>
<p class="st">{esc(head)} 官方下载：<a href="{RELEASE_PAGE}">{RELEASE_PAGE}</a></p>{ipa_line}
{''.join(rows)}
<section><h2>{esc(g["errors_title"][lang])}</h2><table>{errs}</table></section></html>'''


def main(a):
    if not a or a[0] not in ('status', 'download', 'reveal', 'guide', 'explain'): print(__doc__, file=sys.stderr); return 2
    if a[0] == 'status': print(json.dumps(status('--online' in a), ensure_ascii=False)); return 0
    if a[0] == 'download': webbrowser.open(RELEASE_PAGE); return 0
    if a[0] == 'reveal' and len(a) == 2: reveal(a[1]); return 0
    if a[0] == 'explain' and len(a) == 2:
        c = explain(a[1]); print(json.dumps({'code': c, 'next': recovery(c, packaged=True)}, ensure_ascii=False)); return 0
    if a[0] == 'guide':
        ipa = a[a.index('--ipa') + 1] if '--ipa' in a else None
        if ipa: reveal(ipa)
        out = os.path.join(tempfile.gettempdir(), 's2a_impactor_guide.html')
        with open(out, 'w', encoding='utf-8') as f: f.write(guide_html(ipa))
        webbrowser.open('file:///' + out.replace('\\', '/')); print(out); return 0
    print(__doc__, file=sys.stderr); return 2


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main(sys.argv[1:]))
