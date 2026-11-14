"""拉回 iPhone / iPad 上的诊断（Mac 前端「拉回 iPhone 诊断…」，用户体验线 10-23）。

用系统已装 CoreDevice 框架里的 devicectl（不经 Xcode 的包装脚本，见 COREDEVICE）：列出已连接的 iOS 设备 → 找 S2Arm 打的 App（包名 io.s2arm.* / io.s2arm-exp.* / local.s2arm.*，
AltStore 重签后会在后面加团队号，按前缀认）→ 从 App 数据目录只拉诊断要的文件（Documents/diag 里 App 导出的诊断包、最近 3 次
会话的 host.log、frames.tsv、threads.txt、unpack.log、metrickit/），不拉存档和资源包 → 放进 <私有目录>/diagnostics/<时间-随机>/<设备>_<包名>-随机/。
请求里给 device（设备号或名字）就只拉那一台。
"""
from __future__ import annotations
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from core import Failure

PREFIXES = ("io.s2arm.", "io.s2arm-exp.", "local.s2arm.", "s2arm.")
# 只拉这些（相对 App 数据目录；Documents/logs = os.c 每局一份的往局日志 host-<起局时刻>.log）；存档（bis/user/save）、资源包、密钥都不碰
PULL_RECORD = "pull.json"   # 每次拉回的目录里：拉回时刻、来源设备（机型 / 系统）、各款文件数
ITEMS = ("Documents/diag", "Documents/host.log", "Documents/logs", "Documents/frames.tsv",
         "Documents/threads.txt", "Documents/unpack.log", "Documents/metrickit")


# 系统已装的 CoreDevice 框架（Xcode「附加组件」装进 /Library/Developer）。直接调它自带的 devicectl，不经 Xcode 的 usr/bin/devicectl：
#   那个是 zsh 包装脚本，所选 Xcode 期望的 CoreDevice 版本和已装的不同（10-26 Spare-host：启动器选 Xcode 27.1 要 651.13.5，系统装的是 Xcode 27.0 的 642.16）
#   就先跑 xcodebuild -runFirstLaunch 装组件 → 弹管理员密码框；启动器里每次探测都停在框上、60 秒超时（ssh 下没有图形界面、这步直接失败跳过，所以 1 秒）。
#   已装的 CoreDevice 本身能用；出包不替玩家装组件、不弹框。S2A_COREDEVICE 单测改位置
COREDEVICE = Path(os.environ.get("S2A_COREDEVICE", "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A"))
NO_COREDEVICE = "这台 Mac 没装 Xcode 的设备组件（CoreDevice），读不到连着的设备：打开一次 Xcode、按提示装附加组件后再试；也可以在出包页直接选机型"


DEVICECTL_TIMEOUT = 124   # devicectl 超时的返回码（同 coreutils timeout）


def devicectl(c, *args, timeout=120):
    exe = COREDEVICE / "Resources/bin/devicectl"
    if not (exe.is_file() and os.access(exe, os.X_OK)):
        return 127, {}, NO_COREDEVICE
    with tempfile.NamedTemporaryFile(suffix=".json", dir=c.private) as out:
        try:
            p = subprocess.run([str(exe), *args, "--json-output", out.name], env=c.env(), capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            # devicectl 会一直挂到超时（#333）：转成非零退出，不再裸 traceback 收场。原因如实只说「等了多久没返回」，不猜锁屏
            #   （启动器剃刀 H21：推送链实测锁屏照样能写，一律说「可能锁屏了」会把玩家指错方向）；要不要提示解锁由调用方按它知道的事实判
            return DEVICECTL_TIMEOUT, {}, f"devicectl 等了 {timeout} 秒没有返回，已停止等待"
        try:
            data = json.loads(Path(out.name).read_text() or "{}")
        except ValueError:
            data = {}
    return p.returncode, data, (p.stderr or p.stdout).strip()


# Apple Vision Pro（visionOS）：按 iPad 兼容 App 装（「Designed for iPad」），走和 iPad 同一条路——理论支持、未真机验证（没有实物）。
#   机型号以 RealityDevice 开头（本机 Xcode 的 XROS.platform 设备特征库：RealityDevice14,1 = Apple Vision Pro、17,1 = M5 款）；
#   devicectl 给它报的 platform 写法没有公开资料，visionOS / xrOS 两种都认，机型号前缀兜底
VISION_PLATFORMS = ("visionOS", "xrOS")


def _hw(d):
    """devicectl 设备（hardwareProperties 下）或 target 行（顶层 productType / platform）都认"""
    return d.get("hardwareProperties") or d


def is_vision(d):
    h = _hw(d)
    return (h.get("productType") or "").startswith("RealityDevice") or h.get("platform") in VISION_PLATFORMS


def is_mobile(d):
    """能装 iPhone / iPad 版 S2Arm 的设备：iPhone、iPad，以及按 iPad 兼容装的 Apple Vision Pro"""
    return _hw(d).get("platform") in ("iOS", "iPadOS") or is_vision(d)


def is_candidate(d):
    """装机候选（install._pick_device、target.connected）：devicectl 列出的真设备都算——有硬件 UDID、或标着 physical、或有任何配对 / 连接信息。
    不看配对状态 / 是否在线 / 开发者服务这些值来筛——装不装得上让装的那一步说（11-13 维护者：别预先判断拦玩家）。
    只排除物理上装不了的：明确标成模拟器的、Mac / 手表 / 电视（这条装机链装不了 iOS App 上去）；平台没写或没见过的照收"""
    h, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if h.get("reality") == "simulated" or h.get("platform") in ("macOS", "watchOS", "tvOS"):
        return False
    return bool(h.get("udid") or h.get("reality") == "physical" or cp.get("pairingState") or cp.get("transportType"))


def is_physical(d):
    """devicectl 的这台是真机：有 reality 字段就照它（physical）；缺了（公开项目反映有 Xcode 测试版不再输出它，本机 26.6 / 27.0 / 27.1 都还有）
    按真机才有的特征认——有硬件 UDID、且有配对状态或连接方式（模拟器两样都没有）。原先缺字段就一台都认不出、整个装机找不到设备"""
    h, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if h.get("reality"):   # 键缺或值为 null / 空都按「没给」走下面的特征（诊断#091bcf：报告里只见 reality=None，分不出是缺键还是 null）
        return h["reality"] == "physical"
    return bool(h.get("udid")) and bool(cp.get("pairingState") or cp.get("transportType"))


def reachable(d):
    """连着线或隧道已通。数据线连着、已配对时隧道空闲是 disconnected，devicectl 用到会自己拉起（10-26 测试设备2 插着线被判「没连 iPhone」）"""
    cp = d.get("connectionProperties", {})
    return cp.get("tunnelState") == "connected" or (cp.get("transportType") in ("wired", "localNetwork") and cp.get("pairingState") == "paired")


def iml_hint(c, probe, app):
    """App 首启复核写的 Documents/diag/iml_probe.json（ios/iml_probe.m，签名里真实生效的权限）：has_iml_ent 为 false 就打一行黄字提示重签；
    文件没有 / 读不了 / 不是 false（true、null = 读不到）都不提示、不报错"""
    try:
        rec = json.loads(probe.read_text())
    except (OSError, ValueError):
        return
    if isinstance(rec, dict) and rec.get("has_iml_ent") is False:
        c.diagnostic(f"{app}：这台机上装的包签名丢了提高内存上限权限，大游戏容易被系统杀；用 Xcode / AltStore Classic v2.3 重签后重装",
                     code="iml_missing", severity="warning")


def game_ids(c):
    """这台电脑游戏库里的游戏号（试拉各款解包日志用）；库没建好 / 读不了给空"""
    try:
        return sorted({str(g.get("id", "")).upper() for g in c.catalog().get("games", []) if re.fullmatch(r"[0-9A-Fa-f]{16}", str(g.get("id", "")))})
    except Exception:   # 诊断拉取不因游戏库读不了而失败
        return []


def pull(c):
    c.begin("找已连接的 iPhone / iPad", 1, 3)
    rc, data, err = devicectl(c, "list", "devices")
    if rc:
        raise Failure("读不到设备列表：需要完整的 Xcode（devicectl）。" + (err.splitlines()[-1] if err else ""))
    want = (c.r.get("device") or "").strip()
    devices = [d for d in data.get("result", {}).get("devices", [])
               if is_mobile(d)
               and reachable(d)
               and (not want or want in (d.get("identifier"), d.get("hardwareProperties", {}).get("udid"), d.get("deviceProperties", {}).get("name")))]
    if not devices:
        raise Failure("没找到已连接的 iPhone / iPad：用数据线连上并解锁，在手机上点「信任这台电脑」，再试一次。")
    stamp = time.strftime("%m%d-%H%M%S")
    parent = c.private / "diagnostics"
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=stamp + "-", dir=parent))
    pulled, sources = [], []
    c.begin("找 S2Arm 打的游戏 App", 2, 3)
    for d in devices:
        dev = d["identifier"]
        hw = d.get("hardwareProperties", {})
        name = re.sub(r"[^\w.-]+", "_", hw.get("marketingName") or hw.get("productType") or "iPhone")
        # 来源设备只记机型和系统，不记设备号、不记玩家给设备起的名字（诊断包要交到公开帖子里）
        sources.append(dict(model=hw.get("marketingName") or hw.get("productType") or "", platform=hw.get("platform") or "",
                            os=d.get("deviceProperties", {}).get("osVersionNumber") or ""))
        rc, apps, _ = devicectl(c, "device", "info", "apps", "--device", dev)
        for app in apps.get("result", {}).get("apps", []):
            bid = app.get("bundleIdentifier", "")
            if not bid.startswith(PREFIXES):
                continue
            c.begin("拉回 " + (app.get("name") or bid), 3, 3)
            dest = Path(tempfile.mkdtemp(prefix=f"{name}_{bid}-", dir=root))
            got = 0
            for item in ITEMS:
                target = dest / Path(item).name
                rc, _, _ = devicectl(c, "device", "copy", "from", "--device", dev, "--domain-type", "appDataContainer",
                                     "--domain-identifier", bid, "--source", item, "--destination", str(target), timeout=300)
                if rc == 0:
                    got += 1
                elif target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)  # Only this failed copy in the new exclusive directory.
                else:
                    target.unlink(missing_ok=True)
            # 多款容器每款自己的解包日志 Documents/games/<游戏号>/unpack.log（#457：手机 host.log 写「资源包收推送：失败（见 unpack.log）」，
            #   原先只拉容器根上的 unpack.log，这一份没拉回、定不了因）。按这台电脑游戏库里的游戏号逐个试拉，机上没有的跳过；
            #   不列整个 games/ 目录：devicectl 列目录是递归的，资源包十万个文件
            for gid in game_ids(c):
                target = dest / "games" / gid / "unpack.log"
                target.parent.mkdir(parents=True, exist_ok=True)
                rc, _, _ = devicectl(c, "device", "copy", "from", "--device", dev, "--domain-type", "appDataContainer",
                                     "--domain-identifier", bid, "--source", f"Documents/games/{gid}/unpack.log", "--destination", str(target), timeout=120)
                if rc == 0 and target.is_file():
                    got += 1
                else:
                    target.unlink(missing_ok=True)
                    target.parent.rmdir()   # 本次新建的空目录
            if (dest / "games").is_dir() and not any((dest / "games").iterdir()):
                (dest / "games").rmdir()
            if got:
                pulled.append(dict(app=app.get("name") or bid, bundle=bid, files=got, path=str(dest)))
                iml_hint(c, dest / "diag" / "iml_probe.json", app.get("name") or bid)
    if not pulled:
        raise Failure("连着的设备上没找到 S2Arm 打的游戏 App，或者这些 App 还没运行过、没有日志。")
    # 这次拉回的来源与时刻：诊断包导出（library.diagnostics）收最近一次拉回的内容时写进 manifest
    (root / PULL_RECORD).write_text(json.dumps(dict(pulledAt=time.strftime("%Y-%m-%d %H:%M:%S %z"), devices=sources,
                                                    apps=[dict(app=p["app"], files=p["files"]) for p in pulled]), ensure_ascii=False), encoding="utf-8")
    return dict(outputPath=str(root), apps=pulled)
