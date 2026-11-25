# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#2024：出包 / 准备 / 导入这类作业把内置宿主 S2ArmGame.app 当辅助工具执行，系统随即登记它；原先只有起局收尾注销，
   这些作业结束后「App」启动器里一直留一个 S2ArmGame。期望按规则手写：
① 作业环境给过内置宿主（Context.env 走发版运行时、取到内置 S2ArmGame.app）→ 记下 host_app；
② 记过 host_app 的作业结束时注销一次（成功、失败都要），带的就是那个 .app；③ 没碰宿主的作业不碰系统登记库；
④ 注销本身出 OSError 不把作业变失败"""
import json
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from core import atomic
from errors import Failure
import main


class HostForgetAfterJobTests(JobCase):
    def fake_app(self):
        app = self.root / "Engine" / "Binaries" / "S2ArmGame.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/s2arm-host").write_bytes(b"x")
        (app / "Contents/MacOS/libs2a_vaguard.dylib").write_bytes(b"x")
        (app / "Contents/Info.plist").write_text("<plist/>")
        return app

    def run_op(self, op, fn, forget, **extra):
        path = self.root / ("req-" + op + ".json")
        atomic(path, self.request | dict(taskId="t-" + op, operation=op) | extra)
        with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"), \
                patch.object(main, "background_priority"), patch.object(main.host_update, "forget_registrations", forget):
            return main.run_request(path, operation_overrides={op: fn})

    def test_env_with_bundled_host_records_host_app(self):
        app = self.fake_app()
        resources = self.root / "Resources"   # 发版运行时（便携 Runtime schema 5）才走取内置宿主那条
        runtime = resources / "Runtime"
        runtime.mkdir(parents=True)
        (runtime / "versions.json").write_text(json.dumps({"runtimeSchema": 5}))
        seen = []
        def op(c):
            with patch("embedded.artifact", return_value=app):
                env = c.env()
            seen.append((getattr(c, "host_app", None), env.get("S2A_BUNDLED_HOST")))
            return {}
        calls = []
        self.assertEqual(self.run_op("build", op, lambda **kw: calls.append(kw), resources=str(resources)), 0)
        self.assertEqual(seen, [(app, str(app / "Contents/MacOS/s2arm-host"))])
        self.assertEqual(calls, [{"app": app}], "作业结束注销一次，带这个宿主包")

    def test_failed_job_that_used_host_still_forgets(self):
        app = self.fake_app()
        calls = []
        def op(c):
            c.host_app = app
            raise Failure("出包失败")
        self.assertEqual(self.run_op("build", op, lambda **kw: calls.append(kw)), 1)
        self.assertEqual(calls, [{"app": app}])

    def test_job_without_host_does_not_touch_registrations(self):
        calls = []
        self.assertEqual(self.run_op("catalog", lambda c: {}, lambda **kw: calls.append(kw)), 0)
        self.assertEqual(calls, [])

    def test_forget_oserror_does_not_fail_the_job(self):
        app = self.fake_app()
        def boom(**kw):
            raise OSError("锁文件写不进")
        def op(c):
            c.host_app = app
            return {}
        self.assertEqual(self.run_op("build", op, boom), 0)


if __name__ == "__main__":
    import unittest
    unittest.main()
