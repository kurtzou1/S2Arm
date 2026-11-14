"""Shared stdlib-only redaction. Importing this module performs no file access."""
from pathlib import Path
import re

KEY_LINE = re.compile(r'(?im)^(?P<prefix>[ \t]*[A-Za-z0-9_.-]+[ \t]*=[ \t]*)(?P<value>[0-9a-f]{32,})[^\r\n]*(?=\r?$)')

SECRET = re.compile(r'(?i)(?:password|passwd|secret|token|api[_-]?key|authorization|cookie|serial(?:number)?|udid|uuid|imei|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address|uniqueidentifier|identifierforvendor|tester|(?:^|[_-])keys?(?:[_-]|$)|(?:^|[_-])(?:kek|bek|seed|keyblob)(?:[_-]|$)|titlekek|masterkey|headerkey)')

# Scan keys separately so an innocent outer field cannot hide a nested secret assignment.
ASSIGNMENT_KEY = re.compile(r"""["']?(?P<name>[A-Za-z_][A-Za-z0-9_.-]*)["']?[^\S\r\n]*[:=][^\S\r\n]*""")


def redact_assignments(text):
    pieces, cursor = [], 0
    for match in ASSIGNMENT_KEY.finditer(text):
        if match.end() <= cursor or not SECRET.search(match['name']):
            continue
        start = match.end()
        q = text[start] if start < len(text) and text[start] in ('"', "'") else ''
        # Quotes may also start inside an unquoted value (shell-style fragments).
        quote = q or None
        end = start + (1 if q else 0)
        while end < len(text) and text[end] not in '\r\n':
            if quote and text[end] == '\\':
                end += 1
                if end < len(text) and text[end] not in '\r\n':
                    end += 1
            elif quote:
                if text[end] == quote:
                    quote = None
                end += 1
            elif text[end] in ('"', "'"):
                quote = text[end]
                end += 1
            elif text[end].isspace() or text[end] in (',;}]' if q else ',;}'):
                break
            else:
                end += 1
        closed = quote is None
        if end > start:
            # Preserve valid JSON quotes; scan state also covers adjacent fragments and tails.
            pieces.extend((text[cursor:start], q + '[REDACTED]' + (q if closed else '')))
            cursor = end
    pieces.append(text[cursor:])
    return ''.join(pieces)


def load_key_values(paths=None) -> frozenset[str]:
    """Read Switch key assignments lazily; an empty iterable disables default files."""
    if paths is None:
        paths = (Path.home() / '.switch' / 'prod.keys', Path.home() / '.switch' / 'title.keys')
    values = set()
    for path in paths:
        try:
            with Path(path).open(encoding='utf-8', errors='replace') as stream:
                for line in stream:
                    match = KEY_LINE.fullmatch(line.rstrip('\r\n'))
                    if match:
                        values.add(match['value'].lower())
        except FileNotFoundError:
            continue
    return frozenset(values)



# Shared identity contract: tests/fixtures/redact_cases.tsv (Python/Swift/iOS).
# Apply after secret assignments so explicit udid=/serial= retain [REDACTED].
# Shape matches use ASCII alphanumeric boundaries, independent of Unicode \b.
# A legacy 40-hex value is private only on a physical line containing the
# standalone word udid/device/serial; ordinary Git SHAs remain unchanged.
# Device owner is a nonempty token delimited by whitespace, quotes, brackets,
# or log/JSON punctuation. Keep 的iPhone/的iPad so the model remains useful.
IDENTITY_RULES = (
    # Preserve known field labels first; unknown '=' prefixes are ambiguous and hidden.
    (r'''(?i)((?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])(?:contact|email|mail|from|to|reply[_-]?to|user)["']?[ \t]*[:=][ \t]*["']?)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])''', r'\1[EMAIL]'),
    (r"(?i)(?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])", '[EMAIL]'),
    (r'''(?i)(\bDEVELOPMENT_TEAM[ \t]*=[ \t]*["']?|\bSigning[ \t]+with[ \t]+team[ \t]+)(?<![A-Z0-9])[A-Z0-9]{10}(?![A-Z0-9])''', r'\1[TEAM_ID]'),
    (r'(?i)(?<![A-Z0-9])(s2arm\.)[A-Z0-9]{10}(\.[A-F0-9]{16})(?![A-Z0-9])', r'\1[TEAM_ID]\2'),
    (r'(?i)(?<![A-Z0-9])[A-F0-9]{8}-[A-F0-9]{16}(?![A-Z0-9])', '[DEVICE_ID]'),
)
DEVICE_CONTEXT = re.compile(r'(?i)\b(?:udid|device|serial)\b')
LEGACY_UDID = re.compile(r'(?i)(?<![A-Z0-9])[A-F0-9]{40}(?![A-Z0-9])')
# 只在一串非分隔字符的开头试（前面不是同类字符）：原写法从串里每个位置起都往后吞到底再回退，长串（长 JSON 值、零字节）上是平方级——
#   4 MiB 的任务记录脱敏要几分钟（#917）。结果不变：最左匹配本来就从串首开始
DEVICE_NAME = re.compile(r'''(?<![^\s"'<>:=,;{}\[\]，。])[^\s"'<>:=,;{}\[\]，。]+的(iPhone|iPad)''')


def redact_identity(text):
    for pattern, replacement in IDENTITY_RULES:
        text = re.sub(pattern, replacement, text)
    # Preserve CR/LF and restrict device context to that physical line.
    text = re.sub(r'[^\r\n]+', lambda match: LEGACY_UDID.sub('[DEVICE_ID]', match[0])
                  if DEVICE_CONTEXT.search(match[0]) else match[0], text)
    return DEVICE_NAME.sub(r'[DEVICE_NAME]的\1', text)


def _private_path(match):
    """路径换成占位；Windows 路径保留长度和层数（不含内容），WinError 206 这类问题要靠它分清是不是路径太长"""
    path = match.group(0).replace('\\\\', '\\')
    if '\\' not in path:
        return '[PRIVATE_PATH]'
    return f"[PRIVATE_PATH len={len(path)} depth={path.count(chr(92))}]"


# 系统错误原文（strerror）：路径匹配会一直吞到行尾（路径本身可能带空格，不能按空白截断），「cp: <路径>: Operation not permitted」的原因
#   原先跟着路径一起变成 [PRIVATE_PATH]，玩家诊断里看不出是没权限、没空间还是文件不在（11-09 01007EF00011E000拷字体失败 7 行全是这样）。
#   只认这张表里的原文（不收任意尾巴，免得把路径里冒号后的名字漏出去）：末尾是「: 原文」就只换前面的路径
ERRNO_REASONS = ("Operation not permitted", "Permission denied", "No such file or directory", "File exists", "Read-only file system",
                 "No space left on device", "Is a directory", "Not a directory", "Input/output error", "Resource busy", "Device not configured",
                 "File name too long", "Too many open files", "Disc quota exceeded", "Bad file descriptor", "Directory not empty", "Invalid argument",
                 "Cross-device link", "Operation not supported", "Operation timed out", "Resource deadlock avoided", "Resource temporarily unavailable",
                 "Too many levels of symbolic links", "Bad address", "Result too large")
# macOS cp -c 在系统错误前还带系统调用名（#290：「…bfttf: clonefile failed: Cross-device link」），一起保留
_REASON_TAIL = re.compile(r'(?i): (?:(?:clonefile|fclonefileat|copyfile) failed: )?(?:' + '|'.join(map(re.escape, ERRNO_REASONS)) + r')\.?[ \t]*$')


def _private_path_keep_reason(match):
    text = match.group(0)
    tail = _REASON_TAIL.search(text)
    if not tail or tail.start() == 0:
        return _private_path(match)
    return _private_path(re.match(r'.*', text[:tail.start()], re.S)) + text[tail.start():]


def redact_text(text, *, key_values=None, preserve_identity=False) -> str:
    """Redact known values before shape rules, including formal identity fields."""
    values = load_key_values() if key_values is None else key_values
    patterns = [f'(?i:{re.escape(value)})' if re.fullmatch(r'[0-9a-fA-F]+', value) else re.escape(value)
                for value in sorted(set(values), key=len, reverse=True) if value]
    s = re.sub('|'.join(patterns), '[REDACTED]', str(text)) if patterns else str(text)
    s = KEY_LINE.sub(lambda match: match['prefix'] + '[REDACTED]', s)
    s = redact_assignments(s)
    s = re.sub(r'(?im)(authorization\s*[:=]\s*)[^\r\n]+', r'\1[REDACTED]', s)
    s = re.sub(r'(?i)(https?://)[^/\s:@]+:[^/\s@]+@', r'\1[REDACTED]@', s)
    s = re.sub(r'(?i)([?&](?:token|key|api_key|secret|password|auth|signature|session|access_token)=)[^&#\s]+', r'\1[REDACTED]', s)
    s = re.sub(r'(?i)((?:password|passwd|secret|token|api[_-]?key|[a-z0-9_]*_key(?:_[a-z0-9]+)*|titlekek|masterkey|headerkey|cookie|serial(?:number)?|udid|uuid|imei|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address|uniqueidentifier|identifierforvendor)\s*["\x27]?\s*[:=]\s*["\x27]?)[^\s,"\x27;}]+', r'\1[REDACTED]', s)
    s = redact_identity(s)
    s = re.sub(r'(?:/Volumes/|/private/var/|/var/mobile/|/data/user/|/data/data/|\\\\)[^\r\n\"\x27<>]*', _private_path_keep_reason, s)
    s = re.sub(r'(?:/Users/|/home/|[A-Za-z]:[\\/](?:Users|Documents)[\\/])[^\r\n\"\x27<>]*', _private_path_keep_reason, s)
    s = re.sub(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '[DEVICE_ID]', s)
    if not preserve_identity:
        s = re.sub(r'(?i)\b[0-9a-f]{64,}\b', '[KEY_MATERIAL]', s)
    return ''.join(c if c in '\n\t' or ord(c) >= 32 and ord(c) != 127 else '\ufffd' for c in s)

