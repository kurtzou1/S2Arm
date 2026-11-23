"""资源替换类 mod（LayeredFS）导入（11-15 维护者「咱们也可以支持 mod 导入」）：一款游戏文件夹的 mods/ 是唯一的家。
  · 布局：mods/<名字>/romfs/**（服务层 services/S2A.Services/RomFsMods.cs 起局时按文件夹名升序叠到本体 RomFS 上，后叠的覆盖先叠的）。
    Mac 起局经 S2A_MODS_DIR 指到这里（pack/jobs/build.py）；装到 iPhone 时推进机上本款文档根 mods/（pack/jobs/install.py push_mods）。
  · 导入：玩家给 zip 或文件夹，按常见发布结构找出每个 romfs/（Atmosphere atmosphere/contents/<程序号>/romfs、Ryujinx <程序号>/<名字>/romfs、
    直接 <名字>/romfs、只有 romfs/），一个 romfs 一份 mod；合集子程序存成 mods/<名字>/romfs.<完整程序号>，其他游戏的不收。
  · 不收：exefs/（代码补丁：pchtxt / IPS，走社区补丁那条路，这里只报一句）、romfs 以外的东西、符号链接、逃出目录的路径。
  · 只是文件搬运：不解析、不执行 mod 里的任何东西。"""
from __future__ import annotations

import re
import shutil
import tempfile
import zipfile
from pathlib import Path

from core import Failure
import layout

DIR = "mods"
OFF = ".off-"   # 关掉的 mod：文件夹改名为 mods/.off-<名字>（11-15 v0.5.0 收口「导入、关掉、删掉」）。服务层 RomFsMods.cs 跳过 . 开头的文件夹、
                #   装机推送（install.push_mods）也不推 . 开头的 → 关掉 = 起局不叠、手机上那份删掉；打开改回原名即恢复，内容不动
MAX_BYTES = 16 << 30          # 一次导入解开后的总大小上限（大号资源 mod 也就几 GB；防压缩炸弹）
MAX_FILES = 200_000
GID_RE = re.compile(r"^[0-9A-Fa-f]{16}$")
NAME_BAD = re.compile(r'[\x00-\x1f/\\:*?"<>|]')


def mods_dir(c, gid, create=True):
    import layout
    return layout.path(c, gid, DIR, create=create)


def _safe_name(s):
    s = NAME_BAD.sub("_", s).strip(" .") or "mod"
    return s[:80]


def _unpack(src, work):
    """zip → 解到 work；文件夹 → 原样用。逃出目录 / 符号链接 / 超量 → 报错"""
    src = Path(src)
    if src.is_dir():
        return src
    if not src.is_file() or not zipfile.is_zipfile(src):
        raise Failure("mod 要选 zip 压缩包或文件夹（7z / rar 先解压成文件夹再导入）：%s" % src.name, code="job_failed")
    out = Path(work) / "z"
    total = 0
    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        if len(infos) > MAX_FILES:
            raise Failure("这个压缩包文件太多（超过 %d 个）：%s" % (MAX_FILES, src.name), code="job_failed")
        for i in infos:
            name = i.filename.replace("\\", "/")
            parts = [p for p in name.split("/") if p not in ("", ".")]
            if not parts or ".." in parts or name.startswith("/"):
                continue
            if (i.external_attr >> 16) & 0o170000 == 0o120000:   # 符号链接：不收
                continue
            total += i.file_size
            if total > MAX_BYTES:
                raise Failure("这个压缩包解开超过 16 GB：%s" % src.name, code="job_failed")
            dst = out.joinpath(*parts)
            if i.is_dir():
                dst.mkdir(parents=True, exist_ok=True)
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(i) as r, open(dst, "wb") as w:
                shutil.copyfileobj(r, w, 1 << 20)
    return out


CODE_EXT = (".pchtxt", ".ips")   # exefs 里的代码补丁（11-15 维护者：电脑端导入、出包 / S 级升级时编进程序，pack/cpatch.py）


def _code_files(d):
    # ._<名>.pchtxt / .ips（mod 放在 exFAT 上时的附属文件）不是补丁：当补丁编进程序会让出包解析失败
    return [f for f in layout.entries(d) if f.is_file() and not f.is_symlink() and f.suffix.lower() in CODE_EXT]


def _child(d, name):
    """d 下名为 name 的子目录（大小写都认）"""
    return next((p for p in Path(d).iterdir() if p.is_dir() and not p.is_symlink() and p.name.lower() == name), None) if Path(d).is_dir() else None


def _parts(d):
    """mod 根 d → (romfs 目录或 None, 代码补丁目录或 None)：d/romfs；d/exefs 里有 pchtxt / IPS；Atmosphere 的 exefs_patches/<名>/ 本身放着 IPS"""
    code = _child(d, "exefs")
    code = code if code and _code_files(code) else d if d.parent.name.lower() == "exefs_patches" and _code_files(d) else None
    return _child(d, "romfs"), code


PROGRAM_FILES = ("main", "main.npdm", "rtld", "sdk") + tuple("subsdk%d" % i for i in range(10))   # exefs 里的游戏程序件（不是补丁）


def _whole_program(root):
    """root 下（含 root 本身）有名为 exefs 的文件夹、里面有游戏程序件而没有 pchtxt / IPS：整份替换游戏程序的 mod"""
    root = Path(root)
    dirs = ([root] if root.name.lower() == "exefs" else []) + [p for p in root.rglob("*") if p.is_dir() and not p.is_symlink() and p.name.lower() == "exefs"]
    return any(not _code_files(d) and any(f.is_file() and f.name.lower() in PROGRAM_FILES for f in d.iterdir()) for d in dirs)


def _find(root, gid):
    """→ ([(mod 名, romfs 目录或 None, 代码补丁目录或 None, 子程序号或 None)], [说明]）。mod 根 = 下面有 romfs/ 或带代码补丁的 exefs/ 的文件夹（大小写都认；
    玩家直接选 romfs / exefs 本身也认），或 Atmosphere 的 exefs_patches/<名>/（IPS 文件名是构建号、不带程序号：对不上这款的出包时自然不打）。
    路径上最近的程序号决定目标。合集子程序只收资源替换，不改变代码补丁的出包路径。"""
    found, notes = [], []
    root = Path(root)
    if root.name.lower() in ("romfs", "exefs"):
        root = root.parent
        cands = [root]
    else:
        cands = [root] + sorted(p for p in root.rglob("*") if p.is_dir() and not p.is_symlink() and p.name.lower() not in ("romfs", "exefs"))
    for d in cands:
        rel = d.relative_to(root).parts
        if any(q.lower() in ("romfs", "exefs") for q in rel):
            continue   # 不进 romfs / exefs 里面再找
        rd, code = _parts(d)
        if not (rd or code):
            continue
        target = next((q.upper() for q in reversed((root.parent.name, root.name) + rel) if GID_RE.fullmatch(q)), gid)
        if target != gid:
            if target[:-1] != gid[:-1]:   # 同一合集 = 应用号相同（程序号去掉末位的程序序号）；单独导出的程序 n（末位非 0，#1567）也认主程序那份
                notes.append("「%s」是给另一款游戏（%s）的，没收" % ("/".join(rel) or d.name, target))
                continue
            if code:
                notes.append("子程序 %s 的代码补丁暂不支持，没收" % target)
            if not rd:
                continue
            code = None
        label = [q for q in rel if not GID_RE.match(q) and q.lower() not in ("atmosphere", "contents", "mods", "exefs_patches")]
        found.append(("/".join(label[-2:]), rd, code, target if target != gid else None))
    return found, notes


def import_paths(c, game, paths):
    """玩家导入（zip 或文件夹，可多选）：每个 mod 根存成 mods/<名字>/romfs（资源替换，起局叠上）与 mods/<名字>/exefs（代码补丁 pchtxt / IPS，
    下次出包 / S 级升级时编进程序，code_index）；同名整份替换。→ {imported: [名字], notes: [说明]}。一个都没找到 = 报错（说清要什么结构）"""
    gid = game["id"].upper()
    home = mods_dir(c, gid)
    home.mkdir(parents=True, exist_ok=True)
    imported, notes = [], []
    for raw in paths:
        src = Path(raw)
        base = _safe_name(src.stem if src.is_file() else src.parent.name if src.name.lower() in ("romfs", "exefs") else src.name)
        with tempfile.TemporaryDirectory(dir=c.private) as work:
            root = _unpack(src, work)
            found, why = _find(root, gid)
            notes += why
            if not found:
                if why:
                    raise Failure("；".join(why), code="job_failed")
                if _whole_program(root):   # exefs/ 里只有整份游戏程序（main / subsdk / main.npdm 等）、没有补丁：直说不支持（D-P4F5）
                    raise Failure("「%s」是整份替换游戏程序的 mod，S2Arm 不支持：S2Arm 出包时要改写游戏程序，只能把 exefs/ 里的 pchtxt / IPS 补丁编进去；资源替换类（romfs/）照常能用。" % src.name, code="job_failed")
                raise Failure("「%s」里没找到 mod：资源替换要带 romfs/（如 atmosphere/contents/%s/romfs），代码补丁要带 exefs/ 里的 pchtxt / IPS（或 atmosphere/exefs_patches/<名字>/）。" % (src.name, gid), code="job_failed")
            for label, rd, cd, target in found:
                name = _safe_name(base if len(found) == 1 or not label else "%s - %s" % (base, label.replace("/", " - ")))
                if target and not name.upper().endswith(target):
                    name = f"{name[:80 - len(target) - 1]}-{target}"
                code = _code_files(cd) if cd else []
                files = [f for f in layout.entries(rd, recursive=True) if f.is_file() and not f.is_symlink()] if rd else []
                if not files and not code:
                    notes.append("「%s」是空的，没收" % name)
                    continue
                tmp = home / (".importing-" + name)
                shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir()
                if files:
                    romfs_name = f"romfs.{target}" if target else "romfs"
                    shutil.copytree(rd, tmp / romfs_name, symlinks=True, ignore=lambda d, ns: [n for n in ns if Path(d, n).is_symlink()])
                if code:
                    (tmp / "exefs").mkdir()
                    for f in code:
                        shutil.copyfile(f, tmp / "exefs" / f.name)
                    notes.append("「%s」带 %d 份代码补丁：重新打包这款（或 S 级优化升级）后生效" % (name, len(code)))
                dst = home / name
                for old in (dst, home / (OFF + name)):   # 同名整份替换：关着的那份也换掉，新导入的是开着的
                    if old.exists():
                        layout.remove_tree(old)
                tmp.rename(dst)
                imported.append(name)
    return dict(imported=imported, notes=notes)


def _folders(home):
    """→ {名字: (文件夹, 开着?)}；关着的是 .off-<名字>，别的 . 开头（导入中的临时目录）不算"""
    out = {}
    if home.is_dir():
        for d in home.iterdir():
            if not d.is_dir():
                continue
            if d.name.startswith(OFF):
                out.setdefault(d.name[len(OFF):], (d, False))
            elif not d.name.startswith("."):
                out[d.name] = (d, True)
    return out


def listing(c, game):
    """→ [{name, enabled, files, bytes}]（按叠加顺序：名字升序；关着的照列，enabled 为假）"""
    out = []
    for name, (d, on) in sorted(_folders(mods_dir(c, game["id"].upper(), create=False)).items()):
        roots = [p for p in layout.entries(d) if p.is_dir() and not p.is_symlink() and
                 (p.name == "romfs" or (p.name.startswith("romfs.") and GID_RE.fullmatch(p.name[6:])))]
        files = [f for root in roots for f in layout.entries(root, recursive=True) if f.is_file()]
        out.append(dict(name=name, enabled=on, files=len(files), bytes=sum(f.stat().st_size for f in files), code=len(_code_files(d / "exefs"))))
    return out


def remove(c, game, names):
    have = _folders(mods_dir(c, game["id"].upper(), create=False))
    for n in names:
        if n not in have:
            raise Failure("没有这个 mod：%s。" % n, code="job_failed")
        layout.remove_tree(have[n][0])


def set_enabled(c, game, want):
    """{名字: 真 / 假} → 改名在 <名字> 与 .off-<名字> 之间切换（下次开始游戏生效；装到 iPhone 时机上跟着增删）"""
    if not isinstance(want, dict) or not all(isinstance(v, bool) for v in want.values()):
        raise Failure("mod 开关格式不对。", code="job_failed")
    home = mods_dir(c, game["id"].upper(), create=False)
    have = _folders(home)
    for n, on in want.items():
        if n not in have:
            raise Failure("没有这个 mod：%s。" % n, code="job_failed")
        d, cur = have[n]
        if cur != on:
            d.rename(home / (n if on else OFF + n))


def fingerprint(d):
    """一份 mod 的内容记号（相对路径 + 大小 + 改动时间）：装机时只推变了的（install.push_mods）"""
    import hashlib
    h = hashlib.sha256()
    for f in (p for p in layout.entries(d, recursive=True) if p.is_file()):   # 附属文件随访达 / 系统生灭，不该让记号变、触发整份重推
        st = f.stat()
        h.update(f"{f.relative_to(d).as_posix()}\t{st.st_size}\t{int(st.st_mtime)}\n".encode())
    return h.hexdigest()[:16]


def code_index(c, game):
    """出包 / S 级升级前调（pack/jobs/patches.py fetch）：这款各 mod 的代码补丁整理成一个补丁索引目录交 pack/cpatch.py（类别 mod、编号 mod:<sha>）。
    开着、关着的都收：编进程序的是双路开关，运行时按 mods/<名字> 在不在（关掉 = .off-<名字>）决定开不开（runtime/src/cpatch.c），
    手机上关掉也即时生效、不用重出包。索引里路径 = <mod 名>/<文件名>，进 cpatch.tsv「来源」列，运行时按第一段认 mod。没有代码补丁 → None"""
    gid = game["id"].upper()
    rows = [(name, f) for name, (d, _) in sorted(_folders(mods_dir(c, gid, create=False)).items()) for f in _code_files(d / "exefs")]
    out = Path(c.private) / "community-cache" / "games" / gid / "mod"
    shutil.rmtree(out, ignore_errors=True)
    if not rows:
        return None
    import hashlib
    lines = ["\t".join(["game", "title_id", "path", "type", "source", "license", "in_pack", "sha256", "mod", "origin"])]
    for name, f in rows:
        rel = f"{name}/{f.name}"
        (out / name).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, out / rel)
        data = f.read_bytes()
        lines.append("\t".join(["", gid, rel, "pchtxt" if f.suffix.lower() == ".pchtxt" else "ips", "mod", "", "yes",
                                hashlib.sha256(data).hexdigest(), name, rel]))
    (out / "INDEX.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(out)


def code_digest(c, gid):
    """各 mod 代码补丁的内容摘要（S 级升级记号用，pack/jobs/rewrite_refresh.py sgrade_key）：导入 / 删了代码补丁要重编；只开关不算（运行时开关）"""
    import hashlib
    h = hashlib.sha256()
    for name, (d, _) in sorted(_folders(mods_dir(c, gid.upper(), create=False)).items()):
        for f in _code_files(d / "exefs"):
            h.update(f"{name}/{f.name}\0".encode()); h.update(hashlib.sha256(f.read_bytes()).digest())
    return h.hexdigest()[:16] if h.digest() != hashlib.sha256().digest() else "-"

