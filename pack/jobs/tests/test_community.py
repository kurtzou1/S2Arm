"""社区资源（pack/jobs/community.py，10-27 维护者 01:4x 口径）：宽屏 / 60 帧是宿主开关（缺省开、可关），版本不符走跨版本定位不判死，
画面同互斥组单选；Mac 启动按选择设 S2A_WIDESCREEN=0 / S2A_FPS60=0。期望按规则手写"""
import unittest.mock as um
import importlib.util
import json, os, shutil, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import community
import layout
from core import Failure

GID = "0100C2500FC20000"


REPO = Path(__file__).resolve().parents[3]


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        self.work_root = root / "work"   # 程序缓存 cache/programs（pack/jobs/programs.py）
        table = self.engine / community.SETTINGS_TABLE   # 定义表用仓库里的真表
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text, encoding="utf-8")


class LdnEnvTests(unittest.TestCase):
    def test_default_and_explicit_auto_preserve_legacy_environment(self):
        self.assertEqual(community.ldn_env({}), {})
        self.assertEqual(community.ldn_env({"ldnMode": "auto", "ldnHost": True}),
                         {"S2A_LDN_AUTO": "1", "S2A_LDN_MITM": "0"})
        self.assertEqual(community.ldn_env({"ldnMode": "auto"}, {"S2A_LDN_SERVER": "10.0.0.5"}),
                         {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0"})

    def test_manual_host_and_client(self):
        self.assertEqual(community.ldn_env({"ldnMode": "manual", "ldnHost": True}),
                         {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                          "S2A_LDN_SERVER": "127.0.0.1", "S2A_LDN_RELAY": "1", "S2A_LDN_LISTEN": "0.0.0.0"})
        self.assertEqual(community.ldn_env({"ldnMode": "manual", "ldnAddress": " 192.168.1.21 "}),
                         {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                          "S2A_LDN_SERVER": "192.168.1.21", "S2A_LDN_RELAY": "0"})
        self.assertEqual(community.ldn_env({"ldnMode": "manual", "ldnAddress": ""}),
                         {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                          "S2A_LDN_SERVER": "0.0.0.0", "S2A_LDN_RELAY": "0"})

    def test_switch_mode_only_enables_ldn_mitm(self):
        # 「与 Switch 联机」只开 ldn_mitm，不混入中继变量；其余模式显式关掉强制开关
        self.assertEqual(community.ldn_env({"ldnMode": "switch", "ldnHost": True, "ldnAddress": "192.168.1.21"}),
                         {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "1"})
        for s in ({}, {"ldnMode": "auto"}, {"ldnMode": "manual", "ldnHost": True}):
            env = community.ldn_env(s)
            self.assertNotEqual(env.get("S2A_LDN_MITM"), "1")

    def test_shared_settings_save_and_launch_wiring(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        table = {it["id"]: it for it in json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))["items"]}
        game, shared = {"schema": 1, "settings": {}, "patches": {}}, {"schema": 1, "settings": {}}
        context = SimpleNamespace(r={"gameId": GID, "settings": {"ldnMode": "manual", "ldnHost": False, "ldnAddress": "192.168.1.21"}})
        writes = {}
        with patch.object(community, "settings_table", return_value=table), \
             patch.object(community, "game_of", return_value={"id": GID}), \
             patch.object(community, "load_launch", return_value=game), \
             patch.object(community, "load_app", return_value=shared), \
             patch.object(community, "launch_path", return_value="game"), \
             patch.object(community, "app_path", return_value="app"), \
             patch.object(community, "atomic", side_effect=lambda path, data: writes.update({path: data})), \
             patch.object(community, "describe_game", return_value={}), \
             patch.object(community, "runtime_caps", return_value={}), \
             patch.object(community, "runtime_caps_rows", return_value={}), \
             patch.object(community, "game_languages", return_value=[]), \
             patch.object(community, "adaptive_patches", return_value=([], False)), \
             patch.object(community, "packed_patches", return_value=[]):
            community.save(context)
            self.assertEqual(writes["game"]["settings"], {})
            self.assertEqual(writes["app"]["settings"], context.r["settings"])
            self.assertEqual(community.mac_settings(context, GID)["ldnAddress"]["value"], "192.168.1.21")
            self.assertEqual(community.launch_env(context, GID),
                             {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                              "S2A_LDN_SERVER": "192.168.1.21", "S2A_LDN_RELAY": "0"})
            self.assertEqual(community.launch_env(context, GID, {"S2A_LDN_SERVER": "10.0.0.5"}),
                             {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0"})

    def test_explicit_server_wins_as_a_whole(self):
        for server in ("10.0.0.5", ""):
            self.assertEqual(community.ldn_env({"ldnMode": "manual", "ldnHost": True}, {"S2A_LDN_SERVER": server}),
                             {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0"})


class CommunityTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": [
            {"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": "AAAA"}},
            {"type": "update", "version": 1 << 16, "display": "4.1.0", "builds": {}}]}]}))
        write(self.c.engine / "graphics/widen/tables/verified.tsv", "# 注释\n程序号\t构建号\t款\t登记日期\t依据\n" + GID + "\taaaa\tspl3\t2026-10-27\t实测\n")
        # 这款 Mac 包里编进去的补丁（产物 cpatch.tsv，11-12 出包时自动查库）：宽屏 / 画面各一份、帧率一份（跟 60 帧开关，不列）、金手指一条（金手指一栏，不列）
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
              "widescreen:aa\tmain\t0\twidescreen\t21:9\tMIT\tx.pchtxt\t\t0\ngfx:bb\tmain\t1\tgfx\t关动态模糊\t\ty.pchtxt\t\t0\n"
              "fps:cc\tmain\t2\tfps\t60 FPS\t\tz.pchtxt\t\t0\ncheat:dd:1\tmain\t-\tcheat\t无限血\t\tc.txt\t\t0\n")
        cd = self.t / "cp"; os.environ["S2A_COMMUNITY_DIR"] = str(cd)
        write(cd / "fps/full/x/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\ttype\ttarget_fps\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t1.1.1\t\tpchtxt\t60\tfpsrepo\tyes\tabc\nSpl\t{GID}\t4.1.0\t\tpchtxt\t30\tother30\tyes\tdef\n")
        write(cd / "uw/full/y/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\taspect\tkind\tui_fix\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t4.1.0\t\t21:9\tpchtxt\tyes\tuwrepo\tyes\t111\n")

    def test_snapshot_switch_env(self):
        # 即时快照（0.6.0，全部游戏共用，宿主苹果端缺省开）：没选过 / 选开 → 不写（宿主缺省开）；选关 → S2A_SNAP_MODE=0。存数据目录 game-settings.json
        self.assertNotIn("S2A_SNAP_MODE", community.launch_env(self.c, GID))
        for on, want in ((True, None), (False, "0")):
            write(self.c.private / "game-settings.json", json.dumps({"schema": 1, "settings": {"snapshot": on}}))
            self.assertEqual(community.launch_env(self.c, GID).get("S2A_SNAP_MODE"), want, f"snapshot={on}")

    def test_defaults_and_sources(self):
        r = community.listing(self.c)
        ws, fps = r["widescreen"], r["fps60"]
        self.assertEqual((ws["available"], ws["verified"], ws["enabled"], ws["sources"], ws["relocate"]), (True, True, True, ["uwrepo"], False))
        self.assertEqual((fps["available"], fps["verified"], fps["enabled"], fps["sources"], fps["relocate"]), (True, False, True, ["fpsrepo"], True))   # 1.1.1≠4.1.0：跨版本定位、不判死；30 帧那条不算
        self.assertEqual([(it["id"], it["enabled"], it["license"]) for it in r["graphics"]], [("widescreen:aa", True, "MIT"), ("gfx:bb", True, "")])   # 11-13 起没选过 = 默认开（Mac 画面类也开）；帧率 / 金手指不在这里

    def test_other_kind_default_off(self):
        # 11-15：认不出是画面的补丁（other:，声音 / 玩法等）列出来可开，但没选过 = 关：启动设置里 enabled 假、起局开关列表不带；玩家明确开了才带。期望手写
        p = layout.image_mac(self.c, GID) / "cpatch.tsv"
        write(p, p.read_text(encoding="utf-8") + "other:ee\tmain\t3\tother\tNo Music\t\to.pchtxt\t\t0\n")
        g = {it["id"]: it for it in community.listing(self.c)["graphics"]}
        self.assertEqual((g["other:ee"]["enabled"], g["other:ee"]["kind"], g["gfx:bb"]["enabled"]), (False, "other", True))
        self.assertEqual(community.launch_env(self.c, GID)["S2A_CPATCH_ON"], "gfx:bb,widescreen:aa")
        self.c.r = {"gameId": GID, "graphics": {"other:ee": True}}
        community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_CPATCH_ON"], "gfx:bb,other:ee,widescreen:aa")

    def test_load_direction_default_off(self):
        # 11-16 维护者：降负载的画面补丁（表第 14 列方向 load）没选过 = 关、玩家可手动开；玩家开过的照旧开；提画质（quality）/ 没写方向的画面补丁照旧缺省开。期望手写：
        #   aa 宽屏开、bb 没方向开、qq 提画质开、ll 降负载没选过关、kk 降负载玩家开过开 → 起局列表 gfx:bb,gfx:kk,gfx:qq,widescreen:aa
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\t组\t方向\n"
              "widescreen:aa\tmain\t0\twidescreen\t21:9\tMIT\tx.pchtxt\t\t0\t\t\t\t\t\ngfx:bb\tmain\t1\tgfx\tLOD\t\ty.pchtxt\t\t0\t\t\t\t\t\n"
              "gfx:qq\tmain\t2\tgfx\t4K\t\tq.pchtxt\t\t0\t\t\t\t\tquality\ngfx:ll\tmain\t3\tgfx\tDisable DOF\t\tl.pchtxt\t\t0\t\t\t\t\tload\n"
              "gfx:kk\tmain\t4\tgfx\tNo Shadows\t\tk.pchtxt\t\t0\t\t\t\t\tload\n")
        self.c.r = {"gameId": GID, "graphics": {"gfx:kk": True}}
        community.save(self.c)
        g = {it["id"]: it["enabled"] for it in community.listing(self.c)["graphics"]}
        self.assertEqual(g, {"widescreen:aa": True, "gfx:bb": True, "gfx:qq": True, "gfx:ll": False, "gfx:kk": True})
        self.assertEqual(community.launch_env(self.c, GID)["S2A_CPATCH_ON"], "gfx:bb,gfx:kk,gfx:qq,widescreen:aa")
        # 玩家再手动开 ll、关 qq：照玩家的 → gfx:bb,gfx:kk,gfx:ll,widescreen:aa
        self.c.r = {"gameId": GID, "graphics": {"gfx:ll": True, "gfx:qq": False}}
        community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_CPATCH_ON"], "gfx:bb,gfx:kk,gfx:ll,widescreen:aa")

    def test_reclassified_keeps_player_choice(self):
        # 11-15 升级改正分类：原先误判成画面、默认开着的去声音补丁（gfx:ff，没选过）重编后成 other:ff → 关；
        #   玩家在旧编号上手动开过的（gfx:gg 记了 True）重编后 other:gg → 照旧开（玩家自行选择优先）；手动关过的（gfx:hh False）照旧关。期望手写
        data = community.load_launch(self.c, GID)
        p = layout.image_mac(self.c, GID) / "cpatch.tsv"
        write(p, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
              "other:ff\tmain\t0\tother\tNo Music\t\tf.pchtxt\t\t0\nother:gg\tmain\t1\tother\tRemove Audio\t\tg.pchtxt\t\t0\n"
              "other:hh\tmain\t2\tother\tSkip Intro\t\th.pchtxt\t\t0\n")
        self.assertEqual(community.choice({"gfx:gg": True}, "other:gg"), True)
        self.assertEqual(community.choice({"gfx:gg": True}, "other:ff"), None)
        self.assertEqual(community.choice({"other:gg": False, "gfx:gg": True}, "other:gg"), False)   # 新编号上的选择优先
        with um.patch.object(community, "load_launch", return_value=dict(data, patches={"gfx:gg": True, "gfx:hh": False})):
            g = {it["id"]: it["enabled"] for it in community.listing(self.c)["graphics"]}
            self.assertEqual(g, {"other:ff": False, "other:gg": True, "other:hh": False})
            self.assertEqual(community.launch_env(self.c, GID)["S2A_CPATCH_ON"], "other:gg")

    def test_save_and_launch_env(self):
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:bb,widescreen:aa", "S2A_WIDESCREEN": "0"})   # 没选过：包里的补丁全开（11-13），开着宽屏补丁 S2Arm 满屏让开；60 帧由宿主定
        self.c.r.update(settings={"widescreen": False, "fps60": False}, graphics={"gfx:bb": True})
        community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDESCREEN": "0", "S2A_FPS60": "0", "DM_PRESENT_FI": "0", "S2A_CPATCH_ON": "gfx:bb,widescreen:aa"})   # 玩家明确关：写 0；没关过的补丁照开
        self.c.r = {"gameId": GID, "graphics": {"widescreen:aa": True}}
        r = community.save(self.c); g = {it["id"]: it for it in r["graphics"]}
        self.assertEqual((g["widescreen:aa"]["enabled"], g["gfx:bb"]["enabled"]), (True, True))
        self.assertEqual({k: v for k, v in community.launch_env(self.c, GID).items() if k in ("S2A_CPATCH_ON", "S2A_WIDESCREEN")},
                         {"S2A_CPATCH_ON": "gfx:bb,widescreen:aa", "S2A_WIDESCREEN": "0"})   # 开着宽屏补丁：S2Arm 满屏让开
        self.assertEqual((r["widescreen"]["enabled"], r["fps60"]["enabled"]), (False, False))       # 没带的项不变
        self.c.r = {"gameId": GID, "graphics": {"nope": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_ldn_manual_settings(self):
        def ldn():
            return {k: v for k, v in community.launch_env(self.c, GID).items() if k.startswith("S2A_LDN_")}
        self.assertEqual(ldn(), {})
        self.c.r.update(settings={"ldnMode": "manual", "ldnHost": True, "ldnAddress": "192.168.1.20"})
        community.save(self.c)
        self.assertEqual(ldn(), {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                                 "S2A_LDN_SERVER": "127.0.0.1", "S2A_LDN_RELAY": "1", "S2A_LDN_LISTEN": "0.0.0.0"})
        self.assertNotIn("ldnMode", community.load_launch(self.c, GID)["settings"])
        self.assertEqual(community.mac_settings(self.c, GID)["ldnAddress"]["value"], "192.168.1.20")
        self.c.r.update(settings={"ldnHost": False, "ldnAddress": " 192.168.1.21 "})
        community.save(self.c)
        self.assertEqual(ldn(), {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                                 "S2A_LDN_SERVER": "192.168.1.21", "S2A_LDN_RELAY": "0"})
        # 未填写不能回到发现 / 选举；保留游戏启动，把连接失败交给宿主。
        self.c.r.update(settings={"ldnAddress": ""}); community.save(self.c)
        self.assertEqual(ldn(), {"S2A_LDN_AUTO": "0", "S2A_LDN_MITM": "0",
                                 "S2A_LDN_SERVER": "0.0.0.0", "S2A_LDN_RELAY": "0"})
        self.c.r.update(settings={"ldnMode": "auto"}); community.save(self.c)
        self.assertEqual(ldn(), {"S2A_LDN_AUTO": "1", "S2A_LDN_MITM": "0"})
        for change in ({"ldnMode": "other"}, {"ldnHost": "true"}, {"ldnAddress": 123}):
            self.c.r.update(settings=change)
            with self.assertRaises(Failure): community.save(self.c)

    def test_unknown_setting_logs_request_keys(self):
        # D-778G：settings 里带定义表里不可存的键（patches 是补丁一栏）照旧拒收；任务日志记下这次请求的设置键与取值类型、请求其他字段，诊断里看得出是哪个入口发的。期望手写
        self.c.logs, self.c.task = self.t / "logs", "t778g"
        self.c.r = {"gameId": GID, "settings": {"patches": {"gfx:bb": True}, "fps60": True}, "graphics": {"gfx:bb": True}}
        with self.assertRaises(Failure) as got: community.save(self.c)
        self.assertIn("没有这个启动设置：patches", str(got.exception))
        log = (self.c.logs / "t778g-decisions.log").read_text(encoding="utf-8")
        self.assertIn("设置键 patches 不是可存的设置（定义表里是 patches / game）", log)
        self.assertIn("{'patches': 'dict', 'fps60': 'bool'}", log); self.assertIn("['gameId', 'graphics']", log)
        self.c.r = {"gameId": GID, "settings": {"noSuchKey": 1}}
        with self.assertRaises(Failure): community.save(self.c)
        self.assertIn("设置键 noSuchKey 不是可存的设置（定义表里没有）", (self.c.logs / "t778g-decisions.log").read_text(encoding="utf-8"))

    def test_game_language(self):
        # 游戏语言（启动设置页）：跟随系统不设变量（宿主读系统首选语言）；选了哪种就把宿主枚举名交给 S2A_SYSTEM_LANGUAGE；不在表里的值拒收
        self.c.r.update(settings={"language": "system"}); community.save(self.c)
        self.assertNotIn("S2A_SYSTEM_LANGUAGE", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"language": "Japanese"}}; community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_SYSTEM_LANGUAGE"], "Japanese")
        self.c.r = {"gameId": GID, "settings": {"language": "Klingon"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_audio_latency(self):
        # 声音延迟（11-14 维护者收 PR #1066 进启动设置）：标准不设变量（设备默认）；低 / 最低 = 请求设备 IO 缓冲 128 / 32 帧；不在表里的值拒收
        self.assertNotIn("S2A_AUDIO_BUFFER_FRAMES", community.launch_env(self.c, GID))
        for v, frames in (("low", "128"), ("lowest", "32")):
            self.c.r = {"gameId": GID, "settings": {"audioLatency": v}}; community.save(self.c)
            self.assertEqual(community.launch_env(self.c, GID)["S2A_AUDIO_BUFFER_FRAMES"], frames)
        self.c.r = {"gameId": GID, "settings": {"audioLatency": "standard"}}; community.save(self.c)
        self.assertNotIn("S2A_AUDIO_BUFFER_FRAMES", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"audioLatency": "16"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_audio_device_ios_same_as_table(self):
        # 输出设备类型（定义表 audioDevice）与 iOS 同一组值同序：ios/settings.m 起局只转 builtin / headphones / external
        #   （"auto" = 没选过不设）、ios/game_options.m 选项块认同一组、shell S2ArmGameSettings 的多选四项同值同序、
        #   C# 选择器认得表里每个值；iOS 平台在表里声明了
        item = next(i for i in json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))["items"] if i["id"] == "audioDevice")
        values = [o["value"] for o in item["options"]]
        self.assertEqual(values, ["auto", "builtin", "headphones", "external"])
        self.assertIn("ios", item["platforms"])
        accept = '[@[@"builtin", @"headphones", @"external"] containsObject:'
        for path in ("ios/settings.m", "ios/game_options.m"):
            self.assertIn(accept, (REPO / path).read_text(encoding="utf-8"))   # 两处接受的显式类型同一组
        shell = (REPO / "shell/Sources/S2ArmShellHost/S2ArmGameSettings.swift").read_text(encoding="utf-8")
        self.assertIn('["auto", "builtin", "headphones", "external"]', shell)   # shell 多选与表同值同序
        csharp = (REPO / "compat/tree/src/Ryujinx.Audio.Backends.Apple/AppleAudioDeviceType.cs").read_text(encoding="utf-8")
        self.assertEqual([v for v in values if f'"{v}"' not in csharp], [])   # C# 选择器认得表里每个值
    def test_resolution_scale_and_fps_limit(self):
        # 渲染分辨率 / 帧率上限（11-17，Mac 补上 iPhone 已有的两项）：缺省 1× / 不限不设变量；0.5× → S2A_RES_SCALE=0.5，30 帧 → S2A_FPS=30；表外取值拒收
        env = community.launch_env(self.c, GID)
        self.assertNotIn("S2A_RES_SCALE", env); self.assertNotIn("S2A_FPS", env)
        self.c.r = {"gameId": GID, "settings": {"resolutionScale": "0.5", "fpsLimit": "30"}}; community.save(self.c)
        env = community.launch_env(self.c, GID)
        self.assertEqual((env["S2A_RES_SCALE"], env["S2A_FPS"]), ("0.5", "30"))
        self.c.r = {"gameId": GID, "settings": {"resolutionScale": "1", "fpsLimit": "0"}}; community.save(self.c)
        env = community.launch_env(self.c, GID)
        self.assertNotIn("S2A_RES_SCALE", env); self.assertNotIn("S2A_FPS", env)
        self.c.r = {"gameId": GID, "settings": {"resolutionScale": "3"}}
        with self.assertRaises(Failure): community.save(self.c)
    def test_game_language_only_supported(self):
        # 11-14 维护者「按你的建议加上」：只列这款 control.nacp 支持的语言；系统语言不支持时在设置里写明起局用哪种（不弹窗）。期望按 NACP 位序手算
        def nacp(*bits):
            raw = bytearray(0x4000); raw[0x302C:0x3030] = sum(1 << b for b in bits).to_bytes(4, "little"); return bytes(raw)
        self.assertEqual(community.nacp_languages(nacp(0, 2, 13, 14)), ["AmericanEnglish", "Japanese", "TraditionalChinese", "SimplifiedChinese"])
        self.assertEqual(community.nacp_languages(nacp()), [])            # 合成的 nacp 不声明：不知道
        self.assertEqual(community.nacp_languages(b"short"), [])
        # #1209：导入合成的 nacp（ns2_dump.synth_nacp）支持表只写了美式英语、显示版本「?」——不是真表，当不知道，下拉列全部（选得到中文）
        spec = importlib.util.spec_from_file_location("ns2_dump", REPO / "pack/ns2_dump.py"); ns2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(ns2)
        self.assertEqual(community.nacp_languages(ns2.synth_nacp(0x0400486024DEC000, "x")), [])
        self.assertEqual(community.nacp_languages(nacp(0)), ["AmericanEnglish"])   # 真表只声明英语（显示版本不是「?」）：照真表
        ctl = layout.image_mac(self.c, GID) / "ctl" / "control.nacp"
        self.assertNotIn("choices", community.mac_settings(self.c, GID)["language"])   # 还没出包（没有 nacp）：照旧列全部
        write(ctl, ""); ctl.write_bytes(nacp(0, 2, 14))                      # 美英、日、简中
        os.environ["S2A_TEST_PREFERRED_LANGUAGES"] = "zh-Hans-CN,en-US"
        try:
            lang = community.mac_settings(self.c, GID)["language"]
            self.assertEqual(lang["choices"], ["system", "AmericanEnglish", "Japanese", "SimplifiedChinese"])
            self.assertNotIn("note", lang)                                    # 系统简中、这款有：不标
            os.environ["S2A_TEST_PREFERRED_LANGUAGES"] = "ko-KR"
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"],
                             {"zh-Hans": "这款不支持한국어，起局用English (US)。", "en": "This game doesn't have 한국어; it starts in English (US)."})
            ctl.write_bytes(nacp(2, 13))                                       # 没有英语：落支持表第一项（日语）
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"]["zh-Hans"], "这款不支持한국어，起局用日本語。")
            self.c.r = {"gameId": GID, "settings": {"language": "German"}}; community.save(self.c)
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"]["zh-Hans"], "这款不支持Deutsch，起局用日本語。")   # 选过的语言这款没有也标
        finally:
            del os.environ["S2A_TEST_PREFERRED_LANGUAGES"]
        # 系统语言映射照宿主 SystemLocale.Map；实际语言照 TitleFallback：想要的 → 美式 / 英式英语 → 支持表第一项
        for tags, want in ((["zh-Hant-HK"], "TraditionalChinese"), (["zh-HK"], "TraditionalChinese"), (["zh-CN"], "SimplifiedChinese"), (["en-GB"], "BritishEnglish"),
                           (["es-MX"], "LatinAmericanSpanish"), (["es"], "Spanish"), (["pt-BR"], "BrazilianPortuguese"), (["fr-CA"], "CanadianFrench"), (["xx", "ja-JP"], "Japanese"), ([], "AmericanEnglish")):
            self.assertEqual(community.system_title_language(tags), want, tags)
        self.assertEqual(community.effective_language("Korean", ["BritishEnglish", "Japanese"]), "BritishEnglish")
        self.assertEqual(community.effective_language("Korean", []), "Korean")

    def test_game_language_ios_same_as_table(self):
        # 游戏语言 iOS 下拉（ios/settings.m s2a_ios_game_languages、ios/app_settings.m 的标签）与定义表 language 的 options 同值同序、条数相同；
        #   每个值都是宿主 SystemLanguage 枚举名（compat/tree/.../SystemLanguage.cs）、iOS 平台在表里声明了
        import re
        item = next(i for i in json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))["items"] if i["id"] == "language")
        values = [o["value"] for o in item["options"]]
        ios = re.search(r"s2a_ios_game_languages\(void\) \{\s*return @\[(.*?)\];", (REPO / "ios/settings.m").read_text(encoding="utf-8"), re.S).group(1)
        self.assertEqual(re.findall(r'@"(\w+)"', ios), values)
        # 给玩家看的名字：游戏内设置页与游戏库每款设置页共用 settings.m s2a_ios_game_language_label（#1252），除「跟随系统」外每个值都要有名字
        label = re.search(r"NSString \*s2a_ios_game_language_label\(NSString \*value\) \{(.*?)\n\}", (REPO / "ios/settings.m").read_text(encoding="utf-8"), re.S).group(1)
        self.assertEqual(sorted(re.findall(r'@"(\w+)": ', label)), sorted(values[1:]))
        enum = (REPO / "compat/tree/src/Ryujinx.HLE/HOS/SystemState/SystemLanguage.cs").read_text(encoding="utf-8")
        self.assertEqual([v for v in values[1:] if not re.search(r"\b%s,?\s" % v, enum)], [])
        self.assertIn("ios", item["platforms"])

    def test_diag_run_is_one_session_only(self):
        # #438 诊断局：打开后下一次起局设定好的四个探针（帧号 3600 / 7200，图写这款文件夹 diagrun/），起局时就把这项从 launch.json 去掉，
        #   第二次起局不再开；上一次诊断局的图清掉。期望值按规格手写
        (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()   # 只看诊断局变量：这款包里没补丁
        self.c.r.update(settings={"diagRun": True})
        community.save(self.c)
        old = layout.path(self.c, GID, "diagrun") / "shot_1.png"; old.parent.mkdir(parents=True, exist_ok=True); old.write_bytes(b"old")
        env = community.launch_env(self.c, GID)
        out = layout.path(self.c, GID, "diagrun")
        self.assertEqual(env, {"DM_NVN_PASSDUMP": "3600-3601", "DM_NVN_TEXDUMP": f"3600,7200:{out}/td_%d.png",
                               "DM_NVN_TEXSNAP": "0,4,8,12,16,20,24,28", "DM_NVN_SHOT": f"3600,7200:{out}/shot_%d.png"})
        self.assertTrue(out.is_dir()); self.assertFalse(old.exists())
        self.assertNotIn("diagRun", community.load_launch(self.c, GID)["settings"])
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_pack_without_patches(self):
        # 包里没编进补丁（没查到 / 还没出 Mac 版）→ 不列、不能存、不设 S2A_CPATCH_ON；宽屏 / 60 帧（我方能力）照常
        (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()
        r = community.listing(self.c)
        self.assertEqual((r["graphics"], r["widescreen"]["available"], r["fps60"]["available"]), ([], True, True))
        self.assertNotIn("S2A_CPATCH_ON", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "graphics": {"gfx:bb": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_no_data(self):
        os.environ["S2A_COMMUNITY_DIR"] = str(self.t / "none")
        (self.c.engine / "graphics/widen/tables/verified.tsv").unlink(); (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()
        r = community.listing(self.c)
        self.assertEqual((r["widescreen"]["available"], r["fps60"]["available"], r["widescreen"]["enabled"], r["graphics"]), (False, False, False, []))



class MacDisplayTests(unittest.TestCase):
    """Mac 设置页：可用与否和缺省跟这款的能力清单走，只存玩家明确选过的。期望按规则手写"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": []}]}))

    def caps(self, text="widen\t0\t# 缺省关\nfps60\t1\t# 开\ndirect\t1\t# 直连\n"):
        write(layout.image_mac(self.c, GID) / "s2a_caps.tsv", "# 注释\n" + text)

    def save(self, **change):
        self.c.r = {"gameId": GID, "settings": change}
        community.save(self.c)
        self.c.r = {"gameId": GID}

    def mac(self):
        return community.mac_settings(self.c, GID)

    def launch_file(self):
        return json.loads(community.launch_path(self.c, GID, create=False).read_text())

    def test_defaults_follow_the_caps(self):
        self.caps()
        m = self.mac()
        self.assertEqual((m["fps60"]["available"], m["fps60"]["value"]), (True, False))   # 清单 1 但原因不是已验证来源：缺省原帧率（同宿主）
        self.assertEqual((m["widescreen"]["available"], m["widescreen"]["value"]), (True, False))   # 清单 widen 0「缺省关」：没选过显示关、可以开
        self.assertEqual((m["quality"]["available"], m["quality"]["value"], m["quality"].get("blocked")), (True, "Bilinear", None))   # 画质提升缺省标准，三档都能选
        self.assertEqual((m["docked"]["value"], m["rumble"]["value"], m["rumbleLevel"]["value"], m["motion"]["value"], m["hud"]["value"]),
                         ("handheld", True, "2", True, False))   # 定义表缺省：掌机模式（11-17 起同 iPhone）、震动开标准档、体感开、浮层关
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_fps60_default_follows_the_verified_reason_like_the_host(self):
        # 同宿主 runtime/src/caps.c s2a_caps_fps60_verified：清单 fps60 1 且原因含「游戏原生 60 帧」，或同时含「社区帧率补丁」与「逻辑速度同局 A/B 绿」才缺省开
        #   （11-23 #2120：只写「社区帧率补丁」的不再缺省开）；我方来源 fps.tsv / A/B 绿只在旧口径 S2A_CAPS_OWN=1 算；值 0 / 别的原因都是原帧率
        os.environ.pop("S2A_CAPS_OWN", None)
        for line, want, own in (("fps60\t1\t# fps.tsv 登记 60 帧\n", False, False), ("fps60\t1\t# 逻辑速度同局 A/B 绿\n", False, False),
                                ("fps60\t1\t# 游戏原生 60 帧\n", True, False), ("fps60\t1\t# 默认开：来源 社区帧率补丁\n", False, False),
                                ("fps60\t1\t# 默认开：来源 社区帧率补丁，逻辑速度同局 A/B 绿（ρ 1.00、q 1.00，2026-11-20）\n", True, False),
                                ("fps60\t0\t# 原帧率：有社区帧率补丁、本构建号没有逻辑速度同局 A/B 绿\n", False, False),
                                ("fps60\t1\t# 全引擎档\n", False, False), ("fps60\t0\t# fps.tsv 判红\n", False, False),
                                ("fps60\t1\t# fps.tsv 登记 60 帧\n", True, True), ("fps60\t1\t# 默认开：来源 社区帧率补丁\n", False, True)):
            with self.subTest(line=line, own=own):
                if own: os.environ["S2A_CAPS_OWN"] = "1"
                try:
                    self.caps(line + "direct\t1\n")
                    self.assertEqual(self.mac()["fps60"]["value"], want)
                    self.assertEqual(community.launch_env(self.c, GID), {})   # 没选过：不写，宿主自己按同一条规则开 / 不开
                finally:
                    os.environ.pop("S2A_CAPS_OWN", None)

    def test_fullscreen_state_four_states(self):
        # 生效值四态（#2205，期望按口径手写）：选开 → 开；选关 → 关；没选 + 有自适应满屏补丁 → 开；没选 + 没补丁 → 关（清单 widen 1 也关）
        self.caps("widen\t1\t# 默认开：widen_verified.tsv\ndirect\t1\n")
        fam = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\nwsauto:fam:w\tmain\t0\tultrawide\tAuto\t\tsrc\t\t1\n"
        for pick, patch, want in ((True, False, True), (False, False, False), (None, True, True), (None, False, False)):
            with self.subTest(pick=pick, patch=patch):
                tsv = layout.image_mac(self.c, GID) / "cpatch.tsv"
                if patch: write(tsv, fam)
                elif tsv.exists(): tsv.unlink()
                self.save(widescreen=pick)   # None = 清掉选择（没选过）
                self.assertEqual(community.fullscreen_state(self.c, GID)[:2], (want, False))

    def test_fullscreen_shown_value_is_what_the_launch_applies(self):
        # #2205：满屏设置页显示的值必须是起局真生效的。我方通用满屏缺省不开（11-15「手动打开满屏走通用方案」）：
        #   清单 widen 1（老包 / 已验证）没选过 → 显示关、起局不写 S2A_WIDEN_VERIFIED；明确开 → 显示开、起局写 1；明确关 → 显示关、写 S2A_WIDESCREEN=0；
        #   强信号 widen 0 → 改不动、显示关、明确开也不写。期望按口径手写
        for caps, pick, shown, env in (("widen\t1\t# 已验证名单\n", None, False, {}),
                                       ("widen\t1\t# 已验证名单\n", True, True, {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"}),
                                       ("widen\t0\t# 缺省关\n", True, True, {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"}),
                                       ("widen\t1\t# 已验证名单\n", False, False, {"S2A_WIDESCREEN": "0"}),
                                       ("widen\t0\t# 强信号：宽屏画面坏\n", True, False, {})):
            with self.subTest(caps=caps, pick=pick):
                self.caps(caps + "direct\t1\n")
                self.save(widescreen=pick)   # None = 清掉选择（没选过）
                self.assertEqual(self.mac()["widescreen"]["value"], shown)
                self.assertEqual({k: v for k, v in community.launch_env(self.c, GID).items() if k.startswith("S2A_WIDE")}, env)

    def test_without_patches_fps60_is_hidden_but_fullscreen_stays(self):
        # 只用社区补丁（11-13 维护者撤掉我方 60 帧）：清单读得到时，没有帧率补丁 → 「60 帧」hidden；
        #   满屏没有宽屏补丁也列、缺省关（11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」，#2205：原先 hidden，玩家没处开）
        self.caps("fps60\t1\t# fps.tsv 登记 60 帧\nwiden\t0\ndirect\t1\n")
        m = self.mac()
        self.assertEqual((m["fps60"].get("hidden"), m["widescreen"].get("hidden"), m["widescreen"]["value"], m["widescreen"]["available"], m["docked"].get("hidden")),
                         (True, None, False, True, None))
        self.caps("fps60\t1\t# 默认开：来源 社区帧率补丁\nwiden\t0\ndirect\t1\n")
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", "编号\t缺省开\nwidescreen:abc\t1\n")
        m = self.mac()
        self.assertEqual((m["fps60"].get("hidden"), m["widescreen"].get("hidden")), (None, None))
        (layout.image_mac(self.c, GID) / "s2a_caps.tsv").unlink()   # 还没出 Mac 版（读不到清单）：照旧都列、先存偏好
        self.assertEqual((self.mac()["fps60"].get("hidden"), self.mac()["widescreen"].get("hidden")), (None, None))

    def test_audio_device_and_virtual_surround(self):
        # 输出设备类型 + 两个虚拟环绕开关（#189 后续，5.1 虚拟环绕第二片，与 iPhone ios/settings.m 同口径）：没选过不设任何变量
        #   （= auto 按设备真实声道判，5.1 直通缺省不变）；显式选了类型设 S2A_AUDIO_DEVICE、拨过的开关设 1 / 0（各存各的，
        #   只在对应显式类型下生效——驱动侧判）；表外取值拒收。Mac 启动页两个开关只在对应类型下可用、值照旧显示
        env = community.launch_env(self.c, GID)
        self.assertNotIn("S2A_AUDIO_DEVICE", env); self.assertNotIn("S2A_AUDIO_VS_SPEAKERS", env); self.assertNotIn("S2A_AUDIO_VS_HEADPHONES", env)
        for device in ("builtin", "headphones", "external"):
            self.c.r = {"gameId": GID, "settings": {"audioDevice": device}}; community.save(self.c)
            self.assertEqual(community.launch_env(self.c, GID).get("S2A_AUDIO_DEVICE"), device)
        self.c.r = {"gameId": GID, "settings": {"audioDevice": "auto"}}; community.save(self.c)
        self.assertNotIn("S2A_AUDIO_DEVICE", community.launch_env(self.c, GID))   # 「自动」：起局与没选过一致
        self.c.r = {"gameId": GID, "settings": {"audioDevice": "soundbar"}}
        with self.assertRaises(Failure): community.save(self.c)
        self.c.r = {"gameId": GID, "settings": {"vsSpeakers": True, "vsHeadphones": False}}; community.save(self.c)
        env = community.launch_env(self.c, GID)
        self.assertEqual((env.get("S2A_AUDIO_VS_SPEAKERS"), env.get("S2A_AUDIO_VS_HEADPHONES")), ("1", "0"))
        self.assertNotIn("S2A_AUDIO_DEVICE", env)   # 只拨开关不算选了类型：设备仍按真实声道判（驱动侧 VS 只在显式类型生效）
        # Mac 启动页：没选类型 = 两个开关都置灰（值照旧显示，拨过的各存各的）；选了耳机只放开耳机开关
        m = self.mac()
        self.assertEqual((m["vsSpeakers"]["available"], m["vsHeadphones"]["available"]), (False, False))
        self.assertEqual((m["vsSpeakers"]["value"], m["vsHeadphones"]["value"]), (True, False))
        self.assertEqual(m["vsSpeakers"]["reason"], community.NO_VS_SPEAKERS)
        self.c.r = {"gameId": GID, "settings": {"audioDevice": "headphones"}}; community.save(self.c)
        m = self.mac()
        self.assertEqual((m["vsSpeakers"]["available"], m["vsHeadphones"]["available"]), (False, True))
        self.assertEqual(m["vsHeadphones"]["reason"], "")
        self.c.r = {"gameId": GID, "settings": {"audioDevice": "builtin"}}; community.save(self.c)
        m = self.mac()
        self.assertEqual((m["vsSpeakers"]["available"], m["vsHeadphones"]["available"]), (True, False))
        self.assertEqual(m["audioDevice"]["available"], True)   # 设备类型本身不受开关影响，随时可选
        self.c.r = {"gameId": GID, "settings": {"audioDevice": "external", "vsSpeakers": True, "vsHeadphones": False}}; community.save(self.c)
        m = self.mac()
        self.assertEqual((m["vsSpeakers"]["available"], m["vsHeadphones"]["available"]), (False, False))
        self.assertEqual((m["vsSpeakers"]["value"], m["vsHeadphones"]["value"]), (True, False))   # 拨过的值照显示（切换类型各自恢复）

    def test_every_mac_item_of_the_table_is_on_the_page(self):
        # 定义表里 platforms 含 mac 的 bool / choice 项 = quality（11-15 取代 enhance）fps60 widescreen docked rumble rumbleLevel motion hud（11-13 widenForce 并进 widescreen）
        self.caps()
        self.assertEqual(sorted(self.mac()), sorted(["quality", "fps60", "fpsPick", "resolutionScale", "fpsLimit", "widescreen", "docked", "language", "rumble", "rumbleLevel", "motion", "motionInvertY", "motionInvertX", "ldnMode", "ldnHost", "ldnAddress", "padFace", "hud", "snapshot", "pauseUnfocused", "audioLatency", "audioDevice", "vsSpeakers", "vsHeadphones", "diagRun"]))

    def test_fps_pick_level(self):
        # 帧率档位（11-13）：包里帧率补丁（编号 fps:）目标帧率两档以上才出；选具体档 → S2A_FPS_PICK=档，选自动（"0"）不写；表外取值拒收
        self.caps("fps60\t1\t# 默认开：来源 社区帧率补丁\nwiden\t0\ndirect\t1\n")
        tsv = layout.image_mac(self.c, GID) / "cpatch.tsv"
        write(tsv, "编号\t缺省开\t目标帧率\nfps:a\t1\t60\nfps:b\t1\t\nwidescreen:x\t1\t\n")   # 60 与没写（当 60）= 一档
        self.assertEqual((community.fps_levels(self.c, GID), self.mac()["fpsPick"].get("hidden")), ([60], True))
        write(tsv, "编号\t缺省开\t目标帧率\nfps:a\t1\t60\nfps:c\t1\t120\ngfx:d\t1\t30\n")       # gfx: 的目标帧率不算档
        self.assertEqual((community.fps_levels(self.c, GID), self.mac()["fpsPick"].get("hidden"), self.mac()["fpsPick"]["value"]), ([60, 120], None, "0"))
        self.assertNotIn("S2A_FPS_PICK", community.launch_env(self.c, GID))
        self.c.r.update(settings={"fpsPick": "60"}); community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_FPS_PICK"], "60")
        self.c.r = {"gameId": GID, "settings": {"fpsPick": "0"}}; community.save(self.c)
        self.assertNotIn("S2A_FPS_PICK", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"fpsPick": "90"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_game_without_a_mac_build_can_still_pick(self):
        # v0.3.1：还没出 Mac 版也能先选、存成偏好（出好后生效）——原先整页置灰写「还没有做好 Mac 版」，玩家只能先去出包
        m = self.mac()
        for key in ("fps60", "widescreen", "quality", "docked", "hud"):
            self.assertTrue(m[key]["available"]); self.assertEqual(m[key]["reason"], "")

    def test_missing_capabilities_give_their_own_reason(self):
        self.caps("widen\t0\ndirect\t0\n")
        m = self.mac()
        self.assertEqual(m["fps60"]["reason"], community.NO_FPS60)
        # 画质提升：没走直连只是锐利放大用不了——这一行照样能选标准 / 2D，锐利放大置灰、写原因
        self.assertEqual((m["quality"]["available"], m["quality"]["blocked"], m["quality"]["reason"]), (True, ["MetalFX", "Fsr"], community.NO_DIRECT))
        self.assertTrue(m["widescreen"]["available"])   # 「缺省关」不是强信号：照样能开
        self.caps("widen\t0\t# 强信号：宽屏画面坏\ndirect\t1\n")
        self.assertEqual((self.mac()["widescreen"]["available"], self.mac()["widescreen"]["reason"]), (False, community.NO_WIDEN))

    def test_quality_reaches_launch_and_turns_back_off(self):
        # 画质提升（11-15）：2D 游戏专用 → S2A_SCALING_FILTER=Nearest；锐利放大 → MetalFX（只在走直连时）；标准 / 回缺省不写；表外取值拒收
        self.caps()
        self.save(quality="MetalFX")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})
        self.assertEqual(self.mac()["quality"]["value"], "MetalFX")
        self.save(quality="Nearest")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "Nearest"})
        self.save(quality="Bilinear")
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.save(quality=None)   # 回缺省：文件里不留这一项
        self.assertEqual((community.launch_env(self.c, GID), self.launch_file()["settings"]), ({}, {}))
        self.save(quality="MetalFX")
        self.caps("fps60\t1\ndirect\t0\n")
        self.assertEqual(community.launch_env(self.c, GID), {})   # 没走直连：锐利放大不生效
        self.save(quality="Nearest")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "Nearest"})   # 2D 不要直连
        # Fsr（FSR 1）是表里的第四档：走直连才设，没走直连不设（同锐利放大）
        self.save(quality="Fsr")
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.caps("fps60\t1\ndirect\t1\n")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "Fsr"})
        self.c.r = {"gameId": GID, "settings": {"quality": "Lanczos"}}   # 表外值
        with self.assertRaises(Failure): community.save(self.c)

    def test_old_enhance_switch_becomes_sharp_upscaling(self):
        # 旧 launch.json 的「画面增强模式」（enhance）11-15 并进画质提升：开 → 锐利放大（MetalFX），关 → 缺省标准；下次存盘旧键删掉
        self.caps()
        path = community.launch_path(self.c, GID)
        write(path, json.dumps({"schema": 1, "settings": {"enhance": True, "hud": True}, "patches": {}}))
        self.assertEqual(self.mac()["quality"]["value"], "MetalFX")
        self.assertEqual(community.launch_env(self.c, GID)["S2A_SCALING_FILTER"], "MetalFX")
        self.save(docked="handheld")
        self.assertEqual(self.launch_file()["settings"], {"quality": "MetalFX", "hud": True, "docked": "handheld"})
        write(path, json.dumps({"schema": 1, "settings": {"enhance": False}, "patches": {}}))
        self.assertEqual(self.mac()["quality"]["value"], "Bilinear")
        self.save(hud=True)
        self.assertEqual(self.launch_file()["settings"], {"hud": True})
        write(path, json.dumps({"schema": 1, "settings": {"enhance": True, "quality": "Nearest"}, "patches": {}}))   # 两个都有：新键为准
        self.assertEqual(self.mac()["quality"]["value"], "Nearest")

    def test_full_screen_matches_iphone(self):
        # 满屏明确开 = 没验证过也铺满（同 iPhone settings.m）；明确关 = 16:9；强信号判坏的款明确开也不开
        self.caps()
        self.save(widescreen=True)
        # 11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」：明确开 = 我方通用满屏，不要 S2A_CAPS_OWN（原先要，手动开也不生效）
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"})
        self.save(widescreen=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDESCREEN": "0"})
        self.caps("widen\t1\t# 默认开：widen_verified.tsv\ndirect\t1\n")
        self.save(widescreen=None)
        self.assertFalse(self.mac()["widescreen"]["value"])                          # 验过的款没选过：起局不开（我方通用满屏缺省不开），显示也关（#2205：原先显示开）
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.caps("widen\t0\t# 强信号：崩溃归因\ndirect\t1\n")
        write(community.launch_path(self.c, GID), json.dumps({"schema": 1, "settings": {"widescreen": True}, "patches": {}}))
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_full_screen_drives_the_adaptive_patch(self):
        # 包里有自适应满屏补丁（wsauto:<族>:w / :n）：满屏开关一并开关它、不单列；开着时 S2Arm 满屏让开、不强开（同 iPhone）
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
        for default in ("1", "0"):
            with self.subTest(default=default):
                self.caps()
                write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv + "".join(f"wsauto:fam:{x}\tmain\t0\tultrawide\tAuto\t\tsrc\t\t{default}\n" for x in "wn")
                      + "gfx:dof\tmain\t1\tother-gfx\tDisable DOF\t\tsrc\t\t0\n")
                self.assertEqual([it["id"] for it in community.packed_patches(self.c, GID)], ["gfx:dof"])
                self.save(widescreen=None)
                self.assertTrue(self.mac()["widescreen"]["value"])                          # 11-13：有自适应满屏补丁就默认开（不看我方验过标签）
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,wsauto:fam", "S2A_WIDESCREEN": "0"})   # 画面补丁没选过也开
                self.save(widescreen=True)
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,wsauto:fam", "S2A_WIDESCREEN": "0"})
                self.save(widescreen=False)
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof", "S2A_WIDESCREEN": "0"})

    def test_fixed_ratio_variants_are_one_item(self):
        # 定画幅宽屏变体（表「画幅」列，11-13）：几份并成一项 widescreen:auto（宿主按窗口比例开最近一份）；开着时 S2Arm 满屏让开；没画幅的单列
        self.caps()
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\n" + \
            "".join(f"widescreen:v{i}\tmain\t{i}\tultrawide\tHUD\t\tsrc\t\t0\t\t{a}\n" for i, a in enumerate(("1.6000", "2.3333")))
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv + "gfx:dof\tmain\t5\tother-gfx\tDisable DOF\t\tsrc\t\t0\t\t\n")
        got = community.packed_patches(self.c, GID)
        self.assertEqual([(it["id"], it["label"], it.get("ratios")) for it in got],
                         [("widescreen:auto", "满屏补丁（按屏幕比例自动选）", ["16:10", "21:9"]), ("gfx:dof", "Disable DOF", None)])
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,widescreen:auto", "S2A_WIDESCREEN": "0"})

    def test_packed_patch_shows_last_session_result(self):
        # 上一局实际结果（runtime/src/cpatch.c 写 游戏库/temp/<程序号>/cpatch_status.tsv）：没生效写原因、开着量到效果写实测、其余空
        self.caps()
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n" + "".join(f"gfx:{x}\tmain\t{i}\tother-gfx\t{x}\t\tsrc\t\t0\n" for i, x in enumerate("abcdef"))
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv)
        write(Path(self.c.library) / "temp" / GID / "cpatch_status.tsv", "gfx:a\t不配套\t\ngfx:b\t开\tfps=60\ngfx:c\t开\taspect=19.5:9\ngfx:d\t开\t\ngfx:e\t开\tfps=31\ngfx:f\t开\tunfilled\n")
        got = {it["id"]: it["result"] for it in community.packed_patches(self.c, GID)}
        self.assertEqual(got, {"gfx:a": "没生效：补丁与这个版本的游戏不配套", "gfx:b": "已生效：上一局实测 60 帧", "gfx:c": "已生效：上一局画面比例 19.5:9", "gfx:d": "",
                               "gfx:e": "开着，但上一局实测只有 31 帧", "gfx:f": "开着，但上一局画面没铺满"})

    def test_old_force_widescreen_choice_becomes_full_screen_on(self):
        # 旧 launch.json 的 widenForce=真（「宽屏强制启用」）= 满屏明确开
        self.caps()
        write(community.launch_path(self.c, GID), json.dumps({"schema": 1, "settings": {"widenForce": True}, "patches": {}}))
        self.assertTrue(self.mac()["widescreen"]["value"])
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"})   # 11-15：明确开 = 我方通用满屏

    def test_fps60_off_and_manual_on_over_a_red_game(self):
        self.caps()
        self.save(fps60=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "0", "DM_PRESENT_FI": "0"})             # 玩家明确关：写 0
        self.assertFalse(self.mac()["fps60"]["value"])
        self.save(fps60=True)                                                               # 清单开的款玩家开：也要明确传 1（宿主不再看清单）
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1", "DM_PRESENT_FI": "1"})
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(fps60=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1", "DM_PRESENT_FI": "1"})
        self.assertTrue(self.mac()["fps60"]["value"])

    def test_changing_one_switch_does_not_decide_the_others(self):
        # 判红的款：改画质提升不能顺手把 60 帧存成开；文件里只有这一项
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(quality="MetalFX")
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(self.launch_file()["settings"], {"quality": "MetalFX"})
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})

    def test_chosen_docked_survives_the_handheld_default(self):
        # 11-17 缺省改掌机：玩家在这款设置里选过主机的，launch.json 里存着 docked，起局照旧主机（build.launch 在缺省之后合并 launch_env）；没选过的不写，走缺省
        self.caps()
        self.assertNotIn("S2A_DOCKED", community.launch_env(self.c, GID))
        self.save(docked="docked")
        self.assertEqual(community.launch_env(self.c, GID)["S2A_DOCKED"], "1")
        self.assertEqual(self.mac()["docked"]["value"], "docked")

    def test_controls_and_mode_reach_the_host(self):
        # 掌机 → S2A_DOCKED=0；浮层开 → S2A_HUD=1；震动关 → S2A_RUMBLE=0；强度「强」(4) → 倍率 1.8；体感关 → S2A_MOTION=0
        self.caps()
        self.save(docked="handheld", hud=True, rumble=False, rumbleLevel="4", motion=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_DOCKED": "0", "S2A_HUD": "1", "S2A_RUMBLE": "0", "S2A_RUMBLE_SCALE": "1.8", "S2A_MOTION": "0"})

    def test_motion_invert_reaches_the_host(self):
        # #1551：体感上下 / 左右反过来，开着才写 S2A_MOTION_INVERT_Y / _X=1；缺省（没选过）与关都不写
        self.caps()
        self.assertNotIn("S2A_MOTION_INVERT_Y", community.launch_env(self.c, GID))
        self.save(motionInvertY=True)
        env = community.launch_env(self.c, GID)
        self.assertEqual((env.get("S2A_MOTION_INVERT_Y"), env.get("S2A_MOTION_INVERT_X")), ("1", None))
        self.save(motionInvertY=False, motionInvertX=True)
        env = community.launch_env(self.c, GID)
        self.assertEqual((env.get("S2A_MOTION_INVERT_Y"), env.get("S2A_MOTION_INVERT_X")), (None, "1"))

    def test_max_blast_rumble_level(self):
        # 「震爆我」(5) → 倍率 5.0；iOS ios/controller.m 的六档倍率表与定义表一致
        self.caps()
        self.save(rumbleLevel="5")
        self.assertEqual(community.launch_env(self.c, GID)["S2A_RUMBLE_SCALE"], "5.0")
        import re
        table = json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))
        scale = next(i for i in table["items"] if i["id"] == "rumbleLevel")["scale"]
        ios = re.search(r"gains\[6\] = \{([^}]*)\}", (REPO / "ios" / "controller.m").read_text(encoding="utf-8")).group(1)
        self.assertEqual([float(x.strip().rstrip("f")) for x in ios.split(",")], [scale[str(i)] for i in range(6)])

    def test_pad_face_is_shared_by_every_game(self):
        # 全游戏共用：存数据目录 game-settings.json、不进这款 launch.json；另一款（没有 Mac 版）也读到「Switch 布局」；起局转 S2A_PAD_FACE=switch
        self.caps()
        self.save(padFace="switch")
        self.assertEqual(json.loads((self.c.private / "game-settings.json").read_text())["settings"], {"padFace": "switch"})
        self.assertEqual(self.launch_file()["settings"], {})
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_PAD_FACE": "switch"})
        other = "0100000000000001"
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": []}, {"id": other, "packages": []}]}))
        m = community.mac_settings(self.c, other)
        self.assertEqual((m["padFace"]["available"], m["padFace"]["value"]), (True, "switch"))
        self.assertEqual(community.launch_env(self.c, other), {"S2A_PAD_FACE": "switch"})
        self.save(padFace="xbox")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_PAD_FACE": "xbox"})
        self.save(padFace=None)   # 回缺省「自动」：不设环境变量
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.assertEqual(community.mac_settings(self.c, GID)["padFace"]["value"], "auto")

    def test_pad_face_old_values_still_count(self):
        # 11-11 前存下的旧值：按位置 = Switch 布局（照旧转 switch），按字母 = 自动（不设环境变量）
        self.caps()
        for old, value, env in (("position", "switch", {"S2A_PAD_FACE": "switch"}), ("letter", "auto", {})):
            write(self.c.private / "game-settings.json", json.dumps({"schema": 1, "settings": {"padFace": old}}))
            self.assertEqual(community.mac_settings(self.c, GID)["padFace"]["value"], value)
            self.assertEqual(community.launch_env(self.c, GID), env)

    def test_bad_key_or_value_is_refused_and_file_unchanged(self):
        self.caps()
        self.save(hud=True)
        for bad in ({"nosuch": True}, {"docked": "tabletop"}, {"hud": "yes"}, {"input": True}):
            self.c.r = {"gameId": GID, "settings": bad}
            with self.assertRaises(Failure): community.save(self.c)
        self.assertEqual(self.launch_file()["settings"], {"hud": True})

    def test_old_community_file_is_moved_once(self):
        # schema 3：widenForce / metalfx / fps60 都是玩家选的 → widescreen（满屏明确开，11-13 并入）/ quality 锐利放大（11-15 并进画质提升）/ fps60；补丁带过去；旧文件删掉
        self.caps()
        old = layout.path(self.c, GID, "community.json")
        write(old, json.dumps({"schema": 3, "widescreen": False, "fps60": True, "widenForce": True, "metalfx": True, "enabled": {"gfx:a": True}}))
        self.assertEqual(self.mac()["quality"]["value"], "MetalFX")
        self.assertEqual(self.launch_file(), {"schema": 1, "settings": {"widescreen": True, "quality": "MetalFX", "fps60": True}, "patches": {"gfx:a": True}})
        self.assertFalse(old.exists())

    def test_old_file_written_by_the_previous_panel_is_not_a_manual_choice(self):
        # schema 2 存盘总带 fps60=真：不算玩家选的，判红的款 60 帧仍关
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        write(layout.path(self.c, GID, "community.json"), json.dumps({"schema": 2, "widescreen": True, "fps60": True, "enabled": {}}))
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(community.launch_env(self.c, GID), {})

if __name__ == "__main__":
    unittest.main()
