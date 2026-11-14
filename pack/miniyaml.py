"""FPSLocker 配置用到的 YAML 子集解析（随包 Python 没有 YAML 库）：顶层「键: 列表」，列表项是「-」起头的字典（缩进键值），
值可以是标量、流式列表 [ … ]（可跨行、可嵌套、可含 :标签 与 "引号串"）。# 起注释（引号内不算）。解析不了抛 ValueError"""
import re


def _strip_comment(line):
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in '"\'':
            q = ch; out.append(ch)
        elif ch == '#':
            break
        else:
            out.append(ch)
    return ''.join(out).rstrip()


def _scalar(s):
    s = s.strip()
    if not s: return None
    if s[0] in '"\'' and s[-1] == s[0]: return s[1:-1]
    low = s.lower()
    if low in ('true', 'false'): return low == 'true'
    if low in ('null', '~'): return None
    try:
        return int(s, 0) if re.fullmatch(r'[-+]?(0x[0-9a-fA-F]+|\d+)', s) else float(s) if re.fullmatch(r'[-+]?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?', s) else s
    except ValueError:
        return s


def _flow(s, i):
    """s[i] == '[' → (列表, 下一位置)"""
    assert s[i] == '['
    i += 1; out = []; tok = ''
    while i < len(s):
        ch = s[i]
        if ch == '[':
            v, i = _flow(s, i); out.append(v); tok = ''; continue
        if ch in '"\'':
            j = s.index(ch, i + 1); tok += s[i:j + 1]; i = j + 1; continue
        if ch == ',':
            if tok.strip(): out.append(_scalar(tok))
            tok = ''; i += 1; continue
        if ch == ']':
            if tok.strip(): out.append(_scalar(tok))
            return out, i + 1
        tok += ch; i += 1
    raise ValueError('流式列表没闭合')


def _value(text):
    text = text.strip()
    if text.startswith('['):
        v, j = _flow(text, 0)
        if text[j:].strip(): raise ValueError('流式列表后多余内容：' + text[j:][:30])
        return v
    return _scalar(text)


def load(src):
    lines = [_strip_comment(l) for l in src.replace('\r\n', '\n').split('\n')]
    lines = [l for l in lines if l.strip()]
    doc, key, item, k, cont, blk = {}, None, None, 0, None, None   # blk：值写成缩进块列表的那个键（item, 键, 键的缩进）
    while k < len(lines):
        l = lines[k]; k += 1
        ind = len(l) - len(l.lstrip())
        if blk is not None:
            if ind > blk[2] and l.strip().startswith('- '):
                blk[0][blk[1]].append(_value(l.strip()[2:])); continue
            blk = None
        if cont is not None:   # 跨行的流式列表：攒到括号配平
            cont[2] += ' ' + l.strip()
            if _balanced(cont[2]):
                cont[0][cont[1]] = _value(cont[2]); cont = None
            continue
        if not l.startswith((' ', '-')):
            m = re.fullmatch(r'([A-Za-z_][\w]*)\s*:\s*(.*)', l)
            if not m: raise ValueError('顶层行看不懂：' + l[:40])
            key = m.group(1)
            doc[key] = [] if not m.group(2) else _value(m.group(2))
            item = None; continue
        s = l.strip()
        if s == '-' or s.startswith('- '):
            item = {}; doc[key].append(item); s = s[1:].strip()
            if not s: continue
        m = re.fullmatch(r'([A-Za-z_][\w]*)\s*:\s*(.*)', s)
        if not m or item is None: raise ValueError('列表项行看不懂：' + s[:40])
        v = m.group(2)
        if not v.strip():   # 值另起几行写成「- 值」块列表
            item[m.group(1)] = []; blk = (item, m.group(1), ind if not l.strip().startswith('-') else ind + 2); continue
        if v.strip().startswith('[') and not _balanced(v):
            cont = [item, m.group(1), v]; continue
        item[m.group(1)] = _value(v)
    if cont is not None: raise ValueError('文件结束时流式列表没闭合')
    return doc


def _balanced(s):
    d, q = 0, None
    for ch in s:
        if q:
            if ch == q: q = None
        elif ch in '"\'': q = ch
        elif ch == '[': d += 1
        elif ch == ']': d -= 1
    return d == 0
