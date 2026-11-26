# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（维护者 11-11：改写器修了，受影响的款不重出资源包，只换改写产物，随「更新 iPhone 上的 S2Arm」组进新壳）。

为什么不靠缓存键：改写阶段的键含改写器源码指纹（pack/stage_rewrite.sh），改写器一改所有款的键都变；也不能比产物（游戏库里早些时候出的款，
产物本来就跟今天的改写器对不上，比出差别不等于受这次修复影响）。判据由改写器自己报：统计行里 x18_spdyn 或 pacga > 0 的模块，产物会因这次修复而变
（开发丙 11-11 实测：九款金样全 0、产物逐字节同旧；路易吉洋馆 3 两个版本各 38）。

做法（每款）：
  1. 这款记下的改写器指纹（game.json ios.rewriterId）= 本引擎的 → 跳过（改写器没变，平时更新手机不多花时间）
  2. 取原始 exefs：共用解包目录还有效就用它，否则用读取器 --exefs-only 从原件只解 exefs（几秒）；原件不在（外接盘没插）→ 这次跳过、下次再核
  3. 对 main / sdk / subsdk0–9 跑改写器，输入与出包时相同：这款 kit 里的 widen_sites.tsv、fps.tsv，同一份随包代码补丁，S2A_TARGET / 自旋闸同出包
     （11-11 核过：旧改写器按这组输入重跑，产物与完整出包逐字节相同）
  4. 任一模块 x18_spdyn / pacga > 0 → 这款受影响：该模块的改写产物（<模块>.patched.bin / .fixups.tsv / .gates.tsv / .sites.tsv / .gaps.tsv / .widen.tsv / .code_patch.tsv）
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
import struct
import subprocess
import tempfile
from pathlib import Path

import layout
from core import Failure

MODULE = re.compile(r"(main|sdk|subsdk[0-9])")
SGRADE_TABLES = ("cpatch.tsv", "cpatch_rows.tsv", "cpatch_excluded.tsv")   # 随包表（runtime/src/cpatch.c 读 cpatch.tsv）+ 改写用的补丁行表：一起换，kit 里的配方才与产物一致（按配方现建 kit 要用它，11-16）；另有 cheat-src.*（金手指原文随包）
OUTPUTS = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv", "code_patch.tsv")
# 受这次（或往后）改写器修复影响的必改点类别：x18_spdyn（11-11 栈指针动态改写修复）、pacga（11-17 确定性指针认证：较新 Switch 2 SDK
#   切纤程把 pacga 校验值存进内存，宿主密钥每进程不同，即时快照换进程恢复后校验不过；改写器把它换成固定密钥实现）
AFFECTED = re.compile(r"'(?:x18_spdyn|pacga)':\s*(\d+)")
# 分配器初始化闸（11-20，改写器 sdk_sainit，宿主 svc_mem.c s2a_sainit_gate）：sdk 里 StandardAllocator 初始化入口挂门，窗口放不下
#   开局大区时宿主把预留压小。几乎每款 sdk 都有这几个导出，但只有出包静态认出开局大区的款（addr_need.tsv「别名区GB」> 0）用得上：
#   只有这些款算受影响、换 sdk 产物，并按同一套识别重出地址表（多一行「大区来源」，宿主据此不弹「地址不够」页）；其余款不换
SAINIT = re.compile(r"'sdk_sainit':\s*(\d+)")


def static_big(root):
    """这款的地址表认出开局大区（别名区GB > 0；负值 = 上限不定，也算）"""
    try:
        for line in (Path(root) / "addr_need.tsv").read_text(encoding="utf-8").splitlines():
            if line.startswith("别名区GB\t"):   # 非玩家句（地址表的键名）
                return int(line.split("\t", 1)[1]) != 0
    except (OSError, ValueError):
        pass
    return False


def addr_table(c, root, exefs):
    """按本引擎的识别（tools/addr_need.py collect）重出这款的地址表：身份取旧表的程序号 / 构建号，代码取原 main。
    与旧表相同或取不到 → None"""
    import importlib.util
    old = (Path(root) / "addr_need.tsv").read_text(encoding="utf-8")
    ident = dict(l.split("\t", 1) for l in old.splitlines() if l.count("\t") == 1)
    if not {"程序号", "构建号"} <= ident.keys() or not (Path(exefs) / "main").is_file():   # 非玩家句（地址表的键名）
        return None
    spec = importlib.util.spec_from_file_location("addr_need", Path(c.engine) / "tools/addr_need.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    try:
        new = mod.collect(ident["程序号"], ident["构建号"], main=Path(exefs) / "main")   # 非玩家句（地址表的键名）
    except (ValueError, IndexError, OSError, struct.error) as e:   # 读不了原 main：旧表照用（宿主照旧弹「地址不够」页，闸门照样压）
        c.emit("message", f"地址表没重出（{str(e)[:120]}），沿用旧表")  # 非玩家句
        return None
    return new if new != old else None


def write_table(path, text):
    """整份换（先写同目录临时文件再改名）；换行一律 \n，同出包（tools/addr_need.py 写法）"""
    from core import replace_retrying
    tmp = Path(path).with_name(Path(path).name + ".partial")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    try:
        replace_retrying(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def rewriter_id(c):
    """本引擎改写器的身份：编译输入的内容指纹（同 stage_rewrite.sh 的 KR 口径，pack/rewriter.py source）"""
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "source"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode or not r.stdout.strip():
        raise Failure("取不到改写器指纹：" + (r.stderr.strip()[-200:] or "无输出"))  # 非玩家句
    return hashlib.sha256(r.stdout.encode()).hexdigest()[:16]


def rewriter_bin(c):
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "c-path"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    path = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if r.returncode or not Path(path).is_file():
        raise Failure("找不到改写器：" + (r.stderr.strip()[-200:] or "无输出"))  # 非玩家句
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
    formats = {p.get("format") for p in packages if p.get("type") in ("base", "update")}
    # 新两条路上原件读不了 / 程序号不符 / ZBIC 解不开会抛 ValueError、RuntimeError、struct.error：统一成 Failure，
    #   调用方（check_and_update 外层只接 Failure / OSError / SubprocessError）按这一款「没补上」记，不让整轮升级作业崩掉
    try:
        if formats and formats <= {"nup"}:
            return _original_nup_exefs(c, game, packages, work)
        if formats and formats <= {"dump", "extract", "loose"}:
            return _original_tree_exefs(c, game, packages, work)
    except (ValueError, RuntimeError, KeyError, IndexError, struct.error) as e:
        raise Failure(str(e)) from e
    if any(p.get("format") for p in packages if p.get("format") not in (None, "nsp", "xci", "nsz", "xcz")):
        return None
    paths = [source_path(c, p) for p in packages if p["type"] in ("base", "update")]
    if not paths or not all(Path(p).is_file() for p in paths):
        return None
    import toolchain
    out = work / "x"
    c.run(
        [
            toolchain.reader(c),
            c.keys,
            out,
            "--exefs-only",
            "--title-id=" + game["id"],
            *map(str, paths),
        ],
        work / "exefs.log",
        c.env(),
    )
    if not (out / "exefs/main").is_file():
        return None
    return sgrade.save_program(c, game["id"], out / "exefs") or out / "exefs"   # 从原件解出来的存一份，下次不用回原件


def _nxu(c):
    """ZBIC 压缩的 NSO 要 nx_unpack --nso-normalize 解（Switch 2 款常见）：出包时 build.py 经 S2A_NX_UNPACK 给 ns2_dump，S 级升级这条路同样显式给，
    不靠进程环境（作业进程里没有这个变量，原先 ZBIC 主程序一律「没成」）。取不到读取器 = None，normalize_exefs 照旧报缺"""
    try:
        from build import reader_program
        p = reader_program(c)
        return str(p) if Path(p).is_file() else None
    except Exception:   # 取读取器是顺手：取不到（没准备引擎 / 假上下文）= None，只有真遇到 ZBIC 时 normalize_exefs 才报缺，不挡不压缩的款
        return None


def _save_normalized_exefs(c, game, source, work):
    """复制并规范化一个松散 exefs，再按原始程序缓存的原子替换规则保存；不写回 source。"""
    from library import engine_tool
    import sgrade
    dump = engine_tool(c, "ns2_dump")
    Path(work).mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="sgrade-exefs-", dir=work))
    try:
        normalized = scratch / "normalized"
        dump.normalize_exefs(str(source), str(normalized), int(game["id"], 16), nxu=_nxu(c))
        return sgrade.save_program(c, game["id"], normalized)
    finally:
        # save_program 已复制所需模块；保存失败则不留下半成品临时目录。
        shutil.rmtree(scratch, ignore_errors=True)


def _original_tree_exefs(c, game, packages, work):
    """Switch 2 dump 或已解包目录：dump 取最新数字更新（有 main 才用），其余取 exefs/。"""
    from library import source_path
    rows = [p for p in packages if p.get("type") in ("base", "update")]
    if not rows:
        return None
    root = Path(source_path(c, rows[-1]))
    fmt = rows[-1].get("format")
    if fmt == "dump":
        updates = root / "updates"
        versions = sorted((p for p in updates.iterdir() if p.is_dir() and p.name.isdigit()), key=lambda p: int(p.name)) if updates.is_dir() else []
        latest = versions[-1] / "exefs" if versions and (versions[-1] / "exefs" / "main").is_file() else None
        source = latest or root / "base" / "exefs"
    else:
        source = root / "exefs"
    if not (source / "main").is_file() or not (source / "main.npdm").is_file():
        return None
    return _save_normalized_exefs(c, game, source, work)


def _original_nup_exefs(c, game, packages, work):
    """NUP：复用 NUP 扫描与 ns2_dump 的选择规则，只写入本体或所选更新的 exefs 树。"""
    from library import source_path, engine_tool
    import sgrade
    rows = [p for p in packages if p.get("type") in ("base", "update")]
    if not rows:
        return None
    source = source_path(c, rows[-1])
    if not Path(source).is_file():
        return None
    nup = engine_tool(c, "ns2_nup")
    dump = engine_tool(c, "ns2_dump")
    with nup.Nup(str(source)) as container:
        app, base, updates, _ = nup.scan(container)
        if app != int(game["id"], 16):
            raise ValueError(f"NUP 程序号 {app:016X} 与游戏库 {game['id']} 不一致")
        selected_update = next((p for p in rows if p.get("type") == "update"), None)
        chosen = updates.get(int(selected_update["version"])) if selected_update else base
        if chosen is None:
            return None
        if chosen.exefs == nup.NO_DIR or container.child(chosen.exefs, b"main") is None:
            # 与 ns2_dump.convert 一致：更新里没有 main 才回退本体 exefs。
            chosen = base if selected_update else None
        if chosen is None or chosen.exefs == nup.NO_DIR or container.child(chosen.exefs, b"main") is None:
            return None
        Path(work).mkdir(parents=True, exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix="sgrade-nup-", dir=work))
        try:
            extracted = scratch / "exefs"
            stat = [0, 0, 0]
            nup.write_tree(container, chosen.exefs, str(extracted), stat)
            normalized = scratch / "normalized"
            dump.normalize_exefs(str(extracted), str(normalized), app, nxu=_nxu(c))
            return sgrade.save_program(c, game["id"], normalized)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)


def own_table_ok(env):
    """我方帧率表（fps.tsv 的 c 行改指令）只在内部对照口径 S2A_CAPS_OWN=1 打进程序，同 stage_rewrite.sh FT（11-18，#1607）：
    11-13 撤我方 60 帧后运行时只把槽写成关值，c 行却照样改了游戏的限帧代码，60 帧关着也能跑到 60"""
    return env.get("S2A_CAPS_OWN") == "1"


def own_table(p):
    """旧包产物根里带改指令（c 行）的我方帧率表"""
    return p.name == "fps.tsv" and any(l.split("#", 1)[0].split()[:1] == ["c"] for l in p.read_text(encoding="utf-8", errors="replace").splitlines())


def step_table(p):
    """实时步长表：帧率表只有 build / speed 行（至少一行 speed）——不放开帧率、不改指令，只让宿主每次出图把实测帧时写进键页槽，
    缺省口径也随包（同 pack/orch/stages.py step_only_table、pack/stage_rewrite.sh FT）"""
    rows = [l.split("#", 1)[0].split() for l in Path(p).read_text(encoding="utf-8", errors="replace").splitlines()]
    rows = [r for r in rows if r]
    return any(r[0] == "speed" for r in rows) and all(r[0] in ("build", "speed") for r in rows)


def game_tables(c, bid):
    """引擎里这款（主程序构建号 bid）的逐款表 → (游戏缺陷修补表 runtime/fix/<前 16 位>.tsv | None, 实时步长表 runtime/fps/<前 16 位>.tsv | None)。
    修补表交改写器改进程序，步长表随包作 fps.tsv；两者常成对（修补表让游戏读步长表写的槽，#2248），出包时由 pack/stage_rewrite.sh 按同一规则取"""
    name = (bid or "")[:16].lower() + ".tsv"
    if len(name) != 20:
        return None, None
    fix, fps = Path(c.engine) / "runtime/fix" / name, Path(c.engine) / "runtime/fps" / name
    return (fix if fix.is_file() else None), (fps if fps.is_file() and step_table(fps) else None)


def tables_id(c, bid):
    """这款逐款表的内容指纹（记进 iPhone 记录 / Mac 清单的 tablesId）；引擎里这款没有表 = ''。
    改写器指纹（rewriter_id）只看改写器源码、补丁记号只看补丁库，引擎新加 / 改了这款的修补表或步长表，两个记号都不变，「更新这款」原先直接跳过——
    老包拿不到修复，只能重新出包（#2248 一款动作冒险游戏的帧比例修复）。没记过的款按 '' 算：只有引擎里有表的款重做一次，别的款不动"""
    fix, fps = game_tables(c, bid)
    if fix is None and fps is None:
        return ""
    h = hashlib.sha256()
    for tag, p in (("fix", fix), ("fps", fps)):
        h.update(tag.encode() + b"\0" + (p.read_bytes() if p else b"-") + b"\0")
    return h.hexdigest()[:12]


def game_bid(c, gid):
    """这款实际运行的主程序构建号（pack/jobs/cheats.py main_build：解包目录 → Mac 运行版本 → 存下的原始程序 → iPhone 记录）；取不到 = ''"""
    import cheats
    try:
        return cheats.main_build(c, {"id": gid})
    except (OSError, Failure):
        return ""


def step_changes(c, base, bid):
    """随包步长表跟引擎走：引擎有这款的步长表 → 换成它；没有而 base 里留着旧的步长表 → 删。带 c 行等别的帧率表不碰（own_table 那条规矩管）"""
    _, fps = game_tables(c, bid)
    old = Path(base) / "fps.tsv"
    if fps is not None:
        return {} if old.is_file() and old.read_bytes() == fps.read_bytes() else {"fps.tsv": fps}
    return {"fps.tsv": None} if old.is_file() and step_table(old) else {}


def rewrite_env(c, kit, exefs, target):   # exefs None：不带随包代码补丁（补丁按主程序构建号认，只改 exefs 模块）
    env = dict(c.env(), S2A_TARGET=target, S2A_REWRITE_SPIN=os.environ.get("S2A_REWRITE_SPIN", "1"))
    for k in ("S2A_FPS_TSV", "S2A_CPATCH_TSV", "S2A_CODE_PATCH", "S2A_CODE_BUILD", "S2A_FIX_TSV"):
        env.pop(k, None)
    if (kit / "fps.tsv").is_file() and own_table_ok(env):
        env["S2A_FPS_TSV"] = str(kit / "fps.tsv")
    # 游戏缺陷修补表：同 stage_rewrite.sh（引擎里的 runtime/fix/<main 构建号前 16 位>.tsv）
    if exefs is not None and (exefs / "main").is_file():
        fix = Path(c.engine) / "runtime/fix" / ((exefs / "main").read_bytes()[0x40:0x48].hex() + ".tsv")
        if fix.is_file():
            env["S2A_FIX_TSV"] = str(fix)
    # 随包代码补丁：同 stage_rewrite.sh（S2A_PATCH_DIR/<程序号>/patch.tsv，构建号 = main 头 0x40 起 16 字节）
    pdir = env.get("S2A_PATCH_DIR")
    if pdir and exefs is not None:
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


def rewrite_modules(binary, env, exefs, out, widen, sainit=False):
    """exefs 里宿主会装载的模块（同 stage_rewrite.sh 的名单）逐个改写到 out → 这次修复会改到的模块（统计行 x18_spdyn > 0）。
    退出码 3 = 有缺口、产物照出（同 stage_rewrite.sh rw_all：社区补丁轮的缺口由 cpatch.py prune 认领），不算失败"""
    hit = []
    for m in modules_of(exefs):
        args = [binary, str(Path(exefs) / m), str(out), m] + ([str(widen)] if Path(widen).is_file() else [])
        r = subprocess.run(args, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        if r.returncode and not (r.returncode == 3 and (Path(out) / f"{m}.patched.bin").is_file()):
            raise Failure(f"重跑改写 {m} 失败（退出码 {r.returncode}）：" + ((r.stderr.strip().splitlines() or [""])[-1])[:200])  # 非玩家句
        if max((int(x) for x in AFFECTED.findall(r.stdout) + (SAINIT.findall(r.stdout) if sainit else [])), default=0) > 0:
            hit.append(m)
    return hit


def plan_code_id(c):
    """出表代码的指纹（pack/cpatch.py 改了 = 合成规则变了，老游戏要按新规则重出表）"""
    return hashlib.sha256((Path(c.engine) / "pack/cpatch.py").read_bytes()).hexdigest()[:12]


def sgrade_key(c, gid, rid, main_bid):
    """补丁记号：改写器指纹 + 出表代码指纹 + 这款在补丁库里的包版本（pack/jobs/patches.py version_key）+ 这款金手指文件夹的内容
    （11-14：玩家在电脑上导入 / 删了金手指，下次升级要重编——要改游戏代码的条目只能编进程序，记号不变就会被当成「不用补」跳过）"""
    import patches
    import mods   # 玩家导入的 mod 代码补丁（11-15）：导入 / 删了要重编；只开关不算（运行时开关）。没有 mod 代码补丁时记号与原来一字不差（不让所有老游戏白白重补）
    md = mods.code_digest(c, gid)
    fp = fpsl_code_id(c) if _has_fpsl(c, gid, main_bid) else ""   # 带 FPSLocker 配置的款：转换代码变了也要重出表（没带的款记号一字不变，不白白重补）
    return (f"{rid}:{plan_code_id(c)}:{patches.version_key(c, gid, main_bid)}:{cheats_digest(c, gid)}" + (f":{md}" if md != "-" else "")
            + (f":fpsl{fp}" if fp else ""))


def fpsl_code_id(c):
    """FPSLocker 配置转换代码的指纹（pack/fpslocker.py + pack/miniyaml.py）：改了 = 同一份配置会转出不同的补丁行
    （11-17 D-7AQ2：「+160」原先读成绝对偏移，修了以后已出过包的款要按新转换重出表，走 S 级补进同一条路，玩家不用手动重出）"""
    h = hashlib.sha256()
    for f in ("pack/fpslocker.py", "pack/miniyaml.py"):
        h.update((Path(c.engine) / f).read_bytes())
    return h.hexdigest()[:12]


def _has_fpsl(c, gid, main_bid):
    """这款在补丁库里有没有 FPSLocker 配置（kind fpsl / .yaml）；取不到补丁库 → False（记号照旧）"""
    import patches
    try:
        # items_for 返回 [(条目字典, 内容字节)]（patches.py）：11-17 原先按字典直接 .get，元组上 AttributeError、补丁库里有条目的款 sgrade_key 都抛
        return any(it.get("kind") == "fpsl" or str(it.get("name", "")).lower().endswith(".yaml") for it, _ in patches.items_for(c, gid, main_bid))
    except (OSError, ValueError, Failure):
        return False


def cheats_digest(c, gid):
    """这款金手指文件夹里各 txt 的名字与内容摘要（开关状态 enabled.txt / status.txt 不算：开关不改要编进程序的东西）；没有 = '-'"""
    import cheats
    d = cheats.cheats_dir(c, gid.upper(), create=False)
    files = sorted(p for p in d.glob("*.txt") if p.is_file() and p.name not in cheats.SKIP and not layout.os_junk(p.name)) if d.is_dir() else []
    if not files:
        return "-"
    h = hashlib.sha256()
    for p in files:
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()[:12]


def _current(stored_rid, stored_key, rid, key, ignore_rewriter=False):
    """这款记下的改写器指纹 / 补丁记号是否已对上本引擎。ignore_rewriter（11-17 维护者定：后台不再因为改写器变了重改写全部游戏）：
    只看补丁记号里改写器指纹之后的部分（补丁库版本、出表代码、金手指、mod 代码补丁）——改写器指纹单独变了不算要重做；
    改写器的新产物留到玩家对这一款出包 / 推送 / 装机 / 起局时在前台做（那些路不带 ignore_rewriter）"""
    if not ignore_rewriter:
        return stored_rid == rid and (key is None or stored_key == key)
    if key is None:
        return True
    return isinstance(stored_key, str) and stored_key.split(":", 1)[-1] == key.split(":", 1)[-1]


def pending_ios(c, games, rid, ignore_rewriter=False):
    """这几款里 iPhone 件要按新版改写器 / 新补丁记号重做的（refresh_ios 与「更新 iPhone」判要不要真更新共用一个判据）"""
    out = []
    for g in games:
        side = layout.game_info(c, g).get("ios") or {}
        key = ios_key(c, g, rid)   # 补丁库随启动器内置（pack/jobs/patches.py version_key 读本地快照），不会取不到（11-14 维护者：不设这种兜底）
        if not _current(side.get("rewriterId"), side.get("sgradeKey"), rid, key, ignore_rewriter) \
                or side.get("tablesId", "") != tables_id(c, game_bid(c, g)):   # 逐款表变了不算「改写器单独变了」：后台照样补
            out.append(g)
    return out


def sgrade_off(c, gid):
    """出包页取消过「S 级优化（Beta）· 出包时打入」的款（pack/jobs/patches.py prepare 记 game.json sgradeOff）"""
    return layout.game_info(c, gid).get("sgradeOff") is True


def sgrade_rewrite(c, game, base, exefs, target, work):
    """按出包同一套带社区补丁改写（见文件头）→ (产物目录, 全部模块, 随包表文件列表)。base = kit / Mac 运行版本（取 fps.tsv、widen_sites.tsv 等逐款表）"""
    import cheats
    import patches
    gid = game["id"].upper()
    root = Path(work) / "root"; root.mkdir()
    # 拷不链（#1153）：Windows 建目录软链要开发者模式 / 管理员（WinError 1314，玩家每款都「补丁打入失败」）；exefs 只是几个程序模块，拷一份不费事，网络盘也行
    shutil.copytree(Path(exefs).resolve(), root / "exefs")
    skip = tuple("." + e for e in OUTPUTS)
    for p in Path(base).iterdir():   # 逐款表照拷（出表读 fps.tsv 判「本款已有我方帧率表」、改写读 widen_sites.tsv）；改写产物与旧补丁表不拷
        if p.is_file() and not p.name.endswith(skip) and not p.name.startswith(("cpatch", "cheat-src.")) and p.suffix != ".log" \
                and not (own_table(p) and not own_table_ok(c.env())):   # 旧包带的我方帧率表不再照拷：不打改指令，出表也不因它拒社区帧率补丁
            shutil.copyfile(p, root / p.name)
    for name, src in step_changes(c, root, (Path(exefs) / "main").read_bytes()[0x40:0x48].hex()).items():   # 随包步长表跟引擎走（见 step_changes）
        if src:
            shutil.copyfile(src, root / name)
        else:
            (root / name).unlink()
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
        r = subprocess.run(py + ["plan", str(root), ""] + [str(d) for d in dirs], cwd=c.engine, env=env, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=600)
        if r.returncode:
            raise Failure("社区补丁出表出错：" + ((r.stderr.strip().splitlines() or [""])[-1])[:200])  # 非玩家句
        rows = root / "cpatch_rows.tsv"
        if not rows.is_file() or not rows.stat().st_size:
            break
        rewrite_modules(binary, dict(env, S2A_CPATCH_TSV=str(rows)), exefs, root, widen)
        p = subprocess.run(py + ["prune", str(root)], cwd=c.engine, env=env, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=600)
        if p.returncode == 10:
            continue
        if p.returncode:
            raise Failure("社区补丁认领缺口出错：" + ((p.stderr.strip().splitlines() or [""])[-1])[:200])  # 非玩家句
        break
    tables = [root / t for t in SGRADE_TABLES if (root / t).is_file()] + sorted(root.glob("cheat-src.*")) \
        + ([root / "fps.tsv"] if (root / "fps.tsv").is_file() and step_table(root / "fps.tsv") else [])
    return root, modules_of(exefs), tables


def swap(base, changes):
    """把一组文件换进 base（kit / Mac 运行版本），要么全换上、要么一个都不动（审计 P1-186：原先先删旧表、逐个换模块，中途失败已经能玩的那款程序与表
    不再是同一次，失败句却说「先用原来的」）。changes：{文件名: 新内容路径 | None（删掉）}。
    ① 新内容全部先写临时名 <名>.rw（写不成就清掉临时名、旧的一个字节不动）；② 逐个把旧的挪成 <名>.rwold、临时名改成正名
    （中途失败按相反顺序还原，旧的回到原位）；③ 全部换上后才删 .rwold。失败照原样抛，调用方的「先用原来的程序」此时为真"""
    base = Path(base)
    staged = []
    try:
        for name, src in changes.items():
            if src is not None:
                shutil.copyfile(src, base / (name + ".rw")); staged.append(name)
    except BaseException:
        for name in staged:
            (base / (name + ".rw")).unlink(missing_ok=True)
        raise
    done = []
    try:
        for name, src in changes.items():
            dst, old = base / name, base / (name + ".rwold")
            had = dst.exists()
            if had:
                os.replace(dst, old)
            done.append((name, had))
            if src is not None:
                os.replace(base / (name + ".rw"), dst)
    except BaseException:
        for name, had in reversed(done):
            dst, old = base / name, base / (name + ".rwold")
            if changes[name] is not None and not (base / (name + ".rw")).exists():
                dst.unlink(missing_ok=True)   # 新的已换上：撤掉
            if had:
                os.replace(old, dst)
        for name in staged:
            (base / (name + ".rw")).unlink(missing_ok=True)
        raise
    for name, had in done:
        if had:
            (base / (name + ".rwold")).unlink(missing_ok=True)


def table_changes(base, tables):
    """随包表：旧的补丁表与金手指原文这次没出的删掉，出了的换新"""
    base = Path(base)
    ch = {old.name: None for old in list(base.glob("cheat-src.*")) + [base / t for t in SGRADE_TABLES] if old.is_file() and not old.name.endswith((".rw", ".rwold"))}
    if (base / "fps.tsv").is_file() and step_table(base / "fps.tsv"):   # 旧的随包步长表：这次没出（引擎里撤了）就删
        ch["fps.tsv"] = None
    ch.update({t.name: t for t in tables})
    return ch


def output_changes(out, kit, modules):
    """命中模块的改写产物换新；新改写器不再出的那份删掉（旧的留着会被装载器当成本次的）。没命中的模块不在表里、一个字节都不动"""
    ch = {}
    for m in modules:
        for ext in OUTPUTS:
            src, dst = Path(out) / f"{m}.{ext}", Path(kit) / f"{m}.{ext}"
            if src.is_file():
                ch[dst.name] = src
            elif dst.is_file():
                ch[dst.name] = None
    return ch


def apply_sgrade(out, base, modules, tables):
    """S 级优化补进：改写产物与随包表一起换（同一次 swap，不会只换上一半）→ 换上的表名"""
    ch = output_changes(out, base, modules)
    ch.update(table_changes(base, tables))
    swap(base, ch)
    return [t.name for t in tables]


def kept_todo(c, gid, base):
    """游戏库 games/<号>/nro_kept/ 里还没进 base（kit / Mac 运行版本）的 nro_modules.tsv 的 NRO → [路径]（#8be819 运行时留下的 NRO）"""
    kept = layout.nro_kept(c, gid)
    if not kept.is_dir():
        return []
    table = Path(base) / "nro_modules.tsv"
    have = {l.split("\t")[1] for l in (table.read_text().splitlines() if table.is_file() else []) if l and not l.startswith("#") and l.count("\t") >= 4}
    return [p for p in sorted(kept.glob("*.nro")) if re.fullmatch(r"[0-9a-f]{64}\.nro", p.name) and p.name[:64] not in have]


def add_kept_nros(c, gid, base, target):
    """运行时留下、还没进包的 NRO 补进 base（#8be819：游戏把 NRO 藏在自有加密归档里，出包认不出；宿主 LoadNro 缺表时存下游戏解开的那份）：
    同出包（pack/stage_rewrite.sh）：runtime/rewriter/nro_to_nso.py 转 NSO（第三来源）→ 改写器逐个改写（同 widen_sites.tsv / fps.tsv）→ 产物换进 base、
    nro_modules.tsv 接着原有编号追加行。资源包、直连库、已有模块一个字节不动。社区补丁不进这几支（补丁按主程序构建号认）。→ 新加的模块名"""
    todo = kept_todo(c, gid, base)
    if not todo:
        return []
    base = Path(base); table = base / "nro_modules.tsv"
    rows = [l for l in (table.read_text().splitlines() if table.is_file() else []) if l and not l.startswith("#")]
    nxt = max((int(l.split("\t")[0][3:]) for l in rows if re.match(r"nro\d+\t", l)), default=-1) + 1
    with tempfile.TemporaryDirectory(dir=c.private) as tmp:
        t = Path(tmp); (t / "romfs").mkdir(); (t / "k").mkdir(); out = t / "out"; out.mkdir()
        for p in todo:
            shutil.copyfile(p, t / "k" / p.name)
        r = subprocess.run([os.sys.executable, "-X", "utf8", str(c.engine / "runtime/rewriter/nro_to_nso.py"), str(t / "romfs"), str(t / "nso"), str(t / "k")],
                           env=c.env(), capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        made = [l.split("\t") for l in ((t / "nso/nro_modules.tsv").read_text().splitlines() if (t / "nso/nro_modules.tsv").is_file() else []) if l and not l.startswith("#")]
        if r.returncode or not made:
            raise Failure("运行时留下的模块转不出来：" + ((r.stderr.strip() or r.stdout.strip()).splitlines() or ["无输出"])[-1][:200])
        binary, env, widen = rewriter_bin(c), rewrite_env(c, base, None, target), base / "widen_sites.tsv"
        names, add = [], []
        for name0, sha, size, bss, src in made:
            name = f"nro{nxt}"; nxt += 1
            shutil.copyfile(t / "nso" / name0, t / name)
            args = [binary, str(t / name), str(out), name] + ([str(widen)] if widen.is_file() else [])
            rr = subprocess.run(args, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
            if rr.returncode and not (rr.returncode == 3 and (out / f"{name}.patched.bin").is_file()):
                raise Failure(f"改写运行时留下的模块 {name} 失败（退出码 {rr.returncode}）：" + ((rr.stderr.strip().splitlines() or [""])[-1])[:200])
            names.append(name); add.append("\t".join((name, sha, size, bss, src)))
        newtab = t / "nro_modules.tsv"
        newtab.write_text("# 模块名\tSHA-256\tNRO 大小\tbss 大小\tromfs 相对路径\n" + "".join(l + "\n" for l in rows + add))  # 非玩家句
        ch = output_changes(out, base, names); ch[table.name] = newtab   # 模块与表同一次换（中途失败两样都留旧的）
        swap(base, ch)
    return names


def kept_nros_mac(c, gid, runtime):
    """Mac 运行版本补上运行时留下的 NRO（起局前、收局时各核一次）：换进运行版本，清单记大小（同 refresh_mac）。补不上不挡起局 → 新加的模块名"""
    import json
    from core import atomic, read
    runtime = Path(runtime)
    try:
        if not kept_todo(c, gid, runtime):
            return []
        c.emit("message", "正在补上这款游戏运行中才取到的代码模块（只改程序，资源不动）")
        names = add_kept_nros(c, gid, runtime, "apple")
        manifest = read(runtime / "manifest.json", {})
        if isinstance(manifest.get("files"), dict):
            files = dict(manifest["files"])
            for n in ["nro_modules.tsv"] + [f"{m}.{ext}" for m in names for ext in OUTPUTS]:
                if (runtime / n).is_file():
                    files[n] = [(runtime / n).stat().st_size, ""]
            atomic(runtime / "manifest.json", dict(manifest, files=files))
        c.emit("message", f"已补上 {len(names)} 个代码模块，可以继续玩了")
        return names
    except (Failure, OSError, subprocess.SubprocessError, ValueError) as e:
        c.emit("message", f"【红】这款游戏运行中才取到的代码模块没补上：{str(e)[:200]}")
        return []


def ios_key(c, gid, rid):
    """这款 iPhone 件要对上的记号：出包页取消过 S 级优化 = 只看改写器指纹；否则补丁记号（sgrade_key）"""
    info = layout.game_info(c, gid)
    return None if sgrade_off(c, gid) else sgrade_key(c, gid, rid, (info.get("ios") or {}).get("mainBid", ""))


def check_and_update(c, gid, kit, target, rid, ignore_rewriter=False):
    """一款：→ 'skip'（改写器与补丁记号都没变）| 'unavailable'（原件取不到）| 'unaffected' | 'updated'"""
    info = layout.game_info(c, gid)
    side = info.get("ios") or {}
    key = ios_key(c, gid, rid)
    if _current(side.get("rewriterId"), side.get("sgradeKey"), rid, key, ignore_rewriter) and side.get("tablesId", "") == tables_id(c, game_bid(c, gid)):
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
        tid = tables_id(c, bid)
        if key is not None:   # S 级优化补到老游戏：按出包同一套带社区补丁改写，全部模块与补丁表换进 kit
            out, mods, tables = sgrade_rewrite(c, game, kit, exefs, target, work)
            names = apply_sgrade(out, kit, mods, tables)
            import patches
            patches.remember(c, gid.upper(), patches.record(c, gid, "ios", out))   # 哪些打上 / 没打上（结果页列，11-14）
            c.emit("message", f"{gid}：S 级优化已按当前补丁库补进程序（{', '.join(names) or '这款没有匹配的社区补丁'}；资源不用重推）")  # 非玩家句
            layout.update_info(c, gid, ios={**{k: v for k, v in side.items() if k != "sgradeMissing"}, "rewriterId": rid, "sgradeKey": sgrade_key(c, gid, rid, bid), "mainBid": bid, "tablesId": tid})
            return "updated"
        out = work / "out"; out.mkdir()
        big = static_big(kit)
        hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, kit, exefs, target), exefs, out, kit / "widen_sites.tsv", sainit=big)
        steps = {}
        if side.get("tablesId", "") != tid:   # 逐款表变了：修补表可能改任一模块，全部模块换成按本引擎表改写的产物；随包步长表跟着换
            hit, steps = modules_of(exefs), step_changes(c, kit, bid)
        table = addr_table(c, kit, exefs) if big and "sdk" in hit else None
        swap(kit, {**output_changes(out, kit, hit), **steps})   # 程序与随包步长表同一次换（同 apply_sgrade）
        if table is not None:
            write_table(kit / "addr_need.tsv", table)
    layout.update_info(c, gid, ios=dict(side, rewriterId=rid, mainBid=bid, tablesId=tid))
    return "updated" if hit or steps else "unaffected"


def refresh_ios(c, games, ignore_rewriter=False):
    """组容器前：这几款的 iPhone 容器件按本引擎改写器核一遍（见文件头），再补缺的可读瓦片版着色器（pack/jobs/sgrade_bf.py）。→ 换了改写产物 / 资源包的款"""
    if not games:
        return []
    changed = sorted(set(_refresh_code_ios(c, games, ignore_rewriter)) | set(_refresh_bf_ios(c, games)))
    import programs
    for g in changed:   # kit 改过（补进的表、运行时收回的模块）：常驻配方跟着重存（pack/jobs/programs.py），之后按配方现建的 kit 与这份一致
        programs.save_recipe(c, g)
    return changed


def _refresh_bf_ios(c, games):
    """老包直连库缺 _bf 的款：整份重出、覆盖层进资源包（put_game 随后按资源包号只推新增的文件）。取不到原料的点名、记 bfMissing（「更新 iPhone」不再因它重组容器，升级页照样再试）"""
    import sgrade_bf
    todo = [g for g in games if sgrade_bf.stale((layout.game_info(c, g).get("ios") or {}).get("bfGen"))]
    done, missing = [], []
    names = {x["id"].upper(): x.get("name") or x["id"] for x in c.catalog()["games"]} if todo else {}
    for i, g in enumerate(todo, 1):
        c.emit("message", f"补片上读取着色器 {i}/{len(todo)}：{names.get(g.upper(), g)}")
        try:
            r = sgrade_bf.upgrade_ios(c, g)
        except (Failure, OSError, subprocess.SubprocessError) as e:   # 一款出错不挡这次装机：这款保留原来的着色器库、不记代数（下次再试）
            c.emit("message", f"【红】{names.get(g.upper(), g)}：片上读取着色器没补上，先用原来的着色器库：{str(e)[:200]}")
            continue
        if r == "updated":
            done.append(g)
        elif r == "unavailable":
            missing.append(g)
            layout.update_info(c, g, ios=dict(layout.game_info(c, g).get("ios") or {}, bfMissing=sgrade_bf.BF_GEN))
    if missing:   # 不悄悄跳过（同 _refresh_code_ios）
        c.emit("message", "【黄】这几款这次没补上片上读取着色器（游戏库里没有它的资源文件 game.img 与原始程序，也没有 Mac 版可借）："  # 非玩家句
               + "、".join(names.get(g.upper(), g) for g in missing) + "。需要原件：重新添加原件后再升级一次就会补上；这次照常装，游戏照常能玩")  # 非玩家句
    return done


def _refresh_code_ios(c, games, ignore_rewriter=False):
    try:
        rid = rewriter_id(c)
    except (Failure, OSError, subprocess.SubprocessError) as e:
        # 同 refresh_mac：取不到改写器指纹就整轮不核，不挡这次装机；各款保留原来的产物、不记指纹，下次再核
        c.emit("message", f"【黄】没取到改写器指纹，这次先不核要不要按新版更新程序：{str(e)[:200]}")
        return []
    nro = []   # 运行时留下、还没进 iPhone 件的 NRO（#8be819）：不论改写器变没变都补
    for g in [g for g in games if kept_todo(c, g, layout.ios_kit(c, g))]:
        try:
            names = add_kept_nros(c, g, layout.ios_kit(c, g), "ios"); nro.append(g)
            c.emit("message", f"{g}：已补上 {len(names)} 个运行中才取到的代码模块（只更新程序，资源不用重推）")
        except (Failure, OSError, subprocess.SubprocessError) as e:
            c.emit("message", f"【红】{g}：运行中才取到的代码模块没补上，这款先保留原来的程序：{str(e)[:200]}")
    todo = pending_ios(c, games, rid, ignore_rewriter)
    if not todo:
        return nro
    c.emit("message", f"正在核对 {len(todo)} 款游戏的程序是否要按新版更新（含 S 级优化补丁）")
    updated, missing = [], []
    names = {x["id"].upper(): x.get("name") or x["id"] for x in c.catalog()["games"]}
    for i, g in enumerate(todo, 1):
        # 逐款一行（#1132：升级后第一次导出，库里每款都在这一步重核，整体进度停在 0%，玩家看着像卡死）
        c.emit("message", f"核对程序 {i}/{len(todo)}：{names.get(g.upper(), g)}")
        from core import trace
        trace(c, f"改写核对开始 {g}（{i}/{len(todo)}）")
        try:
            r = check_and_update(c, g, layout.ios_kit(c, g), "ios", rid, ignore_rewriter)
            trace(c, f"改写核对结束 {g}：{r}")
            if r == "updated":
                updated.append(g)
            elif r == "unavailable":
                missing.append(g)
                # 缺原件、这一版记号下补不上：记下来，「更新 iPhone」不再因为它重组容器（install.sgrade_pending）；升级页显式升级照样再试
                side = layout.game_info(c, g).get("ios") or {}
                layout.update_info(c, g, ios=dict(side, sgradeMissing=ios_key(c, g, rid) or ""))
        except (Failure, OSError, subprocess.SubprocessError) as e:
            # 改写器在这款上出错：不挡这次装机，这款保留原来的程序、不记指纹（下次再核）；结果页点名「不匹配，补丁打入失败」（11-14 维护者）
            if sgrade_off(c, g):   # 出包时取消过 S 级优化：这里只是按新版改写器更新程序，不涉及补丁
                c.emit("message", f"【黄】{g} 没核成要不要按新版更新程序，先保留原来的：{str(e)[:200]}")
            else:
                import patches
                patches.remember(c, g.upper(), patches.record(c, g, "ios", None, error=str(e)))
                c.emit("message", f"【红】{g}：S 级优化补丁打入失败（不匹配），这款先保留原来的程序：{str(e)[:200]}")
    updated = sorted(set(updated) | set(nro))
    if updated:
        c.emit("message", f"已更新 {len(updated)} 款游戏的程序（资源不用重推）")
    if missing:   # 不悄悄跳过：说清哪几款这次没补上、怎么补
        c.emit("message", "【黄】这几款这次没补上 S 级优化（找不到游戏原件，也没有 Mac 版可借）："  # 非玩家句
               + "、".join(names.get(g.upper(), g) for g in missing) + "。插上存原件的盘（或在游戏库里重新添加原件）后再更新一次就会补上；这次照常装，游戏照常能玩")  # 非玩家句
    return updated


def refresh_mac(c, gid, runtime, hold=None, ignore_rewriter=False):
    """起局前：这款的 Mac 运行版本按本引擎改写器核一遍（运行版本自带 exefs/，不用回原件）；记号记在运行版本的 manifest.json（rewriterId）。
    换了的文件同步改清单里的大小与摘要（起局前按清单核文件）。核不了不挡起局 → True = 换了改写产物
    hold（后台补 S 级用，诊断 D-R8NG）：改写只往临时目录写、不碰运行版本，放在锁外做；换进运行版本前才进 hold()，
      它 yield False（库里有任务在用：玩家点了开始游戏）就整款放弃——开始游戏起局前自己会补这一款。不给 hold = 调用方已持锁（起局）"""
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
        tid = tables_id(c, bid)   # 逐款表（见 tables_id）：变了也要重做，不受 ignore_rewriter 管
        if _current(manifest.get("rewriterId"), manifest.get("sgradeKey"), rid, key, ignore_rewriter) and manifest.get("tablesId", "") == tid:
            return False
        steps = {}
        game = next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), None)
        names = None
        import contextlib
        with tempfile.TemporaryDirectory(dir=c.private) as tmp, contextlib.ExitStack() as held:
            sg = key is not None and game is not None
            if sg:   # S 级优化补到老游戏（见文件头）：全部模块与补丁表换进运行版本
                c.emit("message", "正在按当前补丁库给这款补上 S 级优化（只改程序，资源不动）")
                out, hit, tables = sgrade_rewrite(c, game, runtime, runtime / "exefs", "apple", Path(tmp))
            else:
                out = Path(tmp)
                big = static_big(runtime)
                hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, runtime, runtime / "exefs", "apple"), runtime / "exefs", out, runtime / "widen_sites.tsv", sainit=big)
                if manifest.get("tablesId", "") != tid:   # 逐款表变了：全部模块换新、随包步长表跟着换（同 check_and_update）
                    hit, steps = modules_of(runtime / "exefs"), step_changes(c, runtime, bid)
                table = addr_table(c, runtime, runtime / "exefs") if big and "sdk" in hit else None
            if hold is not None:
                if not held.enter_context(hold()):
                    return False
                manifest = read(runtime / "manifest.json", {})   # 锁外算的这段时间里别的任务（起局）可能已经换过：按换进时的清单记，记号已对上就不再换
                if not isinstance(manifest.get("files"), dict) or (_current(manifest.get("rewriterId"), manifest.get("sgradeKey"), rid, key, ignore_rewriter)
                                                                   and manifest.get("tablesId", "") == tid):
                    return False
            if sg:
                names = apply_sgrade(out, runtime, hit, tables)
                import patches
                patches.remember(c, gid.upper(), patches.record(c, gid, "mac", out))
            else:
                if hit:
                    c.emit("message", "正在按新版更新这款游戏的程序（资源不动）")
                swap(runtime, {**output_changes(out, runtime, hit), **steps})   # 程序与随包步长表同一次换
            files = dict(manifest["files"])
            if not sg and table is not None:   # 地址表（随分配器闸一起换，见 SAINIT）：清单同步记大小
                write_table(runtime / "addr_need.tsv", table)
                files["addr_need.tsv"] = [(runtime / "addr_need.tsv").stat().st_size, ""]
            if names is not None:   # 补丁表：清单里先去掉旧的，再记这次出的
                for k in [k for k in files if k in SGRADE_TABLES or k.startswith("cheat-src.")]:
                    files.pop(k)
                for n in names:
                    files[n] = [(runtime / n).stat().st_size, ""]
            if steps or names is not None:   # 随包步长表（apply_sgrade 的表里也可能有它）：清单按换后的实况记
                if (runtime / "fps.tsv").is_file():
                    files["fps.tsv"] = [(runtime / "fps.tsv").stat().st_size, ""]
                else:
                    files.pop("fps.tsv", None)
            for m in hit:
                for ext in OUTPUTS:
                    name, p = f"{m}.{ext}", runtime / f"{m}.{ext}"
                    if p.is_file():
                        files[name] = [p.stat().st_size, ""]   # 同 build.snapshot：只记大小（v0.2.3 起校验只核大小）
                    else:
                        files.pop(name, None)
            atomic(runtime / "manifest.json", dict(manifest, files=files, rewriterId=rid, tablesId=tid, **({"sgradeKey": key} if names is not None else {})))
            return bool(hit) or names is not None or bool(steps)
    except (Failure, OSError, subprocess.SubprocessError, ValueError) as e:
        import patches
        if not sgrade_off(c, gid):
            patches.remember(c, gid.upper(), patches.record(c, gid, "mac", None, error=str(e)))
        c.emit("message", f"【红】这款的 S 级优化补丁打入失败（不匹配），先用原来的程序：{str(e)[:200]}")
        return False
