#!/bin/bash
# 门禁手动：要联网：把截图发中转站（缺省）/ 本机 claude CLI / OpenRouter 视觉模型，开发期自动玩家用
# 视觉驾驶员（只在 Mac 开发测试里用，产品包不带）：bash tests/autoplay/vision.sh <截图.png> <回答.json>
# 后端 S2A_VISION_BACKEND：不设 = 自动选（有中转站钥匙和地址走 relay，没有走 cli）/ relay（中转站，11-13 维护者：自动玩家一律走中转站；vision_or.py，钥匙 ~/.s2arm/.secrets/relay.key、地址 S2A_VISION_RELAY_URL 或 ~/.s2arm/.secrets/relay.url）
#   / cli（本机 claude CLI 直连，用这台机器上 CLI 自己的登录）/ or（vision_or.py，OpenRouter，要仓库外钥匙）/ jev（先问 vision_jev.py，不够再问 cli）。
#   11-12 曾因中转站停用改缺省 cli（#788：没设地址时每问 0.3 秒退 1、自动玩家当「没答」连问 3 次收局）；恢复后缺地址 / 钥匙一律按「不可用」红停，不再静默退。
#   后端不可用（中转站没钥匙或没地址 / 本机没有 claude CLI / CLI 没登录 / OpenRouter 没钥匙或额度用完）= 打【红】、答案 JSON 带 "unavailable":true 与原因、退出 3：
#   自动玩家（本机与远程信箱两条路）见到就按「驾驶员不可用」红停收局，不当成「这一问没答」静默重试
# 自动玩家每一步导航都调（10-31 AI 看屏驾驶）：截图交给视觉模型，像人类测试员读屏幕文字与布局，回按键序列 + 现在是否已在游戏场景里可操控。
#   维护者 10-20 拍板：「反正这个事情仅在咱们开发中使用」。playable 只是进局双证之一，MARK 还要宿主读数（每帧绘制 / 渲染遍数）到场景量级。
# 输出（<回答.json>）：{"keys":["A","DOWN","A:2","TOUCH:640,360"],"playable":false,"why":"…"}；按键只能取自允许集合，其余一律丢弃（自动玩家侧再校验一次）。
#   TOUCH:x,y = 点触（#196 指针 / 点触页）：模型按截图像素答，这里按截图里游戏画面的高换算成游戏画布坐标（高 720、宽随比例，16:9 即 1280×720）再写出（截图是上屏裁切后的整幅游戏画面）。
# 不做截图缓存（11-01 读数：按截图字节哈希 434 问只命中 11 次——游戏画面每帧细变；跨局复用靠自动玩家的学路线 ap_learn/<程序号>.tsv）。
# 墙钟上限 ${S2A_VISION_TIMEOUT:-90} 秒；模型 ${S2A_VISION_MODEL:-claude-sonnet-5-5}。耗时写 <回答.json>.log。
set -u
# 解释器 / timeout 与出包、runtime/run_mac.sh 同口径：python3 = S2A_PY（环境 → tools/machine.local → PATH 上的 python3），timeout 用仓库 perl 版 tools/bin/timeout。
#   原先直接调 PATH 上的 python3 / timeout：外部贡献者照套件第 1 步起 Mac 局，PATH 上是没装钉版包的系统 / Homebrew Python、又没有 tools/bin 时，
#   驾驶员每一问 rc 1 / 127，自动玩家判「导航卡住」收局（11-10 M1 Pro 实走）。单测：bash tests/vision_env_test.sh
_VD=$(CDPATH= cd "$(dirname "$0")" && pwd); [ -f "$_VD/../../tools/_timeout.sh" ] && . "$_VD/../../tools/_timeout.sh"
_VPY=${S2A_PY:-$(bash "$_VD/../../tools/machine.sh" get S2A_PY 2> /dev/null)}; _VPY=${_VPY:-$(command -v python3)}
python3() { "$_VPY" "$@"; }
PNG=${1:?截图}; OUT=${2:?回答}; MODEL=${S2A_VISION_MODEL:-claude-sonnet-5-5}
t0=$(date +%s)
: > "$OUT.log"
# 缺省后端 Jev（OpenRouter Decisions API，维护者 定；约 2 秒、0.0001 美元一次）：只问一次，把握 ≥ 0.6 直接用、≥ ${S2A_JEV_FLOOR:-0.3} 也用
#   （10-20 马车8 选 Mii 页：Jev 把握 0.33–0.48，每次都退 claude CLI，三次 84 秒，280 秒内没进比赛）；更低 / 失败才退到下面的升级后端。
#   11-01 去掉「不够就再问一次」：普查 + 体验线 439 次第二问里答案只变了 39 次，合计多花 922 秒
# S2A_VISION_ESCALATE=1（自动玩家：回到问过的同一页还卡着）：跳过 Jev 直接问升级后端，题面说明前面的答案没走出这一页
# OpenRouter 回过 402（额度用完；11-02 维护者：不再充值，中转站做主力）：永久标记（or402.py，直到删标记或换钥匙）→ 显式选了 Jev 也跳过，不白撞 402
# 没设 S2A_VISION_BACKEND = 自动选（11-13：外部贡献者没有中转站钥匙，缺省不该一上来就红停）：有中转站钥匙和地址走 relay（维护方机器都有，照样走中转站），没有走本机 cli；
#   日志写一行走的是哪个。显式设了就照设的走（不认的名字照旧不可用红停）
BACKEND=${S2A_VISION_BACKEND:-}
if [ -z "$BACKEND" ]; then
  if [ -r "${S2A_VISION_RELAY_KEY:-$HOME/.s2arm/.secrets/relay.key}" ] && { [ -n "${S2A_VISION_RELAY_URL:-}" ] || [ -r "$HOME/.s2arm/.secrets/relay.url" ]; }; then BACKEND=relay; echo "后端自动选：relay（有中转站钥匙和地址）" >> "$OUT.log"
  else BACKEND=cli; echo "后端自动选：cli（没有中转站钥匙或地址，走本机 claude CLI）" >> "$OUT.log"; fi
fi
export S2A_VISION_BACKEND=$BACKEND   # vision_or.py 按它选中转站 / OpenRouter
# 后端不可用：答案 JSON 带 unavailable + 原因（远程信箱经桥原样推回手机）、日志与标准错误各一行【红】、退出 3
unavail() {
  echo "【红】看屏驾驶员不可用：$1" >> "$OUT.log"; echo "【红】看屏驾驶员不可用：$1" >&2
  python3 -c 'import json, sys; print(json.dumps({"keys": [], "playable": False, "why": sys.argv[1], "unavailable": True}, ensure_ascii=False))' "$1" > "$OUT"
  exit 3; }
case $BACKEND in relay|cli|or|jev) ;; *) unavail "S2A_VISION_BACKEND=${BACKEND} 不认（只有 relay / cli / or / jev）";; esac
if [ "$BACKEND" = jev ] && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import or402; sys.exit(0 if or402.blocked() else 1)' "$(dirname "$0")" 2> /dev/null; then SKIP_JEV=1; echo "OpenRouter 回过 402（永久标记，删标记或换钥匙才恢复），跳过 Jev" >> "$OUT.log"; fi
if [ "$BACKEND" = jev ] && [ -z "${S2A_VISION_ESCALATE:-}" ] && [ -z "${SKIP_JEV:-}" ]; then
  rm -f "$OUT.conf"; python3 "$(dirname "$0")/vision_jev.py" "$PNG" "$OUT"; jr=$?
  [ $jr = 0 ] && exit 0
  if [ $jr = 4 ]; then echo "Jev 判这页要点触（选择题给不出坐标），交升级后端定坐标" >> "$OUT.log"; TOUCH_HINT=1
  else cf=$(cat "$OUT.conf" 2>/dev/null || echo 0)
    if [ $jr = 3 ] && python3 -c "import sys; sys.exit(0 if float('$cf') >= float('${S2A_JEV_FLOOR:-0.3}') else 1)"; then
      echo "Jev 把握 $cf < 0.6、≥ ${S2A_JEV_FLOOR:-0.3}，照用" >> "$OUT.log"; exit 0; fi
    echo "Jev 没给出把握够的答案（rc=${jr}，把握 ${cf}），退到升级后端" >> "$OUT.log"; fi
fi
P=$(cd "$(dirname "$PNG")" && pwd)/$(basename "$PNG")
# 这页按键已试过 ≥ 3 个都没用、还没试过点触（11-01 银河 2「要创建游戏文件吗」框是手形指针页，掌机档只认点触，换了 7 种键没出去）：提示改答点触
NT=$(printf '%s' "${S2A_VISION_TRIED:-}" | tr ',' '\n' | grep -vc '^TOUCH$\|^$'); case ",${S2A_VISION_TRIED:-}," in (*,TOUCH,*) NT=0;; esac
[ "${NT:-0}" -ge 3 ] && TOUCH_HINT=1
# 截图宽高（PNG 头 IHDR）：题面告诉模型、点触坐标按它换算
read -r IW IH < <(python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print(*struct.unpack(">II", d[16:24]))' "$P")
# 当前会话注入的 ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL 不给子进程（会让 CLI 报 Invalid API key）；用本机 CLI 自己的登录
# 截图直接内联进第一条消息（stream-json 图片块）：一轮往返，比让模型再调 Read 工具读图快（同图 22 秒 vs 26–70 秒）
# 导航规则只有一份：tests/autoplay/nav_rules.txt（英文；缺省后端 Jev vision_jev.py 读同一份。11-02 nav1102r：规则原先只写在这里的中文题面，Jev 答了 75% 的问、一条也看不到）
RULES=$(cat "$(dirname "$0")/nav_rules.txt")
Q="你是游戏测试员，看这张 Switch 游戏画面（截图 ${IW}x${IH} 像素），先判断玩家现在是否已在游戏世界里直接操纵角色或载具，再给出下一步按键。导航规则（英文）：
${RULES}
点触时答 \"TOUCH:x,y\"（x、y 是要点的位置在这张截图上的像素坐标，左上为 0,0）。${S2A_VISION_TRIED:+这一页已经按过没用的：${S2A_VISION_TRIED}（其中 TOUCH = 点触没反应，这页别再答点触）。}
${S2A_VISION_ESCALATE:+这一页之前已经问过、照答案按了还是回到这页：别再重复同样的键；改按图例上还没按过的键，或用方向键挪光标后按 A。}${TOUCH_HINT:+另一个模型判断这页要点触（按键在这页上没用）：这次 keys 只答一个 \"TOUCH:x,y\"，点你要选的那一项（开始游戏 / 第一个存档 / 确定这类）。}${S2A_VISION_TRIED:+这一页已经按过 ${S2A_VISION_TRIED}、页面没变，不要再答这些键（试过的是 A 就说明当前高亮项确认不了，先把选择移到别的项上）。}
只输出一行 JSON，不要别的文字：{\"keys\":[…],\"playable\":true 或 false,\"why\":\"一句中文说明画面是什么、为什么这样按（why 里不要用引号）\"}。已可操控时 keys 给一个推左摇杆的键即可。
keys 每项只能是：A B X Y L R ZL ZR PLUS MINUS SL SR UP DOWN LEFT RIGHT LS_UP LS_DOWN LS_LEFT LS_RIGHT RS_UP RS_DOWN RS_LEFT RS_RIGHT TOUCH:x,y，或前加 2: 的按键（只按二号手柄，不能点触）；要长按写成 \"A:2\"（秒，≤3）；画面要两键同按（如「按下 L+R」「press ZL + ZR」）写成一项 \"L|R\" / \"ZL|ZR\"，别拆成两项。最多 8 个。"
ask() {   # 问一次后端：R = 原始回答、rc、J = 解析后的 JSON（滤掉试过的键；滤空 = 空）；后端不可用直接 unavail（退出 3）
if [ "$BACKEND" = or ] || [ "$BACKEND" = relay ]; then
R=$(python3 "$(dirname "$0")/vision_or.py" "$P" "$Q" 2>> "$OUT.err"); rc=$?; SHOW="$([ "$BACKEND" = relay ] && echo 中转站 || echo OpenRouter)（$(grep -a "^模型 " "$OUT.err" | tail -1 | cut -c8-)）"
[ $rc = 3 ] && unavail "$(grep -a '不可用' "$OUT.err" | tail -1)"
else
# 本机 claude CLI 直连：截图内联进第一条消息，用 CLI 自己的登录（去掉当前会话注入的 ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL）
command -v claude > /dev/null || unavail "本机没有 claude CLI（PATH 上找不到 claude）：装 Claude Code 并登录一次，或用缺省的中转站（S2A_VISION_BACKEND=relay）"
R=$(python3 -c 'import base64, json, sys
print(json.dumps({"type": "user", "message": {"role": "user", "content": [
  {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(open(sys.argv[1], "rb").read()).decode()}},
  {"type": "text", "text": sys.argv[2]}]}}))' "$P" "$Q" 2> /dev/null \
  | (cd "${TMPDIR:-/tmp}" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL timeout "${S2A_VISION_TIMEOUT:-90}" claude -p --model "$MODEL" --tools "" --system-prompt "你是游戏画面测试员，只按用户题面回答。" \
      --strict-mcp-config --no-session-persistence --effort low --input-format stream-json --output-format stream-json --verbose 2>> "$OUT.err"; echo $? > "$OUT.clirc") \
  | python3 -c 'import json, sys
for l in sys.stdin:
    try: d = json.loads(l)
    except Exception: continue
    if d.get("type") == "result": print(d.get("result", ""))')
# 退出码取 claude 那一段（11-02 gpuclk5：管道末段 python 总是 0，CLI 超时 124 被记成「升级后端失败 rc=0」）；没有结果行也算失败
rc=$(cat "$OUT.clirc" 2> /dev/null || echo 1); rm -f "$OUT.clirc"; [ "$rc" = 0 ] && [ -z "$R" ] && rc=1; [ "$rc" = 124 ] && echo "claude CLI 超时（${S2A_VISION_TIMEOUT:-90} 秒）" >> "$OUT.log"
SHOW="claude CLI（${MODEL}）"
grep -aq 'Not logged in\|Invalid API key\|Please run /login' "$OUT.err" 2> /dev/null || printf '%s' "$R" | grep -q 'Not logged in' && unavail "本机 claude CLI 没登录（终端里跑一次 claude 登录；日志 $OUT.err）"
fi
dt=$(( $(date +%s) - t0 ))
parse
}
parse() {   # 只认 keys 数组（正则抽，why 里带引号也不怕），重新拼成合法 JSON；why 原样留作说明
J=$(printf '%s' "$R" | python3 -c '
import json, os, re, sys
t = sys.stdin.read(); m = re.search(r"\"keys\"\s*:\s*\[([^\]]*)\]", t)
if not m: sys.exit(1)
iw, ih = int(sys.argv[1]), int(sys.argv[2])
# 游戏画面在截图里的矩形（autoplay.c png_rect 写的 <截图>.rect「x y w h」：截图两侧 / 上下是宿主黑边时才有）；没有 = 整幅
try: rx, ry, rw, rh = map(int, open(sys.argv[4]).read().split()[:4])
except Exception: rx, ry, rw, rh = 0, 0, iw, ih
def touch(k):   # 截图像素 → 游戏画布触摸坐标：扣掉宿主黑边按游戏画面矩形换算（10-29 脑锻炼竖持「开始」点在按钮外）；画外的原样留给自动玩家丢弃
    # 画布高 720；宽按自动玩家给的 S2A_VISION_TOUCH_W（同 ios/vpad.m switchPoint）：游戏不知道宽屏读 1280（x 按游戏画面宽缩放）；
    #   0 / 没给 = 游戏自己出宽图（第二层），宽随画面比例（如 1564×720）。11-02 普查银河2（宿主放宽）按画面比例算成 1564 宽，点「开始」偏右约 22%
    p = re.fullmatch(r"TOUCH:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)", k)
    if not p or rw <= 0 or rh <= 0: return k
    x, y = float(p.group(1)) - rx, float(p.group(2)) - ry
    tw = int(os.environ.get("S2A_VISION_TOUCH_W") or 0)
    return f"TOUCH:{round(x * (tw / rw if tw > 0 else 720 / rh))},{round(y * 720 / rh)}" if 0 <= x < rw and 0 <= y < rh else k
tried = {k for k in sys.argv[3].split(",") if k}   # 这页试过没用的键：模型照答也滤掉，滤空 = 这次没答（自动玩家过会儿再问）
# 试过没用按完整动作比（同 autoplay.c tried_add）：单键连长按秒数、点触记 TOUCH，多键答案整组「K1+K2」；整组试过才滤空。
#   说可操控的答案不滤（可操控是进局判据之一：11-01 一款横版已在局里，推摇杆试过就被滤空、判成导航卡住）
raw = re.findall(r"\"([^\"]+)\"", m.group(1)); pl = re.search(r"\"playable\"\s*:\s*(true|false)", t)
act = "+".join("TOUCH" if k.startswith("TOUCH:") else k for k in raw)
keys = [touch(k) for k in raw] if (pl and pl.group(1) == "true") or act not in tried else []
w = re.search(r"\"why\"\s*:\s*\"(.*?)\"\s*[,}]", t, re.S)
# 没键可按也是一个回答（11-03 归族 A：原先退出码 1 = 驾驶员失败，连 3 次收局，11 款以此收局）：
#   模型自己答空 = 等（加载 / 过场）→ "empty":"wait"；答的全是试过的 = "empty":"tried"（自动玩家用代码兜底挑没试过的动作）
e = {} if keys else {"empty": "tried" if raw else "wait"}
c = re.search(r"\"conf\"\s*:\s*([0-9.]+)", t)   # 只有快档的题面要这个字段
if c: e["conf"] = float(c.group(1))
print(json.dumps({"keys": keys, "playable": bool(pl and pl.group(1) == "true"), "why": w.group(1) if w else "", **e}, ensure_ascii=False))' "$IW" "$IH" "${S2A_VISION_TRIED:-}" "$P.rect" 2> /dev/null)
}
ask
# 答案里的键全是这页试过没用的（被滤空）：带上「刚才答的都试过」当场再问一次（10-26 银河 2「要创建游戏文件吗」框：claude CLI 认定 OK 已高亮、仍答 A，那框要点触）
if [ $rc = 0 ] && printf '%s' "$J" | grep -q '"empty": "tried"'; then
  Q="$Q
你刚才的回答是：$(printf '%s' "$R" | tr '\n' ' ' | cut -c1-200)。里面的键在这一页都已经按过、没有用，这次不要再答它们；看图例上还有哪些键没按过（X / Y / L / R / + / 方向键），或用方向键挪光标再按 A；只有画面明写要点触、且 TOUCH 不在已按过的里面，才答 \"TOUCH:x,y\"（截图像素坐标）。"
  echo "答案全是试过的键，追问一次" >> "$OUT.log"; ask
fi
if [ $rc != 0 ] || [ -z "$J" ]; then
  echo "升级后端失败 rc=$rc ${dt} 秒：$(printf '%s' "$R" | tail -c 300 | tr '\n' ' ')" >> "$OUT.log"; exit 1; fi
printf '%s\n' "$J" > "$OUT"; echo "升级后端 ${SHOW:-$MODEL} ${dt} 秒" >> "$OUT.log"
