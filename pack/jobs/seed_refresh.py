"""推送 / 导出前补这一款的管线预热表（11-25 #1842，维护者批：只在玩家对这一款操作时前台做、只写这一张表、不重出别的；联网失败照推只记日志）。
为什么：随包预热表 shaders/direct/pso_manifest.tsv 是出包那一刻按当时拿到的管线种子生成的（pack/stage_direct_seed.sh；种子 = 本机 pso_seed + 云端统一包
  g/<程序号> 的 pso 条目 + 玩家 iPhone 真跑见过的）。那次没拿到（云端还没收录 / 没联网），包里就是空表，新装首局在提交线程现编几百条管线；
  之后云端补上了，「更新这款」（install.update_game：重编着色器库、按新改写器刷程序）也不会重写这张表，推送时资源包号没变也不重推。
做什么：拉一次这款的云端补丁包（patches.fetch，落管线种子缓存）→ 用种子阶段同一套纯 Python 生成新表（graphics/tools/direct/run_knowledge.py
  快照 → pso_layout.py skey-size → pso_seed.py，按本包直连库的键滤）→ 与资源包里那张不同就写进资源包与产物根，改 index.tsv 这一行、manifest.json
  的 total / index_sha256（资源包号随之变，推送 / 导出照常只带变了的文件）。种子没变 = 新表与旧表相同，什么都不写。
任何一步出错都只记日志、返回原样（推送照常进行）。只认 IMG 形态与旧文件形态资源包里按文件放的 shaders/direct/pso_manifest.tsv"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

MANIFEST = "shaders/direct/pso_manifest.tsv"


def update_pack_file(pack: Path, rel: str, data: bytes) -> bool:
    """资源包目录 pack 里按文件放的 rel 换成 data：写文件、改 index.tsv 那一行（路径<TAB>字节<TAB>sha256）、重算 manifest.json 的 files / total /
    index_sha256。index.tsv 里没有这一行（这包没登记这张表）就不动、回 False；内容相同也回 False。先写文件、再换清单（清单最后原子换）"""
    ix_path = Path(pack) / "index.tsv"
    lines = ix_path.read_text(encoding="utf-8").splitlines(keepends=True)
    sha = hashlib.sha256(data).hexdigest()
    hit = None
    for i, l in enumerate(lines):
        cols = l.rstrip("\n").split("\t")
        if cols and cols[0] == rel:
            hit = i
            if len(cols) >= 3 and cols[2] == sha and cols[1] == str(len(data)):
                return False
    if hit is None:
        return False
    dst = Path(pack) / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    tmp.write_bytes(data); os.replace(tmp, dst)
    lines[hit] = f"{rel}\t{len(data)}\t{sha}\n"
    ix = "".join(lines)
    mf_path = Path(pack) / "manifest.json"
    mf = json.loads(mf_path.read_text(encoding="utf-8")) if mf_path.is_file() else {}
    mf["files"] = len(ix.splitlines())
    mf["total"] = sum(int(l.split("\t")[1]) for l in ix.splitlines() if l.count("\t") >= 2)
    mf["index_sha256"] = hashlib.sha256(ix.encode("utf-8")).hexdigest()
    for name, text in (("index.tsv", ix), ("manifest.json", json.dumps(mf, ensure_ascii=False, indent=1) + "\n")):
        t = Path(pack) / (name + ".tmp")
        with open(t, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.replace(t, Path(pack) / name)
    return True


def generate(engine: Path, root: Path, extra: str | None, env: dict) -> bytes | None:
    """按产物根 root（直连库的 keys.tsv / shader_map.tsv）与种子来源生成预热表内容；生成不了回 None"""
    py = [sys.executable, "-X", "utf8"]
    keys = root / "shaders/direct/keys.tsv"
    if not keys.is_file():
        return None
    env = dict(env)
    if extra:
        env["S2A_PSO_SOURCES_EXTRA"] = extra
    with tempfile.TemporaryDirectory(prefix="s2a_seedref_") as td:
        t = Path(td) / "t"
        r = subprocess.run(py + [str(engine / "graphics/tools/direct/run_knowledge.py"), str(t), str(root)], cwd=engine, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        if r.returncode or not (t / "seen.tsv").is_file():
            print(f"【黄】预热表补跑：跑局知识快照出不来：{(r.stderr or r.stdout).strip()[-200:]}", file=sys.stderr)  # 非玩家句
            return None
        r = subprocess.run(py + [str(engine / "graphics/tools/direct/pso_layout.py"), "skey-size"], cwd=engine, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        sk = r.stdout.strip()
        if r.returncode or not sk:
            return None
        out = Path(td) / "pso_manifest.tsv"
        r = subprocess.run(py + [str(engine / "graphics/tools/direct/pso_seed.py"), str(out), str(keys), str(root / "shaders/direct/shader_map.tsv"),
                                 sk, str(t / "seen.tsv")], cwd=engine, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        if r.returncode or not out.is_file():
            print(f"【黄】预热表补跑：pso_seed.py 失败：{(r.stderr or r.stdout).strip()[-200:]}", file=sys.stderr)  # 非玩家句
            return None
        return out.read_bytes()


def refresh(c, gid: str, pack: Path) -> bool:
    """推送 / 导出前调：补这一款资源包里的预热表；写了回 True。任何意外只记日志、回 False（推送照常）"""
    import layout, patches
    gid = gid.upper()
    try:
        roots = layout.ios_work(c, gid, create=False) / "roots"
        ptr = next(iter(sorted(roots.glob("*" + layout.CURRENT))), None) if roots.is_dir() else None
        root = layout.current_root(c, ptr) if ptr else None
        if not root or not Path(root).is_dir():
            print(f"预热表补跑：{gid} 电脑上没有这款的产物根，跳过", file=sys.stderr)  # 非玩家句
            return False
        root = Path(root); game = {"id": gid}
        try:
            patches.fetch(c, game, str(root / "exefs"), "ios")   # 落云端管线种子缓存（同出包）；没联网 / 查库出错只记日志，用已有缓存
        except Exception as e:
            print(f"【黄】预热表补跑：{gid} 云端补丁包没取到，按本机已有种子：{type(e).__name__}: {str(e)[:160]}", file=sys.stderr)  # 非玩家句
        data = generate(Path(c.engine), root, patches.seed_sources(c, game), c.env() if hasattr(c, "env") else dict(os.environ))
        if not data:
            return False
        old = (Path(pack) / MANIFEST).read_bytes() if (Path(pack) / MANIFEST).is_file() else b""
        if data == old:
            return False
        if not update_pack_file(Path(pack), MANIFEST, data):
            print(f"预热表补跑：{gid} 资源包清单里没有 {MANIFEST} 这一行，没写", file=sys.stderr)  # 非玩家句
            return False
        mroot = root / MANIFEST
        tmp = mroot.with_name(mroot.name + ".tmp"); tmp.write_bytes(data); os.replace(tmp, mroot)
        n_old = sum(1 for l in old.decode("utf-8", "replace").splitlines() if l and not l.startswith("#"))
        n_new = sum(1 for l in data.decode("utf-8", "replace").splitlines() if l and not l.startswith("#"))
        print(f"预热表补跑：{gid} 管线预热表 {n_old} → {n_new} 行，已写进资源包（推送 / 导出只带这张表）", file=sys.stderr)  # 非玩家句
        return True
    except Exception as e:
        print(f"【黄】预热表补跑：{gid} 出错，照常推送：{type(e).__name__}: {str(e)[:200]}", file=sys.stderr)  # 非玩家句
        return False
