#!/usr/bin/env python3
# 门禁手动：清单生成器，维护者在宿主 / 前端代码让上屏矩阵构建核对报红时手跑；要编全部候选并多次重链，不进门禁（门禁跑的是按清单构建与三项核对）
"""生成 t_present_settings 的链接清单（graphics/nvn/tests/t_present_settings.link.txt）：上屏设置矩阵真正链进去的宿主源文件闭包。
在仓库根跑：python3 graphics/nvn/tests/t_present_settings_closure.py [--check]
  --check 只算、和现有清单比，不写；不同退出 1

为什么：上屏设置矩阵原先整目录编 runtime/src、再并上 Mac 前端全部源文件，门禁把这整份当输入，宿主几乎每笔改动都换键重跑
（独占显卡，单次两分多钟）。产物只取决于真链进去的目标文件，所以清单 = 链接器实算的闭包，构建与门禁同读这一份。

怎么算（候选 = 原先编的全集：runtime/src/*.c *.S 除 host_main.c、platform/apple/plat_apple.c、graphics/track/*.c、Mac 前端源文件）：
  1. 用 t_present_settings.sh 生成模式把候选全编、全链一遍（全量链接 = 原先的产物，作对照）。
  2. 带构造函数 / ObjC 类与类别表的候选直接当根（它们没被引用也会跑），其余打成静态库，按同一条链接行链：链接器只拉解析引用要的成员。
  3. 三条补根，循环到不动：
     a. 全量里某个符号由候选 X 提供、闭包里换了提供者（库里的弱兜底定义）或没了 → X 进根；
     b. 闭包程序里的字符串点到候选 X 定义的全局符号（dlsym(RTLD_DEFAULT, "…") 这类运行期自查）→ X 进根；
     c. 闭包程序比全量多出运行期查找（dynamically looked up）的符号 → 提供它的候选进根。
  4. 清单 = 闭包源文件 + 它们与 t_present_settings.m 编译实读的仓库头文件（-MD）+ 链进来的静态库成员的源文件与实读头文件（lib 行，DWARF 行号表；
     门禁输入用，11-26 #2242 改 libnvn 成员没触发本测）+ 闭包程序的运行期查找符号（dyn 行，构建核对用）。
  5. 用正式模式按新清单重建一遍：链接、头文件核对、运行期查找核对都过，且与全量的提供者对照一致，才写。"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.getcwd()
TESTS = os.path.join(ROOT, "graphics/nvn/tests")
LIST = os.path.join(TESTS, "t_present_settings.link.txt")
sys.path.insert(0, TESTS)
import t_present_settings as tps  # noqa: E402

OUT = os.path.join(ROOT, "build/tests/present-settings-closure")
ROOT_SECTS = ("__mod_init_func", "__init_offsets", "__objc_classlist", "__objc_catlist", "__objc_nlclslist", "__objc_nlcatlist")


def sh(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"【红】{' '.join(cmd[:4])} … 失败：\n{(r.stdout + r.stderr)[-3000:]}")
    return r.stdout


def candidates():
    mk = "_ps_front:;@echo $(HOST_SRCS)\n"
    front = sh(["make", "-s", "-f", "launchers/macos/build.mk", "-f", "-", "_ps_front", "S2A_MAC_FRONTEND=1"], input=mk).split()
    if not front:
        sys.exit("【红】Mac 前端源文件清单为空")
    rt = sorted(f for f in os.listdir("runtime/src") if f.endswith((".c", ".S")) and f != "host_main.c")
    return [f"runtime/src/{f}" for f in rt] + ["platform/apple/plat_apple.c", "graphics/track/track.c", "graphics/track/glue.c"] + front


def obj_of(out, rel):
    return os.path.join(out, "host", rel.replace("/", "_") + ".o")


def build(out, lst, gen):
    env = dict(os.environ, PRESENT_SETTINGS_BUILD=out, PRESENT_SETTINGS_LIST=lst, PRESENT_SETTINGS_BUILD_ONLY="1", PRESENT_SETTINGS_GEN="1" if gen else "0")
    env.pop("PRESENT_WIDEN_LIB", None)
    r = subprocess.run(["bash", os.path.join(TESTS, "t_present_settings.sh")], env=env, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def link_args(out):
    return [a for a in open(os.path.join(out, "link.args0"), "rb").read().decode().split("\0") if a]


def relink(args, host_objs, replace, exe, mapf, extra=()):
    """同一条链接行：宿主目标文件换成 replace，输出到 exe，带链接映射"""
    a, done = [], False
    for x in args:
        if x in host_objs:
            if not done:
                a += replace; done = True
            continue
        a.append(x)
    i = a.index("-o")
    a[i + 1] = exe
    r = subprocess.run(a + ["-Wl,-map," + mapf, *extra], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def read_map(mapf):
    """链接映射 → (载入的目标文件路径集合, 符号名 → 提供它的目标文件路径集合)（只看活符号，不看「Dead Stripped Symbols」段）"""
    objs, prov, sect = {}, {}, None
    for line in open(mapf, encoding="utf-8", errors="replace"):
        if line.startswith("# Object files:"):
            sect = "o"; continue
        if line.startswith("# Sections:"):
            sect = None; continue
        if line.startswith("# Symbols:"):
            sect = "s"; continue
        if line.startswith("# Dead Stripped Symbols:"):
            break
        if sect == "o":
            m = re.match(r"\[\s*(\d+)\]\s+(.*)$", line.rstrip("\n"))
            if m:
                objs[m.group(1)] = m.group(2)
        elif sect == "s":
            m = re.match(r"0x[0-9A-Fa-f]+\s+0x[0-9A-Fa-f]+\s+\[\s*(\d+)\]\s+(\S+)", line)
            if m:
                prov.setdefault(m.group(2), set()).add(objs.get(m.group(1), "?"))
    return set(objs.values()), prov


def member(path):
    """映射里的「库.a(成员)」或目标文件路径 → 候选目标文件路径（库成员按成员名回到 host/ 目录）"""
    m = re.match(r"(.*)\((.+)\)$", path)
    return os.path.join(OUT, "host", m.group(2)) if m and m.group(1).endswith("cand.a") else path


def global_defs(objs):
    out = {}
    for o in objs:
        for line in sh(["nm", "-gU", o]).splitlines():
            p = line.split()
            if len(p) == 3:
                out.setdefault(p[2], set()).add(o)
    return out


def has_root_sect(o):
    t = sh(["otool", "-l", o])
    return any(f"sectname {s}" in t for s in ROOT_SECTS)


def strings(exe):
    return set(sh(["strings", "-a", exe]).split("\n"))


def main(argv):
    check = "--check" in argv
    cands = candidates()
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="ps_closure.")
    try:
        all_list = os.path.join(tmp, "all.srcs")
        open(all_list, "w").write("".join(f"src {c}\n" for c in cands))
        rc, log = build(OUT, all_list, gen=True)
        if rc:
            sys.exit(f"【红】候选全集构建失败：\n{log[-3000:]}")
        args = link_args(OUT)
        objof = {obj_of(OUT, c): c for c in cands}
        host_objs = set(objof)
        full_exe, full_map = os.path.join(tmp, "full"), os.path.join(tmp, "full.map")
        rc, log = relink(args, host_objs, sorted(host_objs), full_exe, full_map)
        if rc:
            sys.exit(f"【红】全量对照链接失败：\n{log[-3000:]}")
        _, full_prov = read_map(full_map)
        full_dyn = tps.dynamic(full_exe)
        gdefs = global_defs(host_objs)
        roots = {o for o in host_objs if has_root_sect(o)}
        why = {o: "构造函数 / ObjC 元数据" for o in roots}
        rounds = 0
        while True:
            rounds += 1
            arch = os.path.join(OUT, "cand.a")
            if os.path.exists(arch):
                os.unlink(arch)
            rest = sorted(host_objs - roots)
            if rest:
                sh(["ar", "-rcs", arch, *rest])
            exe, mapf = os.path.join(tmp, "narrow"), os.path.join(tmp, "narrow.map")
            rc, log = relink(args, host_objs, sorted(roots) + ([arch] if rest else []), exe, mapf)
            if rc:
                sys.exit(f"【红】闭包链接失败（第 {rounds} 轮）：\n{log[-3000:]}")
            loaded, prov = read_map(mapf)
            loaded = {member(p) for p in loaded} & host_objs
            add = {}
            for name, ps in prov.items():   # a. 全量里由候选全局定义的符号，闭包里那个候选没载入（只认全局名：静态函数 / 字面量同名不算）
                for p in full_prov.get(name, set()) & gdefs.get(name, set()):
                    if p not in loaded:
                        add.setdefault(p, f"提供 {name}（闭包里换成了 {' '.join(sorted(ps))}）")
            strs = strings(exe)
            for name, os_ in gdefs.items():   # b. 字符串点名
                if name.startswith("_") and name[1:] in strs:
                    for o in os_ - loaded:
                        add.setdefault(o, f"程序里的字符串点名 {name[1:]}（运行期自查）")
            for name in tps.dynamic(exe) - full_dyn:   # c. 多出运行期查找
                for o in gdefs.get(name, set()) - loaded:
                    add.setdefault(o, f"提供 {name}（闭包里成了运行期查找）")
            if not add:
                break
            for o, w in add.items():
                roots.add(o); why[o] = w
            if rounds > 30:
                sys.exit("【红】闭包 30 轮不收敛")
        closure = sorted(objof[o] for o in loaded | roots)
        hdrs = set()
        for rel in closure + ["graphics/nvn/tests/t_present_settings.m"]:
            d = (obj_of(OUT, rel) if rel in cands else os.path.join(OUT, "host", "t_present_settings.m.o")) + ".d"
            for p in tps.deps(d):
                rp = os.path.realpath(p if os.path.isabs(p) else os.path.join(ROOT, p))
                if rp.startswith(os.path.realpath(ROOT) + "/"):
                    rel2 = rp[len(os.path.realpath(ROOT)) + 1:]
                    if not rel2.startswith("build/") and rel2 not in closure and rel2 != tps.MAIN:
                        hdrs.add(rel2)
        libs = [a for a in args if os.path.basename(a) in ("libnvn.a", "libnxgal.a", "libdsx.a")]
        lfiles, blind = tps.pulled_files(mapf, ROOT, libs)
        if blind:
            sys.exit(f"【红】链进来的库成员对不上源文件，lib 行算不出：{' '.join(blind[:10])}")
        libl = sorted(lfiles - set(closure) - hdrs - {tps.MAIN})
        dyn = sorted(tps.dynamic(exe))
        body = ["# 上屏设置矩阵的链接清单：由 graphics/nvn/tests/t_present_settings_closure.py 按链接器实算生成，不要手改（改了也会被构建核对拦住）。",
                "# 构建（t_present_settings.sh）只编、只链 src 行；门禁按本清单的路径算 present_settings_test / present_settings_env_test 的输入。",
                f"# 候选 {len(cands)} 个源文件，闭包 {len(closure)} 个。"]
        body += [f"src {c}" for c in closure] + [f"hdr {h}" for h in sorted(hdrs)] + [f"lib {x}" for x in libl] + [f"dyn {s}" for s in dyn]
        text = "\n".join(body) + "\n"
        print(f"候选 {len(cands)} → 闭包 {len(closure)} 个源文件（{rounds} 轮），头文件 {len(hdrs)}，库成员文件 {len(libl)}，运行期查找 {len(dyn)}")
        for o in sorted(roots):
            if why.get(o, "").startswith(("提供", "程序")):
                print(f"  补根 {objof[o]}：{why[o]}")
        old = open(LIST, encoding="utf-8").read() if os.path.exists(LIST) else ""
        if check:
            same = [l for l in old.splitlines() if not l.startswith("#")] == [l for l in body if not l.startswith("#")]
            print("清单与现算" + ("一致" if same else "不一致"))
            return 0 if same else 1
        new_list = os.path.join(tmp, "new.srcs")
        open(new_list, "w", encoding="utf-8").write(text)
        vout = OUT + "-verify"
        rc, log = build(vout, new_list, gen=False)
        if rc:
            sys.exit("【红】按新清单正式构建失败（清单没写）：\n" + "\n".join(l for l in log.splitlines() if re.search(r"error|【红】|undefined|Undefined|ld: |failed", l))[-4000:])
        vargs, vexe, vmap = link_args(vout), os.path.join(tmp, "verify"), os.path.join(tmp, "verify.map")
        vhost = {obj_of(vout, c) for c in closure}
        rc, log = relink(vargs, vhost, sorted(vhost), vexe, vmap)
        if rc:
            sys.exit(f"【红】核对链接失败：\n{log[-3000:]}")
        vloaded, vprov = read_map(vmap)
        tr = {obj_of(vout, c): obj_of(OUT, c) for c in closure}
        bad = [n for n, ps in vprov.items() for p in full_prov.get(n, set()) & gdefs.get(n, set()) if p not in {tr.get(q, q) for q in ps}]
        if bad or tps.dynamic(vexe) - full_dyn:
            sys.exit(f"【红】正式构建与全量对照的提供者不一致：{' '.join(sorted(bad)[:20])} {' '.join(sorted(tps.dynamic(vexe) - full_dyn))}")
        open(LIST, "w", encoding="utf-8").write(text)
        print(f"已写 {os.path.relpath(LIST, ROOT)}；正式构建通过（链接、头文件核对、运行期查找核对、与全量提供者一致）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
