"""社区资源（pack/jobs/community.py，10-27 维护者 01:4x 口径）：宽屏 / 60 帧是宿主开关（缺省开、可关），版本不符走跨版本定位不判死，
画面同互斥组单选；Mac 启动按选择设 S2A_WIDESCREEN=0 / S2A_FPS60=0。期望按规则手写"""
import json, os, shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import community
import layout
from core import Failure

GID = "0100C2500FC20000"


REPO = Path(__file__).resolve().parents[3]


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        table = self.engine / community.SETTINGS_TABLE   # 定义表用仓库里的真表
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text, encoding="utf-8")


class CommunityTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": [
            {"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": "AAAA"}},
            {"type": "update", "version": 1 << 16, "display": "4.1.0", "builds": {}}]}]}))
        write(self.c.engine / "graphics/widen/tables/verified.tsv", "# 注释\n程序号\t构建号\t款\t登记日期\t依据\n" + GID + "\taaaa\tspl3\t2026-10-27\t实测\n")
        write(self.c.engine / "graphics/community/other_gfx.tsv", "程序号\t版本\t编号\t名称\t互斥组\t已验证\t来源\n"
              f"{GID}\t4.1.0\tres1080\t1080p\tres\t0\t社区A\n{GID}\t4.1.0\tres900\t900p\tres\t0\t社区A\n{GID}\t4.1.0\tnoblur\t关动态模糊\t\t1\t社区B\n{GID}\t3.0.0\tfov\tFOV 加大\t\t0\t社区C\n")
        cd = self.t / "cp"; os.environ["S2A_COMMUNITY_DIR"] = str(cd)
        os.environ["S2A_COMMUNITY_PATCHES"] = "1"   # 下面三例按内部开发 / 测试包口径（列画面补丁）；玩家包缺省见 test_player_pack_no_graphics
        write(cd / "fps/full/x/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\ttype\ttarget_fps\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t1.1.1\t\tpchtxt\t60\tfpsrepo\tyes\tabc\nSpl\t{GID}\t4.1.0\t\tpchtxt\t30\tother30\tyes\tdef\n")
        write(cd / "uw/full/y/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\taspect\tkind\tui_fix\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t4.1.0\t\t21:9\tpchtxt\tyes\tuwrepo\tyes\t111\n")

    def test_defaults_and_sources(self):
        r = community.listing(self.c)
        ws, fps = r["widescreen"], r["fps60"]
        self.assertEqual((ws["available"], ws["verified"], ws["enabled"], ws["sources"], ws["relocate"]), (True, True, True, ["uwrepo"], False))
        self.assertEqual((fps["available"], fps["verified"], fps["enabled"], fps["sources"], fps["relocate"]), (True, False, True, ["fpsrepo"], True))   # 1.1.1≠4.1.0：跨版本定位、不判死；30 帧那条不算
        g = {it["id"]: it for it in r["graphics"]}
        self.assertEqual((g["gfx:noblur"]["enabled"], g["gfx:res1080"]["enabled"], g["gfx:fov"]["relocate"]), (True, False, True))

    def test_save_and_launch_env(self):
        self.assertEqual(community.launch_env(self.c, GID), {})                             # 没选过都不设：宽屏缺省开、60 帧由宿主按清单原因定
        self.c.r.update(settings={"widescreen": False, "fps60": False}, graphics={"gfx:res1080": True})
        community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDESCREEN": "0", "S2A_FPS60": "0"})   # 玩家明确关：写 0
        self.c.r = {"gameId": GID, "graphics": {"gfx:res900": True}}
        r = community.save(self.c); g = {it["id"]: it for it in r["graphics"]}
        self.assertEqual((g["gfx:res900"]["enabled"], g["gfx:res1080"]["enabled"]), (True, False))   # 互斥组单选
        self.assertEqual((r["widescreen"]["enabled"], r["fps60"]["enabled"]), (False, False))       # 没带的项不变
        self.c.r = {"gameId": GID, "graphics": {"nope": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_game_language(self):
        # 游戏语言（启动设置页）：跟随系统不设变量（宿主读系统首选语言）；选了哪种就把宿主枚举名交给 S2A_SYSTEM_LANGUAGE；不在表里的值拒收
        self.c.r.update(settings={"language": "system"}); community.save(self.c)
        self.assertNotIn("S2A_SYSTEM_LANGUAGE", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"language": "Japanese"}}; community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_SYSTEM_LANGUAGE"], "Japanese")
        self.c.r = {"gameId": GID, "settings": {"language": "Klingon"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_game_language_ios_same_as_table(self):
        # 游戏语言 iOS 下拉（ios/settings.m s2a_ios_game_languages、ios/app_settings.m 的标签）与定义表 language 的 options 同值同序、条数相同；
        #   每个值都是宿主 SystemLanguage 枚举名（compat/tree/.../SystemLanguage.cs）、iOS 平台在表里声明了
        import re
        item = next(i for i in json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))["items"] if i["id"] == "language")
        values = [o["value"] for o in item["options"]]
        ios = re.search(r"s2a_ios_game_languages\(void\) \{\s*return @\[(.*?)\];", (REPO / "ios/settings.m").read_text(encoding="utf-8"), re.S).group(1)
        self.assertEqual(re.findall(r'@"(\w+)"', ios), values)
        menu = (REPO / "ios/app_settings.m").read_text(encoding="utf-8")
        labels = re.search(r"labels = @\[S2AL\(@\"settings.gameLanguage.system\"\),(.*?)\];", menu, re.S).group(1)
        self.assertEqual(len(re.findall(r'@"[^"]+"\)?', labels)) + 1, len(values))   # 字面量与 S2AL(@"键") 各算一项
        enum = (REPO / "compat/tree/src/Ryujinx.HLE/HOS/SystemState/SystemLanguage.cs").read_text(encoding="utf-8")
        self.assertEqual([v for v in values[1:] if not re.search(r"\b%s,?\s" % v, enum)], [])
        self.assertIn("ios", item["platforms"])

    def test_diag_run_is_one_session_only(self):
        # #438 诊断局：打开后下一次起局设定好的四个探针（帧号 3600 / 7200，图写这款文件夹 diagrun/），起局时就把这项从 launch.json 去掉，
        #   第二次起局不再开；上一次诊断局的图清掉。期望值按规格手写
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

    def test_player_pack_no_graphics(self):
        # 10-30 维护者：玩家包不带上游补丁字节（S2A_COMMUNITY_PATCHES 没设）→ 画面补丁不列、不能存；宽屏 / 60 帧（我方能力）照常
        os.environ.pop("S2A_COMMUNITY_PATCHES", None)
        r = community.listing(self.c)
        self.assertEqual((r["graphics"], r["widescreen"]["available"], r["fps60"]["available"]), ([], True, True))
        self.c.r = {"gameId": GID, "graphics": {"gfx:res1080": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_no_data(self):
        os.environ["S2A_COMMUNITY_DIR"] = str(self.t / "none")
        for f in ("graphics/community/other_gfx.tsv", "graphics/widen/tables/verified.tsv"): (self.c.engine / f).unlink()
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
        self.assertEqual((m["widenForce"]["available"], m["widenForce"]["value"]), (True, False))
        self.assertEqual((m["enhance"]["available"], m["enhance"]["value"]), (True, False))
        self.assertEqual((m["docked"]["value"], m["rumble"]["value"], m["rumbleLevel"]["value"], m["motion"]["value"], m["hud"]["value"]),
                         ("docked", True, "2", True, False))   # 定义表缺省：Mac 主机模式、震动开标准档、体感开、浮层关
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_fps60_default_follows_the_verified_reason_like_the_host(self):
        # 同宿主 runtime/src/caps.c：清单 fps60 1 且原因含「fps.tsv」「逻辑速度同局 A/B 绿」「游戏原生 60 帧」之一才缺省开；值 0 / 别的原因都是原帧率
        for line, want in (("fps60\t1\t# fps.tsv 登记 60 帧\n", True), ("fps60\t1\t# 逻辑速度同局 A/B 绿\n", True),
                           ("fps60\t1\t# 游戏原生 60 帧\n", True), ("fps60\t1\t# 全引擎档\n", False), ("fps60\t0\t# fps.tsv 判红\n", False)):
            with self.subTest(line=line):
                self.caps(line + "direct\t1\n")
                self.assertEqual(self.mac()["fps60"]["value"], want)
                self.assertEqual(community.launch_env(self.c, GID), {})   # 没选过：不写，宿主自己按同一条规则开 / 不开

    def test_every_mac_item_of_the_table_is_on_the_page(self):
        # 定义表里 platforms 含 mac 的 bool / choice 项 = enhance fps60 widescreen widenForce docked rumble rumbleLevel motion hud
        self.caps()
        self.assertEqual(sorted(self.mac()), sorted(["enhance", "fps60", "widescreen", "widenForce", "docked", "language", "rumble", "rumbleLevel", "motion", "padFace", "hud", "pauseUnfocused", "diagRun"]))

    def test_game_without_a_mac_build_can_still_pick(self):
        # v0.3.1：还没出 Mac 版也能先选、存成偏好（出好后生效）——原先整页置灰写「还没有做好 Mac 版」，玩家只能先去出包
        m = self.mac()
        for key in ("fps60", "widenForce", "enhance", "docked", "hud"):
            self.assertTrue(m[key]["available"]); self.assertEqual(m[key]["reason"], "")

    def test_missing_capabilities_give_their_own_reason(self):
        self.caps("widen\t0\ndirect\t0\n")
        m = self.mac()
        self.assertEqual(m["fps60"]["reason"], community.NO_FPS60)
        self.assertEqual(m["enhance"]["reason"], community.NO_DIRECT)
        self.assertTrue(m["widenForce"]["available"])

    def test_enhance_reaches_launch_and_turns_back_off(self):
        self.caps()
        self.save(enhance=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})
        self.assertTrue(self.mac()["enhance"]["value"])
        self.save(enhance=None)   # 回缺省：文件里不留这一项
        self.assertEqual((community.launch_env(self.c, GID), self.launch_file()["settings"]), ({}, {}))
        self.save(enhance=True)
        self.caps("fps60\t1\ndirect\t0\n")
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_force_widescreen_matches_iphone(self):
        self.caps()
        self.save(widenForce=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"})

    def test_fps60_off_and_manual_on_over_a_red_game(self):
        self.caps()
        self.save(fps60=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "0"})             # 玩家明确关：写 0
        self.assertFalse(self.mac()["fps60"]["value"])
        self.save(fps60=True)                                                               # 清单开的款玩家开：也要明确传 1（宿主不再看清单）
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1"})
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(fps60=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1"})
        self.assertTrue(self.mac()["fps60"]["value"])

    def test_changing_one_switch_does_not_decide_the_others(self):
        # 判红的款：改画面增强不能顺手把 60 帧存成开；文件里只有这一项
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(enhance=True)
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(self.launch_file()["settings"], {"enhance": True})
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})

    def test_controls_and_mode_reach_the_host(self):
        # 掌机 → S2A_DOCKED=0；浮层开 → S2A_HUD=1；震动关 → S2A_RUMBLE=0；强度「强」(4) → 倍率 1.8；体感关 → S2A_MOTION=0
        self.caps()
        self.save(docked="handheld", hud=True, rumble=False, rumbleLevel="4", motion=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_DOCKED": "0", "S2A_HUD": "1", "S2A_RUMBLE": "0", "S2A_RUMBLE_SCALE": "1.8", "S2A_MOTION": "0"})

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
        # schema 3：widenForce / metalfx / fps60 都是玩家选的 → enhance / widenForce / fps60；补丁带过去；旧文件删掉
        self.caps()
        old = layout.path(self.c, GID, "community.json")
        write(old, json.dumps({"schema": 3, "widescreen": False, "fps60": True, "widenForce": True, "metalfx": True, "enabled": {"gfx:a": True}}))
        self.assertTrue(self.mac()["enhance"]["value"])
        self.assertEqual(self.launch_file(), {"schema": 1, "settings": {"widescreen": False, "widenForce": True, "enhance": True, "fps60": True}, "patches": {"gfx:a": True}})
        self.assertFalse(old.exists())

    def test_old_file_written_by_the_previous_panel_is_not_a_manual_choice(self):
        # schema 2 存盘总带 fps60=真：不算玩家选的，判红的款 60 帧仍关
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        write(layout.path(self.c, GID, "community.json"), json.dumps({"schema": 2, "widescreen": True, "fps60": True, "enabled": {}}))
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(community.launch_env(self.c, GID), {})

if __name__ == "__main__":
    unittest.main()
