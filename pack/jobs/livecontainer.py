# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Paired-device access to S2Arm inside a LiveContainer private data container."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import sys
import tempfile
import time
from urllib.parse import urlencode

from core import Failure, atomic
import diag
import layout

KEY = "liveContainerTargets"
SELECTED = "liveContainerTarget"
STATE = "liveContainerState"


def component(value):
    return isinstance(value, str) and value not in ("", ".", "..") and not any(c in value for c in "/\\\0")


class Files:
    def __init__(self, c, device, bundle):
        self.c, self.device, self.bundle = c, device, bundle

    def call(self, *args, container=True, timeout=60, trailing_args=()):
        domain = ("--domain-type", "appDataContainer", "--domain-identifier", self.bundle) if container else ()
        rc, data, error = diag.devicectl(self.c, *args, "--device", self.device, *domain, "--timeout", str(timeout),
                                       timeout=timeout + 5, trailing_args=trailing_args)
        if rc:
            if "DeviceLocked" in error or "device is locked" in error.lower():
                raise Failure("iPhone 已锁屏，宿主文件通道无法准备；请解锁手机后重试。", code="device_not_ready")
            raise Failure("LiveContainer 文件访问失败：" + error[-600:], code="device_not_ready")
        return data.get("result") or {}

    def apps(self):
        return self.call("device", "info", "apps", container=False).get("apps") or []

    def listdir(self, path):
        files = self.call("device", "info", "files", "--subdirectory", path, "--no-recurse").get("files") or []
        return [PurePosixPath(f.get("relativePath") or f.get("name") or "").name for f in files]

    def get(self, remote, local):
        self.call("device", "copy", "from", "--source", remote, "--destination", str(local))
        return Path(local).read_bytes()

    def plist(self, path):
        with tempfile.TemporaryDirectory(dir=self.c.private) as work:
            return plistlib.loads(self.get(path, Path(work) / "info.plist"))

    def json(self, path):
        with tempfile.TemporaryDirectory(dir=self.c.private) as work:
            try:
                return json.loads(self.get(path, Path(work) / "state.json"))
            except (ValueError, UnicodeError) as error:
                raise Failure("手机上的游戏状态文件读不懂，请打开 S2Arm 游戏库后重试。",
                              code="device_not_ready") from error

    def put(self, local, remote):
        # Reuse the existing bounded large-file fallback policy and AFC when available.
        sys.path.insert(0, str(self.c.engine / "tools"))
        import push_pack
        with tempfile.TemporaryDirectory(dir=self.c.private) as work:
            tool = self.c.engine / "Binaries/Prepare/devpush" / push_pack.EXE
            env = dict(self.c.env(), S2A_DEVPUSH_DOCUMENTS="1",
                       S2A_DEVICECTL=str(diag.COREDEVICE / "Resources/bin/devicectl"))
            client = push_pack.Devicectl(self.device, self.bundle, work, udid=self.device,
                                        devpush=str(tool) if tool.is_file() else None, env=env)
            client.say = lambda text: self.c.emit("message", text)
            try:
                client.put_big(local, remote)
            except push_pack.Fail as error:
                raise Failure(str(error), code="resource_transfer_failed") from error

    def put_directory(self, local, remote):
        parent, name = remote.rsplit("/", 1)
        with tempfile.TemporaryDirectory(dir=self.c.private) as work:
            wrapper = Path(work) / "contents"
            shutil.copytree(local, wrapper / name)
            for directory in (wrapper, *(p for p in wrapper.rglob("*") if p.is_dir())):
                directory.chmod(0o755)
            # The destination itself is created by CoreDevice as root. Transfer the
            # directory as a child of its existing parent so source ownership applies.
            self.call("device", "copy", "to", "--source", str(wrapper), "--destination", parent,
                      "--remove-existing-content", "false", timeout=120 + sum(p.stat().st_size for p in wrapper.rglob("*") if p.is_file()) // (10 << 20))

    def launch(self, target):
        url = target["scheme"] + "://livecontainer-launch?" + urlencode({
            "bundle-name": target["guest"], "container-folder-name": target["container"]})
        # launch consumes every argument after the bundle as child argv, including output flags.
        self.call("device", "process", "launch", "--payload-url", url, container=False, trailing_args=(self.bundle,))


def targets(c, device):
    hosts = Files(c, device, "").apps()
    found = []
    failures = []
    for host in hosts:
        name, bid = host.get("name") or "", host.get("bundleIdentifier") or ""
        if not re.fullmatch(r"LiveContainer\d*", name, re.I) or not bid:
            continue
        files = Files(c, device, bid)
        try:
            guests = files.listdir("Documents/Applications")
        except Failure as error:
            failures.append(error)
            continue
        for guest in guests:
            if not component(guest) or not guest.lower().startswith("io.s2arm.games") or not guest.endswith(".app"):
                continue
            if re.search(r"\.[0-9a-f]{16}(?:\.[a-z0-9]+)?\.app$", guest, re.I):
                continue  # Standalone game apps are not the S2Arm game-library receiver.
            root = "Documents/Applications/" + guest
            try:
                info = files.plist(root + "/Info.plist")
                if info.get("CFBundleExecutable") != "S2Arm":
                    continue
                lc = files.plist(root + "/LCAppInfo.plist")
            except Failure as error:
                failures.append(error)
                continue
            except (ValueError, plistlib.InvalidFileException):
                continue
            containers = lc.get("LCContainers") or [{"folderName": lc.get("LCDataUUID")}]
            for item in containers:
                folder = item.get("folderName")
                if item.get("bookmarkData") or not component(folder):
                    continue
                home = "Documents/Data/Application/" + folder
                try:
                    files.listdir(home + "/Documents")
                except Failure as error:
                    failures.append(error)
                    continue
                identity = json.dumps([bid, guest, folder], separators=(",", ":"))
                found.append(dict(id="lc:" + hashlib.sha256(identity.encode()).hexdigest()[:24],
                                  hostBundleId=bid, hostName=name, scheme=name.lower(), guest=guest,
                                  container=folder, home=home,
                                  displayName=name + " / " + (info.get("CFBundleDisplayName") or "S2Arm") + " / " + (item.get("name") or folder)))
    if not found and failures:
        raise failures[0]
    return found


def candidates(found):
    return [dict(bundleId=t["id"], team="", byThisLauncher=False, identityTeam=None, displayName=t["displayName"]) for t in found]


def read_ledger(files, target):
    data = files.json(target["home"] + "/Documents/.s2a-games.json")
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("games"), dict):
        raise Failure("手机上的游戏状态格式暂不支持，请打开 S2Arm 游戏库后重试。", code="device_not_ready")
    games = data["games"]
    if any(not isinstance(v, dict) or v.get("state") not in ("present", "removed") for v in games.values()):
        raise Failure("手机上的游戏状态记录不完整，请打开 S2Arm 游戏库后重试。", code="device_not_ready")
    return games


def refresh_state(c, device, target, rec, live):
    states = dict(rec.get(STATE) or {})
    cached = dict(states.get(target["id"]) or {})
    if live:
        files = Files(c, device, target["hostBundleId"])
        try:
            ledger = read_ledger(files, target)
            pending = set()
            if cached.get("sent"):
                import install
                docs = target["home"] + "/Documents"
                names = files.listdir(docs)
                for inbox in install.IMPORT_DIRS:
                    if inbox in names:
                        pending.update(files.listdir(docs + "/" + inbox))
            sent = {gid: dict(entry, imported=ledger.get(gid, {}).get("state") == "present"
                             and bool(entry.get("files")) and not pending.intersection(entry["files"]))
                    for gid, entry in (cached.get("sent") or {}).items()}
            cached.update(ledger=ledger, pending=sorted(pending), sent=sent, readAt=time.time())
            cached.pop("error", None)
        except Failure as error:
            cached["error"] = str(error)
    states[target["id"]] = cached
    rec[STATE] = states
    return cached


def game_rows(games, cached):
    rows = []
    for original in games:
        row = {k: v for k, v in original.items() if k != "reasons"}
        gid = row["gameId"].upper()
        ledger = cached.get("ledger")
        sent = (cached.get("sent") or {}).get(gid) or {}
        if cached.get("error") or ledger is None:
            row.update(state="unknown", reasons=[cached["error"]] if cached.get("error") else [])
        elif set(sent.get("files") or []).intersection(cached.get("pending") or []):
            row["state"] = "pending"
        elif sent and not sent.get("imported") and ledger.get(gid, {}).get("state") != "removed":
            row["state"] = "pending"
        else:
            row["state"] = "present" if ledger.get(gid, {}).get("state") == "present" else "notPushed"
            if ledger.get(gid, {}).get("state") == "removed":
                row["reasons"] = ["removed"]
        rows.append(row)
    return rows


def overview(c, phones):
    out = []
    for original in phones:
        row = dict(original)
        row.pop("liveContainerProbeError", None)
        device = row["device"]
        rec = layout.load_device(c, device)
        had_targets = KEY in rec
        found = rec.get(KEY) or []
        if c.r.get("probe") is True and row.get("online"):
            try:
                found = targets(c, device)
            except Failure as error:
                row["liveContainerProbeError"] = str(error)
                # A failed read is not evidence that the previously found guest was removed.
        if found:
            chosen = next((t for t in found if t["id"] == rec.get("chosenLCHostId")), None)
            direct = row.get("installed") and row.get("bundleId") and not row["bundleId"].startswith("lc:")
            if not chosen and len(found) == 1 and not direct:
                chosen = found[0]
            if chosen:
                row.update(installed=True, installedBy="external", bundleId=chosen["id"], shellCurrent=None,
                           signMode="external", actions=["exportShellIpa", "pushS2arm", "exportS2arm"], needsChoice=False)
                row["name"] = (original.get("name") or "iPhone") + " · " + chosen["hostName"]
                rec[SELECTED] = chosen
                cached = refresh_state(c, device, chosen, rec, c.r.get("probe") is True and bool(row.get("online"))
                                       and not row.get("liveContainerProbeError"))
                if row.get("liveContainerProbeError"):
                    cached["error"] = row["liveContainerProbeError"]
                row["games"] = game_rows(original.get("games") or [], cached)
                if cached.get("error"):
                    row["liveContainerStateError"] = cached["error"]
            elif not direct or not rec.get("chosenBundleId"):
                row.update(installed=True, installedBy=None, bundleId="", needsChoice=True, signMode=None,
                           actions=["chooseApp"])
                rec.pop(SELECTED, None)
                row["games"] = game_rows(original.get("games") or [], {})
            all_candidates = candidates(found)
            if direct:
                all_candidates += row.get("candidates") or [dict(bundleId=original["bundleId"], team="", byThisLauncher=original.get("installedBy") == "launcher", identityTeam=None)]
            if len(all_candidates) > 1:
                row["candidates"] = all_candidates
        else:
            rec.pop(SELECTED, None)
        if found or had_targets:
            rec[KEY] = found
            layout.save_device(c, device, rec)
        out.append(row)
    return out


def choose(c):
    device, requested = c.r.get("device"), c.r.get("bundleId")
    rec = layout.load_device(c, device)
    found = targets(c, device)
    target = next((t for t in found if t["id"] == requested), None)
    if target is None:
        raise Failure("选的 LiveContainer 内部 S2Arm 已不在这台设备上，请重新选择。", code="phone_app_gone")
    rec.update({KEY: found, SELECTED: target, "chosenLCHostId": requested})
    rec.pop("pendingChoice", None)
    layout.save_device(c, device, rec)
    return dict(device=device, bundleId=requested)


def selected(c):
    device = c.r.get("device")
    if not device:
        return None
    rec = layout.load_device(c, device)
    if rec.get(SELECTED):
        return rec[SELECTED]
    if rec.get(KEY) and not rec.get("chosenBundleId"):
        raise Failure("请先选择这台手机内要使用的 S2Arm 容器。", code="phone_app_choice_required",
                      facts=dict(device=device, candidates=candidates(rec[KEY])))
    return None


def push(c, game_ids):
    import install
    device = c.r["device"]
    cached = selected(c)
    found = targets(c, device)
    target = next((t for t in found if cached and t["id"] == cached["id"]), None)
    if target is None:
        raise Failure("LiveContainer 内部 S2Arm 容器已改变，请重新选择设备。", code="phone_app_gone")
    files = Files(c, device, target["hostBundleId"])
    docs = target["home"] + "/Documents"
    inboxes = files.listdir(docs)
    inbox = next((name for name in install.IMPORT_DIRS if name in inboxes), None)
    if inbox is None:
        files.launch(target)
        inbox = "Import Here"
        for _ in range(15):
            c.check()
            if inbox in files.listdir(docs):
                break
            time.sleep(1)
        else:
            raise Failure("S2Arm 还没建立导入目录，请在手机上打开它的游戏库后重试。", code="device_not_ready")
    state_path = Path(c.private) / "livecontainer_push.json"
    if c.r.get("resume") is True and not game_ids:
        try:
            previous = json.loads(state_path.read_text())
        except (OSError, ValueError):
            previous = {}
        if previous.get("device") != device or previous.get("target") != target["id"]:
            raise Failure("上次推送的设备或容器已改变，请重新选择游戏后推送。", code="device_not_ready")
        game_ids = [g for g in previous.get("games", []) if g not in previous.get("done", [])]
    if not game_ids:
        return dict(device=device, bundleId=target["hostBundleId"], games=[], rows=[], transport="livecontainer")
    state = dict(device=device, target=target["id"], games=list(game_ids), done=[])
    atomic(state_path, state)
    rows = []
    for index, raw_gid in enumerate(game_ids, 1):
        gid = str(raw_gid).upper()
        if re.fullmatch(r"[0-9A-F]{16}", gid) is None:
            raise Failure("游戏号无效，无法定位要推送的游戏。", code="job_failed")
        c.check()
        c.begin("准备推送到 LiveContainer 内部 S2Arm", index, len(game_ids))
        result = install.export_s2arm(c, gid, sign=False)
        sources = [Path(result["s2armPath"])]
        if result.get("resourcePath"):
            sources.append(Path(result["resourcePath"]))
        for source in sources:
            c.check()
            c.emit("message", "正在推送到 LiveContainer：" + source.name)
            files.put(source, docs + "/" + inbox + "/" + source.name)
        import mods
        home = mods.mods_dir(c, gid, create=False)
        enabled = [p for p in layout.entries(home) if p.is_dir() and not p.is_symlink() and not p.name.startswith(".")]
        if enabled:
            parent = docs + "/games/" + gid
            with tempfile.TemporaryDirectory(dir=c.private) as work:
                stage_games = Path(work) / "games"
                stage_mods = stage_games / gid / "mods"
                stage_mods.mkdir(parents=True)
                for mod in enabled:
                    shutil.copytree(mod, stage_mods / mod.name, ignore=lambda d, names: [
                        name for name in names if Path(d, name).is_symlink() or name == ".DS_Store" or name.startswith("._")])
                # Copy new parent directories explicitly with their source metadata, not as
                # devicectl's implicit root-owned parents. Never replace the games/SaveData tree.
                try:
                    game_children = files.listdir(parent)
                except Failure:
                    game_children = None
                if game_children is None:
                    try:
                        files.listdir(docs + "/games")
                        games_present = True
                    except Failure:
                        games_present = False
                    files.put_directory(stage_games / gid if games_present else stage_games,
                                        parent if games_present else docs + "/games")
                else:
                    c.emit("message", "正在同步 Mod：" + "、".join(p.name for p in enabled))
                    files.put_directory(stage_mods, parent + "/mods")
        files.launch(target)
        rec = layout.load_device(c, device)
        states = dict(rec.get(STATE) or {})
        cached = dict(states.get(target["id"]) or {})
        sent = dict(cached.get("sent") or {})
        sent[gid] = dict(at=time.time(), files=[p.name for p in sources], s2armSha256=result.get("sha256"),
                         mods=[p.name for p in enabled], imported=False)
        cached["sent"] = sent
        states[target["id"]] = cached
        rec[STATE] = states
        cached = refresh_state(c, device, target, rec, True)
        imported = cached.get("sent", {}).get(gid, {}).get("imported", False) and not cached.get("error")
        if not imported and not cached.get("error"):
            c.emit("message", "文件已发送，正在等待手机游戏库确认导入。")
            deadline = time.monotonic() + install.IMPORT_WAIT_S[1]
            while not imported and not cached.get("error") and time.monotonic() < deadline:
                c.check()
                time.sleep(2)
                cached = refresh_state(c, device, target, rec, True)
                imported = cached.get("sent", {}).get(gid, {}).get("imported", False) and not cached.get("error")
        layout.save_device(c, device, rec)
        rows.append(dict(gameId=gid, ok=True, mods=[p.name for p in enabled], imported=bool(imported)))
        state["done"].append(raw_gid)
        atomic(state_path, state)
    pending = any(not row["imported"] for row in rows)
    return dict(device=device, bundleId=target["hostBundleId"], installedBy="external", transport="livecontainer",
                games=[row["gameId"] for row in rows], rows=rows, openToFinish=pending,
                unpackPending="文件已发送到 LiveContainer 内部 S2Arm；回到游戏库完成导入，Mod 下次启动游戏时生效。" if pending else None)
