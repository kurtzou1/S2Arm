"""社区资源：宽屏 / 60 帧是我方能力，在宿主层运行时开关（缺省开、可关，下次启动生效）；
社区补丁（11-12 维护者：出包时自动对接公开库，查到的全部进包、缺省关、玩家自己开；10-30「玩家包不带上游补丁字节」作废）按这款包里的 cpatch.tsv 逐条列出（packed_patches）。
面板显示这款有没有宽屏表 / 60 帧表、来自哪（已验证名单 / 社区包；版本对不上的由直连线打包时跨版本定位，不判不可用），
画面类（other-gfx）逐项开关，着色器缓存命中就自动并入（只显示并入数，导入入口留给玩家导自己的缓存）。

数据来源（只读，读不到就当没有，不报错）：
  宽屏已验证：引擎 graphics/widen/tables/verified.tsv（程序号 + main 构建号）
  社区包：S2A_COMMUNITY_DIR（没设 = 没有社区包；11-07 起不再缺省读开发机数据盘，启动器进程也不读 tools/machine.local）下 */full/*/INDEX.tsv（第一轮）与 */*/INDEX.tsv（第二轮，按类分目录），-lite 子集包不收——有 aspect 列的是宽屏包，有 target_fps 列的是帧率包
  社区补丁：这款 Mac 包的 cpatch.tsv（出包时 pack/jobs/patches.py 查库、pack/cpatch.py 编进包）
玩家的选择（启动设置，11-09）存在这款游戏文件夹的 launch.json：{"schema":1,"settings":{设置项:值},"patches":{画面编号:真/假}}，
  设置项的定义（id、类型、取值、缺省、平台）只在 launchers/shared/game_settings.v1.json，Mac 启动设置页与 iOS 游戏内菜单共用；
  只存玩家明确选过的，没选的按定义表缺省（"caps" = 按这款能力清单；60 帧是清单值 1 且原因属于速度已验证正确的来源才算开，同宿主 runtime/src/caps.c）。Mac 启动时由 build.launch 经 launch_env 转成宿主环境变量。
  旧的 community.json（schema 2 / 3）第一次读时转成 launch.json 并删掉，不留两份。"""
from __future__ import annotations

import csv
import json
import shutil
import os
from pathlib import Path

from core import Failure, atomic
import layout


def _rows(path):
    try:
        with open(path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader((l for l in f if not l.startswith("#")), delimiter="\t"))
    except (OSError, UnicodeError, csv.Error):
        return []


def game_of(c, gid):
    try:
        catalog = json.loads((c.library / "catalog.json").read_text())
    except (OSError, ValueError):
        catalog = {}
    game = next((g for g in catalog.get("games", []) if g.get("id") == gid), None)
    if not game:
        raise Failure("游戏库里没有这款游戏。", code="input_missing")
    return game


def _version(game):
    """本机游戏实际跑的版本：有更新取最新更新的显示版本，否则本体"""
    packs = sorted(game.get("packages", []), key=lambda p: (p.get("type") == "update", p.get("version", 0)))
    shown = [p.get("display") for p in packs if p.get("type") in ("base", "update") and p.get("display")]
    return shown[-1] if shown else ""


def _norm(v):
    return (v or "").strip().lower().lstrip("v")


def _community_dir():
    d = os.environ.get("S2A_COMMUNITY_DIR")
    return Path(d) if d else None


def _indexes():
    """社区包索引（同 pack/stage_rewrite.sh 的 S2A_CPATCH_DIRS 缺省）：第一轮 <包>/full/<名>/INDEX.tsv、第二轮 <包>/<类>/INDEX.tsv；名字以 -lite 结尾的包是同轮子集，不收"""
    d = _community_dir()
    if d is None:
        return []
    return [p for p in sorted([*d.glob("*/full/*/INDEX.tsv"), *d.glob("*/*/INDEX.tsv")]) if not p.relative_to(d).parts[0].endswith("-lite")]


SETTINGS_TABLE = "launchers/shared/game_settings.v1.json"


def settings_table(c):
    """定义表里的设置项：{id: 项}。读不到是引擎快照不全，直接报错（不猜缺省）"""
    try:
        items = json.loads((c.engine / SETTINGS_TABLE).read_text(encoding="utf-8"))["items"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Failure("游戏设置定义表读不到（%s），请重新安装 S2Arm。" % e, code="job_failed")
    return {it["id"]: it for it in items}


def launch_path(c, gid, create=True):
    """这款的 launch.json：游戏库结构 v3 的单款文件夹（layout.launch_json；create=False 时这款还没文件夹给不存在的路径）"""
    return layout.launch_json(c, gid, create=create)


def _from_community(old):
    """旧 community.json → launch.json：只带玩家明确选过的（schema 2 存盘总带 fps60=真，不算玩家选的）"""
    settings = {}
    if isinstance(old.get("metalfx"), bool):
        settings["enhance"] = old["metalfx"]
    # 满屏（11-13 并入「宽屏强制启用」，明确开 = 没验证过也铺满）：旧文件的 widescreen=真是旧面板存盘带的缺省（同 fps60），只带关；
    #   widenForce=真才是玩家明确要铺满
    if old.get("widescreen") is False:
        settings["widescreen"] = False
    if old.get("widenForce") is True:
        settings["widescreen"] = True
    if old.get("fps60") is False or (old.get("schema") == 3 and old.get("fps60") is True):
        settings["fps60"] = old["fps60"]
    patches = old.get("enabled") if isinstance(old.get("enabled"), dict) else {}
    return dict(schema=1, settings=settings, patches={str(k): bool(v) for k, v in patches.items()})


def load_launch(c, gid):
    """读 launch.json；没有就把旧 community.json 转过来（写好新的才删旧的）。读不懂按全缺省"""
    path = launch_path(c, gid, create=False)
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        old_path = layout.path(c, gid, "community.json", create=False)
        try:
            old = json.loads(old_path.read_text())
        except (OSError, ValueError):
            old = None
        if not isinstance(old, dict):
            return dict(schema=1, settings={}, patches={})
        data = _from_community(old)
        atomic(launch_path(c, gid), data)
        old_path.unlink(missing_ok=True)
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    settings = data.get("settings") if isinstance(data.get("settings"), dict) else {}
    patches = data.get("patches") if isinstance(data.get("patches"), dict) else {}
    return dict(schema=1, settings=settings, patches={str(k): bool(v) for k, v in patches.items()})


def app_path(c):
    """全游戏共用的设置（定义表 scope=app，如手柄按键对应）：数据目录 game-settings.json，格式同 launch.json"""
    return c.private / "game-settings.json"


# 改过取值的项：旧存档里的值照新值认（11-11 手柄按键对应「按字母 / 按位置」改成「自动 / Switch 布局 / Xbox 布局」；
#   按字母一直就是自动的行为，按位置 = Switch 布局），不然旧值不合定义表、玩家选过的「按位置」会被当没选
LEGACY_VALUES = {"padFace": {"letter": "auto", "position": "switch"}}


def load_app(c):
    try:
        data = json.loads(app_path(c).read_text())
    except (OSError, ValueError):
        data = {}
    settings = data.get("settings") if isinstance(data, dict) and isinstance(data.get("settings"), dict) else {}
    settings = {k: LEGACY_VALUES.get(k, {}).get(v, v) if isinstance(v, str) else v for k, v in settings.items()}
    return dict(schema=1, settings=settings)


def _valid(item, value):
    if item["type"] == "bool":
        return isinstance(value, bool)
    if item["type"] == "choice":
        return isinstance(value, str) and value in [o["value"] for o in item.get("options", [])]
    return False


def chosen(c, gid, table=None):
    """玩家明确选过、且仍合定义表的设置：{id: 值}——按款的从 launch.json、全游戏共用的从 game-settings.json，各认各的 scope
    （定义表改了、旧值不合法的当没选）"""
    table = table or settings_table(c)
    mine = dict(load_launch(c, gid)["settings"])
    if mine.pop("widenForce", None) is True:   # 旧 launch.json 的「宽屏强制启用」（11-13 并进满屏）：开着的 = 满屏明确开
        mine["widescreen"] = True
    picked = {k: v for k, v in mine.items() if k in table and table[k].get("scope") == "game" and _valid(table[k], v)}
    picked.update({k: v for k, v in load_app(c)["settings"].items() if k in table and table[k].get("scope") == "app" and _valid(table[k], v)})
    return picked


def runtime_caps_rows(c, gid):
    """这款 Mac 运行版本的能力清单 s2a_caps.tsv（出包时生成）：{能力: (值, 原因)}，原因 = 值后面那一段（含 # 注释，同宿主 caps.c 读法）"""
    try:
        text = (layout.image_mac(c, gid, create=False) / "s2a_caps.tsv").read_text(encoding="utf-8")
    except (OSError, ValueError, UnicodeError):
        return {}
    rows = (line.split("\t") for line in text.splitlines() if not line.startswith("#"))
    return {r[0].strip(): (r[1].split("#", 1)[0].strip(), "\t".join(r[2:]) if len(r) > 2 else r[1].partition("#")[2])
            for r in rows if len(r) >= 2 and r[0].strip()}


def runtime_caps(c, gid):
    """{能力: 值}。没有清单 = 这款还没有 Mac 运行版本或版本太旧"""
    return {k: v for k, (v, _) in runtime_caps_rows(c, gid).items()}


# 60 帧缺省开的来源（11-11 维护者：出包默认游戏原本帧率、玩家手动开；速度已验证正确的款保留默认 60）。
#   与宿主 runtime/src/caps.c apply_cap 同一条规则、同一组字样：清单 fps60 值 1 且原因含其一，宿主没收到玩家选择时自己开 60 帧
FPS60_VERIFIED = ("fps.tsv", "逻辑速度同局 A/B 绿", "游戏原生 60 帧", "社区帧率补丁")   # 社区帧率补丁：版本精确命中才进得了包，默认开（11-13）


def fps60_default(rows):
    value, why = rows.get("fps60", ("", ""))
    return value == "1" and any(mark in why for mark in FPS60_VERIFIED)


NO_FPS60 = "这款游戏没有可用的 60 帧方案。"
NO_DIRECT = "这款游戏没有走直连渲染，用不了 MetalFX 放大。"
NO_WIDEN = "本款满屏有已知问题，暂不可开。"


def _default(item, caps, platform="mac", rows=None):
    d = item.get("default")
    if isinstance(d, dict):
        d = d.get(platform)
    if d == "caps":   # 按能力清单：60 帧看值和原因（fps60_default，同宿主）；满屏看 widen（发布包只有真机验过的款是 1，同 iPhone），没给原因按值
        if item["id"] == "widescreen":
            return caps.get("widen") == "1"
        return fps60_default(rows) if item["id"] == "fps60" and rows is not None else caps.get(item["id"]) == "1"
    return d


def mac_settings(c, gid):
    """Mac 启动设置页：定义表里 Mac 有的每一项 {available, value, reason}（页面 / 补丁两类由各自的入口画，不在这里）。
    缺省跟定义表 / 能力清单走；60 帧在清单没有方案时、画面增强在没走直连时不可用"""
    rows, table = runtime_caps_rows(c, gid), settings_table(c)
    caps = {k: v for k, (v, _) in rows.items()}
    picked = chosen(c, gid, table)
    # 满屏改不动只认强信号（tools/caps_policy.py 原因写「强信号：…」）；「发布缺省关」只是没验证过，玩家可以明确开（同 iPhone settings.m s2a_ios_fullscreen_state）
    strong = caps.get("widen") == "0" and "强信号" in rows.get("widen", ("", ""))[1]
    need = {"fps60": ("fps60" in caps, NO_FPS60), "enhance": (caps.get("direct") == "1", NO_DIRECT), "widescreen": (not strong, NO_WIDEN)}
    out = {}
    for key, item in table.items():
        if "mac" not in item.get("platforms", []) or item["type"] not in ("bool", "choice"):
            continue
        # 还没出 Mac 版（读不到能力清单）：各项都能选、先存偏好，出好后生效（v0.3.1「拿不准不停」：有没有 60 帧方案、走不走直连此时还不知道，不先挡）；
        #   清单明说没有 60 帧方案 / 没走直连的，才是物理上用不了
        ok, why = need.get(key, (True, "")) if caps else (True, "")
        value = picked.get(key, _default(item, caps, rows=rows))
        if key == "widescreen" and key not in picked and adaptive_patches(c, gid)[0]:
            value = True   # 没选过、包里有自适应满屏补丁：显示开（11-13 命中就默认开，同 iPhone）
        out[key] = dict(available=ok, value=value if ok else _default(item, caps, rows=rows), reason="" if ok else why)
        if key == "language":
            out[key].update(language_state(c, gid, item, out[key]["value"]))
    # 只用社区补丁（11-13 维护者撤掉我方 60 帧与通用满屏，tools/caps_policy.py patch_only）：没有帧率补丁的款不出「60 帧」，没有宽屏补丁的款不出「满屏」
    #   （读到了能力清单才判：还没出 Mac 版时照旧都列、先存偏好）
    if caps:
        fps_p = "社区帧率补丁" in rows.get("fps60", ("", ""))[1]
        ws_p = any((r.get("编号") or "").startswith(("widescreen:", "wsauto:")) for r in _rows(layout.image_mac(c, gid, create=False) / "cpatch.tsv"))
        for key, has in (("fps60", fps_p), ("widescreen", ws_p), ("fpsPick", len(fps_levels(c, gid)) > 1)):
            if key in out and not has:
                out[key]["hidden"] = True
    return out


# ---- 游戏语言（11-14 维护者：「按照你的建议加上」，推翻 11-07「不给玩家选」）----
# 只列这款实际支持的语言：读包里保留的 control.nacp 的支持语言标志（SupportedLanguageFlag，偏移 0x302C，u32），位序 = 宿主 TitleLanguage 枚举
#   （compat/tree/.../TitleLanguage.cs；定义表 language 的选项值就是这些名字）。还没出包 / 标志为 0（合成的 nacp）→ 不知道，照旧列全部
NACP_LANGUAGES = ("AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish", "Spanish", "Italian", "Dutch",
                  "CanadianFrench", "Portuguese", "Russian", "Korean", "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese", "Polish", "Thai")


def nacp_languages(nacp_bytes):
    """control.nacp 原文 → 支持的语言（NACP_LANGUAGES 的名字，按位序）；读不到 / 标志为 0 → []"""
    if len(nacp_bytes) < 0x3030:
        return []
    flag = int.from_bytes(nacp_bytes[0x302C:0x3030], "little")
    return [n for i, n in enumerate(NACP_LANGUAGES) if flag >> i & 1]


def game_languages(c, gid):
    """这款支持的游戏语言：Mac 包、iPhone 资源包里任一份 ctl/control.nacp（同一份游戏数据）；都没有 → []（还没出包，不知道）"""
    for root in (layout.image_mac(c, gid, create=False), layout.image_ios(c, gid, create=False) / layout.IOS_PACK):
        try:
            got = nacp_languages((root / "ctl" / "control.nacp").read_bytes())
        except OSError:
            continue
        if got:
            return got
    return []


def system_title_language(tags):
    """系统首选语言标签（BCP 47）→ 游戏语言名：照搬宿主 services/S2A.Services/SystemLocale.cs Map / FromPreferred（第一个认得的；都不认得 = 美式英语）"""
    for tag in tags:
        p = str(tag).replace("_", "-").lower().split("-")
        has = lambda s: s in p[1:]
        lang = {"ja": "Japanese", "ko": "Korean", "de": "German", "it": "Italian", "nl": "Dutch", "ru": "Russian", "pl": "Polish", "th": "Thai"}.get(p[0])
        if p[0] == "zh":
            lang = "TraditionalChinese" if has("hant") else "SimplifiedChinese" if has("hans") else \
                "TraditionalChinese" if has("tw") or has("hk") or has("mo") else "SimplifiedChinese"
        elif p[0] == "en":
            lang = "BritishEnglish" if any(has(x) for x in ("gb", "au", "nz", "ie", "in", "za")) else "AmericanEnglish"
        elif p[0] == "fr":
            lang = "CanadianFrench" if has("ca") else "French"
        elif p[0] == "es":
            lang = "Spanish" if len(p) == 1 or has("es") else "LatinAmericanSpanish"
        elif p[0] == "pt":
            lang = "BrazilianPortuguese" if has("br") else "Portuguese"
        if lang:
            return lang
    return "AmericanEnglish"


def effective_language(want, supported):
    """起局实际用的语言：同宿主 SystemLocale.TitleFallback + 上游 PickFallbackLanguage——想要的 → 美式 / 英式英语 → 支持表第一项；不知道支持表就是想要的"""
    if not supported:
        return want
    for lang in (want, "AmericanEnglish", "BritishEnglish"):
        if lang in supported:
            return lang
    return supported[0]


def preferred_tags():
    """本机系统首选语言（同宿主 CFLocaleCopyPreferredLanguages）；取不到 → []（S2A_TEST_PREFERRED_LANGUAGES 单测用，逗号分隔）"""
    test = os.environ.get("S2A_TEST_PREFERRED_LANGUAGES")
    if test is not None:
        return [t for t in test.split(",") if t]
    try:
        import ctypes, ctypes.util
        cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
        cf.CFLocaleCopyPreferredLanguages.restype = ctypes.c_void_p
        cf.CFArrayGetCount.restype = ctypes.c_long; cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p; cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        arr = cf.CFLocaleCopyPreferredLanguages()
        if not arr:
            return []
        out, buf = [], ctypes.create_string_buffer(128)
        for i in range(cf.CFArrayGetCount(arr)):
            if cf.CFStringGetCString(cf.CFArrayGetValueAtIndex(arr, i), buf, 128, 0x08000100):
                out.append(buf.value.decode())
        cf.CFRelease(arr)
        return out
    except (OSError, AttributeError):
        return []


def language_state(c, gid, item, value):
    """启动设置「游戏语言」一行的补充：choices = 跟随系统 + 这款支持的（不知道就不给，界面列全部）；
    选的语言（跟随系统 = 系统语言）这款不支持时给 note {zh-Hans, en}：写明起局实际用哪种（不弹窗，11-14 维护者）"""
    supported = game_languages(c, gid)
    if not supported:
        return {}
    out = {"choices": ["system"] + supported}
    want = system_title_language(preferred_tags()) if value in (None, "system") else value
    got = effective_language(want, supported)
    if got != want:
        label = {o["value"]: o["label"] for o in item.get("options", [])}
        name = lambda v, lang: label.get(v, {}).get(lang, v)
        out["note"] = {"zh-Hans": f"这款不支持{name(want, 'zh-Hans')}，起局用{name(got, 'zh-Hans')}。",
                       "en": f"This game doesn't have {name(want, 'en')}; it starts in {name(got, 'en')}."}
    return out


def fps_levels(c, gid):
    """这款 Mac 包里帧率补丁（编号 fps:）的目标帧率档，去重升序；没写目标的当 60（同 iPhone app_settings.m fpsLevels）。两档以上才出「帧率档位」"""
    return sorted({int(r.get("目标帧率") or 0) or 60 for r in _rows(layout.image_mac(c, gid, create=False) / "cpatch.tsv")
                   if (r.get("编号") or "").startswith("fps:") and (r.get("目标帧率") or "0").isdigit()})


def selection(c, gid):
    """补丁与宽屏 / 60 帧总开关（社区面板用）：没选过按开"""
    data = load_launch(c, gid)
    return dict(widescreen=data["settings"].get("widescreen", True) is not False, fps60=data["settings"].get("fps60", True) is not False,
                enabled=data["patches"])


def available(c, game):
    gid, version = game["id"].upper(), _version(game)
    builds = {(p.get("builds") or {}).get("main", "").lower() for p in game.get("packages", [])} - {""}
    ws = dict(verified=False, sources=[], relocate=False)
    for r in _rows(c.engine / "graphics/widen/tables/verified.tsv"):
        if (r.get("程序号") or "").upper() == gid and (r.get("构建号") or "").lower() in builds:
            ws["verified"] = True
    fps = dict(verified=False, sources=[], relocate=False)
    for index in _indexes():
        rows = _rows(index)
        kind = ws if rows and "aspect" in rows[0] else fps if rows and "target_fps" in rows[0] else None
        for r in rows if kind is not None else []:
            if (r.get("title_id") or "").upper() != gid or not (r.get("in_pack") or "").startswith("yes"):
                continue
            if kind is fps and (r.get("target_fps") or "") != "60":
                continue
            if r.get("source") and r["source"] not in kind["sources"]:
                kind["sources"].append(r["source"])
            if r.get("version") and _norm(r["version"]) != _norm(version):
                kind["relocate"] = True   # 版本对不上：打包时由直连线按特征跨版本定位（定不到就不打，不影响出包）
    return dict(widescreen=ws, fps60=fps, graphics=packed_patches(c, gid))


def adaptive_patches(c, gid):
    """这款 Mac 包里的自适应满屏补丁一族（编号 wsauto:<族>:w / :n → 族编号）与「表里有缺省开的」：满屏开关一并开关它们（11-13，同 iPhone settings.m），不在补丁列表单列"""
    fams, default_on = [], False
    for r in _rows(layout.image_mac(c, gid, create=False) / "cpatch.tsv"):
        uid = r.get("编号") or ""
        if uid.startswith("wsauto:"):
            fam = uid.rsplit(":", 1)[0]
            if fam not in fams:
                fams.append(fam)
            default_on = default_on or (r.get("缺省开") or "") == "1"
    return fams, default_on


def patch_status(c, gid):
    """上一局每条社区补丁的实际结果（runtime/src/cpatch.c 写 <起局文档根>/cpatch_status.tsv；Mac 起局文档根 = 游戏库/temp/<程序号>，build.py）：
    {编号: (状态 开 | 关 | 不配套 | 表不认, 实测 fps=<n> | aspect=<w>:<h> | 空)}；没跑过 = {}"""
    try:
        text = (Path(c.library) / "temp" / gid / "cpatch_status.tsv").read_text(encoding="utf-8")
    except OSError:
        return {}
    return {f[0]: (f[1], f[2]) for f in (l.split("\t") for l in text.splitlines()) if len(f) >= 3}


def patch_result(st):
    """给玩家看的一句（同 iPhone ios/game_options.m s2a_ios_cpatch_result）：没生效写原因、开着且量到效果写实测、其余空"""
    if not st:
        return ""
    if st[0] in ("不配套", "表不认"):
        return "没生效：补丁与这个版本的游戏不配套"
    if st[0] != "开":
        return ""
    if st[1].startswith("fps="):   # 达到 55 帧（60 帧补丁目标留 5 帧余量）才算生效，达不到如实写实测
        n = st[1][4:]
        return f"已生效：上一局实测 {n} 帧" if n.isdigit() and int(n) >= 55 else f"开着，但上一局实测只有 {n} 帧"
    if st[1].startswith("aspect="):
        return f"已生效：上一局画面比例 {st[1][7:]}"
    return {"fill=ok": "已生效：上一局画面铺满", "unfilled": "开着，但上一局画面没铺满"}.get(st[1], "")


def ratio_text(a):
    """画幅数 → 常见写法（1.6 → 16:10、2.3333 → 21:9；同 ios/cpatch_model.m S2ACPatchRatioText），对不上的写两位小数"""
    for w, h in ((16, 10), (21, 9), (32, 9), (3, 2), (4, 3), (16, 9), (5, 4), (18, 9), (19, 9), (20, 9), (24, 10), (48, 9), (1, 1)):
        if abs(a - w / h) < 0.005: return f"{w}:{h}"
    return f"{a:.2f}:1"


def packed_patches(c, gid):
    """这款 Mac 包里编进去的社区补丁（产物 cpatch.tsv；11-12 出包时自动查库，pack/jobs/patches.py）：全部列出、11-13 起缺省开、玩家可逐条关（下次启动生效，
    launch_env 转 S2A_CPATCH_ON）。帧率类（编号 fps:）跟「60 帧」开关走、金手指（cheat:）在金手指一栏，都不在这里列。每条带来源库与许可"""
    out, seen, st = [], set(), patch_status(c, gid)
    fixed = None   # 定画幅宽屏变体（表「画幅」列 > 0，pack/cpatch.py）并成一项 widescreen:auto，宿主按窗口比例开最近的一份（runtime/src/cpatch.c）
    for r in _rows(layout.image_mac(c, gid, create=False) / "cpatch.tsv"):
        uid = r.get("编号") or ""
        label = r.get("段名") or uid
        if not uid or uid in seen or uid.startswith(("fps:", "cheat:", "wsauto:")):   # 自适应满屏一族跟满屏开关（adaptive_patches），不单列
            continue
        try: fa = float(r.get("画幅") or 0) if uid.startswith("widescreen:") else 0
        except ValueError: fa = 0
        if fa > 0:
            if fixed is None:
                fixed = dict(id="widescreen:auto", label="", exclusive="", source=r.get("来源") or "", license=r.get("许可") or "",
                             kind="widescreen", state="community", relocate=False, result=patch_result(st.get("widescreen:auto")), ratios=[])
                out.append(fixed)
            fixed["ratios"].append(ratio_text(fa)); fixed["label"] = "满屏补丁（按屏幕比例自动选）"   # 界面 L() 按原文查译文，标题写死、画幅在 ratios
            continue
        seen.add(uid)
        out.append(dict(id=uid, label=label, exclusive="", source=r.get("来源") or "", license=r.get("许可") or "",
                        kind="widescreen" if uid.startswith(("widescreen:", "wsauto:")) else "gfx", state="community", relocate=False,
                        result=patch_result(st.get(uid))))
    return out


def describe_game(c, game):
    a, s = available(c, game), selection(c, game["id"])
    for key in ("widescreen", "fps60"):
        a[key]["available"] = a[key]["verified"] or bool(a[key]["sources"])
        a[key]["enabled"] = a[key]["available"] and s[key]
    for it in a["graphics"]:
        it["enabled"] = s["enabled"].get(it["id"]) is not False   # 11-13：没选过 = 默认开（S 级优化命中的打入并默认开）
    import cheats   # 金手指（11-12）：同一页「游戏设置 → 金手指」列出与开关
    return dict(gameId=game["id"], version=_version(game), mac=mac_settings(c, game["id"]), cheats=cheats.listing(c, game),
                crashed=cheats.crashed(c, game), **a)


def listing(c):
    game = game_of(c, c.r.get("gameId") or "")
    c.begin("读取社区资源")
    return describe_game(c, game)


def save(c):
    """请求可带 settings {设置项: 值 / null（回缺省）}（键与取值按定义表，只认 scope=game 的项）、graphics {画面编号: 真/假}（同互斥组至多开一个）、
    cheatsImport [金手指 txt 路径]（导入进这款 cheats/）与 cheats {「文件名/条目名」: 真/假}（金手指开关）"""
    game = game_of(c, c.r.get("gameId") or "")
    table = settings_table(c)
    data = load_launch(c, game["id"])
    want = c.r.get("settings") or {}
    if not isinstance(want, dict):
        raise Failure("启动设置格式不对。", code="job_failed")
    shared = load_app(c)
    for key, value in want.items():
        item = table.get(key)
        if item is None or item.get("scope") not in ("game", "app") or item["type"] not in ("bool", "choice"):
            raise Failure("没有这个启动设置：%s。" % key, code="job_failed")
        target = shared if item["scope"] == "app" else data
        if value is None:
            target["settings"].pop(key, None)
        elif _valid(item, value):
            target["settings"][key] = value
        else:
            raise Failure("启动设置 %s 的取值不对。" % key, code="job_failed")
    if c.r.get("cheatsImport") or c.r.get("cheats") is not None:   # 金手指（pack/jobs/cheats.py）：导入 [文件路径] / 开关 {「文件名/条目名」: 真 / 假}
        import cheats
        if c.r.get("cheatsImport"):
            if not isinstance(c.r["cheatsImport"], list):
                raise Failure("金手指导入格式不对。", code="job_failed")
            cheats.import_files(c, game, c.r["cheatsImport"])
        if c.r.get("cheats") is not None:
            cheats.save(c, game, c.r["cheats"])
    if c.r.get("crashAnswer") is not None:   # 上次开着金手指 / 补丁时异常退出、已当场关掉，玩家看过通知 ack（pack/jobs/cheats.py answer_crash）
        import cheats
        cheats.answer_crash(c, game, c.r["crashAnswer"])
    graphics = c.r.get("graphics") or {}
    if not isinstance(graphics, dict):
        raise Failure("社区资源选择格式不对。", code="job_failed")
    if graphics:
        every = {it["id"]: it for it in packed_patches(c, game["id"])}
        for key, on in graphics.items():
            it = every.get(key)
            if it is None:
                raise Failure("这款游戏没有这个补丁。", code="job_failed")
            data["patches"][key] = bool(on)
            if on and it["exclusive"]:
                for other in every.values():
                    if other["exclusive"] == it["exclusive"] and other["id"] != key:
                        data["patches"][other["id"]] = False
    atomic(launch_path(c, game["id"]), data)
    if any(table[k]["scope"] == "app" for k in want):
        atomic(app_path(c), shared)
    return describe_game(c, game)


def launch_env(c, gid):
    """Mac 启动时的宿主开关：只把玩家选过、且和宿主缺省不同的转成环境变量（与 iPhone 同口径）"""
    env, caps, table = {}, runtime_caps(c, gid), settings_table(c)
    s = chosen(c, gid, table)
    # 60 帧（11-11 维护者：缺省原帧率、玩家手动开，速度已验证正确的款保留默认 60）：只转玩家明确的选择——开 1、关 0；
    #   没选过不写，由宿主按清单原因自己定（runtime/src/caps.c：验证过的款开、其余原帧率）。没选也写 0 会把验证过的款一起关掉
    if s.get("fps60") is True:
        env["S2A_FPS60"] = "1"
    elif s.get("fps60") is False:
        env["S2A_FPS60"] = "0"
    # 帧率档位（11-13 维护者：60 / 120 帧补丁都带进去，玩家自己选）：选了具体档才写，宿主（runtime/src/cpatch.c fps_pick）取不超过它的最高一档；没选 / 自动不写，宿主按屏幕最高刷新率挑
    if str(s.get("fpsPick") or "0") not in ("", "0"):
        env["S2A_FPS_PICK"] = str(s["fpsPick"])
    # 满屏（11-13 合并「宽屏」与「宽屏强制启用」，同 iPhone settings.m）：明确开 = 没验证过也铺满（画面被拉伸会自动退回 16:9）；明确关 = 16:9；
    #   没选过 = 清单 widen 1 或包里有我方验过的自适应满屏补丁才开。有自适应满屏补丁的款由补丁铺满（下面写进 S2A_CPATCH_ON，S2Arm 满屏让开）；
    #   清单原因「强信号」= 判过坏，一律不开
    strong = caps.get("widen") == "0" and "强信号" in runtime_caps_rows(c, gid).get("widen", ("", ""))[1]
    fams, fam_default = adaptive_patches(c, gid)
    full = False if strong else s["widescreen"] if isinstance(s.get("widescreen"), bool) else (caps.get("widen") == "1" or bool(fams))   # 有自适应满屏补丁 = 默认开（11-13）
    if s.get("widescreen") is True and not strong and not fams:
        env["S2A_WIDEN_VERIFIED"] = "1"
        env["S2A_WIDESCREEN"] = "1"
    elif s.get("widescreen") is False:
        env["S2A_WIDESCREEN"] = "0"       # 满屏关：宿主满屏开关（不用判定局专用的 S2A_WIDEN_VERIFIED，它会盖掉名单门）
    # 社区补丁（11-12，全部缺省关）：包里有才设；只开玩家开着的（自适应满屏一族跟满屏开关），一条都没开写 none，盖掉表里的「缺省开」列（runtime/src/cpatch.c；帧率类另跟 60 帧开关）
    packed = {it["id"] for it in packed_patches(c, gid)}
    if packed or fams:
        chosen_p = load_launch(c, gid)["patches"]
        on = sorted([k for k in packed if chosen_p.get(k) is not False] + (fams if full else []))   # 没选过 = 开（11-13）；玩家关过的不开
        env["S2A_CPATCH_ON"] = ",".join(on) or "none"
        if any(k.startswith(("widescreen:", "wsauto:")) for k in on):
            env["S2A_WIDESCREEN"] = "0"   # 开着社区宽屏 / 画幅补丁：游戏自己画宽画面，S2Arm 的满屏（图形层加宽渲染目标）让开，不拉宽两次；关掉补丁恢复
    if s.get("enhance") is True and caps.get("direct") == "1":
        env["S2A_SCALING_FILTER"] = "MetalFX"   # 画面增强模式 = 直连上屏 MetalFX 空间放大（graphics/nvn/gfx/nvn/nvn_present_fx.inc）
    if "docked" in s:
        env["S2A_DOCKED"] = "1" if s["docked"] == "docked" else "0"
    if s.get("language", "system") != "system":
        env["S2A_SYSTEM_LANGUAGE"] = s["language"]   # 游戏语言：值就是宿主枚举名（services/S2A.Services/Host.cs PickLanguage）；跟随系统不设，宿主读系统首选语言
    if s.get("hud") is True:
        env["S2A_HUD"] = "1"              # S2Arm 诊断浮层：front_mac.m 绘制，hud.c 格式化
    if s.get("rumble") is False:
        env["S2A_RUMBLE"] = "0"           # 手柄震动关（macos/front_mac.m）
    if "rumbleLevel" in s:
        env["S2A_RUMBLE_SCALE"] = str(table["rumbleLevel"]["scale"][s["rumbleLevel"]])
    if s.get("padFace") in ("switch", "xbox"):
        env["S2A_PAD_FACE"] = s["padFace"]  # 手柄按键布局：玩家手动选的 Switch / Xbox 布局（缺省自动不设；宿主 runtime/src/pad.c s2a_pad_layout）
    if s.get("motion") is False:
        env["S2A_MOTION"] = "0"           # 体感关：不开手柄六轴（macos/front_mac.m）
    # 声音延迟（11-14 维护者，PR #1066 收进启动设置）：低 / 最低 = 请求输出设备 IO 缓冲 128 / 32 帧（Ryujinx.Audio.Backends.Apple
    #   AppleDeviceBufferFrames，S2A_AUDIO_BUFFER_FRAMES）；标准不写 = 不请求、跟设备默认（内置扬声器 512 帧 ≈ 10.7 ms）
    frames = next((o.get("frames", 0) for o in table["audioLatency"]["options"] if o["value"] == s.get("audioLatency")), 0) if "audioLatency" in table else 0
    if frames:
        env["S2A_AUDIO_BUFFER_FRAMES"] = str(frames)
    if s.get("pauseUnfocused") is False:
        env["S2A_FOCUS_PAUSE"] = "0"      # 切到别的窗口不暂停：游戏要求失焦暂停时也照常跑（macos/front_mac.m，#989）
    if s.get("diagRun") is True:
        env.update(diag_run_env(c, gid))  # 诊断局（#438）：只管这一局，用掉就关
    return env


DIAG_RUN_FRAMES = "3600,7200"   # 第 3600 / 7200 次出图（60 帧游戏约 1 / 2 分钟）：逐通道读数取的帧，同 iPhone（ios/settings.m s2a_ios_apply_diag_run）


def diag_run_env(c, gid):
    """诊断局的探针（#438，维护者定的变量与帧号，Mac 与 iPhone 同一组）：逐通道记录 [pass] 行走宿主 stderr → 本局 game.log；
    出图与颜色目标 PNG 写这款文件夹的 diagrun/（导出诊断包时带上，library.diagnostics）。这些是重探针、会拖慢帧率：
    读到一次就把 launch.json 里这项去掉，只管这一局"""
    out = layout.path(c, gid, "diagrun")
    shutil.rmtree(out, ignore_errors=True)   # 上一次诊断局的图不混进来
    out.mkdir(parents=True, exist_ok=True)
    data = load_launch(c, gid)
    data["settings"].pop("diagRun", None)
    atomic(launch_path(c, gid), data)
    return {"DM_NVN_PASSDUMP": "3600-3601", "DM_NVN_TEXDUMP": f"{DIAG_RUN_FRAMES}:{out}/td_%d.png",
            "DM_NVN_TEXSNAP": "0,4,8,12,16,20,24,28", "DM_NVN_SHOT": f"{DIAG_RUN_FRAMES}:{out}/shot_%d.png"}
