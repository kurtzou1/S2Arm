"""打 iPhone 包（Mac 前端「打 iPhone 包」，维护者 10-23：测试者不用源码目录和终端）。

调同一套一键出包 pack/oneclick/oneclick.sh（应用内置引擎快照里带着）：把这款游戏在游戏库里的本体 / 更新 / DLC 克隆进一个临时文件夹
（APFS 克隆，不占盘），用玩家导入的密钥和应用自带字体，出到这款文件夹的 build/ios（工作目录），收尾把容器件与资源包放进 image/ios（kit/ + pack/），单款 ipa 不留：装机时现组 S2Arm.ipa（assemble）。
目标设备（GPU 架构 + 系统大版本）见 target.py：只用来提示地址窗口（一包通用）。
iOS 版的 C# 库要现编，需要 .NET 10 SDK（查显式环境、用户目录、PATH 和常见 Mac 安装；没有时环境检查给「一键安装」）。
进度：与 Mac 打包同一套里程碑进度条（milestones.PLANS["ipa_dual"]）：按一键出包打印的 ① / ④ 刷新 / ④ 出包 行切段，
直连库段由 DirectWatcher 看 <输出>/roots 里的直连临时版本；成功后各段实测秒数记进本机历史（下次预计用）。
"""
from __future__ import annotations
import contextlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from core import Failure, contained, display_version, read, release_version
import layout



_SDK_PROBE_TIMEOUT = 3


def _dotnet_candidates():
    configured = os.environ.get('DOTNET', '')
    explicit = [shutil.which(configured) or configured] if configured else []
    explicit.extend(str(Path(os.environ[k]) / 'dotnet') for k in ('DOTNET_ROOT', 'DOTNET_ROOT_ARM64', 'DOTNET_ROOT_X64') if os.environ.get(k))
    return dict.fromkeys(Path(p).expanduser().absolute() for p in [
        *explicit, str(Path.home() / '.dotnet/dotnet'),
        *(str(Path(p) / 'dotnet') for p in os.get_exec_path() if p),
        '/opt/homebrew/bin/dotnet', '/usr/local/bin/dotnet',
        '/opt/homebrew/opt/dotnet/libexec/dotnet', '/opt/homebrew/opt/dotnet@10/libexec/dotnet',
        '/usr/local/opt/dotnet/libexec/dotnet', '/usr/local/opt/dotnet@10/libexec/dotnet',
        '/usr/local/share/dotnet/dotnet',
    ] if p)


def _sdk_requirement():
    """仓库要的 SDK：compat/tree/global.json 的 version + rollForward（tools/doctor.sh 读的是同一份）。读不到就只要 10.x。"""
    try:
        sdk = json.loads((Path(__file__).resolve().parents[2] / "compat/tree/global.json").read_text())["sdk"]
        return sdk["version"], sdk.get("rollForward", "patch")
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _sdk_ok(version, req):
    """与 tools/doctor.sh 同一判法：版本按 主.次.功能段.补丁 比，预览后缀不参与；rollForward 决定能往哪个方向放宽。"""
    def t(v):
        a = v.split("-")[0].split("+")[0].split(".")
        return int(a[0]), int(a[1]), int(a[2]) // 100, int(a[2]) % 100
    try:
        have = t(version)
        if req is None:
            return have[0] == 10
        want, rf = t(req[0]), req[1]
    except (ValueError, IndexError):
        return False
    if rf in ("latestFeature", "feature"):
        return have[:2] == want[:2] and have[2:] >= want[2:]
    if rf in ("patch", "latestPatch"):
        return have[:3] == want[:3] and have[3] >= want[3]
    if rf in ("latestMinor", "minor"):
        return have[0] == want[0] and have[1:] >= want[1:]
    if rf in ("latestMajor", "major"):
        return have >= want
    return have == want


def _listed_sdks():
    """各候选 dotnet 的 --list-sdks 里的 10.x 行：(exe, 版本号, SDK 目录)"""
    # The host may be a Homebrew shell wrapper; --list-sdks supplies the actual SDK root.
    probe_env = {k: v for k, v in os.environ.items() if k != 'DOTNET_ROOT' and not k.startswith('DOTNET_ROOT_')}
    for exe in _dotnet_candidates():
        try:
            if not exe.is_file() or not os.access(exe, os.X_OK):
                continue
            result = subprocess.run([str(exe), '--list-sdks'], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, timeout=_SDK_PROBE_TIMEOUT,
                                    env=probe_env, check=False)
        except (OSError, UnicodeError, subprocess.TimeoutExpired):
            continue
        if result.returncode or len(result.stdout) > 65536:
            continue
        for line in result.stdout.splitlines():
            sdk = re.fullmatch(r'10\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)? \[([^\r\n]+)\]', line.strip())
            if sdk:
                yield exe, line.strip().split(' ', 1)[0], Path(sdk.group(1))


def dotnet_sdk():
    req = _sdk_requirement()
    for exe, version, sdk_path in _listed_sdks():
        # 版本按 compat/tree/global.json 判（10.0.1xx 编不了要 ≥10.0.403 的 Ryujinx 部分，认成「有 SDK」会到编 C# 时才失败）
        if not _sdk_ok(version, req):
            continue
        if sdk_path.is_absolute() and sdk_path.name == 'sdk' and (sdk_path / version).is_dir():
            return sdk_path.parent, exe
    return None, None


def dotnet_missing():
    """dotnet_sdk() 没找到时给人看的原因（applenv.py 与一键出包开跑自检同一句，#449）：装着 10.x 但低于 global.json 的报「太旧」，不报「没有」"""
    req = _sdk_requirement()
    old = list(dict.fromkeys(f"{version}（{exe}）" for exe, version, _ in _listed_sdks() if not _sdk_ok(version, req)))
    fix = "python3 pack/jobs/applenv.py --install dotnet（装到 ~/.dotnet，不要管理员密码）"
    if old and req:
        return f".NET SDK 版本太旧：装着 {'、'.join(old)}，要 {req[0]} 起（rollForward {req[1]}，compat/tree/global.json）：{fix}"
    return f"没有 .NET 10 SDK：{fix}"


def _iml_device_hint(c, tgt, gid):
    """E：出包第一步读设备窗口并提示（只提示，不拦截）。
    ios_ver 取目标设备系统大版本；has_iml 按签名配置判（dev/adhoc 均带 IML，pack/app.entitlements 只有 IML）；
    addr_need.tsv 在产物根里（stage_rewrite.sh 生成，若不存在不报错）。读不到设备 / 表缺失不报错不中止。
    """
    iml_check_path = Path(__file__).resolve().parents[1] / "iml_check.py"
    if not iml_check_path.is_file():
        return
    has_iml = True   # dev 签名描述文件允许 IML = 有；adhoc 自签 app.entitlements 只带 IML = 有
    ios_ver = int(tgt.get("os") or 0)
    # 产物根里的 addr_need.tsv（stage_rewrite.sh 生成；新款第一次出包可能还没有，用 None）
    tsv = ""
    try:
        cur = layout.image_mac(c, gid, create=False)
        if cur.is_dir() and (cur / "addr_need.tsv").is_file():
            tsv = str(cur / "addr_need.tsv")
    except Exception:
        pass
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("iml_check", iml_check_path)
        iml = importlib.util.module_from_spec(spec); spec.loader.exec_module(iml)
        need_gb_val = iml._need_gb_from_tsv(Path(tsv)) if tsv else None
        hint = iml.window_hint(ios_ver, has_iml, need_gb_val)
        c.emit(kind="iml_hint", message=hint)
    except Exception:
        pass


WIN_MILESTONES = (("播种", "refresh"), ("八个轻阶段", "direct"), ("抽取 + 直连库", "ipa"))
# 每步开头行「[时刻] 开始：步名」→ 这一步所属的段：一开始就切过去（社区贡献者补丁 #8：原先只认上一步收尾行，解包读完到播种结束前一直停在「解包 100%」）
WIN_START_MILESTONES = (("播种", "refresh"), ("八个轻阶段", "refresh"), ("抽取 + 直连库", "direct"), ("组工作根", "ipa"), ("ipa 收尾", "ipa"))


def win_milestone(text):
    """Windows 一键出包（oneclick_win）每步收尾打「[时刻] 步名：N 秒」，成功收尾 = 进下一段 → 下一段名；不是收尾行 / 这步失败（收尾行带「（rc=非 0）」）→ None。
    失败的步也打收尾行：原先照样进下一段，#244 / #269 的直连库失败被摘要报成「编 App 与签名」，把排查带偏"""
    if re.search(r"（rc=(?!0）)\d+）", text):
        return None
    started = re.search(r"] 开始：(.+)$", text)
    if started:
        return next((stage for step, stage in WIN_START_MILESTONES if started.group(1).startswith(step)), None)
    return next((stage for step, stage in WIN_MILESTONES if f"] {step}：" in text), None)


def bundled_shell(c):
    """随包预编壳（Windows --shell / Mac S2A_SHELL）：请求给的 shellDir > 应用资源 Shell/（发版随包，壳号与引擎相同；Mac 上 pack/shell_build.sh 出）"""
    d = Path(c.r.get("shellDir") or Path(c.r.get("resources") or c.private) / "Shell")
    if not (d / "manifest.json").is_file():
        raise Failure("应用自带的预编壳缺失，请重新安装完整的 S2Arm。", code="tool_missing")
    return d


def win_oneclick(c, oneclick, extraction, fonts, out, events, log, env, line, sources=(), gid=None):
    """Windows：同一个共用解包目录交给 oneclick_win（--from-extract），产物照 Mac 一键出包交付成 <款>.ipa + <款>资源包（收尾 deliver 搬进这款的 image/ios），
    结果事件里的 ipa / pack 改指交付件。sources / gid：游戏库里这款选中的原件与游戏号，一并交下去——
    共用解包目录只有序号 0 那支程序，多程序合集的其余序号要 oneclick_win 从原件解（#613：原先不给原件，多程序合集直接报「改给原件」）"""
    work = out / "work"
    env = dict(env, S2A_FONTS=str(fonts))
    c.run([os.sys.executable, "-X", "utf8", "-m", "pack.orch.oneclick_win", "--from-extract", extraction, "--out", work, "--target", "ios",
           "--shell", bundled_shell(c), "--events", events, *(["--title-id", gid] if gid else []), *map(str, sources)],
          log, env, cwd=c.engine, on_line=line)   # 按包起（模块里 from pack… 导入），从引擎根起
    res = oneclick_result(events) or {}
    if not res.get("ok"):
        return
    ipa, pack = Path(res["ipa"]), Path(res["pack"])
    kuan = ipa.stem
    shutil.copy2(ipa, out / (kuan + ".ipa"))
    c.run([os.sys.executable, c.engine / "pack/oneclick/deliver_pack.py", pack, out / (kuan + "资源包")], log, env)
    with open(events, "a", encoding="utf-8") as f:   # 末条 result 指向交付件（ipa.build 只认 out 下的包）
        f.write(json.dumps(dict(res, ipa=str(out / (kuan + ".ipa")), pack=str(out / (kuan + "资源包"))), ensure_ascii=False) + "\n")


def build(c):
    # 与 Mac prepare、显式清缓存 / 删除共用执行锁，清理不与同库编库重叠。
    with c.lock("execution"):
        return _build(c)


def _build(c):
    from cache_retention import retention_policy, trim
    try:
        compiler_policy = retention_policy()
    except ValueError as e:
        raise Failure(str(e)) from e
    c.begin("检查游戏输入")
    gid = c.r.get("gameId") or ""
    from library import selected_packages, require_game
    game = next((g for g in c.catalog()["games"] if g["id"] == gid), None)
    if not game:
        raise Failure("游戏库里没有这款游戏。")
    require_game(c, game)
    import downstream
    scheme = downstream.requested(c, game)   # 玩家选了下游深度方案（确认页）：出包最后一步改用下游的做包工具，见 pack/jobs/downstream.py
    if scheme:
        return downstream.build_ios(c, game, scheme)
    from library import apply_location
    apply_location(c, game)   # 出包页选的存放位置（游戏库结构 v3）
    from library import check_pack_space
    space = check_pack_space(c, game, compiler_policy=compiler_policy)   # 不再暂存原件（共用解包目录 + --from-extract），没有跨卷暂存
    # 同量级下一次出包沿用现有空间预算，不把单次额外 10GiB 当完整余量。
    if isinstance(space, dict):
        compiler_policy["min_free_bytes"] = max(compiler_policy["min_free_bytes"], space["compilerMinFreeBytes"])
    # 先认目标设备、再查 SDK（单测不依赖本机装没装 .NET SDK；PR #63 作者发现）
    #   一包通用（10-30 维护者）：直连包与机型无关，目标设备可有可无（有就只用来提示地址窗口）
    tgt = None if os.name == "nt" else resolve_target(c)
    # E：出包第一步读设备窗口，提示窗口大小与需求（只提示，不中止）
    if tgt: _iml_device_hint(c, tgt, gid)
    # 发版应用（请求带 engineBundle）与 Windows：C# 件随发版预编（Binaries/Prepare）、iOS 壳随包（Resources/Shell，内含 NativeAOT C# 库），
    #   只要随包 .NET 运行时（Context.env 已设）；只有源码树开发构建才现出壳、要外部 SDK
    packaged = os.name == "nt" or bool(c.r.get("engineBundle"))
    home, exe = (None, None) if packaged else dotnet_sdk()
    if not exe and not packaged:
        raise Failure("打 iPhone 包需要 .NET SDK：到「设置」的环境检查里点「一键安装」，装好后再点「打 iPhone 包」。", code="dotnet_sdk_missing")
    fonts = c.fonts_dir()
    if fonts is None:
        raise Failure("应用自带的共享字体缺失，请重新安装完整应用。")
    oneclick = c.engine / ("pack/orch/oneclick_win.py" if os.name == "nt" else "pack/oneclick/oneclick.sh")
    if not oneclick.is_file():
        raise Failure("应用内置引擎太旧，没有打 iPhone 包的工具，请安装最新版 S2Arm。")
    out = contained(layout.root_of(c, gid), layout.ios_work(c, gid))
    out.mkdir(parents=True, exist_ok=True)
    import milestones as ms
    size_gb = sum(p.get("size", 0) for p in {p["sha256"]: p for p in selected_packages(game)}.values()) / 1e9
    ms.plan(c, size_gb, "ipa_dual")
    ms.enter(c, "unpack")
    watcher = early = None
    ipa_log = c.logs / (c.task + "-ipa.log")   # 失败报告认这份（早装线程也调 Context.run，会改 c.last_log）
    try:
        env = c.env()
        # 各平台共用解包（11-02 维护者：多平台导出平台无关阶段只做一次）：与 Mac 打包同一个 游戏库/cache/<程序号>/extract，校验快照对得上就复用，一键出包从这里往下（--from-extract）、不再自己解一遍；
        #   iPhone 还没有现行根、Mac 已有 → 克隆 Mac 的现行根起步（build.seed_from_sibling），平台无关阶段按键跳过、只出 iOS 相关的
        from build import ensure_extract, seed_from_sibling, oneclick_kuan
        logs = c.logs / c.task
        logs.mkdir(parents=True, exist_ok=True)
        extraction = ensure_extract(c, game, selected_packages(game), env, logs)
        kuan = oneclick_kuan(c, gid)
        if os.name != "nt" and not (out / "roots" / (kuan + "@现行")).exists():   # Windows 机上没有 Mac 包可克隆
            seed_from_sibling(c, game, out / "roots", kuan)
        # 出 iPhone 包：平台换成 iOS；.NET 用已确认的外部 SDK（App 内置的只是运行时）
        for name in tuple(env):
            if name.startswith('DOTNET_ROOT_'):
                env.pop(name)
        env.update(S2A_PACK_PLAT="ios", S2A_TARGET="ios", S2A_PY=os.sys.executable)
        # 存档游戏身份（和 Mac 存档作业 saves.identity 同一份）：一键出包只在「从原件出包」时自己生成，启动器走 --from-extract 一直缺，
        #   iPhone 包里没有 save-identity.json → 存档管理页报「缺少游戏身份」、iCloud 存档不同步（11-09 真机）。这里按游戏库目录写好交给它
        from saves import identity as save_identity
        identity_file = logs / "save-identity.json"
        identity_file.write_text(json.dumps(save_identity(game), ensure_ascii=False), encoding="utf-8")
        env["S2A_SAVE_IDENTITY"] = str(identity_file)
        if packaged and os.name != "nt":   # Mac 发版应用：随包壳（pack/ipa.sh 见 S2A_SHELL 就不现出壳）+ 应用自带读取器（同 build.py：dotnet 跑 dll 包一层可执行壳）
            from toolchain import reader
            nxu = logs / "nx_unpack"
            nxu.write_text("#!/bin/sh\nexec dotnet " + shlex.quote(str(reader(c))) + ' "$@"\n'); nxu.chmod(0o755)
            env.update(S2A_SHELL=str(bundled_shell(c)), S2A_NX_UNPACK=str(nxu))
        if exe:
            env.update(DOTNET=str(exe), DOTNET_ROOT=str(home), DOTNET_MULTILEVEL_LOOKUP="0",
                       PATH=os.pathsep.join(dict.fromkeys([str(exe.parent), str(home), env["PATH"]])))
        state = {}
        # 出包与装机重叠（installAfter，pack/jobs/early.py）：开工前认账号与设备，旁路完成就先装 App、先推大头资源，与直连库编译并行
        if c.r.get("installAfter") and os.name != "nt":   # Windows：出完再装（install.install 的 Windows 分支），不做出包期间早装
            from early import EarlyInstall
            early = EarlyInstall(c, gid, env, out).start()

        def line(text):
            nonlocal watcher
            m = re.search(r"款 ([^）\s，,]+)", text)
            if m and "款" not in state:
                state["款"] = m.group(1)
            if "④ 刷新" in text and watcher is None:
                ms.enter(c, "refresh")
                watcher = ms.DirectWatcher(c, out / "roots", state.get("款", ""))
                watcher.__enter__()
            if "④ 出包" in text:
                if watcher:
                    watcher.__exit__(None, None, None)
                ms.enter(c, "ipa")
            stage = win_milestone(text)   # Windows 一键出包：这步开头 / 上一步成功收尾 = 进这一段（同一段不重复进，免得计时清零）
            if stage and stage != getattr(c, "milestone", None):
                ms.enter(c, stage)
        # 交付物 / 包号 / 画面模式从一键出包的事件流取（--events，最后一条 result；10-26 照上游 --progress json），不按人读完成行的字面抠
        events = c.logs / (c.task + "-ipa.events.jsonl")
        events.parent.mkdir(parents=True, exist_ok=True); events.write_text("")   # 先清空：只认本轮写的 result
        before_milestone = getattr(c, "milestone", None)
        refresh_log = out / "logs/refresh.log"
        refresh_before = _log_identity(refresh_log)
        try:
            if os.name == "nt":
                from library import source_path
                win_oneclick(c, oneclick, extraction, fonts, out, events, ipa_log, env, line,
                             sources=list(dict.fromkeys(source_path(c, p) for p in selected_packages(game))), gid=gid)
            else:
                c.run(["bash", oneclick, "--from-extract", extraction, "--fonts", fonts, "--out", out, "--events", events],
                      ipa_log, env, on_line=line)
        except Failure as error:
            if error.code != "tool_exit":
                raise
            # 原始退出码由 report_failure 替换 tool_exit 时保留；超时/取消不转换。
            raise oneclick_failure(events, getattr(c, "milestone", None) if getattr(c, "milestone", None) != before_milestone else None, ipa_log, refresh_log=refresh_log, refresh_before=refresh_before) from error
        state["result"] = oneclick_result(events)
    except BaseException:
        if early:   # 出包失败：旁路还没写信号的不再早装；已在装 / 推的等它退出再交回——main 接着清理中间产物，会删它正在读的 roots/ 与 .early（审计 P1-146）
            early.core.finish()
        raise
    finally:
        if watcher:
            watcher.__exit__(None, None, None)
    # 不在输出目录里按修改时间挑：目录里留着别的 / 更「新」的旧 IPA 时会把旧包当成本轮结果，配上本轮包号（#67 qidian99 反证）
    res = state.get("result") or {}
    if res.get("ok") is False:
        raise oneclick_failure(events, getattr(c, "milestone", None) if getattr(c, "milestone", None) != before_milestone else None, ipa_log, refresh_log=refresh_log, refresh_before=refresh_before)
    ipa = Path(res.get("ipa") or "")
    if not res.get("ok") or not res.get("ipa") or not ipa.is_file() or ipa.resolve().parent != out.resolve():
        raise Failure("一键出包结束了，但没报告本轮交付的 IPA（或文件不在输出目录），请查看日志。", code="package_failed")
    ms.record(c, size_gb, gameId=gid)
    # 追加内容没解出（pack/stages/aoc.sh 记产物根 aoc.log，oneclick 结果事件 aoc_missing）：本体照常出、不挡，但走同一条警告，完成页画「完成（有警告）」（审计 P1-74）
    missing = [m for m in (res.get("aoc_missing") or []) if m]
    if missing:
        c.diagnostic("追加内容 %d 份没解出，包里不含（%s）" % (len(missing), "、".join(missing[:5]) + (" 等" if len(missing) > 5 else "")), code="aoc_missing", severity="warning")
    root = product_root(c, gid)
    notes = []
    if root:
        from build import warn_offline_empty, collect_degrade
        warn_offline_empty(c, root)   # 离线 0 支（#470）：照常交付，完成页带黄字
        notes = collect_degrade(c, root)   # 降级继续的玩家提示：随结果交给完成卡（v0.3.1）；清理会删产物根，先读
    # 早装先收尾再清理：清理会删它正在读的 roots/<款>@现行 与 .early（审计 P1-146：直连命中缓存时出包比早装推得快）
    pre = early.finish() if early else None
    # Q15：成功清一次性中间产物，编库缓存跨次保留并按预算裁剪；失败留现场。
    c.begin("清理出包中间产物")
    pack_dir = out / (ipa.stem + "资源包")   # 同 pack/oneclick/oneclick.sh 的交付布局
    deliver(c, gid, product_root(c, gid), pack_dir, ipa)
    prune_unless_follow_up(c, gid)
    cache_result = trim(c.work_root, current_gid=gid, **compiler_policy)
    from cache_retention import engine_installed_at, prune_tool_keys
    prune_tool_keys(c.work_root, engine_installed_at(c.engine))   # 当前引擎用不到的工具缓存旧键（NativeAOT / libvpx / opus / dav1d）
    if not cache_result['accountingComplete'] or cache_result['evictionErrors'] or cache_result['diskErrors'] or cache_result['pressureRemaining']:
        c.diagnostic("编库缓存清理未完整完成：盘余量未恢复/未知或条目未能删除；扫描错误 %d，删除错误 %d，盘量错误 %d，未扫描根 %d，保护链接 %d，变化条目 %d。已完成的 IPA 保留，详见 compilerCache。" %
                     (cache_result['scanErrors'], cache_result['evictionErrors'], cache_result['diskErrors'],
                      cache_result['unscannedRoots'], cache_result['protectedLinks'], cache_result['changedEntries']),
                     code="compiler_cache_incomplete", severity="warning")
    c.emit("message", "编库缓存保护最近 %d 款；已观察保留 %d 字节、淘汰 %d 条；盘余量 %s 字节，底线 %d 字节，仍低于底线：%s。逻辑字节不触发裁剪。" %
           (cache_result['keepTitles'], cache_result['retainedBytes'], cache_result['removedEntries'],
            cache_result['freeBytes'], cache_result['minFreeBytes'], cache_result['pressureRemaining']))
    from library import _part_bytes
    image = layout.image_ios(c, gid)
    result = dict(compilerCache=cache_result, outputPath=str(image), ipa="", ipaBytes=0, packBytes=_part_bytes([image / layout.IOS_PACK]), buildId=res.get("build_id") or "", target=tgt, graphicsMode=res.get("graphics_mode") or "unknown",
                  **({"notes": notes} if notes else {}))
    if early:   # 打完放进容器装到这台：早装推过的不再推，push_pack 按机上已解开的清单只补差量（着色器库 + 变了的小文件）
        import install as inst
        c.begin("装到 iPhone 并补推资源包（出包期间已先推 %d 个文件）" % pre.get("files", 0))
        done = inst.put_game(c, gid, inst.MacPhone(c, early.team, early.dev, early.udid), steps=False)
        shutil.rmtree(early.dir, ignore_errors=True)
        result.update(done, outputPath=str(image), packFiles=done["packFiles"] + pre.get("files", 0), packBytes=done["packBytes"] + pre.get("bytes", 0), earlyPack=pre)
    lib_ipa = refresh_library_ipa(c)
    if lib_ipa:   # 完成页的「显示 .ipa」（两端都读结果里的 ipa）：指向刚组好的库根 S2Arm.ipa
        result.update(ipa=str(lib_ipa), ipaBytes=lib_ipa.stat().st_size)
    import sizes
    sizes.refresh(c, gid)   # 每款各部分大小写回 game.json（游戏库只读不量）
    return result


def prune_unless_follow_up(c, gid):
    """出包收尾清本款解包与中间产物；请求带 followUp（同一款这次还要接着出别的平台）时先不清，留给下一个平台（pack/contracts/README.md，剃刀 M21）。返回是否清了"""
    if c.r.get("followUp") is True:
        c.emit(message="这款接着还要出别的平台：先留着解包与中间产物")
        return False
    from library import prune_build
    try:
        prune_build(c, gid)
    except (Failure, OSError) as error:   # #793 / #796：包已经出好，清中间产物只是收尾——游戏库在删不了文件的地方（Xbox App 管的文件夹）时
        #   原先 PermissionError 一路抛上去，出好的包被判失败；同失败收尾 clean_after_stop：记一条警告，下次空闲再清
        c.diagnostic("清理中间产物没有完成，下次空闲时会再清：" + c.redact(str(error)), code="job_failed", severity="warning")
        return False
    return True


def refresh_library_ipa(c):
    """出 iPhone 包成功就把默认位置根 S2Arm.ipa 换成含游戏库里本版能用的全部各款的容器（#360）：原先它只在「装到 iPhone」成功后才更新，
    只出包、自己用 SideStore / LiveContainer 侧载的玩家拿到的是旧包（或 0.1.x 迁移留下的单款包），出包完成页的「显示 .ipa」也不出现。
    组装同装机（assemble，Mac ad-hoc / Windows 不签，侧载工具重签）、放置同装机（commit_phone_ipa：换了壳把旧的留作上一版）。
    组装失败只警告：这款的 iPhone 版已经出好，不因为别的款连带判出包失败。→ 库根 S2Arm.ipa 路径 | None（没组）"""
    sid = current_shell_id(c)
    ready = [g["id"].upper() for g in c.catalog()["games"] if usable_kit(c, g["id"].upper(), sid)]
    if not ready:
        return None
    c.begin("组装可直接侧载的 S2Arm.ipa（含 %d 款）" % len(ready))
    try:
        ipa, _, _ = assemble(c, None, ready)
        commit_phone_ipa(c, ipa, sid)
    except (Failure, OSError) as e:   # 组装出错（盘满、权限、容器件坏）都只警告
        c.diagnostic("游戏库根目录的 S2Arm.ipa 这次没更新（" + str(e) + "）：这款的 iPhone 版已出好，「装到 iPhone」时会照常组装。", code="job_failed", severity="warning")
        return None
    return layout.phone_ipa(c)


CONTAINER_BUNDLE = "io.s2arm.games"   # 组装时的占位包名：Mac 装机换成团队专属的 io.s2arm.games.<团队>（install.container_bundle_id）；Windows 由 plumesign 按账号定


def deliver(c, gid, root, pack_dir, ipa):
    """出包收尾：交付件搬进这款的 image/ios（游戏库结构 v3），game.json 的 ios 记壳号、兼容判据、资源包号；单款 ipa 不留（装机现组容器）。
    先存容器件、再换资源包、最后写 game.json：中途被打断时 game.json 还是上一版的，资源包号对不上就按「变了」补推，不会少推"""
    import host_update
    from library import save_container_kit, _rm
    if root is None or save_container_kit(c, gid, root) is None:
        raise Failure("一键出包结束了，但产物根里没有组装 iPhone 版要用的文件（main.npdm），请查看日志。", code="package_failed")
    to_img(c, gid, root, pack_dir)
    want = read(Path(pack_dir) / "manifest.json", {}).get("index_sha256")
    if not want:
        raise Failure(f"资源包缺清单或清单没有 index_sha256（{pack_dir}）：请重新打 iPhone 包。", code="package_failed")
    image = layout.image_ios(c, gid)
    managed = layout.root_of(c, gid)
    dest, old = image / layout.IOS_PACK, image / (layout.IOS_PACK + ".old")
    if old.exists():
        _rm(c, managed, old)
    if dest.exists():
        os.replace(dest, old)
    os.replace(pack_dir, dest)   # 同一款文件夹内改名（build/ios → image/ios）
    if old.exists():
        _rm(c, managed, old)
    compat = host_update.engine_compat(c) or {}
    from rewrite_refresh import rewriter_id   # 这次的改写产物出自哪版改写器：改写器以后修了，更新手机时只核记号不同的款（rewrite_refresh.py）
    layout.update_info(c, gid, ios=dict(shellId=current_shell_id(c), pack=want, rewriterId=rewriter_id(c), **compat))
    Path(ipa).unlink(missing_ok=True)


def to_img(c, gid, root, pack_dir):
    """资源包就地转单一 IMG 形态（v0.3.0，pack/img.py convert）：游戏原始资源进 game.img（之后字节不变），着色器库 / 覆盖层照旧按文件。
    多程序合集这一版照旧旧形态。转失败 = 出包失败（不交一半）"""
    c.begin("把游戏资源写成单一 IMG（game.img）")
    log = c.logs / "img.log"
    # 边写边删解包出来的 RomFS（#746）：出包收尾本来就清掉整个出包工作目录（prune_unless_follow_up），提前到写 IMG 时，峰值少一整份游戏大小。
    #   同一款接着还要出别的平台（followUp）要留着解包，不删
    consume = c.r.get("followUp") is not True
    try:   # 走 c.run：它每秒读 S2A_PROGRESS，img.py 按已写字节报进度，出包页这一步有进度条（几十 GB 要写一两分钟）
        c.run([os.sys.executable, "-X", "utf8", "pack/img.py", "convert", str(root), str(pack_dir), "--gid", gid.upper(), *(["--consume", "--work", str(layout.ios_work(c, gid))] if consume else [])],
              log, c.env(), cwd=c.engine)
    except Failure as e:
        if consume:   # 解包已删了一部分：清掉整个出包工作目录（同出包成功的收尾），重试从解包重做，不拿残缺的产物根接着出
            from library import _build_entries, _rm
            for p in _build_entries(c, gid):
                _rm(c, layout.root_of(c, gid), p)
        from errors import tool_reason
        raise Failure("写单一 IMG（game.img）失败：" + (tool_reason(log) or str(e)), code="package_failed") from e


def current_shell_id(c):
    r = subprocess.run([os.sys.executable, "-X", "utf8", "-c", "from pack.shell.manifest import current_id; print(current_id())"], cwd=c.engine, env=c.env(), capture_output=True, text=True)
    if r.returncode or not r.stdout.strip():
        raise Failure("算不出本引擎的壳编号：" + ((r.stderr or "").strip().splitlines() or ["?"])[-1], code="tool_missing")
    return r.stdout.strip()


def container_shell(c, sid):
    """容器用的预编壳：发版（Windows / Mac 发版应用）= 应用自带 Shell/；开发树 = 本树壳编号的本机缓存 <S2A_RUN_ROOT>/s2arm/cache/shell/<壳编号>（打 iPhone 包时 pack/ipa.sh 出 / 取的同一份）"""
    if os.name == "nt" or c.r.get("engineBundle") or c.r.get("shellDir"):
        return bundled_shell(c)
    d = Path(c.env().get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/cache/shell" / sid
    if not (d / "manifest.json").is_file():
        raise Failure("本机还没有这一版的预编壳：先给这款「打 iPhone 包」（会出壳），再装到 iPhone。", code="tool_missing")
    return d


def product_root(c, gid):
    """这款的现行产物根（打包流程的工作目录）；不存在 → None"""
    from build import oneclick_kuan
    out = layout.ios_work(c, gid, create=False)
    r = out / "work/pkg/product" if os.name == "nt" else out / "roots" / (oneclick_kuan(c, gid) + "@现行")   # Windows：win_oneclick 的工作根（现行各项联接 + 直连库，oneclick_win.product）
    return r.resolve() if (r / "main.npdm").is_file() else None


def usable_kit(c, gid, sid, failed=()):
    """这款的容器件能不能放进本版壳 → 路径 | None。本壳出的直接用；别的壳出的，新宿主认得它（host_update：宿主读产物约定号 + 直连链号）
    且这台手机没对本壳装回过上一版（failed）也用——只换宿主，不用重新打 iPhone 包"""
    import host_update
    kit = layout.ios_kit(c, gid)
    if not (kit / "main.npdm").is_file():
        return None
    ios = layout.game_info(c, gid).get("ios") or {}
    if ios.get("shellId") == sid:
        return kit.resolve()
    want = host_update.engine_compat(c)
    have = dict(hostAbi=ios.get("hostAbi", 1), dmshChain=ios.get("dmshChain", host_update.LEGACY_CHAIN))
    return kit.resolve() if want and have == want and sid not in failed else None


def write_container_ipa(c, app, ipa, log):
    c.run([os.sys.executable, "-X", "utf8", "-B", c.engine / "pack/app_bundle.py", "write_ipa", app, ipa], log, c.env())


def container_custom(c):
    """容器里各款的显示名和封面：改过的用玩家的；custom = False 的给原名原图，已经带着旧自定义的容器条目靠它恢复。"""
    from library import game_custom
    out = {}
    for game in c.catalog()["games"]:
        custom = game_custom(c, game["id"])
        original = layout.path(c, game["id"], "cover.jpg", create=False)
        cover = custom["cover"] or (original if original.is_file() else None)
        out[game["id"]] = dict(custom=bool(custom["name"] or custom["cover"]), name=custom["name"] or game.get("name") or "", cover=str(cover) if cover else "")
    return out


def assemble(c, gid, others=(), *, failed=(), root=None, dest=None):
    """现组容器（一个 App 装多款）：本版 iPhone 壳 + 这款和 others（这台手机上已有的各款）的容器件（pack/ship_ext.py container），出 S2Arm.app + S2Arm.ipa 到 dest
    （缺省游戏库同盘临时目录，由调用方装上后再放到默认位置根）。不再在上一次的底包上加款：底包和各款镜像会不一致，且换壳时要整包重出。
    gid 为 None：只组 others（从手机删一款）。哪款放不进本壳（不是本壳出的、新宿主也不认得）就报 container_stale 点名，不装半套；
    游戏库里已删的款不再带（手机上的存档还在）。root / dest：出包重叠早装用（旁路刚完成的产物根，出到临时目录）。
    → (ipa, 全部款, 壳号)。Windows 不签（--sign none，交给 plumesign）；Mac 自签，装机时再按玩家团队重签"""
    import host_update
    sid = current_shell_id(c)
    roots = {}
    if gid:
        gid = gid.upper()
        roots[gid] = Path(root) if root else usable_kit(c, gid, sid, failed)
        if roots[gid] is None:
            raise Failure("这款的 iPhone 版不是这一版 S2Arm 出的（或还没出）：先「打 iPhone 包」，再装到 iPhone。", code="container_stale")
    in_library = {g["id"].upper() for g in c.catalog()["games"]}
    stale, deleted = [], []
    names = {g["id"].upper(): g.get("name") or g["id"] for g in c.catalog()["games"]}
    for g in others:
        g = g.upper()
        if g in roots:
            continue
        if g not in in_library:   # 玩家已从游戏库删掉：重出不了，也不该挡住别的游戏
            deleted.append(g)
            continue
        roots[g] = usable_kit(c, g, sid, failed)
        if roots[g] is None:
            stale.append(names.get(g, g))
    stale_ids = [g for g in roots if roots[g] is None]
    if stale and c.r.get("acceptStale") is not True:   # 认得出的风险（v0.3.1 装机原则）：问玩家，确认后这次先不带它们照装，不替他拒
        raise Failure("S2Arm 更新过，手机上的「" + "」「".join(stale) + "」要按新版重新出包才能放进同一个 App。确认继续的话，这次先不带它们照装这款："
                      "它们的存档和资源都留在手机上，之后给它们各「打 iPhone 包」再装一次就回来。不想这样就先给它们重新出包。", code="container_stale",
                      internal=" ".join(stale_ids))
    if stale:
        for g in stale_ids: roots.pop(g)
        c.diagnostic("「" + "」「".join(stale) + "」这次没放进新版 S2Arm（要按新版重新出包）；手机上的存档和资源都还在，给它们各「打 iPhone 包」再装一次就回来。",
                      code="container_stale", severity="warning")
    if deleted:
        c.diagnostic("「" + "」「".join(deleted) + "」已从游戏库删除，新版 S2Arm 里不再包含它们；手机上的存档还在。", code="job_failed", severity="warning")
    if not roots:
        raise Failure("手机上的 S2Arm 里没有别的游戏了。", code="job_failed")
    shell = container_shell(c, sid)
    icon = c.engine / "launchers/macos/Branding/AppIcon-1024.png"   # 宿主永远用 S2Arm 自己的图标，不退回某款游戏的（游戏图标只进 Games/<游戏号>/）
    if not icon.is_file():
        raise Failure("这个 S2Arm 安装包不完整（缺应用图标），请重新下载 S2Arm。", code="engine_incomplete")
    out = Path(dest) if dest else Path(tempfile.mkdtemp(prefix=".container-", dir=c.library))
    out.mkdir(parents=True, exist_ok=True)
    app, ipa = out / "S2Arm.app", out / "S2Arm.ipa"
    log = c.logs / (c.task + "-container.log")
    shutil.rmtree(app, ignore_errors=True)
    (out / "custom.json").write_text(json.dumps(container_custom(c), ensure_ascii=False), encoding="utf-8")
    # 横图取游戏库那份（导入时作业层抓好，library.store_meta）：组装不联网，Mac / iPhone / Windows 读同一份
    banners = {g: layout.path(c, g, "banner.jpg", create=False) for g in roots}
    banner_args = [x for g, b in banners.items() if b.is_file() for x in ("--banner", f"{g}={b}")]
    try:
        c.run([os.sys.executable, "-X", "utf8", "-B", c.engine / "pack/ship_ext.py", "container", "--shell", shell, "--out", app, "--bundle-id", CONTAINER_BUNDLE,
               "--icon", icon, "--sign", "none" if os.name == "nt" else "adhoc", "--custom", out / "custom.json", "--host-abi", str(host_update.HOST_ABI),
               "--version", release_version(c.engine), "--display-version", display_version(c.engine),
               *[x for r in roots.values() for x in ("--game", r)], *banner_args], log, c.env())
    except Failure as e:
        text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
        if e.code == "tool_exit" and "地址空间类型不一致" in text:
            raise Failure("这款和手机上已有的游戏地址空间类型不同，放不进同一个 App。", code="container_incompatible") from e
        raise
    write_container_ipa(c, app, ipa, log)
    games = [g["title_id"] for g in json.loads((app / "s2a_catalogue.json").read_text(encoding="utf-8"))["games"]]
    if gid and gid not in games:
        # 程序文件（main.npdm 的程序号）和游戏包（导入时 CNMT 的发行号）对不上：游戏文件被改过、或混进了别的游戏的程序
        #   （玩家实报：把别的游戏的程序换进了这款的包里）。设备侧目录按程序号，放过去就推错地方，这道核对保留，只把原因说清
        raise Failure(f"这款游戏的程序文件和游戏包对不上（程序里是 {' '.join(games)}，游戏包是 {gid}），可能是游戏文件被改过或混了别的游戏。请用原版游戏文件重新导入。",
                      code="game_files_mismatch")
    shutil.rmtree(app, ignore_errors=True)
    return ipa, games, sid


def ipa_games(ipa):
    """装机产物里的各款与壳号（读 ipa 里的 s2a_catalogue.json）→ ([游戏号…], 壳号)；读不了 → ([], "")"""
    try:
        with zipfile.ZipFile(ipa) as z:
            name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/s2a_catalogue\.json", n))
            cat = json.loads(z.read(name).decode("utf-8"))
        return [g["title_id"] for g in cat.get("games", [])], cat.get("shell_id") or ""
    except (OSError, StopIteration, ValueError, KeyError, zipfile.BadZipFile):
        return [], ""


def drop_from_ipa(c, ipa, gid):
    """从装机产物里摘掉一款（其余各款逐字节不变、不换壳：升级后还没重出的款也能删）→ (临时 ipa, 剩下的款, 壳号)"""
    tmp = Path(tempfile.mkdtemp(prefix=".container-", dir=c.library))
    log = c.logs / (c.task + "-container.log")
    r = subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipa), str(tmp / "x")] if os.name != "nt" else
                       [os.sys.executable, "-c", "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])", str(ipa), str(tmp / "x")], capture_output=True, text=True)
    base = next((tmp / "x" / "Payload").glob("*.app"), None)
    if r.returncode or base is None:
        shutil.rmtree(tmp, ignore_errors=True)
        raise Failure("手机上的 S2Arm 在游戏库里的那份读不了：先给手机上的游戏各「打 iPhone 包」一次，再删。", code="container_stale")
    c.run([os.sys.executable, "-X", "utf8", "-B", c.engine / "pack/ship_ext.py", "container-drop", "--base", base, "--game", gid, "--out", tmp / "S2Arm.app"], log, c.env())
    write_container_ipa(c, tmp / "S2Arm.app", tmp / "S2Arm.ipa", log)
    cat = json.loads((tmp / "S2Arm.app/s2a_catalogue.json").read_text(encoding="utf-8"))
    return tmp / "S2Arm.ipa", [g["title_id"] for g in cat["games"]], cat.get("shell_id") or ""


def commit_phone_ipa(c, ipa, sid):
    """装上之后放到默认位置根 S2Arm.ipa；换了壳就把原来那份留作 S2Arm.previous.ipa（装回上一版用），同壳直接覆盖"""
    current, previous = layout.phone_ipa(c), layout.phone_ipa(c, previous=True)
    if current.is_file() and ipa_games(current)[1] not in ("", sid):
        os.replace(current, previous)
    os.replace(ipa, current)
    if Path(ipa).parent.name.startswith(".container-"):   # assemble 缺省出到的临时目录
        shutil.rmtree(Path(ipa).parent, ignore_errors=True)


def oneclick_result(path):
    """一键出包事件流（pack/oneclick/oneclick.sh --events）的最后一条 result；没有 / 读不了给 None。坏行跳过（只认整行 JSON）"""
    result = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    e = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(e, dict) and e.get("ev") == "result":
                    result = e
    except OSError:
        return None
    return result


def resolve_target(c):
    """目标设备（只用来提示地址窗口，一包通用）：请求里给了（前端：连着的设备或玩家选的机型）就用它；没给就认连着的那一台。
    认不出目标 → None、照常出包；所用 Xcode 的 SDK 比目标系统旧也不拦（直连库按 iOS 18 下限编）；
    目标本身装不了（系统低于 18、GPU 太老：target_unsupported）照旧报红——包在那台上跑不了"""
    import target as tg
    want = c.r.get("target") or {}
    try:
        if not want:
            devs = [d for d in tg.connected(c) if d.get("gpuArch")]
            # 连着几台同架构、同系统大版本的设备 = 同一个目标
            devs = list({(d["gpuArch"], d["os"]): d for d in devs}.values())
            if len(devs) != 1:
                return None
            want = devs[0]
        return tg.check(want, tg.os_choices(c.env())[0])
    except tg.TargetError as e:
        if not want or e.code == "xcode_sdk_too_old":   # 没给目标时探测连着的设备出错也不拦
            return dict(want) or None
        raise Failure(str(e), code=e.code) from e


# 只登记 oneclick.sh 实际 lap 阶段；子步骤从各自产生错误的脚本取，不虚构事件名。
ONECLICK_PHASES = {
    "认游戏": None, "解包": "unpack", "播种": "seed",
    "刷新各阶段": None, "出包": None, "交付": None,
    "安卓出包": None, "安装与导入": None,
}

# pack/ipa.sh 的 fail 前缀。只匹配外层失败原因，detail 内的同名文字不参与归因。
PACKAGE_FAILURE_PREFIXES = (
    ("签名失败", "sign"), ("自签失败", "sign"), ("签名核实", "sign"),
    ("签名里没有「提高内存上限」权限", "sign"), ("签名含私有 JIT 键", "sign"),
    ("出壳失败", "host"), ("预编壳组装失败", "host"), ("组装没产出", "host"),   # 11-04 全外置：原「make ios 失败 / 没产出」
    ("资源包失败", "seed"), ("资源包核对", "seed"),
    ("直连库不全", "seed"),   # 产物根直连库真残缺（#11：原先落成 package_failed「原因没认出来」）
)


def _log_identity(path):
    try:
        st = path.stat()
        return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns
    except OSError:
        return None


def _new_refresh_red(path, before):
    """只读本轮刷新实际更新的日志；不把上次失败归给新任务。"""
    if path is None or _log_identity(path) == before:
        return None
    try:
        with open(path, "rb") as stream:
            stream.seek(0, 2)
            stream.seek(max(0, stream.tell() - 16000))
            lines = stream.read().decode("utf-8", errors="replace").splitlines()
        red = [line.strip() for line in lines if "【红】" in line]
        return red[-1] if red else None
    except OSError:
        return None


def _package_failure_phase(reason):
    detail = reason.removeprefix("出包失败：").strip()
    detail = re.sub(r"^【红】[^\r\n]*? 出包：", "", detail, count=1).lstrip()
    # ipa.sh.fail 会再包住 iml_check / verify 自带的红行；只剥子原因开头，保留摘要原文。
    detail = re.sub(r"^(?:【红】|🔴)\s*", "", detail, count=1)
    return next((phase for prefix, phase in PACKAGE_FAILURE_PREFIXES if detail.startswith(prefix)), None)


def oneclick_failure(events, milestone, log, *, refresh_log=None, refresh_before=None):
    from errors import classify_failure, player_reason, refresh_stop_phase, tool_reason
    name = "未记录阶段"
    result = None
    try:
        with open(events, encoding="utf-8", errors="replace") as stream:
            for raw in stream:
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get("ev") in ("stage", "stage_begin") and isinstance(event.get("name"), str):
                    name = event["name"]
                elif event.get("ev") == "stage_end":
                    # 已完成的上一阶段不是随后未知失败的归因；显式失败结束才保留。
                    name = event["name"] if event.get("ok") is False and isinstance(event.get("name"), str) else "未记录阶段"
                if event.get("ev") == "result":
                    result = event
    except OSError:
        pass
    phase = ONECLICK_PHASES.get(name)
    reason = result.get("msg") if result and result.get("ok") is False else None
    if not isinstance(reason, str) or not reason.strip():
        reason = tool_reason(log)
    if name == "出包":
        phase = _package_failure_phase(reason)
    elif name == "刷新各阶段":
        # oneclick 会从 result.msg 滤掉「刷新停在」行；回到本轮 refresh.log 找生产方的子阶段。
        red = _new_refresh_red(refresh_log, refresh_before)
        if red and "刷新停在" in red:
            # 未登记的终止子阶段保持宽错误码，不从更早的红行或残留标签猜原因（errors.refresh_stop_phase）。
            phase = refresh_stop_phase(red)
        if red and red not in reason:
            reason += "；" + red
    # 日志确凿根因（盘满 / 缺 Metal / 缺工具）先于阶段映射；读一键出包输出尾 + 原因里点名的 refresh.log → 其红行点名的子日志（errors.gather_evidence）。
    # 本轮 refresh.log 没更新过（_log_identity 未变）就不读，旧失败不归给新任务。
    fresh_refresh = refresh_log if refresh_log is not None and _log_identity(refresh_log) not in (None, refresh_before) else None
    code, why = classify_failure(phase, log, (reason,) + ((str(fresh_refresh),) if fresh_refresh else ()))
    # 上屏只放玩家话术；阶段 / 红行原文 / 归因依据进 internal → 诊断 detail（「复制错误摘要」带走）
    return Failure(player_reason(code), code=code, internal="一键出包失败（" + name + "）：" + reason + "\n" + why)
