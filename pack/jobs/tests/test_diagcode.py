"""诊断码（#1449，pack/jobs/diagcode.py + install.push_diag_code）：出码 / 粘贴解析 / 只收 DM_ 开关 / 只管对得上的那款 / 推进手机即清。
期望值按码的格式手算（base64url(JSON) + CRC32），不跑被测实现推。"""
import base64
import json
import shutil
import sys
import tempfile
import types
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagcode  # noqa: E402
import install  # noqa: E402
from core import Failure  # noqa: E402

GID = "0100F3400332C000"
SCAN = {"DM_NVN_MAGSCAN": "30c6f0c2aa7c3e79:30:600"}


def hand_code(payload):
    body = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()).decode().rstrip("=")
    return f"S2A-DIAG1-{body}-{zlib.crc32(body.encode()) & 0xFFFFFFFF:08x}"


class Code(unittest.TestCase):
    def test_make_matches_hand_format(self):
        self.assertEqual(diagcode.make(GID.lower(), SCAN), hand_code({"g": GID, "e": SCAN}))

    def test_parse_round_trip_and_wrapped_paste(self):
        code = hand_code({"g": GID, "e": SCAN})
        self.assertEqual(diagcode.parse(code), (GID, SCAN))
        wrapped = "  " + code[:20] + "\n" + code[20:41] + " \r\n" + code[41:] + "\n"   # 论坛折行、前后空白
        self.assertEqual(diagcode.parse(wrapped), (GID, SCAN))
        self.assertEqual(diagcode.parse(hand_code({"g": "", "e": SCAN})), ("", SCAN))

    def test_bad_codes(self):
        good = hand_code({"g": GID, "e": SCAN})
        for bad in ("", "hello", good[:-3], good.replace("S2A-DIAG1-", "S2A-DIAG2-"), good[:15] + "x" + good[16:],
                    hand_code({"g": GID, "e": {"S2A_WIDESCREEN": "1"}}),          # 不是 DM_ 开关
                    hand_code({"g": GID, "e": {}}),
                    hand_code({"g": "../etc", "e": SCAN}),
                    hand_code({"g": GID, "e": {"DM_X": "a\nS2A_Y=1"}})):          # 值里夹换行（会在手机文件里多出一行）
            with self.subTest(bad=bad[:30]), self.assertRaises(Failure) as e:
                diagcode.parse(bad)
            self.assertEqual(e.exception.code, "diag_code_invalid")
            self.assertIn("完整复制", str(e.exception))


class Flow(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.msgs, self.diags = [], []
        self.c = types.SimpleNamespace(private=self.t, logs=self.t / "logs", task="t1", r={},
                                       emit=lambda k, m: self.msgs.append(m), diagnostic=lambda m, **k: self.diags.append((m, k)))

    def op(self, **r):
        self.c.r = r
        return diagcode.operation(self.c)

    def test_set_status_clear(self):
        r = self.op(action="set", code=hand_code({"g": GID, "e": SCAN}))
        self.assertEqual((r["game"], r["keys"]), (GID, ["DM_NVN_MAGSCAN"]))
        self.assertIn(GID, r["message"])
        self.assertEqual(self.op(action="status"), dict(pending=True, game=GID, keys=["DM_NVN_MAGSCAN"]))
        self.assertEqual(diagcode.pending(self.c, GID.lower()), SCAN)
        self.assertIsNone(diagcode.pending(self.c, "0100000000000001"))   # 别的游戏不生效
        self.op(action="clear")
        self.assertEqual(self.op(action="status")["pending"], False)

    def test_any_game_code(self):
        self.op(action="set", code=hand_code({"g": "", "e": SCAN}))
        self.assertEqual(diagcode.pending(self.c, "0100000000000001"), SCAN)

    def phone(self, fail=False):
        put = []
        def client(w):
            def p(src, dst):
                if fail: raise RuntimeError("AFC 写不进")
                put.append((dst, Path(src).read_text(encoding="utf-8")))
            return types.SimpleNamespace(put=p)
        return types.SimpleNamespace(client=client, key="dev1"), put

    def test_push_writes_once_file_and_clears(self):
        self.op(action="set", code=hand_code({"g": GID, "e": SCAN}))
        ph, put = self.phone()
        install.push_diag_code(self.c, ph, GID)
        self.assertEqual(put, [(f"Documents/games/{GID}/diag_once.txt", "DM_NVN_MAGSCAN=30c6f0c2aa7c3e79:30:600\n")])
        self.assertIsNone(diagcode.pending(self.c, GID))   # 用掉了
        self.assertEqual(len(self.msgs), 1); self.assertIn("下一局生效一次", self.msgs[0])
        install.push_diag_code(self.c, ph, GID)             # 再推一次不再写
        self.assertEqual(len(put), 1)

    def test_push_other_game_untouched(self):
        self.op(action="set", code=hand_code({"g": GID, "e": SCAN}))
        ph, put = self.phone()
        install.push_diag_code(self.c, ph, "0100000000000001")
        self.assertEqual(put, []); self.assertEqual(diagcode.pending(self.c, GID), SCAN)

    def test_push_failure_keeps_code(self):
        self.op(action="set", code=hand_code({"g": GID, "e": SCAN}))
        ph, _ = self.phone(fail=True)
        install.push_diag_code(self.c, ph, GID)
        self.assertEqual(diagcode.pending(self.c, GID), SCAN)
        self.assertEqual(self.diags[0][1]["severity"], "warning")


if __name__ == "__main__":
    unittest.main()
