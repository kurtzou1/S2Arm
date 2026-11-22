#!/usr/bin/env python3
"""README 联合开发者名单补新人（11-09 维护方：README 写「感谢每一位提交过 PR 或 Issue 的人」，名单不全这句话就是假的）。

用法：python3 tools/thanks_list.py [--write] [--events <json>]
  取公开仓全部 Issue / PR 的作者（gh api，含已关闭），每人取首次贡献时间；去掉机器人（类型 Bot / 名字带 [bot]）和维护方账号（OWN）；
  README.zh-CN.md 与 README.md 联合开发者那一行里没有的人，按首次贡献时间接在现有名单后面（已有的人顺序不动）。
  显示名照 DISPLAY 表改写（链接仍是原账号）。不带 --write 只列出要补的人；--write 两份 README 一起改。--events 给一份 [{"login","created_at","type"}] 代替 gh（单测用）。
  发版前合入运维跑一遍补新人；不进门禁。退出码：0 成功（含没有新人）；1 读不到 / 改不成（README 里找不到名单行等）。
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

REPO = 'jhaizhou-ops/S2Arm'
OWN = {'jhaizhou-ops'}   # 维护方自己的账号，不进致谢
# 显示名改写表：账号名本身是粗口等不宜在 README 里明文显示的，照样列出（「每一位」仍成立）、链接保留原账号，只把显示文字打码；
#   星号转义（\*），免得 Markdown 当成强调。再遇到同类往这里加，不在名单里删人
DISPLAY = {
    'fucknima': r'f\*\*\*\*\*\*\*',   # 11-09 维护方定：用户名是粗口（#145 的报告者）
    'FuckyouBB': r'F\*\*\*\*\*\*\*\*',   # 11-22：用户名是粗口，同上口径（照样列出、链接保留原账号、只打码显示文字）
}
ROOT = Path(__file__).resolve().parent.parent
FILES = [(ROOT / 'README.zh-CN.md', '- **联合开发者**：', '。'), (ROOT / 'README.md', '- **Co-developers**:', '.')]
LINK = re.compile(r'\[@[^\]]+\]\(https://github\.com/([^)/]+)\)')   # 按链接里的账号认人（显示名可能被改写）


def events(path):
    if path:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    out = subprocess.run(['gh', 'api', '--paginate', f'repos/{REPO}/issues?state=all&per_page=100&sort=created&direction=asc',
                          '--jq', '.[] | {login: .user.login, created_at: .created_at, type: .user.type}'],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if out.returncode:
        sys.exit(f'【红】thanks_list：gh 读不到 {REPO} 的 Issue / PR（{out.stderr.strip()[:200]}）')
    return [json.loads(l) for l in out.stdout.splitlines() if l.strip()]


def newcomers(evs, have):
    first = {}
    for e in evs:
        lg = e['login']
        if e.get('type') == 'Bot' or lg.endswith('[bot]') or lg in OWN:
            continue
        if lg not in first or e['created_at'] < first[lg]:
            first[lg] = e['created_at']
    have_l = {h.lower() for h in have}
    return [lg for lg, _ in sorted(first.items(), key=lambda kv: (kv[1], kv[0])) if lg.lower() not in have_l]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--events')
    a = ap.parse_args()
    texts = {}
    for p, head, end in FILES:
        s = p.read_text(encoding='utf-8')
        lines = [l for l in s.splitlines() if l.startswith(head)]
        if len(lines) != 1 or not lines[0].endswith(end):
            sys.exit(f'【红】thanks_list：{p.name} 里联合开发者那一行不是正好 1 行、或不以「{end}」结尾')
        texts[p] = (s, lines[0], end)
    haves = [LINK.findall(line) for _, line, _ in texts.values()]
    if haves[0] != haves[1]:
        sys.exit('【红】thanks_list：中英两份 README 的现有名单不一致，先对齐再补')
    add = newcomers(events(a.events), haves[0])
    print(f'现有 {len(haves[0])} 人，要补 {len(add)} 人' + (f'：{", ".join(add)}' if add else ''))
    if a.write and add:
        tail = ''.join(f', [@{DISPLAY.get(lg, lg)}](https://github.com/{lg})' for lg in add)
        for p, (s, line, end) in texts.items():
            p.write_text(s.replace(line, line[:-len(end)] + tail + end, 1), encoding='utf-8')
        print('已写入 README.zh-CN.md、README.md')
    return 0


if __name__ == '__main__':
    sys.exit(main())
