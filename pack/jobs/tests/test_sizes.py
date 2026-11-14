# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""每款各部分大小（game.json sizes）+ 存储总览（storageOverview）：合成文件，期望值按文件大小手写。"""
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase
import core
from core import Context, read
import layout
import library
import sizes

MIB = 1 << 20
SLACK = 64 * 1024   # 目录元数据余量
GID = "0100F2C0115B6000"
OTHER = "0100000000000001"


def write(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))
    return path


class Sizes(JobCase):
    def setUp(self):
        super().setUp()
        pk = lambda sha, size: dict(type="base", titleId=GID, version=0, display="1.0.0", sha256=sha, size=size, path="/x/" + sha)
        self.games = [dict(id=GID, name="异度神剑3", packages=[pk("a" * 64, 10 * MIB), pk("b" * 64, 4 * MIB)]),
                      dict(id=OTHER, name="别款", packages=[pk("a" * 64, 10 * MIB)])]
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=self.games))
        L = self.c.library
        d = layout.game_dir(self.c, GID, english="Xenoblade 3")
        write(d / "image" / "mac" / "main.bin", 2 * MIB)
        write(d / "saves" / "slot0.bin", 1 * MIB)
        write(d / "save-backups" / "b0.bin", 1 * MIB)
        write(d / "build" / "extract" / "romfs" / "data.arc", 3 * MIB)
        # 镜像里的 romfs 是解包的真克隆（APFS 上共享块；Windows / 非 APFS 退成复制，照实是第 2 份）——同出包 clone_tree
        self.cloned = core.clone(d / "build" / "extract" / "romfs" / "data.arc", d / "image" / "mac" / "romfs" / "data.arc")
        write(d / "shader-cache" / "pso.bin", 1 * MIB)
        write(d / "image" / "ios" / "kit" / "main.bin", 2 * MIB)          # 容器件 → imageIos
        write(d / "image" / "ios" / "pack" / "r.bin", 1 * MIB)           # 资源包 → imageIos
        write(d / "build" / "ios" / "roots" / "r@1" / "x.bin", 1 * MIB)  # iPhone 出包中间产物 → cache
        write(d / "build" / "ios" / "logs" / "build.log", 1 * MIB)       # 日志不算进任何一项
        self.dir = d

    def context(self, operation, **extra):
        self.sequence += 1
        return Context(self.request | dict(taskId=f"sz-{self.sequence}", operation=operation) | extra)

    def assert_mib(self, got, mib, what=""):
        self.assertGreaterEqual(got, mib * MIB, what); self.assertLess(got, mib * MIB + SLACK, what)

    def test_measure_each_part(self):
        s = sizes.measure(self.c, GID)
        want = dict(imageMac=2 if self.cloned else 5, imageIos=3, saves=2, cache=3 + 1 + 1)   # cache = build/extract 3 + shader-cache 1 + roots 1；克隆的 3 MiB 记在先量的 cache
        for k, mib in want.items():
            with self.subTest(part=k):
                self.assert_mib(s[k], mib, k)
        self.assertEqual(s["sources"], 5 * MIB + 4 * MIB)   # a 两款共用记一半，b 只这款

    def test_independent_copy_counted_twice(self):
        # #329 负对照：镜像里的 romfs 是独立写的一份（不是克隆，盘上真是两份）→ 照实算进镜像，不能按目录名当成克隆略掉
        f = self.dir / "image" / "mac" / "romfs" / "data.arc"; f.unlink(); write(f, 3 * MIB)
        s = sizes.measure(self.c, GID)
        self.assert_mib(s["imageMac"], 5); self.assert_mib(s["cache"], 5)

    @unittest.skipIf(os.name == "nt", "NTFS 无克隆，镜像的 romfs 照实算")
    def test_romfs_counted_in_image_once_extract_gone(self):
        # 负对照：解包删了（出包成功后的常态），镜像里的 romfs 就是唯一一份，要算进镜像
        library._rm(self.c, self.c.library, self.dir / "build" / "extract")
        s = sizes.measure(self.c, GID)
        self.assert_mib(s["imageMac"], 5)
        self.assert_mib(s["cache"], 2)

    def test_sources_share_follows_catalog(self):
        self.assertEqual(sizes._source_share(OTHER, self.games), 5 * MIB)
        self.assertEqual(sizes._source_share(GID, self.games[:1]), 14 * MIB)   # 别款删了：整份归这款
        dup = [dict(id=GID, packages=[dict(sha256="c" * 64, size=6)] * 2)]   # 同一个文件列两次（整合版）只算一次
        self.assertEqual(sizes._source_share(GID, dup), 6)

    def test_catalog_reads_saved_sizes_without_measuring(self):
        out = sizes.for_catalog(self.c, GID, self.games)
        self.assertFalse(out["measured"])
        self.assertEqual([out[k] for k in ("imageMac", "imageIos", "saves", "cache")], [0, 0, 0, 0])
        saved = sizes.refresh(self.c, GID)
        self.assertEqual(read(self.dir / "game.json")["sizes"], saved)
        write(self.dir / "saves" / "slot1.bin", 2 * MIB)   # 量过之后又长了：catalog 不现场量，还是上次记的
        out = sizes.for_catalog(self.c, GID, self.games)
        self.assertTrue(out["measured"])
        self.assert_mib(out["saves"], 2)
        self.assertEqual(read(self.dir / "game.json")["id"], GID)   # 写回不丢 game.json 原有字段

    def test_refresh_without_folder_creates_nothing(self):
        self.assertIsNone(sizes.refresh(self.c, OTHER))
        self.assertIsNone(layout.find_game(self.c, OTHER))

    def test_clean_cache_updates_sizes(self):
        sizes.refresh(self.c, GID)
        self.assertGreater(layout.read_sizes(self.c, GID)["cache"], 0)
        library.clean(self.context("clean", gameId=GID, kind="cache"))
        self.assertEqual(layout.read_sizes(self.c, GID)["cache"], 0)

    def test_clean_without_refresh_leaves_stale(self):
        # 负对照：收尾不写回，game.json 里还是清之前的数（证明上一条测的是收尾那一步）
        sizes.refresh(self.c, GID)
        before = layout.read_sizes(self.c, GID)["cache"]
        with patch.object(sizes, "refresh", lambda c, gid: None):
            library.clean(self.context("clean", gameId=GID, kind="cache"))
        self.assertEqual(layout.read_sizes(self.c, GID)["cache"], before)

    def test_delete_moves_shared_source_to_other(self):
        # 删了一款：和它共用原件的别款，原件均摊跟着变成整份（catalog 现算，不靠写回）
        with patch.object(library, "drop_from_container", lambda c, gid: None):
            library.delete(self.context("delete", gameId=GID))
        games = self.c.catalog()["games"]
        self.assertEqual([g["id"] for g in games], [OTHER])
        self.assertEqual(sizes.for_catalog(self.c, OTHER, games)["sources"], 10 * MIB)

    def test_space_free_updates_sizes(self):
        sizes.refresh(self.c, GID)
        library.space_free(self.context("spaceFree", gameId=GID, parts=["ipa"]))
        self.assertEqual(layout.read_sizes(self.c, GID)["imageIos"], 0)

    def test_overview(self):
        L, P, W = self.c.library, self.c.private, self.c.work_root
        write(L / "hosts" / "mac" / "abc" / "S2ArmGame.app" / "h.bin", 2 * MIB)
        write(P / "engines" / "e1" / "x.bin", 1 * MIB)                 # 引擎副本旧位置也算进 hosts
        write(L / "S2Arm.ipa", 3 * MIB)
        write(W / "cache" / "air" / "a.bin", 1 * MIB)
        write(L / "temp" / "t1" / "t.bin", 1 * MIB)
        write(P / "logs" / "job.log", 1 * MIB)
        other = self.root / "外接盘"
        layout.register_location(self.c, other)
        write(other / "temp" / "t2" / "t.bin", 1 * MIB)                # 别的位置的 temp 也算
        out = sizes.overview(self.context("storageOverview"))
        shared = {r["id"]: r["bytes"] for r in out["shared"]}
        self.assertEqual(list(shared), ["hosts", "ipa", "toolCache", "temp", "logs"])
        self.assert_mib(shared["hosts"], 3); self.assert_mib(shared["ipa"], 3); self.assert_mib(shared["temp"], 2)
        self.assert_mib(shared["toolCache"], 1)   # 工作目录就是 <库>/tool-cache 时只算一遍（Windows 实跑曾报成两倍）
        self.assertGreaterEqual(shared["logs"], 1 * MIB)                # 任务记录（jobs/）也在里面，只下限
        rows = {r["path"]: r for r in out["locations"]}
        self.assertEqual(set(rows), {str(L), str(other)})
        self.assertTrue(rows[str(L)]["default"]); self.assertTrue(rows[str(other)]["connected"])
        self.assertGreater(rows[str(L)]["totalBytes"], rows[str(L)]["freeBytes"])
        self.assertGreaterEqual(rows[str(L)]["usedBytes"], (2 + 3 + 2 + 5 + 2 + 3 + 1) * MIB)   # 这款四项 + hosts + S2Arm.ipa + temp
        self.assert_mib(rows[str(other)]["usedBytes"], 1)
        g = {r["gameId"]: r for r in out["games"]}
        self.assertEqual((g[GID]["state"], g[OTHER]["state"]), ("ok", "none"))
        self.assertTrue(g[GID]["sizes"]["measured"])                    # 没量过的这里补量并写回
        self.assertIsNotNone(layout.read_sizes(self.c, GID))
        self.assertEqual(g[OTHER]["sizes"]["sources"], 5 * MIB)

    def test_overview_offline_location(self):
        gone = self.root / "拔掉的盘"
        layout.register_location(self.c, gone)
        import shutil
        shutil.rmtree(gone)   # 测试自己建的临时位置
        rows = {r["path"]: r for r in sizes.overview(self.context("storageOverview"))["locations"]}
        self.assertFalse(rows[str(gone)]["connected"])
        self.assertNotIn("freeBytes", rows[str(gone)])

    def test_overview_drops_previous_library_roots(self):
        """换过游戏库后存储总览「存放位置」不再列没用的旧库根（玩家反馈：设置里改了游戏库位置，总览第二行一直是换之前的 C 盘路径）。
        索引在私有目录、各库共用：① 整库搬家后旧路径那行和本库同号 → 去掉；② 换到别的库后旧库根还在（有 .s2arm-library.json）、
        下面没有游戏记录 → 去掉；③ #946：旧库根下还记着游戏（0.2.x 换库没搬文件的玩家，游戏全在那里）→ 留着、降成普通存放位置，
        游戏照样认得到（原先整行连同游戏记录去掉，升级后库里所有游戏变「未出包」）；真的另一个存放位置（外接盘）照留。期望手写"""
        L = self.c.library
        here = layout.default_id(self.c)
        idx = layout.load_index(self.c)
        moved = self.root / "搬走前的库"                                  # ① 同号的旧路径（搬完已删掉）
        empty = self.root / "空的旧库"; empty.mkdir()                      # ② 旧库还在、没有游戏记录
        (empty / ".s2arm-library.json").write_text('{"schema": 1, "id": "lib-empty"}')
        old = self.root / "上一个库"; old.mkdir()                          # ③ 旧库还在，下面记着游戏
        (old / ".s2arm-library.json").write_text('{"schema": 1, "id": "lib-old"}')
        (old / layout.LOCATION_JSON).write_text('{"schema": 1, "id": "loc-old"}')
        d = old / "games" / "Old"; d.mkdir(parents=True); (d / layout.GAME_JSON).write_text('{"schema": 1, "id": "%s"}' % OTHER)
        idx["locations"] += [dict(id=here, path=str(moved)), dict(id="loc-empty", path=str(empty), library=True), dict(id="loc-old", path=str(old), library=True)]
        idx["games"][OTHER] = dict(location="loc-old", folder="Old")
        layout.save_index(self.c)
        disk = self.root / "外接盘"
        layout.register_location(self.c, disk)
        self.c._layout_idx = None                                          # 下一个作业：从盘上重读索引
        rows = [r["path"] for r in sizes.overview(self.context("storageOverview"))["locations"]]
        self.assertEqual(rows, [str(L), str(old), str(disk)])
        c = self.context("catalog")
        self.assertEqual(layout.load_index(c)["games"][OTHER]["location"], "loc-old")   # 旧库根下的游戏照样认得到
        self.assertNotIn("library", next(l for l in layout.load_index(c)["locations"] if l["id"] == "loc-old"))   # 降成普通存放位置

    def test_location_rows_last_only_points_to_connected(self):
        """#922：last 指着已不存在的位置（换库后常见）→ 位置表的 last 给默认位置；指着连着的外接盘 → 照给"""
        disk = self.root / "外接盘"; lid = layout.register_location(self.c, disk)
        idx = layout.load_index(self.c); idx["last"] = "gone-location"; layout.save_index(self.c)
        self.assertEqual(library.location_rows(self.c)["last"], layout.default_id(self.c))
        idx["last"] = lid; layout.save_index(self.c)
        self.assertEqual(library.location_rows(self.c)["last"], lid)
        import shutil; shutil.rmtree(disk)   # 外接盘拔了：不再给它
        self.c._layout_idx = None
        self.assertEqual(library.location_rows(self.context("locations"))["last"], layout.default_id(self.c))

    def test_catalog_job_returns_sizes(self):
        sizes.refresh(self.c, GID)
        result, event = self.worker("catalog")
        self.assertEqual((result.returncode, event["state"]), (0, "succeeded"), result.stderr)
        g = {x["id"]: x for x in event["result"]["games"]}
        self.assertEqual(set(g[GID]["sizes"]), set(sizes.PARTS) | {"measured"})
        self.assert_mib(g[GID]["sizes"]["saves"], 2)
        self.assertFalse(g[OTHER]["sizes"]["measured"])

    def test_worker_overview(self):
        result, event = self.worker("storageOverview")
        self.assertEqual((result.returncode, event["state"]), (0, "succeeded"), result.stderr)
        self.assertEqual([r["id"] for r in event["result"]["shared"]], list(sizes.SHARED))


if __name__ == "__main__":
    unittest.main()
