# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
import json
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
    spec.loader.exec_module(livecontainer)

GID = "0100000000010000"
TARGET = dict(id="lc:first", hostBundleId="com.example.host", hostName="LiveContainer",
              home="Documents/Data/Application/first", guest="io.s2arm.games.app", container="first",
              displayName="LiveContainer / S2Arm / first")
STATE = "liveContainerState"


class Status(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.c = types.SimpleNamespace(private=Path(self.temp.name), r={"probe": True})
        self.store = {livecontainer.KEY: [TARGET], "chosenLCHostId": TARGET["id"],
                      "games": {GID: {"program": {"sha": "native"}, "pack": {"sha": "native"}}}}
        self.row = dict(device="PHONE", online="network", installed=False,
                        games=[dict(gameId=GID, state="latest", dataOnComputer=True)])

    def overview(self, ledger, pending=()):
        class Reader:
            def __init__(client, *args):
                pass
            def json(client, path):
                if isinstance(ledger, Exception):
                    raise ledger
                return ledger
            def listdir(client, path):
                return ["Import Here"] if path.endswith("/Documents") else list(pending)
        with patch.object(livecontainer, "targets", return_value=[TARGET]), \
             patch.object(livecontainer, "Files", Reader), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(self.store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: self.store.update(value)):
            return livecontainer.overview(self.c, [self.row])[0]

    def test_phone_presence_overrides_native_record_without_claiming_latest(self):
        self.row["games"][0]["state"] = "notPushed"
        result = self.overview({"version": 1, "games": {GID: {"state": "present", "program": ""}}})
        self.assertEqual(result["games"][0]["state"], "present")
        self.assertEqual(self.store["games"][GID]["program"]["sha"], "native")
        self.assertTrue(result["installed"])

    def test_phone_deletion_overrides_cached_presence(self):
        self.store[STATE] = {TARGET["id"]: {"ledger": {GID: {"state": "present"}}}}
        result = self.overview({"version": 1, "games": {GID: {"state": "removed"}}})
        self.assertEqual(result["games"][0]["state"], "notPushed")
        self.assertEqual(self.store[STATE][TARGET["id"]]["ledger"][GID]["state"], "removed")

    def test_phone_deletion_is_authoritative_even_with_different_device_clocks(self):
        self.store[STATE] = {TARGET["id"]: {"sent": {GID: {"at": 2000000000, "files": ["game.s2arm"]}}}}
        result = self.overview({"version": 1, "games": {GID: {"state": "removed", "at": 1}}})
        self.assertEqual(result["games"][0]["state"], "notPushed")
        self.assertEqual(result["games"][0]["reasons"], ["removed"])

    def test_unreadable_ledger_is_unknown_and_keeps_last_known_presence(self):
        self.store[STATE] = {TARGET["id"]: {"ledger": {GID: {"state": "present"}}}}
        result = self.overview(Failure("Device locked", code="device_not_ready"))
        self.assertEqual(result["games"][0]["state"], "unknown")
        self.assertEqual(self.store[STATE][TARGET["id"]]["ledger"][GID]["state"], "present")

    def test_failed_host_probe_does_not_report_cached_presence_as_current(self):
        self.store[STATE] = {TARGET["id"]: {"ledger": {GID: {"state": "present"}}}}
        with patch.object(livecontainer, "targets", side_effect=Failure("Device locked", code="device_not_ready")), \
             patch.object(livecontainer.layout, "load_device", lambda *a: dict(self.store)), \
             patch.object(livecontainer.layout, "save_device", lambda c, key, value: self.store.update(value)):
            result = livecontainer.overview(self.c, [self.row])[0]
        self.assertEqual(result["games"][0]["state"], "unknown")
        self.assertEqual(self.store[STATE][TARGET["id"]]["ledger"][GID]["state"], "present")

    def test_no_probe_uses_only_selected_container_cache(self):
        self.c.r["probe"] = False
        self.store[STATE] = {"lc:other": {"ledger": {GID: {"state": "present"}}}}
        result = self.overview({"version": 1, "games": {}})
        self.assertEqual(result["games"][0]["state"], "unknown")
        self.store[STATE][TARGET["id"]] = {"ledger": {GID: {"state": "removed"}}}
        result = self.overview({"version": 1, "games": {}})
        self.assertEqual(result["games"][0]["state"], "notPushed")

    def test_sent_files_waiting_for_import_are_pending_not_latest(self):
        self.store[STATE] = {TARGET["id"]: {"sent": {GID: {"files": ["game.s2arm", "game.img"]}}}}
        result = self.overview({"version": 1, "games": {GID: {"state": "present"}}}, ["game.s2arm"])
        self.assertEqual(result["games"][0]["state"], "pending")

    def test_native_selection_keeps_native_game_status(self):
        self.row.update(installed=True, installedBy="external", bundleId="io.s2arm.games.native")
        self.store.pop("chosenLCHostId")
        self.store["chosenBundleId"] = self.row["bundleId"]
        result = self.overview({"version": 1, "games": {GID: {"state": "removed"}}})
        self.assertEqual(result["games"], self.row["games"])
        self.assertEqual(result["bundleId"], self.row["bundleId"])

    def test_bad_schema_is_not_an_empty_successful_ledger(self):
        with tempfile.TemporaryDirectory() as work:
            c = types.SimpleNamespace(private=Path(work))
            with patch.object(livecontainer.Files, "get", return_value=json.dumps({"version": 2, "games": {}}).encode()):
                with self.assertRaises(Failure):
                    livecontainer.read_ledger(livecontainer.Files(c, "PHONE", "HOST"), TARGET)


if __name__ == "__main__":
    unittest.main()
