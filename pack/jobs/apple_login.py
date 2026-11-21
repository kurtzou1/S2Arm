#!/usr/bin/env python3
"""0.6.0 通用壳 Mac 的 Apple ID 登录（11-17 方案 A）：启动器自己的登录框 → 随包 plumesign account login，账号存档与私钥落私有目录 plumesign/
（install.mac_plume）。之后签名、续签都用 plumesign 自己存的凭据，启动器不再碰密码。

作业 appleLogin：请求 {account}；密码由适配层起作业进程时放环境变量 S2A_APPLE_PASSWORD，main.run_request 一启动就从环境里摘掉（同证书密码），
  不进请求文件、不传给任何子进程的环境与参数、不写日志——只写进 plumesign 的标准输入（同版 v2.7.2 apps/plumesign/src/commands/account.rs login：
  密码、两步验证码都是 stdin read_line，不要求终端）。
  两步验证：plumesign 提示输入验证码时发 progress 事件 stageKey = appleLogin.needCode（带 account、canSms、sms）；界面经适配层写 <私有目录>/login/<作业号>.code
  （只放 6 位数字），作业读到立刻删、写进 plumesign 的标准输入；最多等 CODE_WAIT 秒。「没收到？再发一次」= 取消这次作业、重起一次。
  短信：苹果设备方式且账号有受信任手机号时，plumesign 的提示是「Enter the code sent to your device, or type 'sms' to receive it by text message」
  （同版 account.rs tfa_closure）→ canSms = True；界面「改用短信接收」往同一个文件写 sms，作业转给 plumesign，它改发短信、再提示
  「Enter the code sent via SMS」→ 再发一次 needCode（sms = True）。受信任手机号不止一个时 plumesign 要弹 dialoguer 选号菜单，
  管道里没有终端，它以「IO error: not a terminal」退出（rc 1）：报 two_factor_wrong + 定句「多个手机号选不了」，叫玩家重新登录改用设备上的验证码。
  验证码交过一次后同一次登录又来要码（苹果接受了码却不信任这台电脑）：不再转给界面，杀掉 plumesign，报 login_identity_rejected + 定句 SAY_2FA_REPEAT。
  结果 {account, team, teamName}；失败码：apple_id_wrong（账号或密码不对）/ two_factor_wrong（验证码不对或过期）/
  signing_server_unreachable、apple_server_unreachable（连不上）/ 其余 job_failed + plumesign 原句。
冷却（#1864）：苹果回 5xx 拒收后，下一次登录先等够冷却再连（30 秒起、连续拒收翻倍、封顶 5 分钟，成功或别的结果清零），等的时候发 appleLogin.wait。
作业 appleAccount：当前登录的账号 → {account, team, teamName}；没登录 → {account: None}。
通用壳开关关着（0.6.0 前缺省）两个作业都只回 {enabled: False}，什么都不做。"""
import json, os, re, subprocess, threading, time
from pathlib import Path

from core import Failure

PASSWORD_ENV = "S2A_APPLE_PASSWORD"
CODE_WAIT = 600            # 等玩家填验证码的上限（秒）
NEED_CODE = re.compile(r"enter (?:the code sent|2fa code)", re.I)   # 同版 account.rs tfa_closure 的三种提示
CAN_SMS = re.compile(r"type 'sms'", re.I)          # 设备方式、账号有受信任手机号：可改发短信
VIA_SMS = re.compile(r"code sent via sms", re.I)   # 已是短信方式
SMS = "sms"
NO_TERMINAL = re.compile(r"not a terminal", re.I)  # 多个受信任手机号：dialoguer 选号菜单要终端（Select::interact → NotConnected）
SAY_SMS_PICK = "这个 Apple ID 绑了不止一个受信任手机号，S2Arm 选不了发到哪一个：重新登录，改用苹果设备上弹出的验证码。"
# 验证码已被苹果接受、它又来要码（玩家报「输入验证码后无限循环」）：再输也一样，停下说清。plumesign 自己最多重登一次、又要码就以
# S2A_2FA_REPEAT 退出（补丁 0002）；这里是兜底：同一次登录里交过一次 6 位码后又看到要码提示，就不再转给界面
REPEAT = "S2A_2FA_REPEAT"
SAY_2FA_REPEAT = ("苹果已经接受了验证码，但随后又要求再验证一次，再输也会一直这样，所以 S2Arm 先停下了。"
                  "请改用在你自己的 iPhone 或 iPad 上登录着的那个 Apple ID 来登录（验证码会弹在那台设备上）；还不行请把诊断发给我们。")
# 苹果回 5xx（apple_login_refused）后的冷却（#1864：失败后登录键立刻又能点，28 分钟连发 74 次、间隔 0.24～1.2 秒，连发只会让苹果限流更久）：
# 下一次登录先等够冷却再连苹果。连续第 n 次拒收冷却 COOL_BASE·2^(n-1) 秒、封顶 COOL_MAX；登录成功或别的结果清零。
# 记在 <私有目录>/login/cooldown.json，换作业、重开启动器都算数；等的时候发 progress（stageKey = appleLogin.wait，wait = 还要等几秒），能取消
COOL_BASE = 30
COOL_MAX = 300
COOL_CODES = ("apple_login_refused",)
LOGIN_OK = "Successfully logged in"
SAY_SIGN_IN = "登录 Apple ID"
SAY_CODE = "等你填验证码"


def _code_file(c):
    return Path(c.private) / "login" / (c.task + ".code")


def _wait_code(c, proc, allow_sms=False):
    """等界面写验证码文件 → 6 位数字，或 allow_sms 时的 sms（改发短信；读到即删）；作业被取消 / plumesign 先退了 / 超时 → None"""
    f = _code_file(c)
    end = time.monotonic() + CODE_WAIT
    while time.monotonic() < end and not c.cancelled and proc.poll() is None:
        if f.is_file():
            try:
                text = f.read_text(encoding="utf-8").strip()
            finally:
                f.unlink(missing_ok=True)
            if re.fullmatch(r"\d{6}", text):
                return text
            if allow_sms and text.lower() == SMS:
                return SMS
        time.sleep(0.3)
    return None


def _cool_file(c):
    return Path(c.private) / "login" / "cooldown.json"


def _cool_read(c):
    try:
        got = json.loads(_cool_file(c).read_text(encoding="utf-8"))
        return float(got.get("until", 0)), int(got.get("n", 0))
    except (OSError, ValueError, TypeError, AttributeError):
        return 0.0, 0


def _cool_after(c, code):
    """这次登录的结果 → 更新冷却：苹果拒收（5xx）累加一次，别的结果清零"""
    f = _cool_file(c)
    if code not in COOL_CODES:
        f.unlink(missing_ok=True)
        return
    n = _cool_read(c)[1] + 1
    f.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    f.write_text(json.dumps(dict(until=time.time() + min(COOL_BASE * 2 ** (n - 1), COOL_MAX), n=n)), encoding="utf-8")


def _cool_wait(c):
    """上次苹果拒收后冷却没过：等够再连（每秒发一次剩余秒数；作业取消照常收尾）"""
    until = _cool_read(c)[0]
    shown = None
    while not c.cancelled:
        left = int(until - time.time() + 0.999)
        if left <= 0:
            return
        left = min(left, COOL_MAX)
        if left != shown:
            c.begin(SAY_SIGN_IN, 1, 1, key="appleLogin.wait")
            c.emit("progress", wait=left)
            shown = left
        time.sleep(min(1.0, max(until - time.time(), 0.05)))


def _classify(text):
    """plumesign 登录输出 → 失败码（impactor.explain 同一份原文对照）"""
    import impactor
    code = impactor.explain(text)
    return code if code in ("apple_id_wrong", "two_factor_wrong", "signing_server_unreachable", "apple_server_unreachable", "apple_login_refused", "login_identity_rejected") else "job_failed"


def _account_result(c, W):
    import install
    got = install.plume_account(c, W)
    return dict(got, enabled=True) if got else dict(account=None, team=None, teamName="", enabled=True)


def login(c):
    """作业 appleLogin（见文件头）"""
    import install
    password = getattr(c, "apple_password", None)
    c.apple_password = None
    if not install.mac_plume(c):
        return dict(enabled=False)
    account = str(c.r.get("account") or "").strip()
    if not account or not password:
        raise Failure("填好 Apple ID 邮箱和密码再登录。", code="apple_id_wrong")
    W = install.win_install_mod(c)
    exe = install.plumesign_exe(c, W)
    if not exe:
        raise Failure("这个 S2Arm 安装包里缺登录要用的组件，请重新下载安装 S2Arm。", code="job_failed", internal="plumesign 不在随包目录 / S2A_PLUMESIGN / PATH")  # 非玩家句（internal 只进诊断）
    _cool_wait(c)
    c.check()   # 等冷却时取消了：照作业取消收尾，不连苹果
    c.begin(SAY_SIGN_IN, 1, 1, key="appleLogin")
    _code_file(c).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    proc = subprocess.Popen([exe, "account", "login", "-u", account], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=W.impactor.plume_env(), text=True, encoding="utf-8", errors="replace")
    lines = []
    asked = threading.Event()
    prompt = [""]   # 最近一次验证码提示原文（判能不能改短信、是不是短信方式）
    sms_sent = False
    code_given = False   # 已交过一次 6 位验证码：之后再要码 = 苹果接受了码却又要（见 SAY_2FA_REPEAT）
    repeat = False

    def pump():
        for ln in proc.stdout:
            lines.append(ln)
            if NEED_CODE.search(ln):
                prompt[0] = ln
                asked.set()
    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        proc.stdin.write(password + "\n")
        proc.stdin.flush()
        while proc.poll() is None and not c.cancelled:
            if asked.wait(0.3):
                asked.clear()
                if code_given:
                    repeat = True
                    break
                can_sms = bool(CAN_SMS.search(prompt[0]))
                c.begin(SAY_CODE, 1, 1, key="appleLogin.needCode")
                c.emit("progress", account=account, canSms=can_sms, sms=bool(VIA_SMS.search(prompt[0])))
                code = _wait_code(c, proc, allow_sms=can_sms)
                if code is None:
                    break
                sms_sent = sms_sent or code == SMS
                code_given = code_given or code != SMS
                c.begin(SAY_SIGN_IN, 1, 1, key="appleLogin")
                proc.stdin.write(code + "\n")
                proc.stdin.flush()
    except (BrokenPipeError, OSError):
        pass   # plumesign 先退了：按它的输出判
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        reader.join(5)
        for f in (proc.stdin, proc.stdout):
            try:
                f.close()
            except OSError:
                pass
        _code_file(c).unlink(missing_ok=True)
    text = "".join(lines)
    if password:   # plumesign 若把读到的密码回显出来（终端里交互登录时会显示），进日志 / 报错前抹掉
        text = text.replace(password, "***")
    password = None
    log = c.logs / (c.task + "-login.log")
    log.write_text(text, encoding="utf-8")   # plumesign 不回显密码；这里只有它的提示与报错
    c.check()   # 取消（再发一次 / 关掉登录框）：照作业取消收尾
    if proc.returncode == 0 and LOGIN_OK in text:
        _cool_after(c, None)
        return _account_result(c, W)
    _cool_after(c, None if repeat or REPEAT in text else _classify(text))
    if repeat or REPEAT in text:
        raise Failure(SAY_2FA_REPEAT, code="login_identity_rejected", internal=prompt[0].strip()[-300:] if repeat else text.strip().splitlines()[-1][-300:])
    if sms_sent and NO_TERMINAL.search(text):   # 改短信时要选号：管道里选不了（见文件头）
        raise Failure(SAY_SMS_PICK, code="two_factor_wrong", internal=text.strip().splitlines()[-1][-300:] if text.strip() else "")
    code = _classify(text)
    tail = [ln.strip() for ln in text.splitlines() if ln.strip() and "DEBUG" not in ln][-1:] or [""]
    if code == "job_failed":
        raise Failure(f"Apple ID 登录没成功：{tail[0][-300:]}", code=code)   # plumesign 英文原句上屏，前缀句式在对照表
    from errors import recovery
    raise Failure(recovery(code, packaged=bool(c.r.get("engineBundle"))), code=code, internal=tail[0][-300:])


def account(c):
    """作业 appleAccount（见文件头）"""
    import install
    if not install.mac_plume(c):
        return dict(enabled=False, account=None)
    return _account_result(c, install.win_install_mod(c))
