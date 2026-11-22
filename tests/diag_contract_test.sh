#!/bin/bash
# 门禁覆盖：tools/diag_contract/* ios/diagcollect.* ios/diagzip.* ios/diagredact.* ios/diag.m pack/jobs/library.py pack/jobs/diag_upload.py android/app/src/main/java/org/s2arm/android/DiagnosticBundlePolicy.java
# 诊断收件契约单测（约 10 秒）：bash tests/diag_contract_test.sh
#   诊断包每一个可能出现的成员都要被收件服务（diag.s2arm.com）收下：收件规则只有一份（tools/diag_contract/diag_contract.json，Worker 用它的逐字节拷贝），
#   发包端新增成员类型而没登记，红在这里，不等上线后玩家整包被拒（11-16 shader_miss/<号>.tar、shaders/<键>.slow.metal 两次事故）。
#   ① 共用用例表 tools/diag_contract/cases.json（Worker 单测跑同一份）过 Python 解释器，期望手写在表里
#   ② iOS：Mac 上编生产同源的 ios/diagcollect.m + diagzip.m + diagredact.m，Documents 夹具每一类都放（含不该收的），真打包，逐个成员过契约
#   ③ Mac / Windows：真跑「上传给开发者」作业（pack/jobs/diag_upload.py → library.diagnostics，本机回环假上传服务收包），夹具每一类都放，逐个成员过契约
#   ④ 安卓：DiagnosticBundlePolicy.java 的允许名单（安卓还没有上传端，不打包）逐个过契约
#   期望（每端应出现的成员清单）按各端收集规则手写；收下的成员一律还要过契约，清单外多出来的也照判
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/main.m" <<'M'
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include "diagcollect.h"
#include "diagzip.h"
#include "diagredact.h"
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 4) return 2;
    NSString *D = @(argv[1]), *W = @(argv[2]);
    [NSFileManager.defaultManager createDirectoryAtPath:[W stringByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *files = [NSMutableArray array], *sessions = [NSMutableArray array]; int crash = 0, hang = 0, exits = 0;
    // 脱敏与生产同源（diagredact.m；生产另把设备名换成占位，要 UIKit，这里不做）；会话摘要只进 manifest、不影响收哪些成员，这里不记
    BOOL ok = s2a_diag_collect(D, W, 8u << 20, NO,
        ^NSString *(NSString *s) { char *c = s2a_diag_redact(s.UTF8String); if (!c) return (NSString *)nil; NSString *r = @(c); free(c); return r; },
        ^NSDictionary *(NSString *p, NSString *n, BOOL cur) { (void)p; (void)n; (void)cur; return (NSDictionary *)nil; },
        files, sessions, &crash, &hang, &exits);
    if (!ok) { fprintf(stderr, "s2a_diag_collect 失败\n"); return 1; }
    // manifest.json 由 diag.m 写（要 UIKit / Bundle）：这里放收件要的最小一份
    [@"{\"schema\": 1}" writeToFile:[W stringByAppendingPathComponent:@"manifest.json"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return s2a_write_zip(W, @(argv[3])) ? 0 : 1;
} }
M
clang -fobjc-arc -O1 -I"$H/ios" -o "$T/collect" "$T/main.m" "$H/ios/diagcollect.m" "$H/ios/diagzip.m" "$H/ios/diagredact.m" -framework Foundation -lz || { echo "✗ iOS 收成员代码在 Mac 上编不过"; exit 1; }
python3 - "$H" "$T" <<'P'
import io, json, os, re, shutil, subprocess, sys, tempfile, unittest, warnings, zipfile
from pathlib import Path
from unittest import mock
H, T = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(H / "tools/diag_contract"))
import diag_contract as dc
contract = dc.load()
fails = 0
def ck(name, ok, detail=""):
    global fails
    fails += not ok
    print(("通 " if ok else "不通 ") + name + (f"：{detail}" if detail else ""))

# ① 共用用例表（只存不压的包：「压缩后超 30 MB」一例要真有 30 MB）
def build(case):
    out = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")   # 「重名」一例故意写两遍同名
        with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
            if case.get("manifest", '{"schema": 1}') is not None:
                z.writestr("manifest.json", case.get("manifest", '{"schema": 1}'))
            for f in case["files"]:
                for i in range(f.get("n", 1)):
                    zi = zipfile.ZipInfo(f["name"].replace("{i}", str(i)))
                    if f.get("link"):
                        zi.external_attr = 0o120777 << 16
                    zi.flag_bits |= 0x800
                    z.writestr(zi, f["text"] if "text" in f else b"x" * f["size"])
    return out.getvalue()
cases = json.loads((H / "tools/diag_contract/cases.json").read_text(encoding="utf-8"))["cases"]
wrong = []
for case in cases:
    bad, _ = dc.check_zip(build(case), contract)
    got = bad[0][0] if bad else "ok"
    if got != case["want"]:
        wrong.append(f"{case['what']}：期望 {case['want']} → 实际 {got}")
ck(f"① 共用用例表 {len(cases)} 例与手写期望一致", not wrong, "；".join(wrong))

def judge_zip(side, data, want):
    """一端真打出来的包：整包收下、清单里的每一类都在（射程：扫了几个成员）"""
    bad, kept = dc.check_zip(data, contract)
    names = {n for n, _ in kept} | {n for _, n, _ in bad if n}
    for code, n, why in bad:
        print(f"    ✗ {side} 打出的成员被收件拒：{n or '（整包）'} → {code}（{why}）")
    ck(f"{side}：真打的包 {len(names)} 个成员全部被收件契约收下", not bad, f"规则命中 {sorted({r for _, r in kept})}")
    missing = sorted(set(want) - names)
    ck(f"{side}：手写清单 {len(want)} 个成员都打进了包（夹具每一类都在，判据没空转）", not missing, "缺 " + "、".join(missing) if missing else "")

# ② iOS：Documents 夹具（ios/diagcollect.m 的收集规则：日志 / 表 / MetricKit / 着色器现场 / 诊断局 / 管线记录 / 补料；多款容器 games/<号>/ 与单款包 wire/<号>/ 两处）
D = T / "ios_docs"
def put(rel, data=b"x\n"):
    p = D / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data if isinstance(data, bytes) else data.encode())
A, B = "0100000000010000", "0400486024DEC000"
for rel in ("host.log", "logs/host-20261116-120000.log", "logs/host-20261115-090000.log", "frames.tsv", "threads.txt", "unpack.log", "far_sites.tsv",
            f"games/{A}/unpack.log", "metrickit/crash-1.json", "metrickit/hang-2.json", "metrickit/x-exit.json", "metrickit/note.txt",
            f"games/{A}/wire/{A}/shaders/aaaaaaaaaaaaaaaa.inflight.ctl", f"games/{A}/wire/{A}/shaders/aaaaaaaaaaaaaaaa.inflight.code",
            f"games/{A}/wire/{A}/shaders/bbbbbbbbbbbbbbbb.fail.ctl", f"games/{A}/wire/{A}/shaders/bbbbbbbbbbbbbbbb.fail.code",
            f"games/{A}/wire/{A}/shaders/cccccccccccccccc_b.slow.metal", f"games/{A}/wire/{A}/shaders/other.bin", f"wire/{B}/shaders/dddddddddddddddd_b.slow.metal",
            "diagrun/shot.png", f"games/{A}/diagrun/frame.PNG", f"games/{A}/diagrun/notes.txt",
            f"games/{A}/wire/{A}/pso_user.tsv", f"wire/{B}/pso_user.tsv",
            f"games/{A}/wire/{A}/shader_miss/index.tsv", f"games/{A}/wire/{A}/shader_miss/0123456789abcdef.ctl", f"games/{A}/wire/{A}/shader_miss/0123456789abcdef.code",
            f"wire/{B}/shader_miss/index.tsv", f"wire/{B}/shader_miss/fedcba9876543210.ctl", f"wire/{B}/shader_miss/fedcba9876543210.code"):
    put(rel)
# 远端缺页点表（runtime/src/far.c 的格式）：Documents 根下一份（单款包）、多款容器每款文档根下一份（原先漏收）；包里各留前 200 个点
FAR = "# 模块\t偏移\t次数\t类别\t代执行失败\nmain\t0x10\t5\t1\t0\n"
put("far_sites.tsv", FAR); put(f"games/{A}/far_sites.tsv", FAR)
# 超长慢管线源：真经 diagcollect.m 截到 4 MB 并插截断标记，成品略超 4 MB（v0.4.3 起客户端实发，11-16 曾被收件整包拒）
put(f"games/{A}/wire/{A}/shaders/cccccccccccccccc_b.slow.metal", ("// msl line\n" * 500000).encode())
ios_want = ["manifest.json", "logs/host.log", "logs/host-20261116-120000.log", "logs/host-20261115-090000.log", "logs/frames.tsv", "logs/threads.txt",
            "logs/unpack.log", "logs/far_sites.tsv", f"logs/far_sites_{A}.tsv", f"logs/unpack_{A}.log", "metrickit/crash-1.json", "metrickit/hang-2.json", "metrickit/x-exit.json",
            f"shaders/{A}_aaaaaaaaaaaaaaaa.inflight.ctl", f"shaders/{A}_aaaaaaaaaaaaaaaa.inflight.code", f"shaders/{A}_bbbbbbbbbbbbbbbb.fail.ctl",
            f"shaders/{A}_bbbbbbbbbbbbbbbb.fail.code", f"shaders/{A}_cccccccccccccccc_b.slow.metal", f"shaders/{B}_dddddddddddddddd_b.slow.metal",
            "diagrun/app_shot.png", f"diagrun/{A}_frame.PNG", f"pso/{A}.tsv", f"pso/{B}.tsv", f"shader_miss/{A}.tar", f"shader_miss/{B}.tar"]
# 往局日志里一行被按字节截在汉字中间（宿主直连层统计行截进定长缓冲，现场「写回原\xe5\x80」）：原先一个坏字节就让整份按 Latin-1 解、中文全成二次编码乱码。
#   期望（手写）：别的行逐字节不变，坏的那截换成一个 U+FFFD
cn_ok1, cn_bad, cn_ok2 = "[s2a] 开发设施：关（玩家口径）\n".encode(), b"[dm] \xe5\x86\x99\xe5\x9b\x9e\xe5\x8e\x9f\xe5\x80\n", "[s2a] 地址窗口：多款容器 要 70124 MB\n".encode()
put("logs/host-20261115-090000.log", cn_ok1 + cn_bad + cn_ok2)
r = subprocess.run([str(T / "collect"), str(D), str(T / "ios_work"), str(T / "ios.zip")], capture_output=True, text=True)
ck("② iOS 收成员 + 写 zip 成功", r.returncode == 0, r.stderr.strip())
if r.returncode == 0:
    judge_zip("② iOS（ios/diagcollect.m）", (T / "ios.zip").read_bytes(), ios_want)
    with zipfile.ZipFile(T / "ios.zip") as z:
        got_cn = z.read("logs/host-20261115-090000.log")
    ck("② 中文日志带一处截断的半个汉字：其余行逐字节不变、坏的那截换成一个 U+FFFD（不再整份二次编码）",
       got_cn == cn_ok1 + "[dm] 写回原\ufffd\n".encode() + cn_ok2, repr(got_cn[:160]))

# ③ Mac / Windows：真跑上传作业，本机回环假服务收包（同 pack/jobs/tests/test_diag_upload.py 的做法，不联外网）
sys.path.insert(0, str(H / "pack/jobs/tests")); sys.path.insert(0, str(H / "pack/jobs"))
import http.server, threading
from jobcase import JobCase   # 私有目录 / 游戏库在临时目录；本机崩溃报告目录、系统应用登记都换成临时 / 不存在的
from core import atomic
import diag_upload, layout, library
got = []
class Svc(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        got.append(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"code": "D-7K3Q"}')
    def log_message(self, *a):
        pass
mac_want = ["manifest.json", "jobs/setup.txt", "logs/launcher.log", "logs/sub/deep.log", "logs/long-session.log", "logs/error-summary.log",
            "phone/host.log", "phone/frames.tsv", "phone/threads.txt", "phone/logs/host-20261116-120000.log", "phone/diag/run.json",
            "phone/metrickit/m.json", "phone/crash.ips", "phone/table.csv", "phone/notes.txt", "phone/shot.png",
            f"diagrun/{A}_shot.png", f"pso/{A}.tsv", f"shader_miss/{A}.tar"]
if sys.platform == "darwin":
    mac_want.append("mac_crash/S2Arm-2026-11-16-120000.ips")
class Mac(JobCase):
    def runTest(self):
        private = Path(tempfile.mkdtemp(prefix="t-diag-contract-")); self.addCleanup(shutil.rmtree, private, True)
        p = mock.patch.object(tempfile, "tempdir", str(private)); p.start(); self.addCleanup(p.stop)
        c = self.c
        for rel in ("launcher.log", "sub/deep.log", "notes.txt"):
            f = c.logs / rel; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("x\n")
        # 超长日志（长局 Mac 实际会有）：真经 library.diagnostics 截成头尾 + 中间心跳，成员要在收件单个成员上限内（11-16 原上限 200 MB 时整包被拒）
        big = c.logs / "long-session.log"; big.write_bytes(("[s2a] [心跳] 帧 1，热状态 0\n" + "[帧] 第 1 帧 数据 " + "y" * 200 + "\n" * 1) .encode() * 90000)
        pull = c.private / "diagnostics" / "20261116-120000-iphone"
        for rel in ("host.log", "frames.tsv", "threads.txt", "logs/host-20261116-120000.log", "diag/run.json", "metrickit/m.json", "crash.ips",
                    "table.csv", "notes.txt", "shot.png", "other.bin", "S2Arm-diag.zip"):
            f = pull / rel; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(b"x\n")
        (pull / "pull.json").write_text('{"pulledAt": "2026-11-16 12:00:00 +0800"}')
        crash = library.MAC_CRASH_DIR; crash.mkdir(parents=True, exist_ok=True); (crash / "S2Arm-2026-11-16-120000.ips").write_text("{}\n")
        atomic(c.library / "catalog.json", dict(schema=1, games=[dict(id=A, name="Alpha", packages=[])]))
        run = layout.game_dir(c, A, english="Alpha") / "diagrun"; run.mkdir(parents=True); (run / "shot.png").write_bytes(b"\x89PNG")
        wire = c.library / "temp" / A / "wire" / A; (wire / "shader_miss").mkdir(parents=True)
        (wire / "pso_user.tsv").write_text("S\t0123456789abcdef_b\t1\n")
        for n in ("index.tsv", "0123456789abcdef.ctl", "0123456789abcdef.code"):
            (wire / "shader_miss" / n).write_bytes(b"x")
        c.r["summary"] = "环境检查没过：示例摘要"   # 没有作业记录的失败：界面交来的摘要放进 logs/error-summary.log
        srv = http.server.HTTPServer(("127.0.0.1", 0), Svc); threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": f"http://127.0.0.1:{srv.server_port}/v1/upload"}):
                self.result = diag_upload.upload(c)
        finally:
            srv.shutdown(); srv.server_close()
case = Mac(); res = unittest.TestResult(); case.run(res)
problems = [t for _, t in res.errors + res.failures]
ck("③ Mac / Windows 上传作业跑完、假服务收到一份包", not problems and len(got) == 1, (problems[0][-600:] if problems else f"收到 {len(got)} 份"))
if got:
    judge_zip("③ Mac / Windows（pack/jobs/library.py diagnostics + diag_upload）", got[0], mac_want)
# 电脑端单份日志上限与收件单个成员上限的关系（期望手写：上限 + 中间心跳 / 现场段 + 每 1 MB 留 1/4 的脱敏与非法字节替换余量 ≤ member_bytes）
cap = library.DIAGNOSTIC_LOG_LIMIT + library.DIAGNOSTIC_LOG_BEATS + library.DIAGNOSTIC_LOG_SCENE + 4096
ck("③ 电脑端单份日志上限留够余量、截后成品不会超收件单个成员上限", cap + library.DIAGNOSTIC_LOG_LIMIT // 4 <= contract["limits"]["member_bytes"],
   f"日志上限 {library.DIAGNOSTIC_LOG_LIMIT} + 中间段 {cap - library.DIAGNOSTIC_LOG_LIMIT} + 余量 {library.DIAGNOSTIC_LOG_LIMIT // 4} 对 member_bytes {contract['limits']['member_bytes']}")
# 电脑端整包预算与收件整包上限的关系（期望手写：预算 + 1 MB 的 manifest / zip 目录余量 ≤ zip_bytes；预算放得太宽，整包又会被拒）
ck("③b 电脑端诊断包整包预算留出 manifest 余量后不超收件整包上限", library.DIAGNOSTIC_ZIP_BUDGET + (1 << 20) <= contract["limits"]["zip_bytes"],
   f"预算 {library.DIAGNOSTIC_ZIP_BUDGET} + 余量 {1 << 20} 对 zip_bytes {contract['limits']['zip_bytes']}")

# ④ 安卓：DiagnosticBundlePolicy.validate 的允许名单（还没有上传端，不打包）：字面量全名 + 归档日志正则的两个样例，逐个过契约
src = (H / "android/app/src/main/java/org/s2arm/android/DiagnosticBundlePolicy.java").read_text(encoding="utf-8")
lits = re.findall(r'"(manifest\.json|logs/[A-Za-z0-9_.-]+)"', src)
# 每条名字正则（归档日志、设备档案 devprofile/<事实摘要前 16 位>.json）都要有手写样例认得它，样例再逐个过契约
pats = [p.replace("\\\\", "\\") for p in re.findall(r'name\.matches\("([^"]+)"\)', src)]
samples = ["logs/host-20261116-120000.log", "logs/host-20261116-120000_02.log", "devprofile/0123456789abcdef.json"]
ck("④ 安卓每条名字正则都有手写样例认得、每个样例都有正则认得", len(pats) == 2 and all(any(re.fullmatch(p, n) for n in samples) for p in pats)
   and all(any(re.fullmatch(p, n) for p in pats) for n in samples), "、".join(pats))
names = sorted(set(lits)) + samples
want = {"manifest.json", "logs/host.log", "logs/frames.tsv", "logs/threads.txt", "logs/unpack.log"}
rej = [n for n in names if dc.judge(contract, n, 1, {})[1]]
ck(f"④ 安卓允许名单 {len(names)} 个成员名全部被收件契约收下", want <= set(names) and not rej, ("拒：" + "、".join(rej)) if rej else "、".join(names))
print("诊断收件契约单测" + ("全过" if not fails else f"：{fails} 项不通"))
sys.exit(1 if fails else 0)
P
