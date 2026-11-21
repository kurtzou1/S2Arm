#!/bin/bash
# 直连出库失败分类单测（graphics/tools/direct/direct_lib.py 的 gap，10-25 维护者：内容缺口打黄退 3、本款走通用；基础设施出错与判不清的报红）：bash tests/direct_gap_test.sh，约 1 秒
# 直接调 direct_lib.gap，喂各子步骤真实形状的日志（消息原文取自 C# 整份出库 dsh_batch build（graphics/tools/direct/dsh/batch/Build.cs Translate）/ graphics/tools/spirv_msl.py / vk_shaders.py），期望按规则手写：
#   ① NVN 一支结构不支持整份停住（「[RED] <16 位键>: vertex shader of shader type 0 without a VertexB part …」）→ 退 3、黄行「直连缺口：NVN 着色器 翻不了 1 支（<键>：<原因去掉括号尾>）」
#   ② 「[RED] vertex shader without a main0 main function … (<键>)」（原因在前、键在括号尾）→ 退 3，键记成「-」（gap 去掉括号尾）
#   ③ 工具链对不上锁文件（基础设施）→ 不退（调用方报红）
#   ④ 前面有单支非致命红行（影子输入库编不过）、最后是发布核验红行（Build.cs LibPack）→ 不退（只认列出的致命形状）
#   ⑤ 有 Python 异常栈 → 不退（判不清），即使日志里也有①的形状
#   ⑥ Vulkan 一支 spirv-cross 失败「[RED] /<路径>: spirv-cross failed: …」→ 退 3、类别「spirv-cross failed: …」；⑦ 「[RED] no SPIR-V files in …」→ 不退
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PYTHON:-${S2A_PY:-python3}}" - "$H" <<'PY'
import contextlib, io, os, sys, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics', 'tools', 'direct'))
import direct_lib
bad = 0
def ck(msg, ok):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += not ok
def G(step, text):
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, 'log'); open(p, 'w', encoding='utf-8').write(text + '\n')
        o = io.StringIO()
        with contextlib.redirect_stdout(o):
            try: direct_lib.gap(p, step); r = 0
            except direct_lib.Exit as e: r = e.code
        return r, (o.getvalue().rstrip('\n') or '返回')
r, o = G('NVN 着色器', '[RED] 1111111111111111: the shadow-input library does not compile (x): its integer inputs keep the CPU conversion\n[RED] 0123456789abcdef: vertex shader of shader type 0 without a VertexB part in the expected place (control +0x748 0x30 0x0 0x0 0x0)')
ck(f'① NVN 一支结构不支持 → 退 3、黄行带键与原因（{o}）', r == 3 and o == '[直连库] 🟡 直连缺口：NVN 着色器 翻不了 1 支（0123456789abcdef：vertex shader of shader type 0 without a VertexB part in the expected place），现有出库不支持部分出库，本款这次走通用')
r, o = G('NVN 着色器', '[RED] vertex shader without a main0 main function, cannot add the depth entry points (0123456789abcdef)')
ck(f'② main0 缺失（键在括号尾） → 退 3（rc={r}）', r == 3 and '直连缺口：NVN 着色器 翻不了 1 支（-：vertex shader without a main0 main function, cannot add the depth entry points）' in o)
r, o = G('NVN 着色器', '[RED] translation chain tools do not match the lock file: spirv-cross: lock 1 / actual missing')
ck(f'③ 工具链对不上 → 不退、不打黄（rc={r}）', r == 0 and o == '返回')
r, o = G('NVN 着色器', '[RED] 1111111111111111: the shadow-input library does not compile (x): its integer inputs keep the CPU conversion\n[RED] 发布 iOS 库却没编 iOS 那份（DMSH_NO_IOS_LIB）')
ck(f'④ 单支非致命红行 + 发布核验红行 → 不退（rc={r}）', r == 0 and o == '返回')
r, o = G('NVN 着色器', 'Traceback (most recent call last):\n  File "vk_shaders.py", line 9\n[RED] 0123456789abcdef: vertex shader of shader type 0 without a VertexB part in the expected place (x)')
ck(f'⑤ 有异常栈 → 不退（rc={r}）', r == 0 and o == '返回')
r, o = G('Vulkan 着色器', '[RED] /r/romfs/shaders/a.frag.spv: spirv-cross failed: error: unsupported capability')
ck(f'⑥ Vulkan 一支 spirv-cross 失败 → 退 3、类别带原因（{o}）', r == 3 and '直连缺口：Vulkan 着色器 翻不了 1 支（a.frag.spv：spirv-cross failed: error: unsupported capability）' in o)
r, o = G('Vulkan 着色器', '[RED] no SPIR-V files in /r/romfs')
ck(f'⑦ 一个 SPIR-V 都没有 → 不退（rc={r}）', r == 0 and o == '返回')
print('直连出库失败分类单测全过' if not bad else '直连出库失败分类单测有不通'); sys.exit(1 if bad else 0)
PY
