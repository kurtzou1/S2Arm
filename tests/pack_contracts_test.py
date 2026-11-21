"""Offline Phase 0 tests. Synthetic outputs are not game packaging acceptance."""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "pack/jobs"))

from core import Cancelled, Context, Failure, atomic
import main as legacy
from pack.contracts.validate import ContractError, validate, validators, _audit, _check
from pack.contracts.fingerprint import content_fingerprint
from pack.jobs.target_main import TargetContext
from pack.targets.ios import adapter


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="s2arm contracts ")
        self.root = Path(self.temporary.name)
        self.request = dict(schema=1, contract="s2a.job-request.v1", operation="ipa", targetId="ios",
                            taskId="contract-test", privateRoot=str(self.root / "private"),
                            engineDir=str(ROOT), library=str(self.root / "library"), libraryId="fixture-library",
                            gameId="0100000000000000", target=dict(gpuArch="applegpu_g18p", os=27))
        self.target = json.loads((ROOT / "pack/targets/ios/target.json").read_text())
        output = self.root / "output"
        output.mkdir()
        ipa = output / "fixture.ipa"
        ipa.write_bytes(b"synthetic IPA fixture; not an installable app")
        resources = output / "fixture资源包"
        resources.mkdir()
        (resources / "manifest.json").write_text('{"fixture":true}')
        (resources / "index.tsv").write_text("fixture\t1\n")
        (resources / "nested").mkdir()
        (resources / "nested/data").write_bytes(b"synthetic resource")
        self.result = dict(outputPath=str(output), ipa=str(ipa), buildId="fixture-001", target=self.request["target"])
        self.signals = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}

    def tearDown(self):
        for s, handler in self.signals.items():
            signal.signal(s, handler)
        self.temporary.cleanup()

    def worker(self, handler, *, new=True):
        request = self.request if new else {k: v for k, v in self.request.items() if k not in ("contract", "targetId")}
        path = self.root / "request.json"
        atomic(path, request)
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["main.py", "--request", str(path)]), \
                mock.patch.object(adapter.platform, "system", return_value="Darwin"), \
                mock.patch.object(adapter.platform, "machine", return_value="arm64"), \
                mock.patch("ipa.build", handler), contextlib.redirect_stdout(output):
            rc = legacy.main(context_class=TargetContext if new else Context,
                             operation_overrides={"ipa": adapter.build} if new else None)
        return rc, [json.loads(line) for line in output.getvalue().splitlines()]

    def build(self, c):
        c.begin("检查游戏输入")
        c.milestone = "direct"
        c.begin("直连着色器库")
        c.emit(done=2, total=2, unit="files")
        c.emit("heartbeat")
        return copy.deepcopy(self.result)

    def test_all_schemas_use_the_supported_local_subset(self):
        self.assertEqual(set(validators()), {"request", "event", "artifact", "target"})

    def test_new_entry_runs_with_no_site_packages(self):
        command = [sys.executable, "-I", "-S", "-B"]
        code = ("import importlib.util,runpy,sys; "
                "assert importlib.util.find_spec('jsonschema') is None; "
                "entry=sys.argv[1]; sys.argv=['validate.py','target',sys.argv[2]]; runpy.run_path(entry,run_name='__main__')")
        run = subprocess.run(command + ["-c", code, str(ROOT / "pack/contracts/validate.py"),
                                       str(ROOT / "pack/targets/ios/target.json")],
                             text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        path = self.root / "request.json"
        atomic(path, self.request | {"contract": "unsupported"})
        run = subprocess.run(command + [str(ROOT / "pack/jobs/target_main.py"), "--request", str(path)],
                             text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertIn("const", run.stderr)

    def test_subset_rejects_unknown_keywords_and_nonlocal_refs(self):
        for schema in ({"maxLength": 2}, {"properties": {"x": {"format": "email"}}}):
            with self.subTest(schema=schema), self.assertRaises(ContractError):
                _audit(schema)
        schema = {"$ref": "https://invalid.example/schema"}
        with self.assertRaises(ContractError):
            _check({}, schema, schema, validators(), "request")

    def test_local_refs_validate_items_and_reject_unknown_fields(self):
        validate("target", self.target)
        self.assertEqual({v["id"] for v in self.target["host"]["variants"]}, {"windows", "linux"})
        self.assertTrue(all(v["available"] is False for v in self.target["host"]["variants"]))
        for extra in ({"available": 0}, {"trackingIssue": -1}, {"unexpected": True}):
            d = copy.deepcopy(self.target)
            d["host"]["variants"][0].update(extra)
            with self.subTest(extra=extra), self.assertRaises(ContractError):
                validate("target", d)
        documents = validators()
        schema = {"$ref": "urn:s2a:contracts:target:v1#/$defs/hostVariant"}
        _check(self.target["host"]["variants"][0], schema, schema, documents, "target")
        with self.assertRaises(ContractError):
            _check({}, schema, schema, documents, "target")

    def test_numeric_string_array_and_const_boundaries(self):
        for extra in ({"schema": True}, {"privateRoot": ""}, {"target": {"os": 0}},
                      {"parentPid": 1.5}, {"parentPid": float('nan')}, {"parentPid": float('inf')}):
            with self.subTest(extra=extra), self.assertRaises(ContractError):
                validate("request", self.request | extra)
        validate("request", self.request | {"parentPid": 1.0})
        validate("request", {k: v for k, v in self.request.items() if k not in ("gameId", "library", "libraryId")} | {"operation": "future"})
        d = copy.deepcopy(self.target)
        d["stages"] = []
        with self.assertRaises(ContractError):
            validate("target", d)
        d = adapter.artifact_manifest(self.result)
        d["files"] = []
        with self.assertRaises(ContractError):
            validate("artifact", d)

    def test_request_keeps_alias_and_extension_fields(self):
        validate("request", self.request | {"newClientField": {"future": True}})
        validate("request", {k: v for k, v in self.request.items() if k != "taskId"} | {"jobId": "client-id"})

    def test_request_rejects_missing_and_wrong_version_fields(self):
        for key in ("schema", "contract", "operation", "privateRoot", "gameId", "library", "libraryId"):
            with self.subTest(key=key), self.assertRaises(ContractError):
                validate("request", {k: v for k, v in self.request.items() if k != key})
        for extra in ({"schema": 2}, {"contract": "s2a.job-request.v99"}, {"taskId": "../job"}, {"parentPid": True}):
            with self.subTest(extra=extra), self.assertRaises(ContractError):
                validate("request", self.request | extra)

    def test_schema_errors_never_echo_values(self):
        secret = "private-content-must-not-appear"
        with self.assertRaises(ContractError) as raised:
            validate("request", self.request | {"parentPid": secret})
        self.assertNotIn(secret, str(raised.exception))

    def test_unsupported_request_creates_no_job_files(self):
        for extra in ({"targetId": "android"}, {"operation": "build"}, {"contract": "bad"}):
            with self.subTest(extra=extra), self.assertRaises(ContractError):
                TargetContext(self.request | extra)
        self.assertFalse(Path(self.request["privateRoot"]).exists())

    def test_unsupported_host_is_explicit(self):
        for system, machine in (("Linux", "arm64"), ("Linux", "x86_64"),
                                ("Windows", "AMD64"), ("Darwin", "x86_64")):
            with self.subTest(system=system, machine=machine), \
                    mock.patch.object(adapter.platform, "system", return_value=system), \
                    mock.patch.object(adapter.platform, "machine", return_value=machine), \
                    self.assertRaises(ContractError):
                adapter.check_request(self.request)

    def test_real_worker_preserves_legacy_fields_and_adds_manifest(self):
        old_rc, old = self.worker(self.build, new=False)
        new_rc, new = self.worker(self.build)
        self.assertEqual((old_rc, new_rc), (0, 0))
        self.assertEqual(len(old), len(new))
        for before, after in zip(old, new):
            validate("event", after)
            self.assertEqual(set(before) - set(after), set())
            for key in before:
                if key not in ("timestamp", "elapsed", "advancedAt", "result"):   # advancedAt：上次前进的墙钟时刻，同 timestamp 每次跑不同
                    self.assertEqual(before[key], after[key], key)
        for key, value in old[-1]["result"].items():
            self.assertEqual(value, new[-1]["result"][key])
        self.assertNotIn("contract", old[0])
        self.assertEqual(new[2]["stageId"], "direct")
        self.assertEqual(new[-1]["code"], "job.succeeded")
        validate("artifact", new[-1]["result"]["artifactManifest"])
        persisted = Path(self.request["privateRoot"]) / "logs/jobs/contract-test.events.jsonl"   # 库没建好：任务记录退回 <私有目录>/logs/jobs
        # Both runs use the same fixture ID: only the new run has contract fields.
        for event in [json.loads(line) for line in persisted.read_text().splitlines()][len(old):]:
            validate("event", event)

    def test_unknown_totals_stay_null(self):
        rc, events = self.worker(self.build)
        self.assertEqual(rc, 0)
        self.assertIsNone(events[0]["totalUnits"])
        self.assertIsNone(events[0]["doneUnits"])

    def test_failure_keeps_code_and_never_emits_an_artifact(self):
        def fail(c):
            c.begin("检查游戏输入")
            raise Failure("fixture failure", code="keys_missing")
        rc, events = self.worker(fail)
        self.assertEqual(rc, 1)
        for event in events:
            validate("event", event)
        self.assertEqual(events[-1]["code"], "keys_missing")
        self.assertEqual(events[-1]["state"], "failed")
        self.assertEqual(events[-1]["result"], {})
        self.assertIn("prod.keys", events[-1]["nextAction"])

    def test_generic_exception_and_error_events_keep_upstream_diagnostic_codes(self):
        def fail(c):
            c.begin("检查游戏输入")
            raise OSError(28, "synthetic disk full")
        rc, events = self.worker(fail)
        self.assertEqual(rc, 1)
        failed = [e for e in events if e["type"] == "diagnostic" or e["state"] == "failed"]
        self.assertEqual(len(failed), 2)
        self.assertTrue(all(e["code"] == "disk_full" for e in failed))
        self.assertEqual(events[-1]["code"], events[-1]["diagnostics"][-1]["code"])
        from pack.contracts.protocol import event_fields
        self.assertEqual(event_fields("result", "", "", None, {"state": "failed"})["code"], "job_failed")

    def test_cancellation_keeps_exit_and_terminal_state(self):
        def cancel(c):
            c.begin("检查游戏输入")
            raise Cancelled()
        rc, events = self.worker(cancel)
        self.assertEqual(rc, 130)
        validate("event", events[-1])
        self.assertEqual(events[-1]["code"], "job.cancelled")
        self.assertEqual(events[-1]["result"], {})

    def test_missing_delivered_resource_is_failure(self):
        (Path(self.result["outputPath"]) / "fixture资源包/manifest.json").unlink()
        rc, events = self.worker(self.build)
        self.assertEqual(rc, 1)
        self.assertEqual(events[-1]["code"], "artifact_invalid")

    def test_manifest_is_read_only_and_uses_real_content_hashes(self):
        root = Path(self.result["outputPath"])
        before = {p.relative_to(root).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns) for p in root.rglob("*") if p.is_file()}
        manifest = adapter.artifact_manifest(self.result)
        self.assertEqual(len(manifest["files"]), 4)
        for entry in manifest["files"]:
            content, mtime = before[entry["path"]]
            self.assertEqual((entry["size"], entry["sha256"]), (len(content), hashlib.sha256(content).hexdigest()))
            self.assertEqual((root / entry["path"]).stat().st_mtime_ns, mtime)
            self.assertEqual((root / entry["path"]).read_bytes(), content)

    def test_manifest_rejects_symlinks(self):
        root = Path(self.result["outputPath"])
        (root / "fixture资源包/outside").symlink_to(self.root)
        with self.assertRaises(ContractError):
            adapter.artifact_manifest(self.result)

    def test_cancellation_during_manifest_hashing_keeps_output(self):
        check = mock.Mock(side_effect=[None, Cancelled()])
        before = Path(self.result["ipa"]).read_bytes()
        with self.assertRaises(Cancelled):
            adapter.artifact_manifest(self.result, check)
        self.assertEqual(check.call_count, 2)
        self.assertEqual(Path(self.result["ipa"]).read_bytes(), before)

    def test_manifest_rejects_bad_paths_duplicates_and_unlisted_delivery(self):
        manifest = adapter.artifact_manifest(self.result)
        for bad in ("../escape", "/absolute", "folder/../../escape", "folder\\escape", "./file"):
            d = copy.deepcopy(manifest)
            d["files"][0]["path"] = bad
            with self.subTest(path=bad), self.assertRaises(ContractError):
                validate("artifact", d)
        for mutation in ("duplicate", "sha", "device", "delivery"):
            d = copy.deepcopy(manifest)
            if mutation == "duplicate":
                d["files"].append(d["files"][0])
            elif mutation == "sha":
                d["files"][0]["sha256"] = "missing"
            elif mutation == "device":
                del d["details"]["device"]["gpuArch"]
            else:
                d["details"]["ipa"] = "not-listed.ipa"
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                validate("artifact", d)

    def test_manifest_rejects_unknown_version(self):
        manifest = adapter.artifact_manifest(self.result)
        with self.assertRaises(ContractError):
            validate("artifact", manifest | {"schema": "s2a.artifact.v3"})

    def content_manifest(self):
        manifest = adapter.artifact_manifest(self.result)
        manifest["inputs"] = dict(stageKeys={".stage_" + s: None for s in
                                          ("rewrite", "sysdata", "uilayout", "aoc", "romfsidx", "shaders", "direct")},
                                  dual=False, directChain=None)
        manifest["fingerprint"] = content_fingerprint("1" * 64, "2" * 64, [])
        return manifest

    def test_content_fields_are_additive_and_missing_keys_are_explicit(self):
        validate("artifact", adapter.artifact_manifest(self.result))
        manifest = self.content_manifest()
        validate("artifact", manifest)
        manifest["inputs"].update(dual=True, directChain="b-0123456789ab")
        manifest["inputs"]["stageKeys"][".stage_direct"] = "0123456789abcdef"
        validate("artifact", manifest)
        for mutate in (lambda d: d["inputs"].pop("dual"),
                       lambda d: d["inputs"]["stageKeys"].pop(".stage_direct"),
                       lambda d: d["inputs"]["stageKeys"].update({".stage_shaders": ""}),
                       lambda d: d["inputs"].update(dual=1),
                       lambda d: d["inputs"].update(directChain="source-commit"),
                       lambda d: d["inputs"].update(unexpected=True)):
            bad = copy.deepcopy(manifest)
            mutate(bad)
            with self.assertRaises(ContractError):
                validate("artifact", bad)

    def test_fingerprint_has_a_fixed_utf8_canonical_digest(self):
        # Independent wire-format vector; no filesystem/source metadata.
        archives = [{"path": "shaders/乙.bin", "sha256": "b" * 64},
                    {"path": "shaders/a.bin", "sha256": "a" * 64}]
        fp = content_fingerprint("1" * 64, "2" * 64, archives)
        raw = ('{"components":{"executableSha256":"' + "1" * 64 +
               '","pipelineArchives":[{"path":"shaders/a.bin","sha256":"' + "a" * 64 +
               '"},{"path":"shaders/乙.bin","sha256":"' + "b" * 64 +
               '"}],"resourceIndexSha256":"' + "2" * 64 +
               '"},"schema":"s2a.content-fingerprint.v1"}').encode("utf-8")
        self.assertEqual(fp["value"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(fp, content_fingerprint("1" * 64, "2" * 64, reversed(archives)))
        self.assertEqual(archives[0]["path"], "shaders/乙.bin")

    def test_fingerprint_ignores_build_inputs_but_detects_each_content_change(self):
        manifest = self.content_manifest()
        before = manifest["fingerprint"]["value"]
        manifest["inputs"]["stageKeys"][".stage_rewrite"] = "a-new-source-key"
        manifest["details"]["buildId"] = "a-new-build"
        validate("artifact", manifest)
        self.assertEqual(before, manifest["fingerprint"]["value"])
        for args in (("3" * 64, "2" * 64, []), ("1" * 64, "3" * 64, []),
                     ("1" * 64, "2" * 64, [{"path": "shaders/gal_pso.bin", "sha256": "4" * 64}])):
            self.assertNotEqual(before, content_fingerprint(*args)["value"])

    def test_fingerprint_rejects_tampered_digest_duplicates_and_invalid_components(self):
        for mutate in (lambda f: f.update(value="0" * 64),
                       lambda f: f["components"].update(executableSha256="not-a-hash"),
                       lambda f: f["components"].update(pipelineArchives=None),
                       lambda f: f["components"].pop("pipelineArchives"),
                       lambda f: f["components"].update(pipelineArchives=[{"path": "../escape", "sha256": "3" * 64}]),
                       lambda f: f["components"].update(pipelineArchives=[{"path": "shaders/a.bin", "sha256": "3" * 64}] * 2),
                       lambda f: f["components"].update(sourceCommit="source-is-not-content")):
            manifest = self.content_manifest()
            mutate(manifest["fingerprint"])
            with self.assertRaises(ContractError):
                validate("artifact", manifest)

    def test_content_manifest_cli_works_without_site_packages(self):
        path = self.root / "artifact.json"
        path.write_text(json.dumps(self.content_manifest()))
        run = subprocess.run([sys.executable, "-I", "-S", "-B", str(ROOT / "pack/contracts/validate.py"),
                              "artifact", str(path)], text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_refresh_declaration_matches_script_order_and_parallel_group(self):
        script = (ROOT / "pack/refresh.sh").read_text()
        script = script[script.index("\n# 只有直连（11-07 拆通用模式"):]   # 苹果路线（安卓分支在它前面、整段 exit 0，#783 起也调 stage_direct.sh，另由 android/target.json 声明）
        loops = re.findall(r"^for s in ([a-z ]+).*; do", script, re.M)
        # 前四段同时起（并行一组）。直连单轨快路（11-06 依赖重排）：RomFS 索引在旁路、与直连链并行（直连库开编前已起）；
        #   11-07 只有直连：没有串行路、没有只记键的着色器阶段与客体代码表
        dt = script[script.index("\ndirect_tail() {"):script.index("\nchk() {")]   # 直连库 → 管线种子表
        self.assertLess(dt.index('bash "$H/stage_direct.sh"'), dt.index("st1 direct_seed"))
        self.assertNotIn("stage_shaders.sh", script); self.assertNotIn("direct_gk", script)
        self.assertLess(script.index("st1 romfsidx"), script.index("\ndirect_tail\n"))
        refresh = loops[0].split() + ["romfsidx", "direct"]
        self.assertEqual(refresh, ["rewrite", "sysdata", "uilayout", "aoc", "romfsidx", "direct"])
        stages = self.target["recipes"][0]["stages"]
        self.assertEqual(stages[2:8], refresh)
        by_id = {s["id"]: s for s in self.target["stages"]}
        for name in refresh[:4]:
            self.assertEqual(by_id[name]["parallelGroup"], "refresh.independent")
        self.assertEqual(by_id["romfsidx"]["parallelGroup"], "refresh.alongside-direct")
        self.assertIn("直连单轨", by_id["direct"]["condition"])
        self.assertFalse({"shaders", "shader.archive", "direct.ready.collect"} & set(by_id))
        from pack.contracts.protocol import STAGES
        self.assertTrue(set(STAGES.values()) <= set(by_id))

    def test_target_rejects_unknown_parent_and_condition_type(self):
        for extra in ({"parentStage": "missing"}, {"parentStage": "input.validate"}, {"condition": True}):
            target = copy.deepcopy(self.target)
            target["stages"][0].update(extra)
            with self.subTest(extra=extra), self.assertRaises(ContractError):
                validate("target", target)

    def test_target_requires_real_stage_references(self):
        validate("target", self.target)
        for mutation in ("unknown", "duplicate", "no-host"):
            d = copy.deepcopy(self.target)
            if mutation == "unknown":
                d["recipes"][0]["stages"].append("imaginary.stage")
            elif mutation == "duplicate":
                d["stages"].append(d["stages"][0])
            else:
                del d["host"]["requires"]
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                validate("target", d)
        for stage in self.target["stages"]:
            path = stage["implementation"].split(":")[0]
            self.assertTrue((ROOT / path).is_file(), path)

    def test_event_rejects_invalid_dates_and_terminal_state(self):
        _, events = self.worker(self.build)
        for bad in ("not-a-date", "2026-13-24T00:00:00Z", "2026-10-24T00:00:00", "2026-10-24T00:00:00+08:00"):
            with self.subTest(timestamp=bad), self.assertRaises(ContractError):
                validate("event", events[0] | {"timestamp": bad})
        with self.assertRaises(ContractError):
            validate("event", events[-1] | {"state": "running"})

    def test_cli_reads_ndjson_and_rejects_bad_or_empty_streams(self):
        _, events = self.worker(self.build)
        path = self.root / "events.ndjson"
        for content, expected in (("\n".join(json.dumps(e) for e in events), 0), ("", 1), ("{}\n", 1), ("not json", 1)):
            path.write_text(content)
            run = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "pack/contracts/validate.py"), "event", str(path), "--ndjson"],
                                 text=True, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, expected, run.stderr)

    def test_entry_rejects_bad_contract_but_accepts_default_permission_request(self):
        path = self.root / "request.json"
        atomic(path, self.request | {"contract": "invalid-secret-contract"})
        command = [sys.executable, "-I", "-B", str(ROOT / "pack/jobs/target_main.py"), "--request", str(path)]
        run = subprocess.run(command, text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertNotIn("invalid-secret-contract", run.stderr)
        self.assertFalse(Path(self.request["privateRoot"]).exists())
        atomic(path, self.request)
        path.chmod(0o644)   # 11-16 不再自设权限：系统缺省权限（0644）的请求照常收、照常出事件（原先按「不是 0600」拒收、stdout 为空）
        run = subprocess.run(command, text=True, capture_output=True, timeout=20)
        self.assertTrue(run.stdout.strip(), run.stderr)
        self.assertEqual(json.loads(run.stdout.splitlines()[0])["jobId"], self.request["taskId"])


if __name__ == "__main__":
    unittest.main()
