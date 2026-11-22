"""本地玩家（#623）：Mac 启动器把顶栏选的玩家放进 launch 请求的 player 字段，作业层（build.runtime_env）给服务层
S2A_PLAYER_USER / S2A_PLAYER_NAME，存档位置换成这款文件夹里这个玩家的那个。期望手写（services/S2A.Services/LocalPlayer.cs 的约定）。"""
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import Failure
import build
import layout

HONG = "d7a43a96495d0a594e615dd88587b6bf"


class LocalPlayerEnvTests(JobCase):
    def game(self):
        return dict(id="0100000000000000", name="Test title", display="1.0", hidden=False, packages=[])

    def env(self, player):
        if player is None:
            self.c.r.pop("player", None)
        else:
            self.c.r["player"] = player
        with patch.dict(os.environ):
            os.environ.pop("S2A_PLAYER_USER", None)
            return build.runtime_env(self.c, self.game(), self.root / "runtime")

    def test_no_player_keeps_the_old_launch(self):
        env = self.env(None)
        self.assertNotIn("S2A_PLAYER_USER", env)
        self.assertNotIn("S2A_PLAYER_NAME", env)
        self.assertEqual(env["S2A_SAVE_FOLDER"], str(layout.path(self.c, self.game()["id"], "SaveData")))

    def test_first_player_keeps_savedata_and_second_gets_her_own_folder(self):
        gid = self.game()["id"]
        env = self.env(dict(user="first", name="", folder="SaveData"))
        self.assertEqual((env["S2A_PLAYER_USER"], env.get("S2A_PLAYER_NAME")), ("first", None))
        self.assertEqual(env["S2A_SAVE_FOLDER"], str(layout.path(self.c, gid, "SaveData")))
        env = self.env(dict(user=HONG, name="Hong", folder="SaveData-Hong"))
        self.assertEqual((env["S2A_PLAYER_USER"], env["S2A_PLAYER_NAME"]), (HONG, "Hong"))
        self.assertEqual(env["S2A_SAVE_FOLDER"], str(layout.path(self.c, gid, "SaveData-Hong")))
        # Ryujinx 数据根不按玩家分（存档按用户号隔离在同一个数据根里）
        self.assertEqual(env["S2A_RYU_DATA"], str(layout.path(self.c, gid, "saves")))

    def test_bad_players_are_rejected(self):
        for bad in ("first", dict(user="first", name="", folder="SaveData-x"), dict(user=HONG, name="H", folder="SaveData"),
                    dict(user="0" * 32, name="", folder="SaveData-a"), dict(user=HONG.upper(), name="", folder="SaveData-a"),
                    dict(user=HONG, name="", folder="SaveData-../../x"), dict(user=HONG, name="", folder="../SaveData"),
                    dict(user=HONG, name=3, folder="SaveData-a")):
            with self.subTest(bad=bad), self.assertRaises(Failure):
                self.env(bad)

    def test_local_players_list_passes_through_to_service_env(self):
        players = [dict(user="first", name="P1", folder="SaveData"),
                   dict(user=HONG, name="Hong", folder="SaveData-Hong")]
        self.c.r["player"] = players[0]
        self.c.r["localPlayers"] = players
        with patch.dict(os.environ):
            os.environ.pop("S2A_LOCAL_PLAYERS", None)
            env = build.runtime_env(self.c, self.game(), self.root / "runtime")
        import json
        self.assertEqual(json.loads(env["S2A_LOCAL_PLAYERS"]), players)


if __name__ == "__main__":
    unittest.main()
