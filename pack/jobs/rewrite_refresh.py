# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（维护者 11-11：改写器修了，受影响的款不重出资源包，只换改写产物，随「更新 iPhone 上的 S2Arm」组进新壳）。

为什么不靠缓存键：改写阶段的键含改写器源码指纹（pack/stage_rewrite.sh），改写器一改所有款的键都变；也不能比产物（游戏库里早些时候出的款，
产物本来就跟今天的改写器对不上，比出差别不等于受这次修复影响）。判据由改写器自己报：统计行里 x18_spdyn > 0 的模块，产物会因这次修复而变
（开发丙 11-11 实测：九款金样全 0、产物逐字节同旧；路易吉洋馆 3 两个版本各 38）。

做法（每款）：
  1. 这款记下的改写器指纹（game.json ios.rewriterId）= 本引擎的 → 跳过（改写器没变，平时更新手机不多花时间）
  2. 取原始 exefs：共用解包目录还有效就用它，否则用读取器 --exefs-only 从原件只解 exefs（几秒）；原件不在（外接盘没插）→ 这次跳过、下次再核
  3. 对 main / sdk / subsdk0–9 跑改写器，输入与出包时相同：这款 kit 里的 widen_sites.tsv、fps.tsv，同一份随包代码补丁，S2A_TARGET / 自旋闸同出包
     （11-11 核过：旧改写器按这组输入重跑，产物与完整出包逐字节相同）
  4. 任一模块 x18_spdyn > 0 → 这款受影响：该模块的改写产物（<模块>.patched.bin / .fixups.tsv / .gates.tsv / .sites.tsv / .gaps.tsv / .widen.tsv / .code_patch.tsv）
     换进 kit；资源包（game.img）、直连库不动不推
  5. 记下本引擎的改写器指纹
romfs 里藏的 NRO 模块没有原件可取（资源在 game.img 里），不在这里重跑：保持 kit 原样。

S 级优化补到老游戏（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包，iPhone 只更新 IPA、Mac 下次起局就带上社区补丁）：
  同一步里多核一个「补丁记号」（sgradeKey = 改写器指纹 + 出表代码指纹 + 这款在补丁库里的包版本）。记号变了就按出包同一套
  （pack/stage_rewrite.sh 社区补丁段）现做：不带补丁改写一遍 → pack/cpatch.py plan 出表 → 带补丁行改写 → prune 认领补丁造成的缺口、剔掉重来（至多 6 轮），
  全部模块的改写产物与 cpatch.tsv / cheat-src.* 换进 kit（Mac：运行版本）；资源包、直连库不动。
  出包页取消过「出包时打入」的款（game.json sgradeOff，pack/jobs/patches.py prepare 记）不补。"""
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import layout
from core import Failure

MODULE = re.compile(r"(main|sdk|subsdk[0-9])")
SGRADE_TABLES = ("cpatch.tsv",)   # 随包表（runtime/src/cpatch.c 读）；另有 cheat-src.*（金手指原文随包）
OUTPUTS = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv", "code_patch.tsv")
AFFECTED = re.compile(r"'x18_spdyn':\s*(\d+)")


def rewriter_id(c):
    """本引擎改写器的身份：编译输入的内容指纹（同 stage_rewrite.sh 的 KR 口径，pack/rewriter.py source）"""
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "source"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True)
    if r.returncode or not r.stdout.strip():
        raise Failure("取不到改写器指纹：" + (r.stderr.strip()[-200:] or "无输出"))
    return hashlib.sha256(r.stdout.encode()).hexdigest()[:16]


def rewriter_bin(c):
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "c-path"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True)
    path = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if r.returncode or not Path(path).is_file():
        raise Failure("找不到改写器：" + (r.stderr.strip()[-200:] or "无输出"))
    return path


def original_exefs(c, game, work):
    """这款的原始 exefs 目录；取不到（原件不在 / 不是 NSP、XCI）→ None。
    顺序：共用解包目录 → 这款的 Mac 运行版本自带的 exefs/（出过 Mac 版的款，原件删了 / 外接盘没插也能补 S 级优化）→ 从原件只解 exefs"""
    from build import extract_valid, shared_dir
    from library import selected_packages, source_path
    import sgrade
    saved = sgrade.saved_program(c, game["id"])   # 出包时存下的原始程序（pack/jobs/sgrade.py）：有就不用回原件
    if saved:
        return saved
    if extract_valid(c, game):
        return shared_dir(c, game) / "extract/exefs"
    try:
        mac = layout.image_mac(c, game["id"], create=False) / "exefs"
        if (mac / "main").is_file() and (mac / "main.npdm").is_file():
            return mac
    except (OSError, Failure):
        pass
    packages = selected_packages(game)
    if any(p.get("format") for p in packages if p.get("format") not in (None, "nsp", "xci", "nsz", "xcz")):
        return None   # 解包好的文件夹 / Switch 2 NUP：没有现成的只解 exefs 路子，留给重新出包
    paths = [source_path(c, p) for p in packages if p["type"] in ("base", "update")]
    if not paths or not all(Path(p).is_file() for p in paths):
        return None
    import toolchain
    out = work / "x"
    c.run(["dotnet", toolchain.reader(c), c.keys, out, "--exefs-only", "--title-id=" + game["id"], *map(str, paths)], work / "exefs.log", c.env())
    if not (out / "exefs/main").is_file():
        return None
    return sgrade.save_program(c, game["id"], out / "exefs") or out / "exefs"   # 从原件解出来的存一份，下次不用回原件


def rewrite_env(c, kit, exefs, target):
    env = dict(c.env(), S2A_TARGET=target, S2A_REWRITE_SPIN=os.environ.get("S2A_REWRITE_SPIN", "1"))
    for k in ("S2A_FPS_TSV", "S2A_CPATCH_TSV", "S2A_CODE_PATCH", "S2A_CODE_BUILD"):
        env.pop(k, None)
    if (kit / "fps.tsv").is_file():
        env["S2A_FPS_TSV"] = str(kit / "fps.tsv")
    # 随包代码补丁：同 stage_rewrite.sh（S2A_PATCH_DIR/<程序号>/patch.tsv，构建号 = main 头 0x40 起 16 字节）
    pdir = env.get("S2A_PATCH_DIR")
    if pdir:
        d = (exefs / "main").read_bytes()
        bid = d[0x40:0x50].hex()
        npdm = (exefs / "main.npdm").read_bytes()
        aci = int.from_bytes(npdm[0x70:0x74], "little")
        pid = "%016X" % int.from_bytes(npdm[aci + 0x10:aci + 0x18], "little") if npdm[aci:aci + 4] == b"ACI0" else ""
        patch = Path(pdir) / pid / "patch.tsv"
        if pid and patch.is_file():
            env.update(S2A_CODE_PATCH=str(patch), S2A_CODE_BUILD=bid)
    return env


def modules_of(exefs):
    return sorted(p.name for p in Path(exefs).iterdir() if MODULE.fullmatch(p.name))


def rewrite_modules(binary, env, exefs, out, widen):
    """exefs 里宿主会装载的模块（同 stage_rewrite.sh 的名单）逐个改写到 out → 这次修复会改到的模块（统计行 x18_spdyn > 0）。
    退出码 3 = 有缺口、产物照出（同 stage_rewrite.sh rw_all：社区补丁轮的缺口由 cpatch.py prune 认领），不算失败"""
    hit = []
    for m in modules_of(exefs):
        args = [binary, str(Path(exefs) / m), str(out), m] + ([str(widen)] if Path(widen).is_file() else [])
        r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=600)
        if r.returncode and not (r.returncode == 3 and (Path(out) / f"{m}.patched.bin").is_file()):
            raise Failure(f"重跑改写 {m} 失败（退出码 {r.returncode}）：" + ((r.stderr.strip().splitlines() or [""])[-1])[:200])
        if max((int(x) for x in AFFECTED.findall(r.stdout)), default=0) > 0:
            hit.append(m)
    return hit


def plan_code_id(c):
    """出表代码的指纹（pack/cpatch.py 改了 = 合成规则变了，老游戏要按新规则重出表）"""
    return hashlib.sha256((Path(c.engine) / "pack/cpatch.py").read_bytes()).hexdigest()[:12]


def sgrade_key(c, gid, rid, main_bid):
    """补丁记号：改写器指纹 + 出表代码指纹 + 这款在补丁库里的包版本（pack/jobs/patches.py version_key）"""
    import patches
    return f"{rid}:{plan_code_id(c)}:{patches.version_key(c, gid, main_bid)}"


def sgrade_off(c, gid):
    """出包页取消过「S 级优化（Beta）· 出包时打入」的款（pack/jobs/patches.py prepare 记 game.json sgradeOff）"""
    return layout.game_info(c, gid).get("sgradeOff") is True


def sgrade_rewrite(c, game, base, exefs, target, work):
    """按出包同一套带社区补丁改写（见文件头）→ (产物目录, 全部模块, 随包表文件列表)。base = kit / Mac 运行版本（取 fps.tsv、widen_sites.tsv 等逐款表）"""
    import cheats
    import patches
    gid = game["id"].upper()
    root = Path(work) / "root"; root.mkdir()
    (root / "exefs").symlink_to(Path(exefs).resolve())
    skip = tuple("." + e for e in OUTPUTS)
    for p in Path(base).iterdir():   # 逐款表照拷（出表读 fps.tsv 判「本款已有我方帧率表」、改写读 widen_sites.tsv）；改写产物与旧补丁表不拷
        if p.is_file() and not p.name.endswith(skip) and not p.name.startswith(("cpatch", "cheat-src.")) and p.suffix != ".log":
            shutil.copyfile(p, root / p.name)
    dirs = patches.fetch(c, game, str(exefs), "ios" if target == "ios" else "mac")
    try:
        cheats.fetch(c, game)
    except Exception as e:   # 查库是附加：失败不挡（同 patches.prepare）
        c.emit("message", f"【黄】{gid} 金手指查库没成，先不带：{str(e)[:120]}")
    env = rewrite_env(c, root, exefs, target)
    cd = cheats.cheats_dir(c, gid, create=False)
    if cd.is_dir() and any(f.name not in cheats.SKIP for f in cd.glob("*.txt")):
        env["S2A_CHEATS_DIRS"] = str(cd)
    binary, widen = rewriter_bin(c), root / "widen_sites.tsv"
    rewrite_modules(binary, env, exefs, root, widen)   # 不带补丁的一轮：出表按它的改写点预筛（同 stage_rewrite.sh rw_all 0）
    py = [os.sys.executable, "-X", "utf8", str(Path(c.engine) / "pack/cpatch.py")]
    for _ in range(6):
        r = subprocess.run(py + ["plan", str(root), ""] + [str(d) for d in dirs], cwd=c.engine, env=env, capture_output=True, text=True, timeout=600)
        if r.returncode:
            raise Failure("社区补丁出表出错：" + ((r.stderr.strip().splitlines() or [""])[-1])[:200])
        rows = root / "cpatch_rows.tsv"
        if not rows.is_file() or not rows.stat().st_size:
            break
        rewrite_modules(binary, dict(env, S2A_CPATCH_TSV=str(rows)), exefs, root, widen)
        p = subprocess.run(py + ["prune", str(root)], cwd=c.engine, env=env, capture_output=True, text=True, timeout=600)
        if p.returncode == 10:
            continue
        if p.returncode:
            raise Failure("社区补丁认领缺口出错：" + ((p.stderr.strip().splitlines() or [""])[-1])[:200])
        break
    tables = [root / t for t in SGRADE_TABLES if (root / t).is_file()] + sorted(root.glob("cheat-src.*"))
    return root, modules_of(exefs), tables


def put_tables(base, tables):
    """随包表换进 kit / 运行版本：旧的补丁表与金手指原文先删（这次没出的不留），再拷新的"""
    base = Path(base)
    for old in list(base.glob("cheat-src.*")) + [base / t for t in SGRADE_TABLES]:
        if old.is_file():
            old.unlink()
    for t in tables:
        tmp = base / (t.name + ".rw")
        shutil.copyfile(t, tmp); os.replace(tmp, base / t.name)
    return [t.name for t in tables]


def apply_outputs(out, kit, modules):
    """命中模块的改写产物换进 kit（逐个原子替换）；新改写器不再出的那份删掉（旧的留着会被装载器当成本次的）。没命中的模块一个字节都不动"""
    for m in modules:
        for ext in OUTPUTS:
            src, dst = Path(out) / f"{m}.{ext}", Path(kit) / f"{m}.{ext}"
            if src.is_file():
                tmp = dst.with_name(dst.name + ".rw")
                shutil.copyfile(src, tmp); os.replace(tmp, dst)
            elif dst.is_file():
                dst.unlink()


def ios_key(c, gid, rid):
    """这款 iPhone 件要对上的记号：出包页取消过 S 级优化 = 只看改写器指纹；否则补丁记号（sgrade_key）"""
    info = layout.game_info(c, gid)
    return None if sgrade_off(c, gid) else sgrade_key(c, gid, rid, (info.get("ios") or {}).get("mainBid", ""))


def check_and_update(c, gid, kit, target, rid):
    """一款：→ 'skip'（改写器与补丁记号都没变）| 'unavailable'（原件取不到）| 'unaffected' | 'updated'"""
    info = layout.game_info(c, gid)
    side = info.get("ios") or {}
    key = ios_key(c, gid, rid)
    if side.get("rewriterId") == rid and (key is None or side.get("sgradeKey") == key):
        return "skip"
    game = next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), None)
    if game is None or not (kit / "main.patched.bin").is_file():
        return "unavailable"
    with tempfile.TemporaryDirectory(dir=c.private) as tmp:
        work = Path(tmp)
        exefs = original_exefs(c, game, work)
        if exefs is None:
            return "unavailable"
        bid = (Path(exefs) / "main").read_bytes()[0x40:0x48].hex().upper()
        if key is not None:   # S 级优化补到老游戏：按出包同一套带社区补丁改写，全部模块与补丁表换进 kit
            out, mods, tables = sgrade_rewrite(c, game, kit, exefs, target, work)
            apply_outputs(out, kit, mods)
            names = put_tables(kit, tables)
            c.emit("message", f"{gid}：S 级优化已按当前补丁库补进程序（{', '.join(names) or '这款没有匹配的社区补丁'}；资源不用重推）")
            layout.update_info(c, gid, ios=dict(side, rewriterId=rid, sgradeKey=sgrade_key(c, gid, rid, bid), mainBid=bid))
            return "updated"
        out = work / "out"; out.mkdir()
        hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, kit, exefs, target), exefs, out, kit / "widen_sites.tsv")
        apply_outputs(out, kit, hit)
    layout.update_info(c, gid, ios=dict(side, rewriterId=rid, mainBid=bid))
    return "updated" if hit else "unaffected"


def refresh_ios(c, games):
    """组容器前：这几款的 iPhone 容器件按本引擎改写器核一遍（见文件头）。→ 换了改写产物的款"""
    if not games:
        return []
    try:
        rid = rewriter_id(c)
    except (Failure, OSError, subprocess.SubprocessError) as e:
        # 同 refresh_mac：取不到改写器指纹就整轮不核，不挡这次装机；各款保留原来的产物、不记指纹，下次再核
        c.emit("message", f"【黄】没取到改写器指纹，这次先不核要不要按新版更新程序：{str(e)[:200]}")
        return []
    todo = []
    for g in games:
        side = layout.game_info(c, g).get("ios") or {}
        try:
            key = ios_key(c, g, rid)
        except (Failure, OSError, ValueError) as e:   # 补丁库版本取不到：只按改写器核
            c.emit("message", f"【黄】{g} 没取到补丁库版本，这次只按改写器核：{str(e)[:120]}"); key = None
        if side.get("rewriterId") != rid or (key is not None and side.get("sgradeKey") != key):
            todo.append(g)
    if not todo:
        return []
    c.emit("message", f"正在核对 {len(todo)} 款游戏的程序是否要按新版更新（含 S 级优化补丁）")
    updated, missing = [], []
    for g in todo:
        try:
            r = check_and_update(c, g, layout.ios_kit(c, g), "ios", rid)
            if r == "updated":
                updated.append(g)
            elif r == "unavailable":
                missing.append(g)
        except (Failure, OSError, subprocess.SubprocessError) as e:
            # 核对是附带的一步：某款核不了（改写器在它上面出错、原件读不了）不挡这次装机；这款保留原来的产物、不记指纹，下次再核
            c.emit("message", f"【黄】{g} 没核成要不要按新版更新程序，先保留原来的：{str(e)[:200]}")
    if updated:
        c.emit("message", f"已更新 {len(updated)} 款游戏的程序（资源不用重推）")
    if missing:   # 不悄悄跳过：说清哪几款这次没补上、怎么补
        names = {x["id"].upper(): x.get("name") or x["id"] for x in c.catalog()["games"]}
        c.emit("message", "【黄】这几款这次没补上 S 级优化（找不到游戏原件，也没有 Mac 版可借）："
               + "、".join(names.get(g.upper(), g) for g in missing) + "。插上存原件的盘（或在游戏库里重新添加原件）后再更新一次就会补上；这次照常装，游戏照常能玩")
    return updated


def refresh_mac(c, gid, runtime):
    """起局前：这款的 Mac 运行版本按本引擎改写器核一遍（运行版本自带 exefs/，不用回原件）；记号记在运行版本的 manifest.json（rewriterId）。
    换了的文件同步改清单里的大小与摘要（起局前按清单核文件）。核不了不挡起局 → True = 换了改写产物"""
    import json
    from core import atomic, read
    runtime = Path(runtime)
    manifest = read(runtime / "manifest.json", {})
    if not isinstance(manifest.get("files"), dict) or not (runtime / "exefs/main").is_file():
        return False
    try:
        rid = rewriter_id(c)
        bid = (runtime / "exefs/main").read_bytes()[0x40:0x48].hex().upper()
        key = None if sgrade_off(c, gid) else sgrade_key(c, gid, rid, bid)
        if manifest.get("rewriterId") == rid and (key is None or manifest.get("sgradeKey") == key):
            return False
        game = next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), None)
        names = None
        with tempfile.TemporaryDirectory(dir=c.private) as tmp:
            if key is not None and game is not None:   # S 级优化补到老游戏（见文件头）：全部模块与补丁表换进运行版本
                c.emit("message", "正在按当前补丁库给这款补上 S 级优化（只改程序，资源不动）")
                out, hit, tables = sgrade_rewrite(c, game, runtime, runtime / "exefs", "apple", Path(tmp))
                apply_outputs(out, runtime, hit)
                names = put_tables(runtime, tables)
            else:
                out = Path(tmp)
                hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, runtime, runtime / "exefs", "apple"), runtime / "exefs", out, runtime / "widen_sites.tsv")
                if hit:
                    c.emit("message", "正在按新版更新这款游戏的程序（资源不动）")
                apply_outputs(out, runtime, hit)
        files = dict(manifest["files"])
        if names is not None:   # 补丁表：清单里先去掉旧的，再记这次出的
            for k in [k for k in files if k in SGRADE_TABLES or k.startswith("cheat-src.")]:
                files.pop(k)
            for n in names:
                files[n] = [(runtime / n).stat().st_size, ""]
        for m in hit:
            for ext in OUTPUTS:
                name, p = f"{m}.{ext}", runtime / f"{m}.{ext}"
                if p.is_file():
                    files[name] = [p.stat().st_size, ""]   # 同 build.snapshot：只记大小（v0.2.3 起校验只核大小）
                else:
                    files.pop(name, None)
        atomic(runtime / "manifest.json", dict(manifest, files=files, rewriterId=rid, **({"sgradeKey": key} if names is not None else {})))
        return bool(hit) or names is not None
    except (Failure, OSError, subprocess.SubprocessError, ValueError) as e:
        c.emit("message", f"【黄】没核成要不要按新版更新这款的程序，先用原来的：{str(e)[:200]}")
        return False
