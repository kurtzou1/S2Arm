"""下游深度方案（登记表 pack/downstream/schemes.json）：某款游戏有下游项目做的专门移植时，玩家确认后出包的最后一步改用它的做包工具，
导入、解包、签名、装机、推资源仍走 S2Arm 原流程。

做法跟着下游走、不在 S2Arm 里另起一套：下游项目自己适配 S2Arm（只用 S2Arm 随包的 Python / spirv-cross / .NET 运行时；
认 S2Arm 的解包目录；做包时顺带出 S2Arm 格式的资源包；App 认 S2A_PACK_APPLY_ONLY）。S2Arm 这边只做三件事：
  1. 认程序号 → 读库时附上方案、能不能选与原因（启动器据此弹确认页）；玩家的选择记在这款文件夹 downstream.json。
  2. 出包：开工就在后台下载登记的「下游包件」（挂 s2arm.com 的一个 zip：下游源码 + 壳 + 预编翻译工具 + bundle.json），同时照常共用解包；
     两边都好了调包件里的做包工具，出安装包 + S2Arm 资源包，记下下游的标签与提交（两边版本可追溯）。
  3. 装机：独立 App（自己的包名，不进 S2Arm 多款容器）用玩家 Apple ID 签、装，资源包用 S2Arm 的推送（install.push_pack）推进去。
唯一不让选的情况是物理上做不出来：下游按某一版游戏程序逐字节改写，导入的更新不是那一版就做不出。原因与办法写给玩家看。
玩家选「仍用原版方案」照原版出（请求不带 scheme），这里一行不碰。
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile

from core import Failure, atomic, contained, read

REGISTRY = Path(__file__).resolve().parents[1] / "downstream" / "schemes.json"   # 源码树里作业代码就在 pack/jobs 下时的位置（单测 / 开发）


# 只有付费开发者团队签得出的权限（#897；同 devcert.py WANT 的「付费账号才有」）
PAID_ONLY_ENTITLEMENTS = ("com.apple.developer.kernel.extended-virtual-addressing",)


def install_entitlements(target, team):
    """装下游 App 要申请的权限：方案登记的那几项，免费个人团队去掉只有付费团队才有的（#897）"""
    return [k for k in target.get("entitlements", []) if not (team.get("free", True) and k in PAID_ONLY_ENTITLEMENTS)]

def registry(c=None):
    """登记表按引擎目录取（同其余作业模块读仓库数据的口径 c.engine / …）：发版 App 里作业代码单独拷在 Resources/Jobs，
    按本文件位置拼会落到 Resources/downstream（v0.3.3 候选导入即红：FileNotFoundError），引擎快照里是 Engine/pack/downstream/schemes.json"""
    engine = getattr(c, "engine", None) if c is not None else None
    return Path(engine) / "pack" / "downstream" / "schemes.json" if engine else REGISTRY
REQUIRED = ("id", "name", "repo", "license", "titleIds", "needs", "bundle", "targets", "copy")
CHOICE = "downstream.json"   # 这款文件夹里记玩家的选择：{"scheme": 方案 id 或 ""（原版）, "at": 时刻}


class SchemeError(ValueError):
    pass


# ---------- 登记表 ----------

def load(path=None, c=None):
    """读登记表 → {方案 id: 方案}。读不了（文件缺 / 坏）= 当没有下游方案、打一行黄，导入与出包照常走（反防御：不为附加功能挡掉所有游戏）；
    缺字段、程序号格式不对、同一程序号登记两次抛 SchemeError（登记表是仓库文件，内容坏了是开发错误，单测拦）"""
    try:
        data = json.loads(Path(path or registry(c)).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"【黄】下游方案登记表读不了，按没有下游方案处理：{e}", file=sys.stderr)
        return {}
    if data.get("schema") != 1:
        raise SchemeError("下游方案登记表 schema 不是 1")  # 非玩家句
    out, seen = {}, {}
    for s in data.get("schemes", []):
        miss = [k for k in REQUIRED if k not in s]
        if miss:
            raise SchemeError(f"下游方案 {s.get('id', '?')} 缺字段：{'、'.join(miss)}")  # 非玩家句
        if len(s["bundle"].get("commit", "")) != 40:
            raise SchemeError(f"下游方案 {s['id']} 的提交号要写全 40 位")  # 非玩家句
        for t in s["titleIds"]:
            t = t.upper()
            if len(t) != 16 or any(ch not in "0123456789ABCDEF" for ch in t):
                raise SchemeError(f"下游方案 {s['id']} 的程序号格式不对：{t}")  # 非玩家句
            if t in seen:
                raise SchemeError(f"程序号 {t} 登记了两个下游方案：{seen[t]}、{s['id']}")  # 非玩家句
            seen[t] = s["id"]
        if s["id"] in out:
            raise SchemeError(f"下游方案 id 重复：{s['id']}")  # 非玩家句
        out[s["id"]] = s
    return out


def match(game, schemes=None, c=None):
    """这款游戏命中的下游方案；没有返回 None"""
    gid = (game.get("id") or "").upper()
    for s in (load(c=c) if schemes is None else schemes).values():
        if gid in (t.upper() for t in s["titleIds"]):
            return s
    return None


# ---------- 能不能选 ----------

def _selected(game):
    from space_rule import selected_packages
    return selected_packages(game)


def update_of(game):
    ups = [p for p in _selected(game) if p.get("type") == "update"]
    return max(ups, key=lambda p: p["version"]) if ups else None


HOST = "windows" if os.name == "nt" else "mac"


def hosts(scheme):
    """这个方案能在哪些电脑上出包：登记表 targets.ios.hosts（mac / windows）；没写 = 只有 mac（下游做包工具要在这台电脑上跑，
    Windows 上能不能跑由下游包件决定，下游声明了才放开，#1272）"""
    return (scheme["targets"].get("ios") or {}).get("hosts") or ["mac"]


def eligibility(scheme, game, lang="zh", host=None):
    """(能选, 原因)。① 这台电脑出不了这个方案的包（登记表 hosts 没有本机平台）；② 下游按某一版程序逐字节改写，别的版本做不出来：
    原因写清只支持哪一版、现在是哪一版、怎么办（lang = zh / en）"""
    if (host or HOST) not in hosts(scheme):
        if lang == "en":
            return False, f"{scheme['name']} can be built on a Mac only for now; use S2Arm on a Mac to choose it"
        return False, f"{scheme['name']} 目前只能在 Mac 上出包：用 Mac 版 S2Arm 才能选它"  # 非玩家句
    need = scheme["needs"].get("updateVersion")
    if need is None:
        return True, ""
    want = scheme["needs"].get("updateDisplay") or f"v{need}"
    up = update_of(game)
    if up and up["version"] == need:
        return True, ""
    have = (up.get("display") or "v%d" % up["version"]) if up else ""
    if lang == "en":
        now = f"you imported {have}" if up else "you have not imported an update"
        return False, f"{scheme['name']} supports update {want} only, and {now}. Import update {want} to choose it"
    return False, f"{scheme['name']} 只支持 {want} 更新，{f'你导入的是 {have}' if up else '你还没导入更新'}。导入 {want} 更新后可选"  # 非玩家句


def describe(c, game, schemes=None):
    """读库时附在每款游戏上的 downstream 字段（没命中 → None）：方案、能不能选与原因、终端、确认页文案、玩家上次的选择（None = 没选过，第一次导出弹确认页）"""
    s = match(game, schemes, c)
    if not s:
        return None
    ok, why = eligibility(s, game)
    choice = read(_choice_path(c, game["id"], create=False), None)
    return dict(id=s["id"], name=s["name"], repo=s["repo"], tag=s["bundle"]["tag"], commit=s["bundle"]["commit"], license=s["license"],
                targets=sorted(s["targets"]), eligible=ok, reason=dict(zh=why, en=eligibility(s, game, "en")[1]), copy=s["copy"],   # 界面按语言挑
                choice=choice.get("scheme") if isinstance(choice, dict) else None)


def _choice_path(c, gid, create=True):
    import layout
    return layout.path(c, gid, CHOICE, create=create)


def set_choice(c):
    """作业 downstreamChoice：记玩家对这款的选择（scheme = 方案 id；"" = 仍用原版）。只记，不出包"""
    gid = (c.r.get("gameId") or "").upper()
    want = c.r.get("scheme") or ""
    game = next((g for g in c.catalog()["games"] if g["id"].upper() == gid), None)
    if not game:
        raise Failure("游戏库里没有这款游戏。")
    if want:
        s = requested(c, game)
        ok, why = eligibility(s, game)
        if not ok:
            raise Failure(why, code="downstream_ineligible")
    atomic(_choice_path(c, gid), dict(scheme=want, at=time.time()))
    return dict(gameId=gid, scheme=want)


def requested(c, game):
    """这一单走不走下游：请求带 scheme 键就按它（"" = 原版）；不带就按玩家在确认页记下的选择（这款文件夹 downstream.json）。
    这样各个前端（两版 Mac 启动器、出包编排的子作业、s2armctl）只管弹确认页记选择，出包 / 装机请求不用各自加字段。→ 方案或 None（原版）"""
    if "scheme" in c.r:
        want = c.r.get("scheme") or ""
    else:
        choice = read(_choice_path(c, game.get("id", ""), create=False), None) if game.get("id") else None
        want = (choice or {}).get("scheme") or "" if isinstance(choice, dict) else ""
    if not want:
        return None
    s = match(game, c=c)
    if not s and not load(c=c):   # 登记表读不了：当没有下游方案，按原版出包（load 已打黄）
        return None
    if not s or s["id"] != want:
        raise Failure("这款游戏没有这个下游方案。", code="job_failed")
    return s


# ---------- 下游包件（一边出包一边下载） ----------

def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def bundle_dir(c, scheme):
    b = scheme["bundle"]
    return contained(c.private, c.private / "downstream" / scheme["id"] / b["sha256"][:16])


def fetch_bundle(c, scheme, progress=None):
    """下载并解开登记的下游包件 → 解开的目录（里面 bundle.json、shell.zip、src/）。已解开且核过就直接用。
    逐个地址试，下完核 SHA-256，核不上不用；bundle.json 的提交号必须是登记的那个（两边版本可追溯）"""
    b = scheme["bundle"]
    if not b.get("sha256") or not b.get("urls"):
        raise Failure(f"{scheme['name']} 的包件还没上线，现在只能用原版方案出包。", code="download_failed")
    root = bundle_dir(c, scheme)
    ok = root / ".ok"
    if ok.is_file() and ok.read_text().strip() == b["sha256"]:
        return root
    root.mkdir(parents=True, exist_ok=True)
    z = root.parent / (b["sha256"][:16] + ".zip")
    # 维护者 11-17（玩家判断不了的我们替他判）：核不上不装坏的那份，自动重下一遍；重下还不对才报。
    #   SHA 不对：每个地址最多下两遍；内容（提交号 / shell.zip / src/）和登记的不一致：删掉这份、整件再下一遍
    for attempt in (1, 2):
        last = ""
        if not (z.is_file() and file_sha256(z) == b["sha256"]):
            z.unlink(missing_ok=True)
            for url in [u for u in b["urls"] for _ in (1, 2)]:
                part = z.with_suffix(".part")
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "S2Arm"}), timeout=60) as r, open(part, "wb") as f:
                        total, done = int(r.headers.get("Content-Length") or 0), 0
                        for chunk in iter(lambda: r.read(1 << 20), b""):
                            f.write(chunk); done += len(chunk)
                            if progress and total:
                                progress(done, total)
                    if file_sha256(part) != b["sha256"]:
                        last = "校验不对"; part.unlink(missing_ok=True); continue  # 非玩家句
                    os.replace(part, z); break
                except OSError as e:   # urllib 的网络错误都是 OSError 子类
                    last = str(e); part.unlink(missing_ok=True)
            else:
                raise Failure(f"{scheme['name']} 的包件下载不下来：{last}。检查网络后再点一次。", code="download_failed")
        tmp = Path(tempfile.mkdtemp(prefix="x-", dir=root.parent))
        try:
            with zipfile.ZipFile(z) as zf:
                zf.extractall(tmp)
            info = read(tmp / "bundle.json", {})
            if info.get("commit") != b["commit"] or not (tmp / "shell.zip").is_file() or not (tmp / "src").is_dir():
                z.unlink(missing_ok=True)   # 不留这份：下次也不会再用它
                if attempt == 1:
                    continue
                raise Failure(f"{scheme['name']} 的包件内容和登记的不一致（提交 {str(info.get('commit'))[:12]}），重新下载后还是不对：没有用它。", code="download_failed")
            shutil.rmtree(root, ignore_errors=True)
            os.replace(tmp, root)
            ok.write_text(b["sha256"])
            return root
        except zipfile.BadZipFile:
            z.unlink(missing_ok=True)
            if attempt == 2:
                raise Failure(f"{scheme['name']} 的包件解不开，重新下载后还是不对：没有用它。", code="download_failed")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return root


class BundleFetch:
    """开工时起：后台下载包件，与解包并行；join() 取结果（失败原样抛）"""

    def __init__(self, c, scheme):
        self.c, self.scheme, self.result, self.error = c, scheme, None, None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        try:
            self.result = fetch_bundle(self.c, self.scheme)
        except BaseException as e:   # 交给 join 在主线程原样抛
            self.error = e

    def start(self):
        self.thread.start(); return self

    def join(self):
        self.thread.join()
        if self.error:
            raise self.error
        return self.result


# ---------- 出 iPhone 包 ----------

def _check_exefs(scheme, extraction):
    for name, want in (scheme["needs"].get("exefsSha256") or {}).items():
        f = Path(extraction) / "exefs" / name
        if not f.is_file() or file_sha256(f) != want:
            disp = scheme["needs"].get("updateDisplay", "")
            raise Failure(f"解包出的游戏程序 {name} 不是 {scheme['name']} 要的那一版{f'（{disp}）' if disp else ''}，做不出来。"  # 非玩家句
                          f"导入 {disp or '对应版本的'} 更新后再导出。", code="downstream_ineligible")  # 非玩家句


def _downstream_input(c, extraction, work):
    """给下游做包工具的游戏目录（#1570）：下游工具按逐文件的 exefs/ + romfs/（或 ExeFS/ + RomFS/）读游戏。0.5.7 起共用解包不落散文件，
    RomFS 是单个标准镜像 romfs.std（或 0.6.0 一款一份的 game.img），工具找不到 RomFS/data/build_manifest.psv、退出 1。
    有 romfs/ 真目录 → 原样交解包目录；只有镜像 → 在 work 下搭一个输入目录：解包目录里别的东西（exefs/、ctl/ 等）逐文件硬链接进去，
    romfs/ 从镜像逐文件展开（macOS / Windows 都没有区间克隆，只能真写一份；工具跑完由调用方删）。→ (交给工具的目录, 要删的展开目录或 None)"""
    ex = Path(extraction)
    if (ex / "romfs").is_dir():
        return ex, None
    std, img = ex / "romfs.std", ex / "game.img"
    if not std.is_file() and not img.is_file():
        return ex, None   # 没有 RomFS：照交，缺什么由工具自己报
    from onerom import _romfs_img
    m = _romfs_img(c)
    rom = m.RomfsImage(std) if std.is_file() else m.RomfsImage.in_img(str(img))
    view = Path(work) / "downstream-input"
    if view.exists() or view.is_symlink():
        shutil.rmtree(view)
    view.mkdir(parents=True)
    def link(a, b):   # 硬链接（同卷不另占盘；Windows 普通用户建不了软链、硬链接可以），建不了退成复制
        try:
            os.link(a, b)
        except OSError:
            shutil.copy2(a, b)
    for p in ex.iterdir():
        if p.name in ("romfs", "romfs.std", "game.img"):
            continue
        if p.is_dir():
            shutil.copytree(p, view / p.name, copy_function=link)
        else:
            link(p, view / p.name)
    romfs = view / "romfs"
    files = rom.files()
    total, done = sum(size for _, size in files.values()), 0
    c.emit("message", "正在把游戏资源镜像展开成下游工具要的逐文件目录")  # 非玩家句
    for d in rom.dirs():
        (contained(romfs, romfs / d) if d else romfs).mkdir(parents=True, exist_ok=True)
    for rel, (_, size) in files.items():
        c.check()
        dst = contained(romfs, romfs / rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        with rom.open(rel) as src, open(dst, "wb") as out:
            shutil.copyfileobj(src, out, 1 << 22)
        done += size
        c.progress(done, total)
    return view, romfs


def out_dir(c, gid, scheme):
    import layout
    return layout.path(c, gid, "downstream", scheme["id"])


def build_ios(c, game, scheme):
    """走下游方案出 iPhone 包：后台下包件 ‖ 共用解包 → 核程序版本 → 包件里的做包工具（S2Arm 自带的 Python）→ 安装包 + S2Arm 资源包 → 记版本"""
    t = scheme["targets"].get("ios")
    if not t:
        raise Failure(f"{scheme['name']} 没登记 iPhone / iPad。", code="job_failed")
    # 不按导入更新的版本号预先拦（预检清单 #63）：解包后 _check_exefs 按程序字节核是不是那一版，真不对才停（界面上的 eligibility 只当提示）
    from build import ensure_extract
    import milestones as ms
    gid = game["id"].upper()
    out = out_dir(c, gid, scheme)
    logs = c.private / "logs" / c.task
    logs.mkdir(parents=True, exist_ok=True)
    fetch = BundleFetch(c, scheme).start()
    ms.plan(c, sum(p.get("size", 0) for p in {p["sha256"]: p for p in _selected(game)}.values()) / 1e9, "ipa_downstream")
    extraction = ensure_extract(c, game, _selected(game), c.env(), logs)   # 进「解包」里程碑；包件同时在后台下
    _check_exefs(scheme, extraction)
    bundle = fetch.join()
    ms.enter(c, "ipa")
    ipa = out / f"{scheme['id']}.ipa"
    pack = out / f"{scheme['id']}资源包"  # 非玩家句
    ipa.unlink(missing_ok=True)
    env = dict(c.env(), DM_ROOT=str(out / "work"), D2RM_S2ARM_PACK=str(pack), PYTHONUTF8="1")
    game_dir, expanded = _downstream_input(c, extraction, out / "work")
    try:
        c.run([sys.executable, bundle / "src" / t["tool"], bundle / "shell.zip", game_dir, ipa], logs / "downstream-ios.log", env)
    finally:
        if expanded is not None:
            shutil.rmtree(game_dir, ignore_errors=True)   # 展开的 RomFS 是一整份游戏资源：做完就删
    if not ipa.is_file() or not (pack / "manifest.json").is_file():
        raise Failure(f"{scheme['name']} 做包结束了，但没写出安装包或资源包，请查看日志。", code="package_failed")
    info = read(bundle / "bundle.json", {})
    record = dict(scheme=scheme["id"], name=scheme["name"], repo=scheme["repo"], tag=info.get("tag"), commit=info.get("commit"),
                  product=info.get("product"), ipa=str(ipa), pack=str(pack), ipaSha256=file_sha256(ipa), at=time.time())
    atomic(out / "record.json", record)
    return dict(outputPath=str(out), ipa=str(ipa), ipaBytes=ipa.stat().st_size, downstream=record, graphicsMode="downstream")


# ---------- 装到 iPhone ----------

def last_record(c, gid, scheme):
    import layout
    rec = read(layout.path(c, gid, "downstream", scheme["id"], "record.json", create=False), None)
    return rec if isinstance(rec, dict) and Path(rec.get("ipa") or "").is_file() and Path(rec.get("pack") or "").is_dir() else None


def bundle_id(scheme, team):
    return f"io.s2arm.ds.{scheme['id']}.{team.lower()}"


def install_ios(c, game, scheme):
    """独立 App 装到 iPhone（Windows 见 install_ios_win，入参与返回同形）：改包名 → 按登记的权限申请描述文件、用玩家 Apple ID 签 → devicectl 覆盖装（存档在 App 里，不卸载）
    → 资源包用 S2Arm 的推送推进去，传完即装好（App 第一次打开时自己解开）"""
    if os.name == "nt":
        return install_ios_win(c, game, scheme)
    import install as inst
    from diag import devicectl
    t = scheme["targets"]["ios"]
    gid = game["id"].upper()
    rec = last_record(c, gid, scheme)
    if not rec:
        raise Failure(f"这款还没用 {scheme['name']} 出过 iPhone 包：先导出 iPhone 包。", code="job_failed")
    c.begin("找签名账号与 iPhone", 1, 4)
    team = inst.pick_team(inst.xcode_teams(c.env()), c.r.get("teamId"))
    dev = inst.phone(c)
    udid = inst.udid_of(c, dev["id"])
    bid = bundle_id(scheme, team["id"])
    stage = Path(tempfile.mkdtemp(prefix="s2a-ds-install-", dir=c.private))
    log = c.private / "logs" / (c.task + "-install.log")
    try:
        r = subprocess.run(["/usr/bin/ditto", "-x", "-k", rec["ipa"], str(stage)], capture_output=True, text=True)
        app = next((p for p in (stage / "Payload").glob("*.app") if p.is_dir()), None)
        if r.returncode or not app:
            raise Failure("解不开 iPhone 包：" + (r.stderr.strip()[-200:] or rec["ipa"]), code="job_failed")  # 非玩家句
        info = app / "Info.plist"
        pl = plistlib.loads(info.read_bytes()); pl["CFBundleIdentifier"] = bid
        if c.r.get("displayName"):   # 可选：主屏显示名（手测时与手机上同名的别的包区分开）；缺省用下游包自己的
            pl["CFBundleDisplayName"] = str(c.r["displayName"])[:30]
        info.write_bytes(plistlib.dumps(pl))
        ents = stage / "app.entitlements"
        # #897：免费个人团队签不了「扩展虚拟寻址」，带上它 Xcode 直接拒建描述文件（「Personal development teams … do not support the Extended Virtual Addressing
        #   capability」）。同 pack/dev_sign.py NEED / devcert.py WANT 的口径：免费团队只申请提高内存上限，付费团队才带扩展寻址（下游壳缺它只是地址窗口小一点，上游同样摘掉）
        ents.write_bytes(plistlib.dumps({k: True for k in install_entitlements(t, team)}))
        c.begin("用你的 Apple ID 签名", 2, 4)
        try:
            c.run(["bash", c.engine / "pack/ensure_profile.sh", bid, team["id"], ents] + ([udid] if udid else []), log)
            c.run([sys.executable, c.engine / "pack/dev_sign.py", app, bid, team["id"], ents], log)
        except Failure as e:
            if e.code != "tool_exit":
                raise
            from errors import tool_reason
            raise Failure("签名没成：" + tool_reason(log), code=inst.classify(log.read_text(errors="replace")[-8000:] if log.is_file() else "")) from e  # 非玩家句
        c.begin("装到 iPhone", 3, 4)
        rc, _, err = devicectl(c, "device", "install", "app", "--device", dev["id"], str(app), timeout=1800)
        if rc:
            raise Failure("装不上 iPhone：" + (err.strip()[-2000:] or f"devicectl 退出 {rc}"), code=inst.classify(err, default="device_install_failed"))  # 非玩家句
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    c.begin("把游戏资源推进 iPhone（只推变了的文件；第一次要几分钟）", 4, 4)
    files, size = inst.push_pack(c, dev["id"], bid, Path(rec["pack"]), udid=udid)   # 单款 App：文档根 Documents；传完即装好，App 第一次打开时自己解开（不由电脑拉起）
    record = dict(rec, installed=dict(at=time.time(), device=dev["name"], bundleId=bid, team=team["name"], free=team["free"]))
    atomic(out_dir(c, gid, scheme) / "record.json", record)
    # openToFinish：两端完成页写「已传到 iPhone，打开会自动完成安装」，并照常提示第一次打开前信任开发者（免费账号）
    return dict(bundleId=bid, device=dev["name"], team=team["name"], free=team["free"], packFiles=files, packBytes=size, downstream=record, openToFinish=True)


def adhoc_entitle(c, app, ents, log):
    """Windows：plumesign 没有指定权限的参数，按主程序已有签名里的权限去申请（S2Arm 壳同此：出壳时 ad-hoc 签进 pack/app.entitlements）。
    下游壳不带签名：先用随包 rcodesign（pack/jobs/devcert.py rcodesign_path）把这几项 ad-hoc 签进去，再交 plumesign 用 Apple ID 签"""
    import devcert
    ent = Path(app).parent / "downstream.entitlements"
    ent.write_bytes(plistlib.dumps({k: True for k in ents}))
    eargs, ecwd = devcert.rcodesign_ents(ent)   # Windows 盘符：-e 按第一个冒号拆（D-J7CH），只传文件名
    c.run([devcert.rcodesign_path(c), "sign", *eargs, str(Path(app).resolve())], log, cwd=ecwd)


def _zip_payload(stage, out):
    """stage/Payload → out（.ipa）：plumesign 只对 .ipa 输入给 -o 签好的包（install_win 从它读实际包名）"""
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted((stage / "Payload").rglob("*")):
            z.write(f, f.relative_to(stage).as_posix())


def install_ios_win(c, game, scheme):
    """Windows 版独立 App 装机（同 install_ios 的入参与返回）：Impactor 当前账号定包名 → rcodesign ad-hoc 签进权限 → plumesign 用 Apple ID 签名装机
    （pack/orch/install_win.py，同容器装机）→ 资源包用 S2Arm 的推送（install_win.push_pack，s2a-devpush）推进去，传完即装好（App 第一次打开时自己解开）。
    Windows 读不出账号是不是付费团队：权限按免费团队申请（只要提高内存上限，同 S2Arm 容器在 Windows 上的口径）"""
    import argparse
    import install as inst
    t = scheme["targets"]["ios"]
    gid = game["id"].upper()
    rec = last_record(c, gid, scheme)
    if not rec:
        raise Failure(f"这款还没用 {scheme['name']} 出过 iPhone 包：先导出 iPhone 包。", code="job_failed")
    c.begin("找签名账号与 iPhone", 1, 4)
    W = inst.win_install_mod(c)
    b = W.impactor.bundled(c.r.get("resources")) or {}
    exe = W.plumesign_path(b.get("plumesign"))
    if W.impactor.select_only_account(exe):   # 只存了一个 Apple ID 却没选中（D-ZM37）：先选上，包名与签名都认选中的那个（同 WinPhone.install）
        c.emit("message", "Impactor 里存着一个 Apple ID 但没选中，已替你选上")
    team = W.impactor.selected_team()
    if not team:
        raise Failure("读不到 Impactor 当前选中的 Apple ID：在 Impactor 里登录并选中你的 Apple ID 后再装。", code="apple_not_signed_in")
    udid = inst.win_udid(c, W)
    bid = bundle_id(scheme, team)
    log = c.private / "logs" / (c.task + "-install.log")
    log.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="s2a-ds-install-", dir=c.private))
    try:
        try:
            with zipfile.ZipFile(rec["ipa"]) as z:
                z.extractall(stage)
        except (OSError, zipfile.BadZipFile) as e:
            raise Failure(f"解不开 iPhone 包：{e}", code="job_failed") from e  # 非玩家句
        app = next((p for p in (stage / "Payload").glob("*.app") if p.is_dir()), None)
        if not app:
            raise Failure("解不开 iPhone 包：" + rec["ipa"], code="job_failed")  # 非玩家句
        c.begin("写进 App 要申请的权限", 2, 4)
        adhoc_entitle(c, app, install_entitlements(t, {"free": True}), log)
        ipa = stage / f"{scheme['id']}.ipa"
        _zip_payload(stage, ipa)
        c.begin("签名并装到 iPhone（Impactor 官方命令行 plumesign）", 3, 4)
        name = str(c.r["displayName"])[:30] if c.r.get("displayName") else None
        ns = argparse.Namespace(ipa=str(ipa), udid=udid, name=name, plumesign=b.get("plumesign"), log=str(log), bundle=bid)
        try:
            bid = W.install_app(ns, say=lambda m: inst.win_say(c, m))
        except W.Fail as e:
            raise inst.win_install_failure(e) from e
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    c.begin("把游戏资源推进 iPhone（只推变了的文件；第一次要几分钟）", 4, 4)
    devpush = c.engine / "Binaries/Prepare/devpush/s2a-devpush.exe"
    try:   # 单款 App：文档根 Documents、不起 App 解包（同 Mac install_ios 的 push_pack 口径）
        files, size = W.push_pack(udid, bid, rec["pack"], str(devpush) if devpush.is_file() else None, accept_low_space=c.r.get("acceptLowSpace") is True,
                                  say=lambda m: c.emit("message", m), progress=lambda d, tot, k, n: inst.push_progress(c, d, tot, k, n),
                                  stage=lambda nm, d=None, tot=None: inst.push_stage(c, nm, d, tot))
    except W.Fail as e:
        raise Failure(str(e), code=e.err or "resource_transfer_failed") from e
    record = dict(rec, installed=dict(at=time.time(), device=udid, bundleId=bid, team=team))
    atomic(out_dir(c, gid, scheme) / "record.json", record)
    return dict(bundleId=bid, device=udid, team=team, packFiles=files, packBytes=size, downstream=record, openToFinish=True)
