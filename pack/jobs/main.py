#!/usr/bin/env python3
"""Versioned local JSON request / NDJSON event entry point. No daemon required.

Subcommands (J10 / #186):
  run     --request <file>                      run one request (the Mac launcher's call; a bare --request still works)
  get     --private-root <dir> --task <id>      the journal of one task: state, stage, attempts, whether the worker is still there
  events  --private-root <dir> --task <id> [--since N] [--limit N]
                                                the task's NDJSON events, incrementally
  cancel  --private-root <dir> --task <id> [--signal TERM|KILL]
                                                signal the worker this task recorded (refuses a reused pid)
"""
from __future__ import annotations
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
if os.name == "nt":   # 作业主程序自己也要长路径处理：子 Python 进程靠 sitecustomize 装，主进程没人装（注册表 LongPathsEnabled 关着时，数据目录 ~200 字符起启动器后端就起不来）
    sys.path.insert(1, str(Path(__file__).resolve().parents[2]))
    from pack.orch import winlong as _winlong
    _winlong.install()
import android_export
import apple_login
import awake
import community
import devcert
import diag
import diag_upload
import downstream
import embedded
import export_plan
import host_update
import install
import tvos
import ipa
import layout
import patches
import library
import winproc
import saves
import save_previous
import sgrade
import sizes
import target
import toolchain
from core import (KEEP_DAYS, KEEP_FAILED_PER_OPERATION, KEEP_PER_OPERATION, KEEP_TOTAL, Cancelled, Context, Failure, Paused, TERMINAL_STATES, cancel, describe, journal, pid_alive, prune_jobs,
                  read_events, request_path, status)

import build


def partial_import_result(c):
    """中途失败 / 取消时随终态带回的逐来源结果：只有要 partialResults 的调用方才有（默认路径同 #124 之前，失败结果为空）"""
    return getattr(c, "import_result", None) if c.operation == "import" and c.r.get("partialResults") is True else None


def app_installed_result(c):
    """独立 App 装上了、资源没推完就失败（install.put_app 记的 c.app_installed）：失败结果带 appInstalled，失败页写「App 已装上，资源没推完」、重试只推剩下的"""
    got = getattr(c, "app_installed", None)
    return dict(appInstalled=got) if c.operation == "install" and got else None


def run_request(request_path, *, context_class=Context, operation_overrides=None):
    # 开发者证书密码（devCert 导入那一次由启动器经环境变量给，devcert.py ⑤）：先从环境摘掉，任何子进程都拿不到；请求文件里从不放
    devcert_password = os.environ.pop(devcert.PASSWORD_ENV, None)
    apple_password = os.environ.pop(apple_login.PASSWORD_ENV, None)   # Mac 通用壳 Apple ID 登录（appleLogin）那一次：同上，只写进 plumesign 的标准输入
    winproc.prepare_child_environment()
    path = Path(request_path)
    request = json.loads(path.read_text())
    if request.get("schema") != 1:
        raise SystemExit("unsupported request schema")
    try:
        c = context_class(request)
    except Failure as error:
        # Validation precedes job registration: use the existing CLI rejection
        # shape, not a fabricated job result/event for a task that never started.
        print(json.dumps({"error": str(error), "code": getattr(error, "code", "job_failed")}, ensure_ascii=False))
        return 2
    except OSError as error:
        # The job cannot even register its record (full disk, read-only volume): say why and come back non-zero instead of a traceback (J10)
        print(f"[s2a] 【红】任务记录写不进磁盘，任务未开始：{error}", file=sys.stderr, flush=True)
        return 1
    c.devcert_password = devcert_password
    c.apple_password = apple_password
    signal.signal(signal.SIGTERM, lambda *_: c.stop())
    signal.signal(signal.SIGINT, lambda *_: c.stop())
    ended = threading.Event()
    def supervise():
        while not ended.wait(1):
            parent = request.get("parentPid")
            if parent and not pid_alive(parent):   # 启动器没了：停本任务（Windows 不能用 os.kill(pid, 0) 探活，见 core.pid_alive）
                c.parent_gone = True   # 出包编排据此把停下记成 paused（启动器退出），不是玩家取消（剃刀 H13）
                c.stop()
            if not c.cancelled:
                c.emit("heartbeat")
    threading.Thread(target=supervise, daemon=True).start()
    operations = {"preflight": toolchain.preflight, "prepareEngine": toolchain.prepare, "downloadMetal": toolchain.download_metal, "downloadIosPlatform": toolchain.download_ios_platform,
                  "setup": library.setup, "keys": library.keys, "import": library.import_games,
                  "catalog": library.catalog, "customize": library.customize, "remove": library.remove, "delete": library.delete, "clean": library.clean,
                  "spaceSurvey": library.space_survey, "spaceFree": library.space_free, "storageOverview": sizes.overview,
                  "phoneSaves": install.phone_saves,
                  "phoneSaveRestore": install.restore_phone_save,
                  "diagnostics": library.diagnostics, "diagnosticsUpload": diag_upload.upload, "saveInput": library.save_input,
                  "phoneUsage": install.phone_usage,
                  "locations": library.list_locations, "moveGame": library.move_game, "relinkGame": library.relink_game, "forgetGame": library.forget_game,
                  "phoneIdentity": install.phone_identity, "phoneChooseApp": install.phone_choose_app,
                  "appleLogin": apple_login.login, "appleAccount": apple_login.account,
                  "build": build.prepare, "launch": build.launch, "pullDiagnostics": diag.pull, "ipa": ipa.build, "adoptProduct": ipa.adopt_product, "downstreamChoice": downstream.set_choice, "install": install.install, "updateGame": install.update_game, "installRemove": install.remove_from_phone, "installRestore": install.restore_previous, "installUpdate": install.update_phone, "installUpdatePrepare": install.update_prepare, "phoneKeptPull": install.phone_kept_pull, "pushSelected": install.push_selected, "installMode": install.install_mode_job, "installCheck": install.readiness, "signingProject": install.signing_project, "installDotnet": toolchain.install_dotnet, "targetDevice": target.probe,
                  "tvInstall": tvos.install_tv, "tvExport": tvos.export_tv, "tvDevices": tvos.devices_job, "tvSaveBackup": tvos.autobackup,   # Apple TV（tvOS 版，pack/jobs/tvos.py）
                  "pushSelected": install.push_selected,
                  "signModeSet": install.sign_mode_set,
                  "layoutSet": install.layout_set,   # 出法：通用 S2Arm / 独立 App（一 App 一游戏，0.6.3）
                  "saveStatus": saves.status, "saveBackup": saves.backup, "saveInspect": saves.inspect, "saveRestore": saves.restore, "savePrevious": save_previous.status, "saveRestorePrevious": save_previous.restore,
                  "community": community.listing, "communitySave": community.save, "patchMatch": patches.match, "sgradeScan": sgrade.scan, "sgradeUpgradeGame": sgrade.upgrade_one, "sgradeUpgradeBatch": sgrade.upgrade_batch, "sgradeUpgradeStop": sgrade.upgrade_stop, "sgradeUpgradeStatus": sgrade.upgrade_status, "updateHints": host_update.update_hints, "phoneOverview": host_update.phone_overview, "sgradeMac": sgrade.mac_all, "sgradeReenable": sgrade.reenable, "devCert": devcert.operation, "export": export_plan.export,
                  "android": android_export.build_job, "androidDevices": android_export.devices_job}
    if operation_overrides:
        operations.update(operation_overrides)
    try:
        if c.operation not in operations:
            raise Failure("不支持的任务类型。")
        if c.operation == "import" and c.r.get("partialResults") is True:   # 默认路径不带 sources（结果与任务记录同 #124 之前）
            c.import_result = library.initial_import_result(c)
        if c.operation not in saves.OPERATIONS and c.operation not in ORCHESTRATION + DEVICE_ONLY:
            embedded.install(c)
        if c.operation not in NO_LIBRARY:
            layout.ensure(c)   # 旧布局的库先一次性整理成新结构（layout.py），之后各作业只按新布局找路径
        if c.operation in AUTO_HEAVY or c.operation in LOW_PRIORITY:
            background_priority()
        with c.lock("auto-heavy", wait=AUTO_HEAVY_WAIT_S) if c.operation in AUTO_HEAVY else contextlib.nullcontext(), \
                awake.keep_awake() if c.operation in KEEP_AWAKE else contextlib.nullcontext():
            result = operations[c.operation](c)
        if c.operation in HEAL_AFTER:
            # 英文名可能刚拿到（导入读 NACP、出包解出 control.nacp）：锁已放，空闲就把还叫游戏号的文件夹改名（剃刀 H3）。
            #   改名只是好看，出错不把已完成的任务变成失败，原文进标准错误（随任务日志）
            try:
                layout.heal_folder_names(c)
            except (OSError, ValueError) as error:
                print(f"[s2a] 游戏文件夹改英文名没做成，下次导入 / 出包再试：{error}", file=sys.stderr, flush=True)
        # A completed save-directory swap is the commit point. A later cancel
        # signal cannot turn a committed restore into a misleading cancelled job.
        if not (c.operation == "saveRestore" and result.get("committed")):
            c.check()
        ended.set()
        c.finish("completed", "操作完成", result)
        # The operation is done, but a job whose record never reached the disk must not come back as success (J10)
        return 0 if not getattr(c, "journal_broken", False) else 1
    except Paused as pause:   # 出包编排磁盘满停下：独立终态，不算完成也不算失败（剃刀 H13）
        ended.set()
        c.finish("paused", str(pause), pause.result)
        return 0 if not getattr(c, "journal_broken", False) else 1
    except (Cancelled, KeyboardInterrupt):
        ended.set()
        return _finish_cancelled(c)
    except Exception as error:
        ended.set()
        if not isinstance(error, Failure) or c.last_log is None:
            log = c.logs / (c.task + "-exception.log")
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(c.redact(traceback.format_exc()))
            c.last_log = log
        # 取消（SIGTERM / 启动器没了）会把正在跑的工具一起停掉，工具因此报的错只是取消的后果，照取消收尾。否则 report_failure →
        #   diagnostic → emit 先查取消标志，在这个异常处理里再抛 Cancelled：作业带着回溯退出、没有终态事件也不是 130，
        #   前端只能报「工作进程已退出」（11-12 Mac 出包页设备探测：xcrun 被 TERM，退出码 -15）。原错误已在上面的日志里
        if c.cancelled:
            return _finish_cancelled(c)
        kept = len(c.job["diagnostics"])
        try:
            diagnostic = c.report_failure(error)
        except Cancelled:   # 取消恰好落在写错误摘要的当口：摘要没发出去，不带进取消的终态
            del c.job["diagnostics"][kept:]
            return _finish_cancelled(c)
        message = diagnostic["summary"]
        integrity_note(c)
        if c.operation in CLEANS_AFTER_STOP:   # 错误摘要要读产物根里的日志，所以排在它后面
            library.clean_after_stop(c)
        c.finish("failed", message, partial_import_result(c) or app_installed_result(c))
        return 1
    finally:
        ended.set()
        _drop_job_tmp(c)


def integrity_note(c):
    """出包 / 起局等带游戏号的作业失败时：这款导入时有内容跳过了完整性校验 → 补一条 warning 级诊断（维护者 11-17：免得难查）。
    读不到游戏库或不是游戏作业就不补，不让补充说明本身把失败收尾弄坏"""
    gid = c.r.get("gameId")
    if not gid:
        return
    try:
        game = next((g for g in c.catalog()["games"] if g["id"] == gid), None)
        if library.integrity_skipped(game):
            c.diagnostic(library.SOURCE_INTEGRITY_FAILED_NOTE, code="source_integrity_skipped", severity="warning")
        # 出包时资源包核对没对上（pack/verify.py 改黄后照常出包，原因落 <包目录>.verify_warn.txt；全对时它会删掉旧的）：现行产物根里还留着就补一句
        roots = (layout.current_root(c, p) for p in layout.build_dir(c, gid, create=False).glob("*/roots/*" + layout.CURRENT))
        if any(r is not None and any(r.glob("pkg/*.verify_warn.txt")) for r in roots):
            c.diagnostic(PACK_VERIFY_NOTE, code="source_integrity_skipped", severity="warning")
    except (Failure, OSError, ValueError, KeyError, TypeError):
        pass


PACK_VERIFY_NOTE = "之前出包时这款的资源包核对没对上（包里有文件和原件不一致），这次失败可能与此有关；重新出包一次再试。"


def _finish_cancelled(c):
    # 一局被停是玩家自己关游戏，不是「任务取消」（11-07 新前端验收）
    # 下载 Xcode 组件的传输由系统资产服务持有：停掉本进程只是不再等，传输可能还在继续（实测 11-08：取消后 Xcode 仍在下载）
    waiting = c.operation in ("downloadIosPlatform", "downloadMetal")
    if c.operation in CLEANS_AFTER_STOP:
        library.clean_after_stop(c)
    c.finish("cancelled", "游戏已停止。" if c.operation == "launch" else
             "已停止等待：Xcode 的下载可能仍在继续（可在 Xcode → 设置 → Components 里查看）。" if waiting else
             "任务已取消；上次成功的运行版本和存档已保留。", partial_import_result(c))
    return 130


def _drop_job_tmp(c):
    """作业临时目录（Context.env 设的 S2A_JOB_TMP）随作业结束删掉；删不掉留给下次清 temp/"""
    gid = c.r.get("gameId")
    if gid and c.r.get("library"):
        try:
            import shutil
            shutil.rmtree(layout.job_tmp(c, gid, c.task), ignore_errors=True)
        except Exception:   # noqa: BLE001 —— 收尾不影响作业结果
            pass


CLEANS_AFTER_STOP = ("build", "ipa")
# 打开启动器时自动起的后台重活（#1439 / #1442 / #1443）：installUpdatePrepare（有手机要更新就预出包）、sgradeMac（S 级规则变了重出）。
#   两件同时跑时各按整机开满路数，玩家的 Mac 内存耗尽 panic。这两项只由启动器自动发起（S2ArmLauncherModel / +PhoneBanner），按作业名就能认：
#   互相串行（游戏库里一把「auto-heavy」锁，后到的排队、显示在等谁、能取消），整条链低优先级（nice 19 子进程继承；macOS 再加后台档），不和玩家抢机器
AUTO_HEAVY = ("installUpdatePrepare",)   # sgradeMac 11-17 起不自动（玩家点了才做单款，sgrade.upgrade_game），不再算后台重活
AUTO_HEAVY_WAIT_S = 6 * 3600
# 玩家点的 S 级升级（批量 / 单款同一个队列入口，sgrade.upgrade_batch；同一时刻只升一款）：不算自动任务（不拿 auto-heavy 锁、启动器照常算玩家发起），
#   但同样整条链降到后台档——11-17 维护者「做好线程管理和内存管理，不要一次批量升级就把用户电脑干爆了」；路数另按 upgrade_budget 定
LOW_PRIORITY = ("sgradeUpgradeGame", "sgradeUpgradeBatch")


def background_priority():
    """本进程（及之后起的子进程）降到最低优先级：nice 19；macOS 再设后台档（PRIO_DARWIN_BG：CPU / 磁盘都让前台）；
    Windows 设空闲优先级类（IDLE_PRIORITY_CLASS，之后起的子进程继承）。做不成不挡作业"""
    try:
        if sys.platform == "win32":
            import ctypes
            ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x40)   # IDLE_PRIORITY_CLASS
        if hasattr(os, "nice"):
            os.nice(max(0, 19 - os.nice(0)))
        if hasattr(os, "PRIO_DARWIN_BG"):
            os.setpriority(os.PRIO_DARWIN_PROCESS, 0, os.PRIO_DARWIN_BG)
    except OSError as error:
        print(f"[s2a] 自动任务降优先级没做成，照常跑：{error}", file=sys.stderr, flush=True)


KEEP_AWAKE = ("build", "ipa", "android", "install", "installUpdate", "installRestore", "exportPush", "tvInstall", "tvExport")   # 出包 / 推送期间电脑不空闲休眠（awake.py；v0.3.1 玩家推大包被休眠打断成「传输中断」）
HEAL_AFTER = ("import", "build", "ipa")   # 结束时顺手把还叫游戏号的文件夹改英文名（layout.heal_folder_names）
ORCHESTRATION = ("export",)   # 只起子作业的编排：引擎副本、游戏库结构由每一步的子作业自己核（剃刀 H13）
DEVICE_ONLY = ("androidDevices",)   # 只问已连接设备（adb），不碰引擎副本与游戏库
NO_LIBRARY = ORCHESTRATION + DEVICE_ONLY + ("preflight", "prepareEngine", "downloadMetal", "downloadIosPlatform", "installDotnet", "targetDevice", "setup", "signingProject", "devCert", "appleLogin", "appleAccount")


def parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command")
    run = sub.add_parser("run", help="run one request")
    run.add_argument("--request", required=True)
    for name, help_text in (("get", "print the journal of one task"), ("cancel", "signal the worker this task recorded")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--private-root", required=True)
        p.add_argument("--task", required=True)
        if name == "cancel":
            p.add_argument("--signal", default="TERM", choices=("TERM", "KILL"))
    report_parser = sub.add_parser("report", help="print the error summary of one failed task, or of the newest failed task")
    report_parser.add_argument("--private-root", required=True)
    report_parser.add_argument("--task")
    report_parser.add_argument("--game")
    report_parser.add_argument("--operations", help="comma separated")
    resume = sub.add_parser("resume", help="run the same task again from its journal (a killed attempt's stages are skipped by their own keys)")
    resume.add_argument("--private-root", required=True)
    resume.add_argument("--task", required=True)
    resume.add_argument("--force", action="store_true", help="re-run even when the task already has a terminal state")
    resume.add_argument("--dry-run", action="store_true", help="print what a resume would do, without running it")
    status_parser = sub.add_parser("status", help="counts and size of the whole job store")
    status_parser.add_argument("--private-root", required=True)
    pruner = sub.add_parser("prune", help="drop old finished job records (core.prune_jobs: total and age caps, per-operation floors; running ones are kept)")
    pruner.add_argument("--private-root", required=True)
    pruner.add_argument("--keep-days", type=float, default=KEEP_DAYS)
    pruner.add_argument("--keep-count", type=int, default=KEEP_TOTAL)
    pruner.add_argument("--per-operation", type=int, default=KEEP_PER_OPERATION, help="newest finished records kept per operation regardless of the caps")
    pruner.add_argument("--failed-per-operation", type=int, default=KEEP_FAILED_PER_OPERATION, help="newest failed / cancelled records kept per operation")
    pruner.add_argument("--dry-run", action="store_true")
    events = sub.add_parser("events", help="print the NDJSON events of one task")
    events.add_argument("--private-root", required=True)
    events.add_argument("--task", required=True)
    events.add_argument("--since", type=int, default=0, help="skip the first N events")
    events.add_argument("--limit", type=int, default=0, help="print at most N events (0 = all)")
    return ap


def cli(argv, *, context_class=Context, operation_overrides=None):
    if not argv or argv[0].startswith("-"):
        argv = ["run"] + list(argv)   # the Mac launcher passes only --request; keep that call working
    args = parser().parse_args(argv)
    if args.command == "run":
        return run_request(args.request, context_class=context_class, operation_overrides=operation_overrides)
    if not Path(args.private_root).is_dir():
        print(json.dumps({"error": "私有目录不存在。"}, ensure_ascii=False))
        return 2
    try:
        if args.command == "get":
            print(json.dumps(describe(args.private_root, args.task), ensure_ascii=False))
            return 0
        if args.command == "events":
            for event in read_events(args.private_root, args.task, since=max(0, args.since), limit=(args.limit or None)):
                print(json.dumps(event, ensure_ascii=False))
            return 0
        if args.command == "status":
            print(json.dumps(status(args.private_root), ensure_ascii=False))
            return 0
        if args.command == "prune":
            print(json.dumps(prune_jobs(args.private_root, args.keep_days, args.keep_count, args.dry_run, per_operation=args.per_operation,
                                        failed_per_operation=args.failed_per_operation), ensure_ascii=False))
            return 0
        if args.command == "resume":
            record = journal(args.private_root, args.task)
            if args.dry_run:
                # Report only: what the next attempt would be, and what the journal already knows. Whether a stage is actually skipped is each
                # stage's own product key (.stage_<阶段>), which the job layer does not predict (J10).
                terminal = record.get("state") in TERMINAL_STATES or bool(record.get("ended"))
                print(json.dumps(dict(dryRun=True, wouldResume=bool(args.force) or not terminal, operation=record.get("operation"),
                                      attemptNo=(record.get("attemptNo") or 1) + (0 if terminal and not args.force else 1),
                                      stage=record.get("stage") or "", attempts=record.get("attempts") or {},
                                      note="阶段是否跳过只由各阶段自己的产物键（.stage_<阶段>）决定，job 层不记也不预判"), ensure_ascii=False))  # 非玩家句
                return 0
            if record.get("state") in TERMINAL_STATES and not args.force:
                # Re-running a finished task on purpose is allowed, but a caller that thinks it is resuming must not silently restart it
                print(json.dumps(dict(resumed=False, reason="任务已有终态，需要 --force 才会重跑。", state=record.get("state"),
                                      attempts=record.get("attempts") or {}), ensure_ascii=False))
                return 2
            request = request_path(args.private_root, args.task)
            if not request.is_file():
                print(json.dumps(dict(resumed=False, reason="这条任务没有留下请求记录，无法续跑。", code="job_no_request"), ensure_ascii=False))
                return 2
            # 记一行：这次续跑会重跑整条操作，已完成阶段由各阶段自己的产物键跳过（job 层不记也不预判）
            print(json.dumps(dict(resumed=True, attemptNo=(record.get("attemptNo") or 1) + 1,
                                  stage=record.get("stage") or "", attempts=record.get("attempts") or {}), ensure_ascii=False),
                  file=sys.stderr, flush=True)
            return run_request(request, context_class=context_class, operation_overrides=operation_overrides)
        if args.command == "report":
            import report
            return report.main(args.private_root, args.task, args.game, args.operations.split(",") if args.operations else None)
        if args.command == "cancel":
            result = cancel(args.private_root, args.task, args.signal)
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result.get("cancelled") else 2
    except Failure as error:
        print(json.dumps({"error": str(error), "code": getattr(error, "code", "job_failed")}, ensure_ascii=False))
        return 2
    return 2


def main(*, context_class=Context, operation_overrides=None):
    """The launcher's original call shape (`--request` in argv); tests and packaged workers may inject context / operations."""
    return cli(sys.argv[1:], context_class=context_class, operation_overrides=operation_overrides)


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
