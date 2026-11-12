"""「复制错误摘要」的正文（Mac / Windows 共用）：给维护者和玩家自己的 AI 分析用。

只读作业记录、请求、游戏库目录和日志；全文过 tools/redact.py，家目录换成 ~。不改任何状态。
前端传进来的只有它独有的信息（App 版本、目标设备、环境检查未过项），见 S2A_REPORT_EXTRA。
"""
import ctypes
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from core import Failure, _job_dirs, journal, logs_root, read, request_path, shared_redact

FAILED_STATES = ("failed", "interrupted")
LOG_CHARS = 12000
FEEDBACK = "反馈：https://github.com/jhaizhou-ops/S2Arm/issues 或 X @happyjoejiang"


def bytes_text(n):
    if not isinstance(n, (int, float)) or n < 0:
        return "-"
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} B" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024


def when(stamp):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stamp)) if isinstance(stamp, (int, float)) else "-"


def find_task(private, game=None, operations=None):
    """最近一条失败的作业；game / operations 只收窄范围。没有就抛 job_unknown。"""
    best = None
    for path in (p for d in _job_dirs(private) for p in d.glob("*.json")):
        if path.name.endswith(".request.json"):
            continue
        record = read(path)
        if not isinstance(record, dict) or record.get("state") not in FAILED_STATES:
            continue
        if game and record.get("gameId") != game:
            continue
        if operations and record.get("operation") not in operations:
            continue
        if best is None or (record.get("started") or 0) > (best.get("started") or 0):
            best = record
    if best is None:
        raise Failure("没有找到失败的作业记录。", code="job_unknown")
    return best["id"]


def log_paths(private, record):
    logs = logs_root(private)
    found = [Path(d["logPath"]) for d in record.get("diagnostics") or [] if isinstance(d, dict) and d.get("logPath")]
    if logs.is_dir():
        found += sorted(logs.glob(record["id"] + "*"), key=lambda p: p.stat().st_mtime)
    return [p for p in dict.fromkeys(found) if p.is_file()]


def tail(path, limit=LOG_CHARS):
    with path.open("rb") as handle:
        handle.seek(max(0, path.stat().st_size - limit * 4))
        return handle.read().decode(errors="replace")[-limit:]


CRASH_SCAN = 32 << 20   # 往前找崩溃现场的最大字节（现场后面的全线程表可达几 MB）
CRASH_LINES = 60        # 现场节最多几行（寄存器 + 回溯）


def crash_excerpt(path):
    """宿主崩溃现场（runtime/src/crash.c：一行「【红】CRASH 信号 … pc … lr …」，后跟缩进的寄存器与 #0…#N 回溯）：
    取最后一次的那行与其后缩进行，外加它之前最近 5 条【红】行。现场后面是所有线程的等待栈（「[现场] 线程 …」，一百多条线程几百 KB），
    原先只截日志末尾就只剩别的线程在等锁，崩溃线程被挤掉、玩家贴了摘要也定不了因（#806 / #786）。没有现场返回空串"""
    try:
        with path.open("rb") as handle:
            size = path.stat().st_size; handle.seek(max(0, size - CRASH_SCAN))
            lines = handle.read().decode(errors="replace").splitlines()
    except OSError:
        return ""
    at = max((i for i, line in enumerate(lines) if "【红】CRASH" in line), default=-1)
    if at < 0:
        return ""
    keep = [line for line in lines[max(0, at - 400):at] if "【红】" in line and "崩溃原始现场" not in line][-5:] + [lines[at]]
    for line in lines[at + 1:]:
        if len(keep) >= CRASH_LINES + 6 or not line.startswith("[s2a]   "):
            break
        keep.append(line)
    return "\n".join(line[:300] for line in keep)


def memory_bytes():
    if os.name == "nt":
        class Status(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong), ("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong),
                        ("pageTotal", ctypes.c_ulonglong), ("pageFree", ctypes.c_ulonglong), ("virtualTotal", ctypes.c_ulonglong),
                        ("virtualFree", ctypes.c_ulonglong), ("extended", ctypes.c_ulonglong)]
        status = Status(length=ctypes.sizeof(Status))
        return status.total if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)) else None
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")


def processor():
    if sys.platform == "darwin":
        try:
            return subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return platform.machine()
    return platform.processor() or platform.machine()


def volume_format(path):
    """游戏库所在磁盘的格式：exFAT 等不支持克隆的盘是常见失败原因。查不到返回 "-"。"""
    try:
        if os.name == "nt":
            name = ctypes.create_unicode_buffer(64)
            root = os.path.splitdrive(os.path.abspath(path))[0] + "\\"
            return name.value if ctypes.windll.kernel32.GetVolumeInformationW(root, None, 0, None, None, None, name, 64) else "-"
        best, kind = "", "-"
        for line in subprocess.run(["/sbin/mount"], capture_output=True, text=True, timeout=5).stdout.splitlines():
            if " on " not in line or "(" not in line:
                continue
            mount = line.split(" on ", 1)[1].rsplit(" (", 1)[0]
            if str(path).startswith(mount) and len(mount) > len(best):
                best, kind = mount, line.rsplit(" (", 1)[1].split(",")[0].rstrip(")")
        return kind
    except (OSError, subprocess.SubprocessError, ValueError):
        return "-"


def disk_lines(label, path):
    while path and not Path(path).exists() and Path(path).parent != Path(path):
        path = Path(path).parent
    try:
        return [f"{label}可用：{bytes_text(shutil.disk_usage(path).free)}（{volume_format(Path(path).resolve())}）"]
    except OSError:
        return [f"{label}可用：-"]


def own_bytes(package, packages):
    """这一项自己的字节：同一个原件里装了多项（本体 + 更新 + DLC 合集、NUP 容器）时 size 是整个原件，改用读取器记的本项内容字节
    （contentBytes，nx_unpack --inspect / nup_inspect 按项算）；单项原件或老记录没有 contentBytes 时照旧用 size（原件大小）。
    原包合计仍按 sha256 去重用 size（#141：23 个约 0.1 MB 的 DLC 各显示成合集的 14.16 GB）"""
    sha = package.get("sha256")
    shared = bool(sha) and sum(1 for p in packages if p.get("sha256") == sha) > 1
    return (package.get("contentBytes") or package.get("size")) if shared else package.get("size")


def game_lines(request, game_id):
    if not game_id:
        return []
    lines = ["", "【游戏】", "程序号：" + game_id]
    library = request.get("library")
    games = (read(Path(library) / "catalog.json") or {}).get("games", []) if library else []
    game = next((g for g in games if isinstance(g, dict) and g.get("id") == game_id), None)
    if not game:
        return lines
    packages = [p for p in game.get("packages") or [] if isinstance(p, dict)]
    lines += ["名称：" + str(game.get("name") or "-"), "版本：" + str(game.get("display") or "-")]
    for package in packages:
        lines.append(f"包：{package.get('type') or '?'} v{package.get('version', '?')} {package.get('format') or 'NSP/XCI'} {bytes_text(own_bytes(package, packages))}")
    sources = {p["sha256"]: p for p in packages if p.get("sha256")}
    source_packages = list(sources.values()) + [p for p in packages if not p.get("sha256")]
    lines.append("原包合计：" + bytes_text(sum(p.get("size") or 0 for p in source_packages)))
    return lines


def build(private, task, extra=None):
    extra = extra or {}
    record = journal(private, task)
    request = read(request_path(private, task)) or {}
    lines = ["S2Arm 错误摘要", "", "【出错】"]
    if extra.get("platform"):
        lines.append("平台：" + str(extra["platform"]))
    lines += ["任务号：" + task, "操作：" + str(record.get("operation") or "-"), "结果：" + str(record.get("state") or "-"),
              "出错阶段：" + str(record.get("milestone") or record.get("stage") or "-"), "原因：" + str(record.get("message") or "-"),
              "开始：" + when(record.get("started")), "结束：" + when(record.get("ended"))]
    if isinstance(record.get("attemptNo"), int) and record["attemptNo"] > 1:
        lines.append(f"第 {record['attemptNo']} 次尝试")
    diagnostics = [d for d in record.get("diagnostics") or [] if isinstance(d, dict)]
    for item in diagnostics:
        lines.append(f"错误码：{item.get('code') or '-'}（{item.get('component') or '-'}，阶段 {item.get('stage') or '-'}" +
                     (f"，退出码 {item['exitCode']}" if item.get("exitCode") is not None else "") + "）")
        lines.append("  说明：" + str(item.get("summary") or "-"))
        if item.get("suggestion"):
            lines.append("  建议：" + str(item["suggestion"]))
    if not diagnostics:
        lines.append("错误码：无（作业没有写出诊断，通常是进程被结束或崩溃）")
    started = record.get("milestoneStarted") or {}
    order = [m["id"] for m in record.get("milestones") or [] if isinstance(m, dict) and m.get("id") in started]
    if order:
        end = record.get("ended") or time.time()
        spans = [f"{m} {(started[order[i + 1]] if i + 1 < len(order) else end) - started[m]:.0f} 秒" for i, m in enumerate(order)]
        lines += ["", "【阶段用时】", "；".join(spans)]
    lines += game_lines(request, record.get("gameId"))
    library = request.get("library")
    lines += ["", "【电脑】", f"S2Arm：{extra.get('app') or '-'}（{extra.get('build') or '-'}）",
              "系统：" + platform.platform(), "处理器：" + str(processor()), "内存：" + bytes_text(memory_bytes())]
    if library:
        lines += disk_lines("游戏库所在盘", library)
    lines += disk_lines("数据目录所在盘", str(private))
    for label, key in (("Xcode", "xcode"), ("目标设备", "device")):
        if extra.get(key):
            lines.append(f"{label}：{extra[key]}")
    if sys.platform == "darwin":
        try:
            from install import signing_summary
            lines.append("Xcode 签名：" + signing_summary())
        except Exception:
            pass   # 诊断附带信息，取不到不影响摘要
    lines.append("密钥：" + ("已放入" if (Path(private) / "keys/prod.keys").is_file() else "没有"))
    checks = [c for c in extra.get("checks") or [] if isinstance(c, dict)]
    if checks:
        lines += ["", "【环境检查未通过】"] + [f"{c.get('name')}：{c.get('message')}" for c in checks]
    logs = log_paths(private, record)
    body = "\n\n".join(f"--- {p.name} ---\n{tail(p)}" for p in logs[-2:])
    if not body:
        details = [str(d["detail"]) for d in diagnostics if d.get("detail")]
        body = "\n\n".join(details) or "（这条作业没有留下日志文件）"
    crash = next((c for c in (crash_excerpt(p) for p in reversed(logs[-2:])) if c), "")
    if crash:
        lines += ["", "【崩溃现场】", crash]
    lines += ["", "【日志末尾】", body, "", FEEDBACK]
    # 任务号是 UUID，脱敏规则会当成设备号抹掉；它不敏感，分析时要靠它对上日志
    mark = "S2ARMTASKMARK"
    text = "\n".join(lines).replace(str(Path.home()), "~").replace(task, mark)
    redact = shared_redact()
    return redact.redact_text(text, key_values=redact.load_key_values([Path(private) / "keys/prod.keys"])).replace(mark, task)


def main(private, task=None, game=None, operations=None):
    try:
        extra = json.loads(os.environ.get("S2A_REPORT_EXTRA") or "{}")
    except json.JSONDecodeError:
        extra = {}
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(build(private, task or find_task(private, game, operations), extra))
    return 0
