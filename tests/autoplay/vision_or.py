#!/usr/bin/env python3
# 门禁手动：要联网：调 OpenRouter 对话接口（要仓库外密钥），要传截图与题面
# 11-12：中转站档已删（中转站停用）。vision.sh 缺省走本机 claude CLI，本文件只在 S2A_VISION_BACKEND=or 时用；没钥匙 / 额度用完 = 打「不可用」、退出 3（vision.sh 据此红停）
# 视觉测试员·看图对话退路（只在 Mac 开发测试里用）：python3 vision_or.py <截图.png> <题面>  → 打印模型回答原文（vision.sh 照 claude CLI 的回答同样解析）
# vision.sh 在本机 claude CLI 不在或没登录时用它（10-26：Spare-host / gate-host 上远端局用假家目录、ssh 会话拿不到钥匙串，claude CLI 报「Not logged in」，
#   升级那一问整个白丢）。走 OpenRouter 的对话接口，与 Jev 同一把钥匙（~/.s2arm/.secrets/openrouter.key，不打印、不写日志）。
# 顺序见下面（OpenRouter 各模型，S2A_VISION_OR_MODELS 逗号分隔），任何一档失败落下一档：Spare-host 直连外网时 Anthropic / Google / OpenAI 都回 403（10-26 实测，本机走代理才通），
#   月之暗面 kimi-k3 直连能通；三张真截图（银河 2 存档页、创建游戏文件框、暗黑3 选难度）kimi-k3 答 TOUCH:343,420 / TOUCH:820,558 / A，与路线实测一致
import base64, io, json, os, sys, time, urllib.error, urllib.request

png, prompt = sys.argv[1], sys.argv[2]
# 外发范围（11-01 维护者核）：每次只发这一张截图（游戏出图帧，转 JPEG）+ 题面文字；不发游戏文件 / 存档 / prod.keys / 局目录其他内容。
# 密钥只从仓库外 ~/.s2arm/.secrets/openrouter.key 读，只进请求头；不打印、不写日志 / 局目录 / 命令行。按量计费：每次把 OpenRouter 回的费用与 token 写 stderr（进 <回答.json>.err）
try: key = open(os.path.expanduser(os.environ.get("S2A_VISION_OR_KEY", "~/.s2arm/.secrets/openrouter.key"))).read().strip()   # S2A_VISION_OR_KEY / _OR_URL 只给单测指到假服务
except OSError: key = ""   # 没有 OpenRouter 钥匙：下面打「不可用」退出 3
# 上传用 JPEG（质量 85、分辨率不变；同 vision_jev.py：PNG 690 KB → 90 KB，Spare-host 往返省约 1.2 秒）
from PIL import Image
b = io.BytesIO(); Image.open(png).convert("RGB").save(b, "JPEG", quality=85)
img = "data:image/jpeg;base64," + base64.b64encode(b.getvalue()).decode()
TO = float(os.environ.get("S2A_VISION_TIMEOUT", 90))
# 模型请求代理（11-01 维护者：Spare-host 直连外网时 Anthropic 回 403、只能退 kimi，单问 20~48 秒吃光局时）：S2A_VISION_PROXY=http://127.0.0.1:18118（Spare-host 上是本机 ssh 反向隧道的出口；8118 被 Spare-host 自己的代理占了，11-01 运维线改端口）只用于这一个请求进程，
#   其它进程不走代理；代理连不上（隧道断）立刻退回直连。只作用于 OpenRouter 档
PROXY = os.environ.get("S2A_VISION_PROXY", "").strip()
used = {"px": PROXY}   # 这次请求实际走的路：代理不通退回直连后，403 要记在直连那份缓存下（不然隧道恢复后走代理也跳过 sonnet）
def ask_or(m):   # OpenRouter：回 (回答, 日志两行)
    body = {"model": m, "max_tokens": 2000, "reasoning": {"effort": "low"}, "usage": {"include": True},   # 推理模型 400 个输出额度会被思考用完、正文为空
            "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}}, {"type": "text", "text": prompt}]}]}
    def fetch(px):
        req = urllib.request.Request(os.environ.get("S2A_VISION_OR_URL", "https://openrouter.ai/api/v1/chat/completions"), data=json.dumps(body).encode(),   # 每次新建：走代理会改写 Request 的主机，重试直连不能复用
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        op = urllib.request.build_opener(urllib.request.ProxyHandler({"https": px, "http": px})) if px else urllib.request.build_opener()   # 直连 = 原行为（仍认环境里的 HTTPS_PROXY）
        return json.load(op.open(req, timeout=TO))
    try: r = fetch(PROXY)
    except urllib.error.HTTPError: raise
    except (urllib.error.URLError, OSError) as e:   # 代理连不上（隧道断）→ 直连重试一次
        if not PROXY: raise
        print(f"代理 {PROXY} 不通（{e}），退回直连", file=sys.stderr); used["px"] = ""; r = fetch("")
    u = r.get("usage") or {}
    return r["choices"][0]["message"]["content"] or "", f"模型 {m}", f"费用 {u.get('cost', '?')} 美元 输入 {u.get('prompt_tokens', '?')} 输出 {u.get('completion_tokens', '?')} token"
# 顺序：OpenRouter 各模型（S2A_VISION_OR_MODELS 逗号分隔），任何一档失败（HTTP 错 / 网络 / 超时 / 空回答）落下一档，都失败退出 1。
ors = os.environ.get("S2A_VISION_OR_MODELS", "anthropic/claude-sonnet-5.5,moonshotai/kimi-k3").split(",")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import or402   # 402 / 余额不足标记（vision_jev.py / quality_check.py 共用）：永久跳过，直到删标记或换钥匙
if not key: print("OpenRouter 后端不可用：没有钥匙（~/.s2arm/.secrets/openrouter.key）", file=sys.stderr); sys.exit(3)
if or402.blocked(key): print("OpenRouter 后端不可用：这把钥匙回过 402（额度用完，永久标记；删标记或换钥匙才恢复）", file=sys.stderr); sys.exit(3)
chain = [("or", m) for m in ors]
# 这条网络上回过 HTTP 403 的档跳过（11-01 普查：Spare-host 直连每次升级都先请求 sonnet 吃 403，145 次白跑一趟）：缓存只记 403 的「档:模型」，
#   按「走代理 / 直连」分开存（隧道通了用另一份、照常先试 sonnet）。超时 / 网络抖动这类偶发失败不记——记「上次成功」会把偶发一次落到慢档后永远先问慢档
def cache(px): return os.path.expanduser("~/.cache/s2a/vision_or_403" + ("_px" if px else ""))
# 每条记「档:模型<TAB>记下时刻」，一小时后作废：网络变了（11-01 维护者 给 Spare-host 开 VPN，直连 sonnet 就通）自己恢复，不用人去清缓存
import time
def load(f):
    try: return {a: float(t) for a, _, t in (l.strip().partition("\t") for l in open(f) if l.strip()) if t and time.time() - float(t) < 3600}
    except (OSError, ValueError): return {}
blocked = set(load(cache(PROXY)))
if any(f"{k}:{m}" not in blocked for k, m in chain): chain = [c for c in chain if f"{c[0]}:{c[1]}" not in blocked]
def block(c):   # 记在这次实际走的那条路的缓存下
    f = cache(used["px"]); cur = load(f); cur[c] = time.time()
    try:   # 先写临时文件再改名：同机并发局不读到半份
        os.makedirs(os.path.dirname(f), exist_ok=True); tmp = f"{f}.{os.getpid()}.tmp"; open(tmp, "w").write("".join(f"{x}\t{t:.0f}\n" for x, t in sorted(cur.items()))); os.replace(tmp, f)
    except OSError: pass
for i, (kind, m) in enumerate(chain):
    try: out, l1, l2 = ask_or(m)
    except Exception as e:
        print(f"OpenRouter {m} 失败（{type(e).__name__}{' HTTP %d' % e.code if isinstance(e, urllib.error.HTTPError) else ''}），换下一档", file=sys.stderr)
        if isinstance(e, urllib.error.HTTPError) and e.code == 403: block(f"{kind}:{m}")
        if isinstance(e, urllib.error.HTTPError) and or402.is_quota(e.code, e.read() if e.fp else b""):   # 额度用完是整把钥匙的事：记永久标记、后面的 OpenRouter 模型不再白问
            or402.mark(key); chain[i + 1:] = [c for c in chain[i + 1:] if c[0] != "or"]
        if i + 1 < len(chain): continue
        raise
    if not out.strip():
        print(f"OpenRouter {m} 回答为空，换下一档", file=sys.stderr)
        if i + 1 < len(chain): continue
    print(l1, file=sys.stderr); print(l2, file=sys.stderr)
    print(out); break
