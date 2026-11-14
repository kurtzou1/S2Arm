"""上传诊断给开发者（diagnosticsUpload 作业，11-13 诊断一键上传，Mac / Windows 启动器共用）。

原来「复制错误摘要 / 导出诊断包」两个入口合成一个「上传给开发者」：打一份和「导出诊断包」完全相同的脱敏包
（library.diagnostics，同一套规则）；请求带了 gameId / operations 时，把那次失败的错误摘要（report.py，同「复制错误摘要」的正文）
一并放进包里（logs/error-summary.log），交上传服务换回一个短码，界面只让玩家复制这个码。
上传没成（服务没开通、没网、被拒收）→ 作业失败，码 diag_upload_failed：界面据此退回「导出诊断包」，玩家照旧手动发。
打出来的包在系统临时目录里，传完或传失败都删掉，不在玩家机器上留副本。

上传协议照维护方方案文件末尾「上传协议与短码」（服务端代码在维护方私有工具库 release/diag/，worker.js 头注释是同一份规则）：
  POST https://diag.s2arm.com/v1/upload，正文 = 诊断包 zip 原样，头 Content-Type: application/zip、X-S2Arm-Client: <mac|windows>/<版本>；
  200 {"code": "D-7K3Q", "expiresAt": …}；400 / 413 {"error", "message"}（message 是给玩家看的中文一句）；429 太频繁；5xx / 网络不通。
  只在网络错误 / 5xx 时重试一次（429 要等一分钟，不在这里干等，说清楚让玩家稍后再试或导出）。
  收件规则里 manifest.json 必须有 "schema": 1（library.diagnostics 写）；扩展名白名单含 .log，摘要放 logs/ 下合规。
"""
import json
import os
import time
from pathlib import Path
import re
import shutil
import tempfile
import threading
import urllib.error
import urllib.request
import zipfile

from core import Failure

REPO = "github.com/jhaizhou-ops/S2Arm"   # 短码页上同时写出仓库地址：打不开链接的玩家照着手动去
ISSUE_FORM = "问题回报.yml"   # .github/ISSUE_TEMPLATE/问题回报.yml：字段 id logs / version / platform 以它为准
PLATFORM_OPTION = {"mac": "Mac（前端里打包或启动）", "windows": "出包的电脑（一键出包命令）"}   # = 模板 platform 下拉的选项原文（预填要逐字相同）
UPLOAD_URL = "https://diag.s2arm.com/v1/upload"   # *.workers.dev 国内不通，只用这个；S2A_DIAG_UPLOAD_URL 覆盖（内部联调 / 单测）
LIMIT = 30 * 1024 * 1024   # 服务端收件上限（压缩后 ≤ 30 MB，方案「服务端」节）：超了不白传，直接退回导出
CODE_RE = re.compile(r"D-[2-9A-HJKMNP-TV-Z]{4}")   # D- + 4 位，去掉 0 1 I L O U（念、抄不混）
SUMMARY = "logs/error-summary.log"
FALLBACK = "可以先导出诊断包，手动发给我们。"
TOTAL_S = 90   # 打包 + 上传的总时限（11-13 玩家卡在「正在上传…」一直不动）：urlopen 的 timeout 只管两次收发之间多久没动静，网慢 / 代理半通时可以一直挂着，
#   失败还会再试一次，没有总上限；打包这步也没有。到点按失败处理（diag_upload_failed，界面退回导出），说清是超时


def _within(seconds, what, fn, *args):
    """在 seconds 秒内跑完 fn，跑不完按失败处理。fn 在守护线程里跑：超时后作业照常以失败收尾、进程退出时线程随之结束（作业是独立进程）"""
    box = {}

    def run():
        try:
            box["value"] = fn(*args)
        except BaseException as e:   # 原样带回主线程再抛（含 Failure）
            box["error"] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(max(0.0, seconds))
    if t.is_alive():
        raise Failure(f"{what}超过 {TOTAL_S} 秒还没完成（网络太慢或连接卡住），已停止。{FALLBACK}", code="diag_upload_failed",
                      internal=f"{what}超时：总时限 {TOTAL_S} 秒")
    if "error" in box:
        raise box["error"]
    return box.get("value")


def endpoint():
    return os.environ.get("S2A_DIAG_UPLOAD_URL") or UPLOAD_URL


def client_tag(c):
    """X-S2Arm-Client：平台 / 版本（服务端只记来源，不判收拒）。版本取界面交来的 App 版本，没有就取引擎发版号"""
    extra = c.r.get("extra") if isinstance(c.r.get("extra"), dict) else {}
    version = str(extra.get("app") or "")
    if not version:
        try:
            from core import release_version
            version = release_version(c.engine)
        except (OSError, ValueError):   # 版本只是来源标注：拿不到不挡上传
            version = "-"
    return ("windows" if os.name == "nt" else "mac") + "/" + re.sub(r"[^0-9A-Za-z.+_-]", "", version or "-")[:40]


def _message(body):
    try:
        m = json.loads(body.decode("utf-8")).get("message")
        return m.strip() if isinstance(m, str) and m.strip() else None
    except (ValueError, AttributeError):
        return None


def send(url, path, client="mac/-", timeout=120, retry_wait=2.0):
    """把诊断包交给上传服务 → 短码。被拒收（400 / 413）用服务端给玩家的那句；太频繁（429）说清稍后再试；网络 / 5xx 重试一次仍不行就报连不上。
    都是 Failure（diag_upload_failed，原文进 internal），界面据此退回导出"""
    data = Path(path).read_bytes()
    for attempt in (1, 2):
        req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/zip", "X-S2Arm-Client": client,
                                     "User-Agent": "S2Arm/" + client})   # Python 缺省的 Python-urllib 标识被 Cloudflare 按浏览器签名拦（11-13 实测 403 / 1010）
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read(64 * 1024)
            break
        except urllib.error.HTTPError as e:
            body = e.read(64 * 1024) if e.fp else b""
            e.close()
            if e.code in (400, 413):
                raise Failure(f"{_message(body) or f'上传服务没收下这份诊断包（{e.code}）。'}{FALLBACK}", code="diag_upload_failed",
                              internal=f"HTTP {e.code} {body[:300].decode('utf-8', 'replace')}") from e
            if e.code == 429:
                raise Failure(f"上传太频繁了，稍等一分钟再试。{FALLBACK}", code="diag_upload_failed", internal=f"HTTP 429 {body[:300].decode('utf-8', 'replace')}") from e
            if attempt == 2 or e.code < 500:
                raise Failure(f"上传服务出错了（{e.code}）。{FALLBACK}", code="diag_upload_failed", internal=f"HTTP {e.code} {body[:300].decode('utf-8', 'replace')}") from e
        except (urllib.error.URLError, OSError) as e:
            if attempt == 2:
                raise Failure(f"连不上上传服务（检查一下网络）。{FALLBACK}", code="diag_upload_failed", internal=str(e)) from e
        time.sleep(retry_wait)
    try:
        code = json.loads(body.decode("utf-8")).get("code")
    except (ValueError, AttributeError) as e:
        raise Failure(f"上传服务的回应看不懂。{FALLBACK}", code="diag_upload_failed", internal=body[:200].decode("utf-8", "replace")) from e
    if not isinstance(code, str) or not CODE_RE.fullmatch(code):
        raise Failure(f"上传服务没给回短码。{FALLBACK}", code="diag_upload_failed", internal=repr(code)[:200])
    return code


def issue_url(code, client):
    """预填好的新帖页（维护方方案「去 GitHub 发帖」，iOS 端同格式）：模板问题回报、logs = 诊断码、version、platform 下拉原文、标题前缀。
    client = X-S2Arm-Client 的 <平台>/<版本>"""
    from urllib.parse import urlencode, quote
    plat, _, version = client.partition("/")
    query = dict(template=ISSUE_FORM, logs=code, version=version if version and version != "-" else "", platform=PLATFORM_OPTION.get(plat, ""), title="[问题] ")
    return f"https://{REPO}/issues/new?" + urlencode({k: v for k, v in query.items() if v}, quote_via=quote)


def add_summary(c, path):
    """请求带了 gameId / operations：把最近那次失败的错误摘要放进包（同「复制错误摘要」的正文，report.py 已脱敏）；
    顶栏全局「故障报修」什么都不带：附全部作业里最近一次失败的摘要，一次都没失败过就不附。
    没有作业记录的失败（环境检查，界面不带 operations）：界面把它显示的那段正文作 summary 交来，脱敏后放进去。都没有就不放"""
    text = None
    given = isinstance(c.r.get("summary"), str) and c.r["summary"].strip()
    # 顶栏全局「故障报修」（不带 gameId / operations / summary）：最近有失败的作业就附最近一次的摘要，没有就不附（11-13）
    if c.r.get("operations") is not None or c.r.get("gameId") or not given:
        import report
        try:
            task = report.find_task(c.private, c.r.get("gameId") or None, c.r.get("operations") or None)
            text = report.build(c.private, task, c.r.get("extra") if isinstance(c.r.get("extra"), dict) else None)
        except Failure:
            text = None
    if text is None and given:
        text = c.redact(c.r["summary"], limit=None)
    if text is None:
        return False
    with zipfile.ZipFile(path, "a", zipfile.ZIP_DEFLATED) as z:
        z.writestr(SUMMARY, text)
    return True


def upload(c):
    import library
    tmp = Path(tempfile.mkdtemp(prefix="s2a-diag-"))
    try:
        path = tmp / "S2Arm-diagnostics.zip"
        c.r["path"] = str(path)
        deadline = time.monotonic() + TOTAL_S
        _within(deadline - time.monotonic(), "打包诊断", library.diagnostics, c)
        add_summary(c, path)
        url = endpoint()
        if not url:
            raise Failure(f"上传服务还没开通。{FALLBACK}", code="diag_upload_failed")
        size = path.stat().st_size
        if size > LIMIT:
            raise Failure(f"诊断包有 {size / 2**20:.0f} MB，超过上传上限 {LIMIT // 2**20} MB。{FALLBACK}", code="diag_upload_failed")
        c.begin("上传诊断")
        client = client_tag(c)
        code = _within(deadline - time.monotonic(), "上传诊断", send, url, path, client, min(60, max(5, int(deadline - time.monotonic()))))
        return dict(code=code, issueUrl=issue_url(code, client), repo=REPO)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
