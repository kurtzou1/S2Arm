"""诊断码（#1449）：维护者在帖子里给玩家一串诊断码，玩家粘进电脑启动器，下次把这款推到 iPhone（或在 Mac 上起这款）时生效一局，跑完自动失效。
为什么：iPhone 上从桌面点开带不了环境变量，玩家也放不进 App 容器的 env.txt；界面「诊断局」只开固定一组探针。诊断码让我们按需开别的诊断开关，
  玩家只做「粘一下、推一次、玩一局、导诊断包」，不加看不懂的选项。

码的样子：S2A-DIAG1-<内容>-<校验>
  内容 = base64url(JSON {"g": 游戏号（16 位十六进制，空 = 下一款推的游戏）, "e": {开关: 值}})，校验 = 内容的 CRC32（8 位十六进制，挡复制时截断 / 改字）。
  粘贴时中间夹的空白、换行都去掉（论坛排版会折行）。
只收 DM_ 开头的诊断开关（同手机端 envfile.c s2a_envfile_apply_once）：码贴在公开帖里，不让它改别的启动行为。

手机端：推送时写进本款文档根 diag_once.txt（KEY=VALUE 每行一条），宿主起局读到就先改名作废再生效（runtime/src/envfile.c）。
Mac：起这款时直接并进起局环境（community.launch_env）。两边谁先用掉，电脑上这条待用的码就清掉。

维护者出码：python3 pack/jobs/diagcode.py make <游戏号或 -> DM_X=值 [DM_Y=值 …]"""
from __future__ import annotations

import base64
import json
import re
import sys
import time
import zlib
from pathlib import Path

from core import Failure, atomic, read, trace

PREFIX = "S2A-DIAG1-"
KEY = re.compile(r"DM_[A-Z0-9_]{1,60}")
GID = re.compile(r"[0-9A-F]{16}")
MAX_KEYS, MAX_VALUE = 16, 512
ONCE = "diag_once.txt"   # 手机上本款文档根下的文件名（envfile.c 同名）

BAD = "诊断码不对：请从帖子里完整复制那一整串（以 S2A-DIAG1- 开头），再粘一次。"
SET = "已收下诊断码（游戏 {0}）：下次把这款推到 iPhone（或在这台 Mac 上开它）时生效一局，玩完自动失效。"
SET_ANY = "已收下诊断码：下次推到 iPhone（或在这台 Mac 上开）的那一款生效一局，玩完自动失效。"
CLEARED = "诊断码已清掉。"
PUSHED = "诊断码已写进 iPhone：下一局生效一次，玩完请在 S2Arm 里导出诊断包。"


def _crc(body):
    return f"{zlib.crc32(body.encode('ascii')) & 0xFFFFFFFF:08x}"


def make(gid, env):
    """维护者出码：gid 空 = 不限游戏"""
    gid = (gid or "").upper()
    check(gid, env)
    body = base64.urlsafe_b64encode(json.dumps({"g": gid, "e": env}, separators=(",", ":"), sort_keys=True).encode()).decode().rstrip("=")
    return f"{PREFIX}{body}-{_crc(body)}"


def check(gid, env):
    if gid and not GID.fullmatch(gid):
        raise Failure(BAD, code="diag_code_invalid", internal=f"游戏号不对：{gid}")  # 非玩家句（internal 只进日志）
    if not isinstance(env, dict) or not env or len(env) > MAX_KEYS:
        raise Failure(BAD, code="diag_code_invalid", internal="开关为空或太多")  # 非玩家句
    for k, v in env.items():
        if not isinstance(k, str) or not KEY.fullmatch(k) or not isinstance(v, str) or len(v) > MAX_VALUE or any(ch in v for ch in "\r\n\0"):
            raise Failure(BAD, code="diag_code_invalid", internal=f"开关不合法：{str(k)[:64]}")  # 非玩家句


def parse(code):
    """粘贴的码 → (游戏号或空, {开关: 值})；不对 → Failure diag_code_invalid"""
    s = re.sub(r"\s+", "", str(code or ""))
    if not s.startswith(PREFIX):
        raise Failure(BAD, code="diag_code_invalid", internal="前缀不对")  # 非玩家句
    body, _, crc = s[len(PREFIX):].rpartition("-")
    if not body or crc.lower() != _crc(body):
        raise Failure(BAD, code="diag_code_invalid", internal="校验不对（复制不全）")  # 非玩家句
    try:
        d = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except ValueError:
        raise Failure(BAD, code="diag_code_invalid", internal="内容解不开") from None  # 非玩家句
    gid, env = str(d.get("g") or "").upper(), d.get("e")
    check(gid, env)
    return gid, env


def _path(c):
    return Path(c.private) / "diagcode.json"   # 有的上下文给的是字符串


def pending(c, gid):
    """这款现在有没有待用的诊断码 → {开关: 值} 或 None（码限定了别的游戏 = None）"""
    if getattr(c, "private", None) is None:   # 没有私有目录的上下文（只算起局环境的单测替身）：没有待用码
        return None
    p = read(_path(c), None) or {}
    if not p.get("env") or (p.get("game") and p["game"] != gid.upper()):
        return None
    return dict(p["env"])


def used(c, how):
    """码用掉了（写进手机 / Mac 起局用了）：清掉，记一行用在哪"""
    _path(c).unlink(missing_ok=True)
    trace(c, f"诊断码已用掉：{how}")  # 非玩家句


def once_text(env):
    return "".join(f"{k}={v}\n" for k, v in sorted(env.items()))


def operation(c):
    """作业 diagCode：set（code）收下一条码（只留最新一条）；clear 清掉；status 看有没有待用的"""
    action = c.r.get("action") or "status"
    if action == "set":
        gid, env = parse(c.r.get("code"))
        atomic(_path(c), dict(game=gid, env=env, at=time.time()))
        return dict(game=gid, keys=sorted(env), message=SET.format(gid) if gid else SET_ANY)
    if action == "clear":
        _path(c).unlink(missing_ok=True)
        return dict(cleared=True, message=CLEARED)
    if action == "status":
        p = read(_path(c), None) or {}
        return dict(pending=bool(p.get("env")), game=p.get("game") or "", keys=sorted(p.get("env") or {}))
    raise Failure("不支持的诊断码操作。")


if __name__ == "__main__":   # 维护者出码
    if len(sys.argv) < 4 or sys.argv[1] != "make":
        print("用法：diagcode.py make <游戏号或 -> DM_X=值 [DM_Y=值 …]", file=sys.stderr)
        sys.exit(2)
    pairs = dict(a.split("=", 1) for a in sys.argv[3:])
    print(make("" if sys.argv[2] == "-" else sys.argv[2], pairs))
