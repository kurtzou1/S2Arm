# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import livecontainer
from core import Failure
if os.environ.get("S2A_LC_TEST_MODULE"):
    spec = importlib.util.spec_from_file_location("livecontainer", os.environ["S2A_LC_TEST_MODULE"])
    livecontainer = importlib.util.module_from_spec(spec)
    sys.modules["livecontainer"] = livecontainer
    spec.loader.exec_module(livecontainer)

HOST = "com.example.livecontainer.TEAM"
GUEST = "io.s2arm.games.app"
CONTAINER = "test-container"


class Files:
    def __init__(self, c, device, bundle):
        self.c, self.device, self.bundle = c, device, bundle

    def apps(self):
        return [{"name": "LiveContainer", "bundleIdentifier": HOST}]

    def listdir(self, path):
        if path == "Documents/Applications":
            return [GUEST, "com.other.app"]
        if path.endswith("/Documents"):
            return ["Import Here"]
        return []

    def plist(self, path):
        if path.endswith("/Info.plist"):
            return {"CFBundleIdentifier": "io.s2arm.games", "CFBundleExecutable": "S2Arm"}
        return {"LCDataUUID": CONTAINER, "LCContainers": [{"folderName": CONTAINER, "name": "Default"}]}

    def json(self, path):
        return {"version": 1, "games": {}}


class Discovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.c = types.SimpleNamespace(private=Path(self.temp.name), r={"probe": True, "liveContainer": True})

    def test_private_target_maps_guest_home(self):
        with patch.object(livecontainer, "Files", Files):
            targets = livecontainer.targets(self.c, "PHONE")
        self.assertEqual(len(targets), 1)
        self.assertEqual(targets[0]["hostBundleId"], HOST)
        self.assertEqual(targets[0]["home"], f"Documents/Data/Application/{CONTAINER}")
        self.assertEqual(targets[0]["guest"], GUEST)

    def test_external_bookmark_is_not_mistaken_for_private_container(self):
        old = Files.plist
        def plist(client, path):
            result = old(client, path)
            if path.endswith("/LCAppInfo.plist"):
                result["LCContainers"][0]["bookmarkData"] = b"external bookmark"
            return result
        with patch.object(livecontainer, "Files", Files), patch.object(Files, "plist", plist):
            self.assertEqual(livecontainer.targets(self.c, "PHONE"), [])

    def test_no_guest_does_not_claim_s2arm_installed(self):
        with patch.object(livecontainer, "Files", Files), patch.object(Files, "listdir", lambda self, p: []):
            self.assertEqual(livecontainer.targets(self.c, "PHONE"), [])

    def test_container_path_cannot_escape_host(self):
        old = Files.plist
        def plist(client, path):
            result = old(client, path)
            if path.endswith("/LCAppInfo.plist"):
                result["LCContainers"][0]["folderName"] = "../other"
            return result
        with patch.object(livecontainer, "Files", Files), patch.object(Files, "plist", plist):
            self.assertEqual(livecontainer.targets(self.c, "PHONE"), [])

    def test_overview_reuses_physical_device_and_preserves_fields(self):
        store = {}
        row = {"device": "PHONE", "name": "iPhone", "online": "network", "installed": False, "games": [{"gameId": "G"}]}
        with patch.object(livecontainer, "Files", Files), \
             patch.object(livecontainer.layout, "load_device", lambda c, key: dict(store.get(key, {}))), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: store.__setitem__(key, value)):
            result = livecontainer.overview(self.c, [row])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["device"], "PHONE")
        self.assertTrue(result[0]["installed"])
        self.assertEqual(result[0]["installedBy"], "external")
        self.assertEqual(result[0]["games"][0]["gameId"], row["games"][0]["gameId"])
        self.assertIn("liveContainerTarget", store["PHONE"])

    def test_multiple_containers_require_existing_choice_flow(self):
        old = Files.plist
        def plist(client, path):
            result = old(client, path)
            if path.endswith("/LCAppInfo.plist"):
                result["LCContainers"].append({"folderName": "second", "name": "Second"})
            return result
        with patch.object(livecontainer, "Files", Files), patch.object(Files, "plist", plist), \
             patch.object(livecontainer.layout, "load_device", lambda *a: {}), \
             patch.object(livecontainer.layout, "save_device", lambda *a: None):
            result = livecontainer.overview(self.c, [{"device": "PHONE", "online": "network", "installed": False}])
        self.assertTrue(result[0]["needsChoice"])
        self.assertEqual(len(result[0]["candidates"]), 2)
        self.assertEqual(result[0]["actions"], ["chooseApp"])

    def test_failed_probe_reports_access_error_and_recovers_after_unlock(self):
        row = {"device": "PHONE", "online": "network", "installed": False}
        store = {}
        error = Failure("iPhone 已锁屏，请解锁后重试。", code="device_not_ready")
        with patch.object(livecontainer, "targets", side_effect=error), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: store.update(value)):
            result = livecontainer.overview(self.c, [row])
        self.assertEqual(result[0]["liveContainerProbeError"], str(error))
        self.assertFalse(result[0]["installed"])
        with patch.object(livecontainer, "Files", Files), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: store.update(value)):
            result = livecontainer.overview(self.c, [row])
        self.assertNotIn("liveContainerProbeError", result[0])
        self.assertTrue(result[0]["installed"])

    def test_failed_probe_keeps_last_known_target(self):
        with patch.object(livecontainer, "Files", Files):
            target = livecontainer.targets(self.c, "PHONE")[0]
        store = {livecontainer.KEY: [target], livecontainer.SELECTED: target}
        error = Failure("文件访问失败", code="device_not_ready")
        with patch.object(livecontainer, "targets", side_effect=error), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: store.update(value)):
            result = livecontainer.overview(self.c, [{"device": "PHONE", "online": "network", "installed": False}])
        self.assertEqual(result[0]["liveContainerProbeError"], str(error))
        self.assertEqual(store[livecontainer.SELECTED], target)

    def test_host_file_access_failure_is_not_reported_as_missing_guest(self):
        with patch.object(livecontainer, "Files", Files), \
             patch.object(Files, "listdir", side_effect=Failure("设备已锁定", code="device_not_ready")):
            with self.assertRaises(Failure):
                livecontainer.targets(self.c, "PHONE")


class DirectoryCopy(unittest.TestCase):
    def test_directory_is_a_child_of_existing_destination_not_root_created_destination(self):
        with tempfile.TemporaryDirectory() as work:
            src = Path(work) / "different-local-name"
            (src / "translation/romfs").mkdir(parents=True)
            (src / "translation/romfs/data").write_bytes(b"original synthetic Mod")
            c = types.SimpleNamespace(private=Path(work))
            calls = []
            def copy(*args, **kwargs):
                local = Path(args[args.index("--source") + 1])
                destination = args[args.index("--destination") + 1]
                calls.append((destination, sorted(p.relative_to(local).as_posix() for p in local.rglob("*"))))
                self.assertEqual(args[args.index("--remove-existing-content") + 1], "false")
            with patch.object(livecontainer.Files, "call", side_effect=copy):
                livecontainer.Files(c, "PHONE", HOST).put_directory(src, "Documents/games/GAME/mods")
            self.assertEqual(calls, [("Documents/games/GAME", ["mods", "mods/translation", "mods/translation/romfs", "mods/translation/romfs/data"])])
            self.assertEqual((src / "translation/romfs/data").read_bytes(), b"original synthetic Mod")


class Launch(unittest.TestCase):
    def test_launch_options_and_json_output_precede_bundle_identifier(self):
        import json
        calls = []
        with tempfile.TemporaryDirectory() as work:
            c = types.SimpleNamespace(private=Path(work), env=lambda: dict(os.environ))
            def run(argv, **kwargs):
                calls.append(argv)
                # devicectl launch treats everything after the app argument as child argv.
                bundle_index = argv.index(HOST)
                options = argv[:bundle_index]
                if "--device" not in options or "--payload-url" not in options or "--json-output" not in options:
                    return types.SimpleNamespace(returncode=1, stderr="Missing expected argument '--device'", stdout="")
                Path(options[options.index("--json-output") + 1]).write_text(json.dumps({"result": {"processIdentifier": 1}}))
                return types.SimpleNamespace(returncode=0, stderr="", stdout="")
            with patch.object(livecontainer.diag.subprocess, "run", run):
                livecontainer.Files(c, "PHONE", HOST).launch({
                    "scheme": "livecontainer", "guest": GUEST, "container": CONTAINER})
        self.assertEqual(calls[0][-1], HOST, "No devicectl options may become guest command-line arguments")
        self.assertNotIn("--terminate-existing", calls[0])
        from urllib.parse import urlparse, parse_qs
        url = calls[0][calls[0].index("--payload-url") + 1]
        self.assertEqual(parse_qs(urlparse(url).query), {
            "bundle-name": [GUEST], "container-folder-name": [CONTAINER]})


class Push(unittest.TestCase):
    def setUp(self):
        import install
        self.enterContext(patch.object(install, "IMPORT_WAIT_S", (0, 0)))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.c = types.SimpleNamespace(private=self.root, library=self.root, r={"device": "PHONE"},
                                       check=lambda: None, begin=lambda *a: None, emit=lambda *a: None)
        self.mod_home = self.root / "mods"
        (self.mod_home / "translation/romfs").mkdir(parents=True)
        (self.mod_home / "translation/romfs/game.win").write_bytes(b"synthetic translation")
        (self.mod_home / ".off-disabled/romfs").mkdir(parents=True)
        (self.mod_home / ".off-disabled/romfs/disabled").write_bytes(b"not enabled")
        (self.mod_home / "translation/romfs/link").symlink_to(self.root / "not-part-of-mod")
        self.program = self.root / "game.s2arm"
        self.image = self.root / "game.img"
        self.program.write_bytes(b"synthetic program")
        self.image.write_bytes(b"synthetic resource")
        with patch.object(livecontainer, "Files", Files):
            self.target = livecontainer.targets(self.c, "PHONE")[0]

    def test_two_files_and_enabled_mod_are_sent_to_guest_not_host_root(self):
        import install
        import mods
        calls = []
        class Sender(Files):
            def listdir(client, path):
                return ["mods"] if "/games/" in path else super().listdir(path)
            def put(client, src, remote):
                calls.append(("file", remote, Path(src).read_bytes()))
            def put_directory(client, src, remote):
                calls.append(("mod", remote, sorted(p.relative_to(src).as_posix() for p in Path(src).rglob("*") if p.is_file())))
            def launch(client, target):
                calls.append(("launch", target["container"], None))
        exports = []
        def export(c, gid, sign=True):
            exports.append((gid, sign))
            return {"s2armPath": str(self.program), "resourcePath": str(self.image)}
        with patch.object(livecontainer, "Files", Sender), \
             patch.object(livecontainer.layout, "load_device", lambda *a: {livecontainer.SELECTED: self.target}), \
             patch.object(install, "export_s2arm", export), \
             patch.object(mods, "mods_dir", lambda *a, **k: self.mod_home):
            result = livecontainer.push(self.c, ["0100000000010000"])
        base = f"Documents/Data/Application/{CONTAINER}/Documents"
        self.assertEqual(exports, [("0100000000010000", False)])
        self.assertEqual([c[1] for c in calls if c[0] == "file"],
                         [base + "/Import Here/game.s2arm", base + "/Import Here/game.img"])
        self.assertEqual([c[1:] for c in calls if c[0] == "mod"],
                         [(base + "/games/0100000000010000/mods", ["translation/romfs/game.win"])])
        self.assertEqual(result["rows"][0]["mods"], ["translation"])
        self.assertEqual(result["transport"], "livecontainer")
        self.assertIn("unpackPending", result, "File transfer is not reported as confirmed game import")
        self.assertLess(next(i for i, call in enumerate(calls) if call[0] == "mod"),
                        next(i for i, call in enumerate(calls) if call[0] == "launch"),
                        "Enabled Mods must arrive before the guest starts importing")

    def test_stale_container_is_not_replaced_by_first_available_target(self):
        with patch.object(livecontainer, "Files", Files), \
             patch.object(livecontainer.layout, "load_device", lambda *a: {livecontainer.SELECTED: dict(self.target, id="lc:removed")}):
            with self.assertRaises(Failure) as failure:
                livecontainer.push(self.c, ["0100000000010000"])
        self.assertEqual(failure.exception.code, "phone_app_gone")

    def test_first_push_copies_only_mod_tree_when_game_documents_do_not_exist(self):
        import install
        import mods
        copies = []
        class Sender(Files):
            def listdir(client, path):
                if path.endswith("/games/0100000000010000"):
                    raise Failure("not found", code="device_not_ready")
                return super().listdir(path)
            def put(client, *args):
                pass
            def launch(client, *args):
                pass
            def put_directory(client, src, remote):
                copies.append((remote, sorted(p.relative_to(src).as_posix() for p in Path(src).rglob("*") if p.is_file())))
        with patch.object(livecontainer, "Files", Sender), \
             patch.object(livecontainer.layout, "load_device", lambda *a: {livecontainer.SELECTED: self.target}), \
             patch.object(install, "export_s2arm", lambda *a, **k: {"s2armPath": str(self.program), "resourcePath": str(self.image)}), \
             patch.object(mods, "mods_dir", lambda *a, **k: self.mod_home):
            livecontainer.push(self.c, ["0100000000010000"])
        self.assertEqual(copies, [(f"Documents/Data/Application/{CONTAINER}/Documents/games/0100000000010000",
                                  ["mods/translation/romfs/game.win"])])

    def test_push_saves_receipt_only_for_selected_container_and_reads_import_ack(self):
        import install
        import mods
        gid = "0100000000010000"
        other = {"ledger": {gid: {"state": "removed"}}}
        store = {livecontainer.SELECTED: self.target, livecontainer.STATE: {"lc:other": other},
                 "games": {gid: {"program": "native"}}}
        class Sender(Files):
            def put(client, *args):
                pass
            def put_directory(client, *args):
                pass
            def launch(client, *args):
                pass
            def json(client, path):
                return {"version": 1, "games": {gid: {"state": "present"}}}
        with patch.object(livecontainer, "Files", Sender), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: store.update(value)), \
             patch.object(install, "export_s2arm", lambda *a, **k: {"s2armPath": str(self.program), "resourcePath": str(self.image), "sha256": "synthetic-sha"}), \
             patch.object(mods, "mods_dir", lambda *a, **k: self.mod_home):
            result = livecontainer.push(self.c, [gid])
        receipt = store[livecontainer.STATE][self.target["id"]]["sent"][gid]
        self.assertEqual(receipt["s2armSha256"], "synthetic-sha")
        self.assertTrue(receipt["imported"])
        self.assertEqual(store[livecontainer.STATE]["lc:other"], other)
        self.assertEqual(store["games"], {gid: {"program": "native"}})
        self.assertIsNone(result["unpackPending"])


if __name__ == "__main__":
    unittest.main()
