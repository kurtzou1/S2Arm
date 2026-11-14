"""社区资源（10-30 维护者 拍板：社区补丁一律学成我方通用能力，公开发布的包不带上游补丁字节）：宽屏 / 60 帧是我方能力，在宿主层运行时开关（缺省开、可关，下次启动生效）；
画面类社区补丁（other-gfx）只在内部开发 / 测试包里列出（S2A_COMMUNITY_PATCHES=1，同 pack/stage_rewrite.sh 打补丁字节的开关），玩家包缺省不列、不打。
面板显示这款有没有宽屏表 / 60 帧表、来自哪（已验证名单 / 社区包；版本对不上的由直连线打包时跨版本定位，不判不可用），
画面类（other-gfx）逐项开关，着色器缓存命中就自动并入（只显示并入数，导入入口留给玩家导自己的缓存）。

数据来源（只读，读不到就当没有，不报错）：
  宽屏已验证：引擎 graphics/widen/tables/verified.tsv（程序号 + main 构建号）
  社区包：S2A_COMMUNITY_DIR（没设 = 没有社区包；11-07 起不再缺省读开发机数据盘，启动器进程也不读 tools/machine.local）下 */full/*/INDEX.tsv（第一轮）与 */*/INDEX.tsv（第二轮，按类分目录），-lite 子集包不收——有 aspect 列的是宽屏包，有 target_fps 列的是帧率包
  画面：补丁应用层（直连线）出的 graphics/community/other_gfx.tsv：程序号 版本 编号 名称 互斥组 已验证(0/1) 来源
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
    for key, new in (("widescreen", "widescreen"), ("widenForce", "widenForce"), ("metalfx", "enhance")):
        if isinstance(old.get(key), bool):
            settings[new] = old[key]
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
    picked = {k: v for k, v in load_launch(c, gid)["settings"].items() if k in table and table[k].get("scope") == "game" and _valid(table[k], v)}
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
FPS60_VERIFIED = ("fps.tsv", "逻辑速度同局 A/B 绿", "游戏原生 60 帧")


def fps60_default(rows):
    value, why = rows.get("fps60", ("", ""))
    return value == "1" and any(mark in why for mark in FPS60_VERIFIED)


NO_FPS60 = "这款游戏没有可用的 60 帧方案。"
NO_DIRECT = "这款游戏没有走直连渲染，用不了 MetalFX 放大。"


def _default(item, caps, platform="mac", rows=None):
    d = item.get("default")
    if isinstance(d, dict):
        d = d.get(platform)
    if d == "caps":   # 按能力清单：现在只有 60 帧，看值和原因（fps60_default，同宿主），没给原因按值
        return fps60_default(rows) if item["id"] == "fps60" and rows is not None else caps.get(item["id"]) == "1"
    return d


def mac_settings(c, gid):
    """Mac 启动设置页：定义表里 Mac 有的每一项 {available, value, reason}（页面 / 补丁两类由各自的入口画，不在这里）。
    缺省跟定义表 / 能力清单走；60 帧在清单没有方案时、画面增强在没走直连时不可用"""
    rows, table = runtime_caps_rows(c, gid), settings_table(c)
    caps = {k: v for k, (v, _) in rows.items()}
    picked = chosen(c, gid, table)
    need = {"fps60": ("fps60" in caps, NO_FPS60), "enhance": (caps.get("direct") == "1", NO_DIRECT)}
    out = {}
    for key, item in table.items():
        if "mac" not in item.get("platforms", []) or item["type"] not in ("bool", "choice"):
            continue
        # 还没出 Mac 版（读不到能力清单）：各项都能选、先存偏好，出好后生效（v0.3.1「拿不准不停」：有没有 60 帧方案、走不走直连此时还不知道，不先挡）；
        #   清单明说没有 60 帧方案 / 没走直连的，才是物理上用不了
        ok, why = need.get(key, (True, "")) if caps else (True, "")
        value = picked.get(key, _default(item, caps, rows=rows))
        out[key] = dict(available=ok, value=value if ok else _default(item, caps, rows=rows), reason="" if ok else why)
    return out


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
    gfx = []
    for r in _rows(c.engine / "graphics/community/other_gfx.tsv") if os.environ.get("S2A_COMMUNITY_PATCHES") == "1" else []:   # 画面补丁只能靠补丁字节生效：玩家包不带字节，就不列
        if (r.get("程序号") or "").upper() != gid:
            continue
        gfx.append(dict(id="gfx:" + (r.get("编号") or ""), label=r.get("名称") or r.get("编号") or "",
                        exclusive=r.get("互斥组") or "", source=r.get("来源") or "",
                        state="verified" if r.get("已验证") == "1" else "community",
                        relocate=bool(r.get("版本")) and _norm(r.get("版本")) != _norm(version)))
    return dict(widescreen=ws, fps60=fps, graphics=gfx)


def describe_game(c, game):
    a, s = available(c, game), selection(c, game["id"])
    for key in ("widescreen", "fps60"):
        a[key]["available"] = a[key]["verified"] or bool(a[key]["sources"])
        a[key]["enabled"] = a[key]["available"] and s[key]
    for it in a["graphics"]:
        it["enabled"] = bool(s["enabled"].get(it["id"], it["state"] == "verified"))
    return dict(gameId=game["id"], version=_version(game), mac=mac_settings(c, game["id"]), **a)


def listing(c):
    game = game_of(c, c.r.get("gameId") or "")
    c.begin("读取社区资源")
    return describe_game(c, game)


def save(c):
    """请求可带 settings {设置项: 值 / null（回缺省）}（键与取值按定义表，只认 scope=game 的项）与 graphics {画面编号: 真/假}（同互斥组至多开一个）"""
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
    graphics = c.r.get("graphics") or {}
    if not isinstance(graphics, dict):
        raise Failure("社区资源选择格式不对。", code="job_failed")
    if graphics:
        every = {it["id"]: it for it in available(c, game)["graphics"]}
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
    if s.get("widenForce") is True:       # 同 iPhone「宽屏强制启用」：没验证过的也铺满，画面被拉伸会自动退回 16:9
        env["S2A_WIDEN_VERIFIED"] = "1"
        env["S2A_WIDESCREEN"] = "1"
    elif s.get("widescreen") is False:
        env["S2A_WIDESCREEN"] = "0"       # 宽屏关：宿主宽屏开关（不用判定局专用的 S2A_WIDEN_VERIFIED，它会盖掉名单门）
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
