#!/bin/bash
# 门禁层：合入后
# 门禁路由：graphics/ runtime/ compat/ Makefile */build.mk tests/vk_indirect_count/ tests/vk_core/ tests/vk_xlate/ tools/tt_env. tests/frame_pacing/
# 门禁本机：pso_cache 管线分片缓存反证：gate-host（macOS 27.0.1）载入 applegpu_g16s.macos27.0 旧归档报 deployment target 不兼容，4 项红（本机 26.4.1 全过）
# 门禁本机：dsh 直连兜底现编对拍的考卷是本机直连库缓存 ~/.s2arm/run/s2arm/cache/direct/01006F8002326000（游戏着色器，不分发、不同步）且要 Homebrew spirv-cross；gate-host 上没有这两样，t_dsh.sh 缺考卷即报红
# 门禁本机：gl OpenGL 前端最小绘制单测（graphics/nvn/tests/gl/t_gl_min.sh）要 Homebrew glslang 与 spirv-cross 现出合成着色器库；gate-host 上没有
# 门禁本机：vk Vulkan 层真 GPU 回归（间接计数 + 核心命令）同 gl 子项依赖 Homebrew glslang 与 spirv-cross 现出合成着色器库；gate-host 上没有这两项依赖
# 门禁本机：shdist shbake 分发组（t_pso_dist / t_pso_tt_retry / t_pso_list）：10-28 本机整份 graphics/gate.sh 改到 shbake 时 1019 秒，超钩子 900 秒上限（rc=124，gate-host / Spare-host 自检与 #612 / #613 同死于此）；拆出来本机并行另跑，主步与子项各自在上限内
# 门禁本机：m3pack Metal 3 归档出包到命中（make -C graphics/metal test-m3）：gate-host（macOS 27）载旧 Metal 3 归档报 deployment target 不兼容，4 项不符（10-28 #638 自检红，与改动无关，同 pso_cache 那条）；本机另跑
# 帧率能耗线门禁钩子（测试出包线约定：仓库根运行，退出 0 = 绿，最后一行「期望 → 真结果」；墙钟上限见下面「门禁预算」行）
# 内容：写跟踪单测 t_track、写跟踪 × GPFIFO 排空时机单测 fifodrain、计数结果回调换线程单测 t_cntdead、Metal 渲染器单测（graphics/metal make test）、写跟踪对拍（Ryujinx 原版 MemoryTracking vs 我方，固定种子 1、2000 轮）、MTL4 直接调用棘轮
# 子项键（tools/gate.sh 分派 gate-host 用，见本文件头「# 门禁本机：」）：pso_cache = 管线分片缓存反证（graphics/tools/shbake/tests/t_pso_cache.sh）；
#   dsh = 直连兜底现编对拍（graphics/tools/direct/tests/t_dsh.sh，要本机考卷与 Homebrew spirv-cross）；
#   gl = OpenGL 前端最小路径与真实 MRT / 深度模板 GPU 回归、GLSL 改写层、运行时兜底现编（要 Homebrew glslang 与 spirv-cross；兜底那项另要 cmake / ninja 首次构建 glslang）。
#   vk = Vulkan 层真 GPU 回归：间接计数（tests/vk_indirect_count）+ 核心命令（tests/vk_core，含设备现编）+ 现编与出包工具对拍（tests/vk_xlate）；测试源码现编 SPIR-V / Metal 库，只链 libnvn.a + 宿主替身，约 15 秒。
#   present_residency = 真实 Mac 前端上屏驻留集成矩阵（Metal 4 / 3 × DM_PRESENT_LINK 0 / 1）；涉及节拍时加跑 40 项帧率上限 / HUD 核心矩阵，涉及画面设置时加跑 AA/滤镜真实 drawable 像素矩阵。
#   m3pack = Metal 3 归档出包到命中（graphics/metal make test-m3，run_m3pack）：gate-host macOS 27 载旧 Metal 3 归档报部署目标不兼容，本机另跑（10-28 #638）。
#   shdist = shbake 分发组（t_pso_dist / t_pso_tt_retry / t_pso_list，见 run_shdist）：单测上限合计 360 秒；10-28 本机实测和主步合在一份 1019 秒、超 tools/gate.sh 给钩子的 900 秒（rc=124），拆出来本机并行另跑、各自在上限内。
#   GATE_SKIP=<键…>：不跑这些（别处另跑）、末行写明；GATE_ONLY=<键…>：只跑这些（同一步几个键空格分开合成一份）。认不得的键 = 红。
set -u
# 超时（#591）：把仓库 tools/bin 放到 PATH 最前（perl 版 timeout，同 tools/toolchain.sh）。
_s2a_d=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || _s2a_d=; while [ -n "$_s2a_d" ] && [ ! -f "$_s2a_d/tools/_timeout.sh" ] && [ "$_s2a_d" != / ]; do _s2a_d=${_s2a_d%/*}; done; { [ -n "$_s2a_d" ] && [ -f "$_s2a_d/tools/_timeout.sh" ] && . "$_s2a_d/tools/_timeout.sh"; } || :
cd "$(dirname "$0")/.." || exit 2
# 门禁预算：--budget → 1500 秒（10-29 基础设施线空家目录实测整份 1010 秒、本机负载 17–31，当时定 1010；不自报时 tools/gate.sh 给 600 + 等 GPU 300 = 900 秒，到点 rc=124 掐掉）
#   11-06 放到 1500：守望在 gate-host 跑整份合入后层，11-04 起 14 次 675–989 秒（11-05 两次 989），11-06 03:18 一次 1012 秒到点被掐。按跑完最长 989 的约 1.5 倍，仍能拦卡死
[ "${1:-}" = --budget ] && { echo 1500; exit 0; }
# #735：只检查 merge-base→HEAD 已提交路径；不读取宏内容，不阻止维护方删除。
# contrib_check --base 已把对应差集放入 GATE_CHANGED；显式空集合也必须保留。
check_macro_corpus() (
  local changed path quoted paths blocked=0
  git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "宏语料检查：HEAD 不可用" >&2; return 2; }
  paths=$(mktemp) || return 2
  trap 'rm -f "$paths"' EXIT
  if [ "${GATE_CHANGED+x}" = x ]; then
    changed=${GATE_CHANGED//$'\n'/ }
    # 此入口沿用门禁空白分隔协议。按完整树名比较，不能拆坏带空格的宏名。
    git ls-tree -r --name-only -z HEAD > "$paths" || return 2
  else
    # 独立入口保留 NUL 路径；只取仍存在于 HEAD 的已提交新增/修改，删除允许。
    git diff --no-renames --diff-filter=ACMRT --name-only -z origin/main...HEAD -- > "$paths" || {
      echo "宏语料检查：无法取得已提交差集，请通过 contrib_check --base 指定基线" >&2; return 2;
    }
  fi
  while IFS= read -r -d '' path; do
    case "$path" in corpus/*.mme|*/corpus/*.mme)
      quoted=$(git -c core.quotepath=off ls-tree --name-only HEAD -- "$path") || return 2
      if [ "${GATE_CHANGED+x}" = x ]; then
        # 对特殊字符同时接受 Git name-only 的 C 引号表示。
        case " $changed " in *" $path "*|*" $quoted "*) ;; *) continue;; esac
      fi
      echo "宏语料检查：禁止新增或修改 ${quoted}；语料请放仓库外目录，用 S2A_MACRO_CORPUS 指定" >&2
      blocked=1
    ;; esac
  done < "$paths"
  [ "$blocked" = 0 ] || return 1
  echo "宏语料检查：本批无新增或修改的 .mme → 通过（允许删除，不检查 untracked）"
)
has() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }
# 两个本机长子项只在改到自己的面时跑（10-24 门禁整改，维护者「只测碰到的」）：pso_cache（管线分片缓存键，约 60 秒）只看 graphics/tools/shbake/ 与出包着色器阶段；
#   dsh（直连兜底现编对拍，本机约 60～90 秒）看 graphics/tools/direct/ 与离线链 translator/。原先每次 gfx 钩子都跑，改 graphics/metal 一行也要等 6 分钟。
#   GATE_CHANGED 为空（不知道改了啥）照跑
touched() { local f p; [ -z "${GATE_CHANGED:-}" ] && return 0; for f in $GATE_CHANGED; do for p in "$@"; do case $f in $p*) return 0;; esac; done; done; return 1; }
need_pso() { touched graphics/tools/shbake/ graphics/tools/shader_pack.sh tools/tt_env.; }
# 管线分片分发这几项只测 shbake 自己的分发与编库（10-25 gate-host 热态：t_pso_dist 一项 80 秒，占本钩子 208 秒的大头），
#   只在本批改到它们或它们调的远端分发脚本时跑；GATE_CHANGED 为空（全跑 / 合入后钩子）照旧跑
need_shdist() { touched graphics/tools/shbake/ graphics/tools/shader_pack.sh graphics/metal/tools/unity_check.py tools/remote.sh tools/machine.sh tools/safe_killpg.sh tools/toolchain.sh tools/tt_env.; }   # tools/tt_env.*：metal-tt 查询缓存后缀入口（pso_chunk 用）
need_dsh() { touched graphics/tools/direct/ translator/ graphics/nvn/gfx/nvn/dmsh_chain.h; }   # 10-25 起考卷由被测树的离线链现出：改离线链也要对拍（原先离线链改了不跑，等下次出库把生产缓存里的考卷换掉才在别人的批里红）
need_dsh_vk() { touched graphics/tools/direct/dsh/ graphics/tools/direct/tests/dsh_vk/ graphics/tools/direct/tests/t_dsh_vk.sh translator/dmsh_xlate/ graphics/third_party/spirv_cross/ compat/tree/src/Ryujinx.Graphics.Shader/ graphics/dsx/gal_colorround. graphics/dsx/gal_spvx. graphics/dsx/gal_spill. graphics/dsx/gal_log.h graphics/metal/gal_abi.h graphics/metal/Makefile graphics/gate.sh; }   # 出包 Vulkan 产物单测（#783）：要编 S2A.Dsh，只在改到它 / 翻译器 / SPIRV-Cross 时跑
need_dsh_vklib() { need_dsh_vk || touched graphics/tools/direct/vklib/ graphics/tools/direct/tests/dsh_vklib/ graphics/tools/direct/tests/t_dsh_vklib.sh graphics/tools/direct/tests/t_vklib_exit.py translator/dmsh_chain.py pack/stage_inputs/direct.tsv; }   # 出包 Vulkan 独立入口单测（#783）：同 dsh_vk 的条件，外加改到 vklib 工程与它的单测；它还核苹果侧指纹不含 vklib/，改 xlate_fp 清单 / 直连阶段键时也跑
need_gl() { touched graphics/nvn/gfx/gl/ graphics/nvn/tests/gl/ translator/gl_shaders.py translator/mbundle.py graphics/third_party/glslang/ graphics/third_party/spirv_cross/; }
need_vk() { touched graphics/nvn/gfx/vk/ translator/vk_shaders.py graphics/metal/gal_vkx.m tests/vk_indirect_count/ tests/vk_core/ tests/vk_xlate/ graphics/nvn/tests/host_stubs.h graphics/nvn/Makefile graphics/gate.sh; }
need_present_residency() { touched graphics/nvn/gfx/nvn/ graphics/nvn/gfx/gl/egl.m graphics/nvn/gfx/vk/hle_vk.m graphics/nvn/host/ graphics/nvn/Makefile graphics/nvn/tests/t_present_residency. graphics/nvn/tests/t_fps_limit. graphics/nvn/tests/t_present_settings. graphics/metal/ macos/ platform/apple/plat_apple.c platform/plat.h platform/plat_asm.h runtime/src/ runtime/include/ graphics/track/ graphics/widen/ runtime/build.mk tools/toolchain.sh tools/toolchain.env Directory.Build. Makefile graphics/gate.sh; }
need_fps_limit() { touched graphics/nvn/gfx/nvn/nvn_fps. graphics/nvn/gfx/nvn/hle_nvn.c graphics/nvn/gfx/nvn/nvn_mtl. graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/gl/egl.m graphics/nvn/gfx/vk/hle_vk.m graphics/nvn/tests/t_fps_limit. runtime/src/hud.c graphics/gate.sh; }
need_present_settings() { touched graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_present_aa.inc graphics/nvn/Makefile graphics/nvn/tests/t_present_settings. graphics/metal/shaders/aa_ graphics/metal/tools/embed_ graphics/gate.sh; }
# 主流程按依赖分组（10-29 列车提速：本钩子 432 次中位 284 秒、p90 598 秒，只改 runtime/src/crash.c 也整份跑）：每组的触发前缀按该组子测试真实编进 / 链进 / 运行时调用的文件推出，
#   .NET 组按 .csproj 的 ProjectReference / Compile Include 闭包现算（csproj_pfx，不手抄 Ryujinx 依赖表）；改到本文件或超时垫片 → 全跑；GATE_CHANGED 空 → 全跑（touched）。
#   没列进分组的子项（棘轮、宏表、Python 工具单测、图形接口判法）依赖面拿不准或只要几秒，照旧总是跑。GFX_GATE_PLAN=1：只打印各组跑 / 不跑后退出（不看 GATE_SKIP、不跑任何测试）
ALL_PFX="graphics/gate.sh tools/_timeout.sh tools/bin/"
# 写跟踪 C 一半：track.c 的 include（s2a_track.h / track_platform.h / platform/plat.h / runtime/include/s2a_lowva.h）+ 一起编的模拟访存（emul_ld / emul_st，graphics/build.mk gfx-test-track）
TRACK_C_PFX="graphics/track/track.c graphics/track/s2a_track.h graphics/track/track_platform.h platform/plat.h runtime/src/emul_ld.c runtime/src/emul_st.c runtime/include/"
# Metal 渲染器（make -C graphics/metal test-deps / test）：SRCS = gal_*.m、SPIRV-Cross 源码、toolchain.env、SMAA 查表（AA_LUT）；gal_offline.py 引 tools/progress.py；
#   t_psopf 现跑 psouse.py；超时现场 graphics/tools/timeout_snap.sh
METAL_PFX="graphics/metal/ graphics/third_party/ graphics/tools/timeout_snap.sh graphics/tools/shbake/psouse.py tools/toolchain. tools/progress.py compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures/"
# 打印这些 .csproj 的工程引用闭包涉及的仓库路径前缀：各工程目录、工程外 Compile / Import 等文件、各工程往上到仓库根的 Directory.Build.* / Directory.Packages.props / global.json / nuget.config。
#   有解不开的 $(属性) / 引用的工程不在 → 非 0（调用方当全跑）
csproj_pfx() {
  python3 - "$@" <<'PY'
import os, re, sys
root = os.getcwd(); out = set(); seen = set(); todo = [os.path.abspath(a) for a in sys.argv[1:]]
def add(p, d=False):
    r = os.path.relpath(p, root)
    if not r.startswith('..'): out.add(r + '/' if d else r)
while todo:
    p = os.path.normpath(todo.pop())
    if p in seen: continue
    seen.add(p); d = os.path.dirname(p)
    t = re.sub(r'<!--.*?-->', '', open(p, encoding='utf-8-sig').read(), flags=re.S)
    pr = {'MSBuildThisFileDirectory': d + '/', 'MSBuildProjectDirectory': d}
    for k, v in re.findall(r'<(\w+)\b[^>]*>([^<]*)</\1>', t): pr.setdefault(k, v.strip())
    def res(s):
        for _ in range(8): s = re.sub(r'\$\((\w+)\)', lambda m: pr.get(m.group(1), m.group(0)), s)
        if '$(' in s or '@(' in s or '%(' in s: sys.exit('csproj_pfx：%s 里 %s 解不开' % (p, s))
        return os.path.normpath(os.path.join(d, s.replace('\\', '/')))
    add(d, True)
    for kind, inc in re.findall(r'<(ProjectReference|Compile|Content|None|EmbeddedResource|Import)\b[^>]*?\b(?:Include|Project)="([^"]*)"', t):
        for one in filter(None, (x.strip() for x in inc.split(';'))):
            f = res(one)
            if kind == 'ProjectReference': todo.append(f); continue
            while '*' in f: f = os.path.dirname(f)
            add(f, os.path.isdir(f))
    a = d
    while True:
        for n in ('Directory.Build.', 'Directory.Packages.props', 'global.json', 'nuget.config', 'NuGet.Config'): add(os.path.join(a, n))
        if len(a) <= len(root): break
        a = os.path.dirname(a)
dirs = [x for x in out if x.endswith('/')]
print(' '.join(sorted(x for x in out if not any(x != d and x.startswith(d) for d in dirs))))   # 已被所在工程目录盖住的不重复列
PY
}
# net_touched "<csproj…>" <另加前缀…>：闭包前缀 + 另加前缀 + ALL_PFX 里有改到的 → 0；闭包算不出 → 0（宁多勿漏）
net_touched() { local cs=$1 p; shift; [ -z "${GATE_CHANGED:-}" ] && return 0; p=$(csproj_pfx $cs) && [ -n "$p" ] || return 0; local a; read -r -a a <<< "$p"; touched $ALL_PFX "${a[@]}" "$@"; }
need_track_c() { touched $ALL_PFX $TRACK_C_PFX graphics/track/tests/t_track.c graphics/build.mk Makefile '*/build.mk' tools/toolchain.; }   # make gfx-test-track（根 Makefile include 全部 */build.mk）
# 写跟踪 .NET 组（ryucmp / fifodrain / drain_readflush / flushlock / partial / keepact / zcpolicy / vrcsplit / texprecise）：各 build_run.sh 现编 track.c（+ cmp_native.c / fixture.c / 模拟访存）与各自 .csproj
need_track_net() { local t=graphics/track/tests; net_touched "$t/ryucmp/RyuCmp.csproj $t/fifodrain/FifoDrain.csproj $t/drain_readflush/DrainReadflush.csproj $t/flushlock/FlushLock.csproj $t/partial/Partial.csproj $t/keepact/KeepAct.csproj $t/zcpolicy/ZcPolicy.csproj $t/vrcsplit/VrcSplit.csproj $t/texprecise/TexPrecise.csproj" graphics/track/ $TRACK_C_PFX; }
need_shared_gpu_contract() { net_touched graphics/track/tests/shared_contract/SharedContracts.csproj; }
need_vvl() { net_touched "graphics/tools/shbake/tests/vvl-clamp/S2A.VvlClampTest.csproj graphics/tools/shbake/tests/vvl-stage/S2A.VvlStageTest.csproj graphics/tools/shbake/tests/vvl-sync/S2A.VvlSyncTest.csproj graphics/tools/shbake/tests/vvl-texel/S2A.VvlTexelTest.csproj graphics/tools/shbake/tests/vvl-filter/S2A.VvlFilterTest.csproj" graphics/tools/shbake/tests/t_vvl_clamp.sh graphics/tools/shbake/tests/t_vvl_stage.sh graphics/tools/shbake/tests/t_vvl_sync.sh graphics/tools/shbake/tests/t_vvl_texel.sh graphics/tools/shbake/tests/t_vvl_filter.sh; }
need_vulkan_diag() { net_touched "graphics/track/tests/vulkan_diag/VulkanDiag.csproj graphics/vulkan/runtime/tests/Runtime.Tests.csproj"; }
# texture_read_test.py：ReadonlyCopy.Tests.csproj + 现编 native_fixture.c / mac_vm_adapter.c（工程目录）/ readonly_copy.c / track.c
need_texture_dma_read() { net_touched android/core-link/runtime-tests/readonly-copy/ReadonlyCopy.Tests.csproj android/native/runtime/tracking/ $TRACK_C_PFX; }
need_metal() { touched $ALL_PFX $METAL_PFX; }   # 渲染器预编 + 单测、离线库按阶段 / 大 MSL、.air 缓存
need_cntdead() { net_touched graphics/metal/tests/cntdead/CntDead.csproj $METAL_PFX; }   # build_run.sh 先 make libnxgal.dylib，再编 CntDead（引 NxGal.csproj → Ryujinx GAL / Memory）
need_session() { net_touched graphics/metal/tests/session/Session.csproj $METAL_PFX; }   # 同上引 NxGal.csproj；NativeAOT 发布 Session，无窗口呈现 / 读回、释放队列、原生线程上开下一局
need_m3pack() { touched $ALL_PFX $METAL_PFX graphics/tools/shbake/ tools/; }   # t_m3pack.sh / m3archive_pack.py 现跑 shbake 的 pso_gen / pso_chunk / m3_combo / gpu_arch
# 直连曲面 / 共享内存溢出（组名 direct_link 沿用：11-08 起用直连翻译库 build/dsx/libdsx.dylib）：翻译段源码在 graphics/dsx；
#   11-01 起 t_dmsh_reuse 真跑的出库每键改写是 C# 批量进程（graphics/tools/direct/dsh），它编进 Ryujinx 着色器翻译器 / Spv.Generator 与宽屏着色器分析的源码
need_direct_link() { touched $ALL_PFX $METAL_PFX graphics/dsx/ graphics/tools/direct/ translator/ compat/tree/src/Ryujinx.Graphics.Shader/ compat/tree/src/Spv.Generator/ graphics/widen/shader/ graphics/widen/SpirvCbufUseText.cs; }
# shbake .NET 组（特化核对 / 录段分块 / 等程序不自旋 / 转计算 / 片元输出 / 实化 / 翻译告警 / seen）：各测试 .csproj（S2A.ShBake → Ryujinx Gpu + NxGalCaps + Widen.Shader）
need_shbake_net() { local s=graphics/tools/shbake; net_touched "$s/S2A.ShBake.csproj $s/tests/spec/S2A.SpecTest.csproj $s/tests/segchunks/S2A.SegChunksTest.csproj $s/tests/progqueue/S2A.ProgQueueTest.csproj graphics/tools/direct/tests/seen/S2A.SeenTest.csproj $s/tests/targetcaps/S2A.TargetCapsTest.csproj" graphics/tools/direct/tests/t_seen.sh; }
# 帧节奏策略（S2AFramePacing 30/60/120、交换间隔下限、SurfaceFlinger.S2AEffective）：FramePacingTest → S2A.Gfx → Ryujinx.HLE（11-01 审计 P1-39：原先只挂顶层 make test，没有门禁跑）
need_frame_pacing() { net_touched tests/frame_pacing/FramePacingTest.csproj; }
need_nvn() { touched graphics/nvn/; }   # 直连未守卫新系统 API + 两路后端冒烟（原样搬来）
need_red() { touched graphics/nvn/ graphics/tools/direct/; }
need_nvn_tex() { touched graphics/nvn/gfx/tex/ graphics/nvn/gfx/nvn/nvn_tex.; }
need_dmsh_giant() { touched graphics/tools/direct/dsh/ graphics/tools/direct/tests/dsh_cmp/ graphics/tools/direct/tests/dshfn.py translator/dmsh_chain.lock graphics/tools/direct/tests/t_dmsh_giant.py; }   # 不含 graphics/gate.sh：改门禁本身不必重跑这 15 秒
GFX_GROUPS="track_c track_net shared_gpu_contract vulkan_diag vvl texture_dma_read metal cntdead session m3pack direct_link shbake_net frame_pacing nvn red nvn_tex pso dsh gl vk present_residency fps_limit present_settings shdist dmsh_giant"
want() { case $1 in fps_limit|present_settings) need_present_residency && "need_$1";; *) "need_$1";; esac; }   # 帧率上限 / 画面设置矩阵只在上屏驻留集成里加跑
if [ "${GFX_GATE_PLAN:-}" = 1 ]; then for g in $GFX_GROUPS; do if want "$g"; then echo "$g 跑"; else echo "$g 不跑"; fi; done; exit 0; fi
# 合成测试只跑这段生产检查，不能继续执行 GPU / regen / 编译步骤。
if [ "${1:-}" = --check-macro-corpus ]; then check_macro_corpus; exit $?; fi
check_macro_corpus || exit $?
T0=$(date +%s); LOG=build/gate_gfx; mkdir -p "$LOG"
# 每项一行登记（10-24：末尾汇总的 ok= / echo 两行是全仓库最热的冲突点，一天四次因新加单测互撞被列车退回）：
#   新加的单测在自己那一步后面写一行 reg <退出码> "<汇总片段>"，不要再改末尾那两行；末尾的老项照旧
REGOK=1; REGS=; REGBAD=
# 逐子项计时（10-25 列车提速：今天门禁超过 280 秒的几乎全是本钩子一步拖的，要知道时间花在哪）：同名函数包住 timeout，
#   每项一行「秒数<TAB>命令」记进 $LOG/timing.tsv，收尾时连同时刻 / 主机追加进 gate_snap/gfx_timing.tsv（gate-host 上累积，列车提速按它拆账）
: > "$LOG/timing.tsv"; TMF=${S2A_SNAP_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_snap}/gfx_timing.tsv
timeout() { local s=$SECONDS r; command timeout "$@"; r=$?; printf '%s\t%s\n' "$((SECONDS - s))" "$(printf '%s ' "$@" | cut -c1-90)" >> "$LOG/timing.tsv"; return $r; }
trap 'mkdir -p "$(dirname "$TMF")" 2> /dev/null && sed "s|^|$(date +%m%d%H%M%S)\t$(hostname -s)\t|" "$LOG/timing.tsv" >> "$TMF" 2> /dev/null' EXIT
# 红项证据（11-01 维护者：红报告只留一句、截断两次丢证据）：每登记一项打一次标记；某项红时，把上次标记以来新写的 $LOG/*.log 记为它的证据，
#   收尾时（总判行之前）每个证据日志打完整路径 + 末 30 行，行首「  ┊」——tools/gate.sh 红步展示原样保留这些行
REDLOGS=; FNRED=
# 红项证据：每个判红的子项带它自己那条命令写的日志（reg / ev 第 3 个起的参数；组合函数用 redlog 自己登记），总判行前打完整路径 + 末 30 行（行首 ┊）
#   不按修改时间猜：并行跑的子项日志会被算到别人头上（11-01 首版把 900/900 全过的 fps_limit 列成红项）
redlog() { [ "$1" = 0 ] || FNRED="$FNRED $2"; }
ev() { local rc=$1 lf; shift; if [ "$rc" != 0 ]; then for lf in "$@" $FNRED; do case " $REDLOGS " in *" $lf "*) ;; *) REDLOGS="$REDLOGS $lf";; esac; done; fi; FNRED=; return "$rc"; }
# 先列全文里的判红行（✗ / 不通 / FAIL / error / Traceback / AssertionError，前 20 条）再给末 30 行：判红行打得早时末 30 行里看不到（11-01 审计 P2-54）
evidence() { local lf k; for lf in $REDLOGS; do echo "  ┊ 红项日志 $(cd "$(dirname "$lf")" && pwd)/$(basename "$lf")："
  k=$(grep -anE '^(✗ |不通 |FAIL)|: (fatal )?error:|^Traceback|AssertionError|^ld: |Undefined symbols' "$lf" | head -20)
  [ -n "$k" ] && { echo "  ┊   判红行（行号:内容，前 20 条）："; sed 's/^/  ┊   /' <<< "$k"; }
  echo "  ┊   末 30 行："; tail -30 "$lf" | sed 's/^/  ┊   /'; done; }
reg() { ev "$1" "${@:3}"; [ "$1" = 0 ] || { REGOK=0; REGBAD="${REGBAD:+${REGBAD}；}$(cut -c1-200 <<< "$2")"; }; REGS="$REGS / $2"; }   # REGBAD：判红的项原文，总判行点名（10-30 维护者：红藏在结果段里要人翻）
for k in ${GATE_SKIP:-} ${GATE_ONLY:-}; do case $k in pso_cache|dsh|gl|vk|present_residency|shdist|m3pack|texture_dma_read|shared_gpu_contract|vulkan_diag) ;; *) echo "帧率能耗线钩子：子项键 $k 认不得（只认 pso_cache / dsh / gl / vk / present_residency / shdist / m3pack / texture_dma_read / shared_gpu_contract / vulkan_diag）→ 红"; exit 1;; esac; done
run_vk() {
  local start r r2; start=$(date +%s)
  timeout 300 make -s -j1 -f tests/vk_indirect_count/Makefile vk-indirect-count-test > "$LOG/vk_indirect.log" 2>&1; r=$?; redlog $r "$LOG/vk_indirect.log"
  timeout 300 make -s -j1 -f tests/vk_core/Makefile vk-core-test > "$LOG/vk_core.log" 2>&1; r2=$?; redlog $r2 "$LOG/vk_core.log"
  # 设备现编（乙）与出包工具对拍：vk_core 的着色器（含计算 / 子遍输入）两边资源栏逐字相同、现编得出入口
  timeout 120 bash tests/vk_xlate/t_vk_xlate.sh build/tests/vk_core/shaders/vk/vk_shaders.tsv build/tests/vk_core/spv > "$LOG/vk_xlate.log" 2>&1; r3=$?; redlog $r3 "$LOG/vk_xlate.log"
  VK_RESULT="Vulkan 层：$(tail -1 "$LOG/vk_indirect.log")（退出 ${r}）/ $(tail -1 "$LOG/vk_core.log")（退出 ${r2}）/ $(tail -1 "$LOG/vk_xlate.log")（退出 ${r3}），用时 $(( $(date +%s) - start )) 秒"
  [ $r = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ]
}
run_texture_dma_read() {
  timeout 300 "${S2A_PY:-python3}" android/core-link/runtime-tests/readonly-copy/texture_read_test.py > "$LOG/texture_dma_read.log" 2>&1
}
run_shared_gpu_contract() {
  timeout 300 bash graphics/track/tests/shared_contract/build_run.sh > "$LOG/shared_gpu_contract.log" 2>&1
}
run_vulkan_diag() {
  timeout 300 bash graphics/track/tests/vulkan_diag/build_run.sh > "$LOG/vulkan_diag.log" 2>&1
}
run_present_residency() {
  local out="build/tests/present-residency" widen_build="build/tests/present-residency/deps"
  local widen_target="$widen_build/tests/nvn/widen/S2Arm.Gfx.Widen.dylib"
  local widen_lib="$PWD/$widen_target" build_status test_status fps_status=0 settings_status=0
  timeout 240 make -s -j1 S2A_CS=0 BUILD="$widen_build" "$widen_target" > "$LOG/present_residency_widen.log" 2>&1
  build_status=$?; redlog $build_status "$LOG/present_residency_widen.log"
  if [ "$build_status" = 0 ]; then
    timeout 300 env PRESENT_RESIDENCY_BUILD="$PWD/$out" PRESENT_WIDEN_LIB="$widen_lib" \
      bash graphics/nvn/tests/t_present_residency.sh > "$LOG/present_residency.log" 2>&1
    test_status=$?; redlog $test_status "$LOG/present_residency.log"
  else
    test_status=1
  fi
  if [ "$build_status" != 0 ]; then
    PRESENT_RESIDENCY_RESULT="上屏驻留集成：生产 Widen 构建失败（退出 ${build_status}）：$(tail -1 "$LOG/present_residency_widen.log")"
  else
    PRESENT_RESIDENCY_RESULT="上屏驻留集成：$(tail -1 "$LOG/present_residency.log")（退出 ${test_status}）"
  fi
  if [ "$build_status" = 0 ] && need_fps_limit; then
    # 450 秒：核心矩阵 56 个场景按真实显示时钟跑（每个约 3 秒、动态档 4 阶段），10-30 加动态换档场景后整组实测 286–303 秒，
    #   原 300 秒到点 rc=124、已跑完的全 PASS 也判红（11-01 gfx 钩子合入后层红的一项）；按实测 1.5 倍给
    timeout 450 env FPS_HIGH_REFRESH=0 FPS_WIDEN_LIB="$widen_lib" \
      bash graphics/nvn/tests/t_fps_limit.sh > "$LOG/fps_limit.log" 2>&1
    fps_status=$?; redlog $fps_status "$LOG/fps_limit.log"
    PRESENT_RESIDENCY_RESULT="$PRESENT_RESIDENCY_RESULT / 帧率上限核心矩阵：$(tail -2 "$LOG/fps_limit.log" | tr '\n' ' ')（退出 ${fps_status}；120 Hz 专项须在支持设备另跑）"
  fi
  if [ "$build_status" = 0 ] && need_present_settings; then
    timeout 300 env PRESENT_WIDEN_LIB="$widen_lib" bash graphics/nvn/tests/t_present_settings.sh > "$LOG/present_settings.log" 2>&1
    settings_status=$?; redlog $settings_status "$LOG/present_settings.log"
    PRESENT_RESIDENCY_RESULT="$PRESENT_RESIDENCY_RESULT / 直连画面设置：$(tail -2 "$LOG/present_settings.log" | tr '\n' ' ')（退出 ${settings_status}）"
  fi
  [ "$build_status" = 0 ] && [ "$test_status" = 0 ] && [ "$fps_status" = 0 ] && [ "$settings_status" = 0 ]
}
PYV=$HOME/.s2arm/venv/bin/python; [ -x "$PYV" ] || PYV=python3   # 出包同一个 venv（RE 引擎程序表等要 lz4；run_shdist 在 GATE_ONLY 分支也要用，故放在分支前）
# shbake 分发组（子项键 shdist）：管线分片分发各单测，主流程与 GATE_ONLY=shdist 共用这一份；设 pr / dt / pl2（及 *c 汇总片段）；全过返回 0
run_shdist() {
  timeout 240 bash graphics/tools/shbake/tests/t_pso_dist.sh > "$LOG/pso_dist.log" 2>&1; pr=$?; redlog $pr "$LOG/pso_dist.log"; prc=$(tail -1 "$LOG/pso_dist.log")   # 管线分片本机 + gate-host 并行编（本机模拟远端）：产物齐对、gate-host 不可用全退本机
  # pso_chunk Metal 3 分支的 metal-tt 并发下偶发「找不到翻译器」只对这一句重试（假工具，不依赖本机 GPU 架构）
  timeout 60 bash graphics/tools/shbake/tests/t_pso_tt_retry.sh > "$LOG/pso_tt.log" 2>&1; dt=$?; redlog $dt "$LOG/pso_tt.log"; dtc=$(tail -1 "$LOG/pso_tt.log")
  # 管线分片清单不经命令行参数（10-24 #100 奥德赛 12572 片 ls 超 ARG_MAX）：旧写法反证失败、find 列全、清单行数与应有片数不符报红
  timeout 60 bash graphics/tools/shbake/tests/t_pso_list.sh > "$LOG/pso_list.log" 2>&1; pl2=$?; redlog $pl2 "$LOG/pso_list.log"; pl2c=$(tail -1 "$LOG/pso_list.log")
  [ $pr = 0 ] && [ $dt = 0 ] && [ $pl2 = 0 ]
}
# Metal 3 归档出包到命中（子项 m3pack；10-28 #638：gate-host macOS 27 载旧 Metal 3 归档报 deployment target 不兼容，4 项不符，与改动无关）：主流程与 GATE_ONLY=m3pack 共用
run_m3pack() { timeout 300 make -s -C graphics/metal test-m3 > "$LOG/m3pack.log" 2>&1; local r=$?; redlog $r "$LOG/m3pack.log"; M3PACK_RESULT="Metal 3 归档出包到命中：$(grep -c '✓' "$LOG/m3pack.log") 项通过、$(grep -c '✗' "$LOG/m3pack.log") 项不符（退出 ${r}）"; return $r; }
if [ -n "${GATE_ONLY:-}" ]; then
  ok=1; out=
  if has "$GATE_ONLY" texture_dma_read; then run_texture_dma_read; r=$?; out="纹理 / DMA 保护页读取 $(tail -1 "$LOG/texture_dma_read.log")（退出 ${r}）"; [ "$r" = 0 ] || ok=0; fi
  if has "$GATE_ONLY" shared_gpu_contract; then run_shared_gpu_contract; r=$?; out="${out:+$out / }共享 GPU 合同 $(tail -1 "$LOG/shared_gpu_contract.log")（退出 ${r}）"; [ "$r" = 0 ] || ok=0; fi
  if has "$GATE_ONLY" vulkan_diag; then run_vulkan_diag; r=$?; out="${out:+$out / }Vulkan 诊断默认值 $(tail -1 "$LOG/vulkan_diag.log")（退出 ${r}）"; [ "$r" = 0 ] || ok=0; fi
  if has "$GATE_ONLY" pso_cache && ! need_pso; then out="${out:+$out / }管线分片缓存反证：本批没改到 shbake / 着色器阶段，不跑"
  elif has "$GATE_ONLY" pso_cache; then timeout 60 bash graphics/tools/shbake/tests/t_pso_cache.sh > "$LOG/pso_cache.log" 2>&1; p=$?; out="${out:+$out / }管线分片缓存反证 $(tail -1 "$LOG/pso_cache.log")（退出 ${p}）"; ev $p "$LOG/pso_cache.log" || ok=0; fi
  if has "$GATE_ONLY" dsh && ! need_dsh; then out="${out:+$out / }直连兜底现编对拍：本批没改到 graphics/tools/direct，不跑"
  elif has "$GATE_ONLY" dsh; then timeout 300 bash graphics/tools/direct/tests/t_dsh.sh > "$LOG/dsh.log" 2>&1; d=$?; out="${out:+$out / }直连兜底现编对拍 $(tail -1 "$LOG/dsh.log")（退出 ${d}）"; ev $d "$LOG/dsh.log" || ok=0; fi
  if has "$GATE_ONLY" gl && ! need_gl; then out="${out:+$out / }OpenGL 前端最小绘制：本批没改到 GL 前端，不跑"
  elif has "$GATE_ONLY" gl; then
    timeout 120 bash graphics/nvn/tests/gl/t_gl_min.sh > "$LOG/gl.log" 2>&1; g=$?; out="${out:+$out / }OpenGL 前端最小绘制 $(tail -1 "$LOG/gl.log")（退出 ${g}）"; ev $g "$LOG/gl.log" || ok=0
    timeout 300 bash graphics/nvn/tests/gl/t_gpu_mip.sh > "$LOG/gl_gpu_mip.log" 2>&1; g=$?; out="${out:+$out / }OpenGL 渲染纹理 mip / cube $(tail -1 "$LOG/gl_gpu_mip.log")（退出 ${g}）"; ev $g "$LOG/gl_gpu_mip.log" || ok=0
    timeout 300 bash graphics/nvn/tests/gl/t_gpu_mrt.sh > "$LOG/gl_gpu_mrt.log" 2>&1; g=$?; out="${out:+$out / }OpenGL MRT $(tail -1 "$LOG/gl_gpu_mrt.log")（退出 ${g}）"; ev $g "$LOG/gl_gpu_mrt.log" || ok=0
    timeout 300 bash graphics/nvn/tests/gl/t_gpu_depth_stencil.sh > "$LOG/gl_gpu_depth_stencil.log" 2>&1; g=$?; out="${out:+$out / }OpenGL 深度模板 $(tail -1 "$LOG/gl_gpu_depth_stencil.log")（退出 ${g}）"; ev $g "$LOG/gl_gpu_depth_stencil.log" || ok=0
    timeout 120 bash graphics/nvn/tests/gl/t_gl_api.sh > "$LOG/gl_api.log" 2>&1; g=$?; out="${out:+$out / }OpenGL 接口补齐 $(tail -1 "$LOG/gl_api.log")（退出 ${g}）"; ev $g "$LOG/gl_api.log" || ok=0
    timeout 60 bash graphics/nvn/tests/gl/t_glsl_es.sh > "$LOG/gl_glsl_es.log" 2>&1; g=$?; out="${out:+$out / }GLSL 改写层 $(tail -1 "$LOG/gl_glsl_es.log")（退出 ${g}）"; ev $g "$LOG/gl_glsl_es.log" || ok=0
    timeout 300 bash graphics/nvn/tests/gl/t_gl_rt.sh > "$LOG/gl_rt.log" 2>&1; g=$?; out="${out:+$out / }OpenGL 运行时兜底 $(tail -1 "$LOG/gl_rt.log")（退出 ${g}）"; ev $g "$LOG/gl_rt.log" || ok=0
  fi
  if has "$GATE_ONLY" vk && ! need_vk; then out="${out:+$out / }Vulkan 层：本批没改到 Vulkan 前端，不跑"
  elif has "$GATE_ONLY" vk; then run_vk; vi=$?; out="${out:+$out / }$VK_RESULT"; ev $vi || ok=0; fi
  if has "$GATE_ONLY" present_residency && ! need_present_residency; then out="${out:+$out / }上屏驻留集成：本批没改到相关路径，不跑"
  elif has "$GATE_ONLY" present_residency; then run_present_residency; pr=$?; out="${out:+$out / }$PRESENT_RESIDENCY_RESULT"; ev $pr || ok=0; fi
  if has "$GATE_ONLY" shdist && ! need_shdist; then out="${out:+$out / }shbake 分发组：本批没改到 shbake / 远端分发，不跑"
  elif has "$GATE_ONLY" shdist; then run_shdist; sd=$?; out="${out:+$out / }shbake 分发组：管线分片分发 ${prc}（退出 ${pr}）/ 翻译器重试 ${dtc}（退出 ${dt}）/ 分片清单 ${pl2c}（退出 ${pl2}）${REGS}"; ev $sd || ok=0; fi
  if has "$GATE_ONLY" m3pack; then run_m3pack; m3r=$?; out="${out:+$out / }$M3PACK_RESULT"; ev $m3r || ok=0; fi
  [ $ok = 1 ] || evidence
  echo "期望 本机子项（${GATE_ONLY}）全过 → 真结果 ${out} $([ $ok = 1 ] && echo ✓ || echo ✗)"; [ $ok = 1 ]; exit $?
fi
RUNG=; for g in $GFX_GROUPS; do want "$g" && RUNG="$RUNG $g"; done   # 本批要跑的组（同 GFX_GATE_PLAN=1 打印的那份）
if has "$RUNG" vvl; then
    timeout 400 bash graphics/tools/shbake/tests/t_vvl_clamp.sh > "$LOG/vvl_clamp.log" 2>&1; r=$?; reg $r "VVL UBO 范围：$(tail -1 "$LOG/vvl_clamp.log")（退出 ${r}）" "$LOG/vvl_clamp.log"
    timeout 400 bash graphics/tools/shbake/tests/t_vvl_stage.sh > "$LOG/vvl_stage.log" 2>&1; r=$?; reg $r "VVL 阶段布局：$(tail -1 "$LOG/vvl_stage.log")（退出 ${r}）" "$LOG/vvl_stage.log"
    timeout 400 bash graphics/tools/shbake/tests/t_vvl_sync.sh > "$LOG/vvl_sync.log" 2>&1; r=$?; reg $r "VVL 附件访问状态：$(tail -1 "$LOG/vvl_sync.log")（退出 ${r}）" "$LOG/vvl_sync.log"
    timeout 400 bash graphics/tools/shbake/tests/t_vvl_texel.sh > "$LOG/vvl_texel.log" 2>&1; r=$?; reg $r "VVL texel 视图对齐影子：$(tail -1 "$LOG/vvl_texel.log")（退出 ${r}）" "$LOG/vvl_texel.log"
    timeout 400 bash graphics/tools/shbake/tests/t_vvl_filter.sh > "$LOG/vvl_filter.log" 2>&1; r=$?; reg $r "VVL 采样器线性降级：$(tail -1 "$LOG/vvl_filter.log")（退出 ${r}）" "$LOG/vvl_filter.log"
else
    reg 0 "VVL 五项：本批没改到其闭包，不跑"
fi
if has "$RUNG" track_c; then t=$(timeout 120 make -s gfx-test-track > "$LOG/track.log" 2>&1; echo $?)
else t=0; reg 0 "写跟踪单测 t_track：本批没改到 track.c / 模拟访存 / 构建脚本，不跑"; fi
# 超时前抓现场（10-23 维护者：今天 4 次 300 秒超时一行没出，不循环复现，下次自然发生时带栈）：到上限前 10 秒对进程组 + 本用户 MTLCompilerService sample 5 秒，
#   连同 ps / vm_stat / 负载写进持久目录（门禁工作树会被删）；栈摘要以「不通」行带进门禁红行
SNAP=${S2A_SNAP_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/gate_snap}/metal_$(date +%m%d%H%M%S)_$$.txt
# 先并行预编单测要的全部产物（10-23 第一次超时现场：300 秒全花在 make test 的前置编译上、和门禁别的步骤抢核；本机冷编顺序 362 秒、-j 并行 60 秒），
#   自己的上限；编不过直接红并带编译日志尾。之后计时那步依赖都已是新的，只跑单测（本机 33 秒）
if has "$RUNG" metal; then
# 冷编按进度判挂死（tools/nostall.py：日志在长 / 编译子进程活着 / CPU 或磁盘在涨都算进展，连续 300 秒一样没有才停、退出 124）；
#   原先 timeout 300 墙钟：干净树满载冷编超 300 秒被杀（10-29 red_1029233345 退出 124，#1012；11-05 不稳定项 #14）
pb=$("${S2A_PY:-python3}" tools/nostall.py --watch build/gal 300 -- make -s -j"${S2A_CPU_GATE:-$(sysctl -n hw.ncpu 2> /dev/null || echo 8)}" -C graphics/metal test-deps > "$LOG/metal_build.log" 2>&1; echo $?)
[ "$pb" = 0 ] || { echo "不通 渲染器单测预编（make -j test-deps）退出 ${pb}$([ "$pb" = 124 ] && echo "（300 秒无进展）")：$(grep -m1 -E 'error|Error' "$LOG/metal_build.log" | cut -c1-200)"; }
m=$(bash graphics/tools/timeout_snap.sh 300 "$SNAP" make -s -C graphics/metal test > "$LOG/metal.log" 2>&1; echo $?)
if [ "$m" = 124 ] && [ -f "$SNAP" ]; then
  echo "不通 渲染器单测超时现场：$(hostname -s):${SNAP}（$(sed -n 2p "$SNAP" | cut -c5-)）"
  sed 's/^/不通 现场 /' "$SNAP.digest" 2> /dev/null | head -8
fi
# 渲染器单测撞 300 秒上限（10-23 两个不碰 gfx 的分支各撞一次，平时整套 19 秒）：报出超时时在跑哪一项、已跑完各项里最慢的一项（Makefile 每项打「·· <项> N 秒」），不再只剩一个退出码
mx=; [ "$m" = 124 ] && mx="：超时时在跑 $(grep '^== ' "$LOG/metal.log" | tail -1 | cut -c4-)，已跑完的最慢 $(grep '^·· ' "$LOG/metal.log" | sort -t' ' -k3 -n | tail -1 | sed 's/^·· //')"
else pb=0; m=0; mx=; reg 0 "渲染器预编与单测（graphics/metal make test-deps / test）：本批没改到 graphics/metal 及其源码依赖，不跑"; fi
if has "$RUNG" track_net; then
c=$(timeout 150 bash graphics/track/tests/ryucmp/build_run.sh 1 2000 > "$LOG/ryucmp.log" 2>&1; echo $?)
# 写跟踪 × GPFIFO 排空时机（真 Ryujinx GPFifoDevice + 真缺页）：排空之后才提交的命令，处理时它提交前的写已报脏
fd=$(timeout 300 bash graphics/track/tests/fifodrain/build_run.sh > "$LOG/fifodrain.log" 2>&1; echo $?)
# Android 精确排空读取不可读页（Mac 真实 tracker / 保护页与 Android 托管消费者）
dr=$(timeout 300 bash graphics/track/tests/drain_readflush/build_run.sh > "$LOG/drain_readflush.log" 2>&1; echo $?)
reg "$dr" "Android 精确排空：$(tail -1 "$LOG/drain_readflush.log")（退出 ${dr}）" "$LOG/drain_readflush.log"
else c=0; fd=0; reg 0 "写跟踪 .NET 组（对拍 / 排空时机 / Android 精确排空 / 回写锁顺序 / 部分回写 / 保留回写 / 零拷贝 / 多段映射 / 贴图精确跳过）：本批没改到写跟踪及其 Ryujinx / 产品依赖，不跑"; fi
# Real Texture and DMA consumers, tracker-protected pages, and the old borrowed-read red control.
if has "${GATE_SKIP:-}" texture_dma_read; then reg 0 "纹理 / DMA 保护页读取另跑（GATE_SKIP）"
elif ! has "$RUNG" texture_dma_read; then reg 0 "纹理 / DMA 保护页读取：本批没改到写跟踪 / 安卓只读拷贝及其 Ryujinx / 产品依赖，不跑"
else run_texture_dma_read; r=$?; reg "$r" "纹理 / DMA 保护页读取：$(tail -1 "$LOG/texture_dma_read.log")（退出 ${r}）" "$LOG/texture_dma_read.log"; fi
if has "${GATE_SKIP:-}" shared_gpu_contract; then reg 0 "共享 GPU 合同另跑（GATE_SKIP）"
elif ! has "$RUNG" shared_gpu_contract; then reg 0 "共享 GPU 合同：本批没改到它的 Ryujinx 依赖，不跑"
else run_shared_gpu_contract; r=$?; reg "$r" "共享 GPU 合同：$(tail -1 "$LOG/shared_gpu_contract.log")（退出 ${r}）" "$LOG/shared_gpu_contract.log"; fi
if has "${GATE_SKIP:-}" vulkan_diag; then reg 0 "Vulkan 诊断默认值另跑（GATE_SKIP）"
elif ! has "$RUNG" vulkan_diag; then reg 0 "Vulkan 诊断默认值：本批没改到 Vulkan 后端及其依赖，不跑"
else run_vulkan_diag; r=$?; reg "$r" "Vulkan 诊断默认值：$(tail -1 "$LOG/vulkan_diag.log")（退出 ${r}）" "$LOG/vulkan_diag.log"; fi
# 回写锁顺序（真 Ryujinx Buffer / 区间表 / MemoryTracking + 产品 GuestMemory）：持区间表锁回写时不拿跟踪锁，和持跟踪锁清区间不互等（旧回写别名即 ABBA 死锁）
if has "$RUNG" track_net; then
fa=$(timeout 300 bash graphics/track/tests/flushlock/build_run.sh > "$LOG/flushlock.log" 2>&1; echo $?)
# 部分回写换算（S2APartialLayout 逐子页 = Ryujinx 原版整张转换）与保留回写动作（RegionHandle.S2AKeepAction 两线程不漏拦）
pl=$(timeout 300 bash graphics/track/tests/partial/build_run.sh > "$LOG/partial.log" 2>&1; echo $?)
ka=$(timeout 300 bash graphics/track/tests/keepact/build_run.sh > "$LOG/keepact.log" 2>&1; echo $?)
zp=$(timeout 300 bash graphics/track/tests/zcpolicy/build_run.sh > "$LOG/zcpolicy.log" 2>&1; echo $?)
# 多段映射不压段（真 VirtualRangeCache / BufferCache + 产品 GuestMemory）：跨两映射、第二段不 64 KB 对齐的拷贝 / 清缓冲逐段写，第一段之后的游戏内存不动（10-28 银河2 崩溃根修）
vs=$(timeout 300 bash graphics/track/tests/vrcsplit/build_run.sh > "$LOG/vrcsplit.log" 2>&1; echo $?)
tp=$(timeout 300 bash graphics/track/tests/texprecise/build_run.sh > "$LOG/texprecise.log" 2>&1; echo $?)
else fa=0; pl=0; ka=0; zp=0; vs=0; tp=0; fi
# 计数结果回调换线程（真 ThreadedRenderer + 真 Metal 渲染器）：游戏线程持写跟踪锁等同步号不互等、Flush 返回时回调已做完、次序与次数
if has "$RUNG" cntdead; then cd_=$(timeout 300 bash graphics/metal/tests/cntdead/build_run.sh > "$LOG/cntdead.log" 2>&1; echo $?)
else cd_=0; fi
# 图形会话与释放队列（真 NativeAOT + NxGal，graphics/metal/tests/session）：10 局 × 120 次呈现读回、每局 10032 个真缓冲释放、旧释放顺序必须红（本机负载 30 时约 55 秒）
if has "$RUNG" session; then ss=$(timeout 300 bash graphics/metal/tests/session/build_run.sh > "$LOG/session.log" 2>&1; echo $?); reg $ss "图形会话：$(tail -1 "$LOG/session.log" | cut -c1-120)（退出 ${ss}）" "$LOG/session.log"
else reg 0 "图形会话：本批没改到渲染器 / NxGal 闭包，不跑"; fi
n4=$(bash graphics/metal/tools/mtl4_count.sh); b4=$(cat graphics/metal/tools/mtl4_baseline.txt); m4=$(python3 tools/mtl4_ratchet.py metal); r4=$?; [ $r4 = 0 ] || REGBAD="${REGBAD:+${REGBAD}；}$m4"   # Metal 4 直接调用棘轮：新代码走 graphics/metal/gal_be.h，只减不增（减了就同笔改小基线）
# 参数绑定棘轮（#114 M3-7）：gal 层直接调参数表 setAddress 的行数只减不增——目标是全部收进 gal_be_bind 入口（M4 = setAddress，M3 = 编码器 set*Buffer）
n5=$(bash graphics/metal/tools/setaddr_count.sh); b5=$(cat graphics/metal/tools/setaddr_baseline.txt); reg $(( n5 <= b5 ? 0 : 1 )) "参数绑定 setAddress 直调 ${n5} 行（基线 ≤ ${b5}；收一处同笔改小基线）"
# 直连后端接口棘轮（#199 WP17 D0）：NVN 前端 hle_nvn.c 只经与后端无关的 nvn_be_* 调后端（Metal 实现在 nvn_mtl.m，Vulkan 后端 nvn_vk.c 实现同一套），不许直接出现 mtl_ 调用
n6=$(sed 's#//.*##' graphics/nvn/gfx/nvn/hle_nvn.c | grep -c '\bmtl_'); reg $(( n6 == 0 ? 0 : 1 )) "NVN 前端直调 mtl_ ${n6} 处（要 0：经 nvn_be_* 调后端）"
# 直连回放层同款棘轮（#277 D3-1）：graphics/nvn/gfx 下 MTL4 出现处只减不增，新代码经 nvn_mtl.m 包装函数碰 Metal 4
m4d=$(python3 tools/mtl4_ratchet.py nvn); reg $? "$m4d"   # 直连 MTL4 棘轮：超基线时点名新增的 文件:行（函数）；同一判定在入队预检的快步 tests/mtl4_ratchet_test.sh
# 直连「未守卫新系统 API」棘轮在合入前快步 tests/avail_ratchet_test.sh（11-01 挪出：钩子是合入后层慢步，新增红会被旧红淹没）
# 直连回放层两路后端冒烟（#277，graphics/nvn/tests/t_nvn_m3.m）：链 libnvn.a，缺省 Metal 4 与 NXGAL_BE=mtl3 各一个子进程（选路行 / 提交与完成回写 / 主拷贝 / 上屏等外部事件），约 2 秒
if ! need_nvn; then reg 0 "直连两路后端冒烟：本批没改到 graphics/nvn，不跑"
else timeout 300 make -s -C graphics/nvn test > "$LOG/nvn_m3.log" 2>&1; r=$?; reg $r "直连两路后端冒烟：$(tail -1 "$LOG/nvn_m3.log")（退出 ${r}）" "$LOG/nvn_m3.log"; fi
# 采样器归约 / LOD 偏置的设备端模拟变体（S2A.Dsh FsLb / FsRd + nvn_red.h，#800）：改写逐字核 + 常量都假 = 原样（含动森真库逐支）+ GPU 对拍，
#   同一采样位置 Metal 26 原生 min / max 归约 / 采样器偏置 vs 着色器模拟逐位相等、平均采样反证；要 macOS 26。
#   11-01 缺口族 31：任意边界色（s2a_bs 对 CPU 手算、改前三档反证）、最近点 / 混合过滤的归约、比较采样的 LOD 偏置（--cmp）同在这一项
if ! need_red; then reg 0 "采样器模拟变体：本批没改到 graphics/nvn，不跑"
else timeout 300 python3 graphics/nvn/tests/t_red.py > "$LOG/red.log" 2>&1; r=$?; reg $r "采样器模拟变体：$(tail -1 "$LOG/red.log")（退出 ${r}）" "$LOG/red.log"; fi
# 折行贴图（11-03 Switch Sports 字库 1024×32768 超 Metal 2D 上限：tex_linear 折行 + 变体 s2a_fx）：nvn_fold_k 手算 + 硬件采样逻辑贴图对拍变体读折行贴图（graphics/nvn/tests/t_fold.py）
if ! need_red; then reg 0 "折行贴图：本批没改到 graphics/nvn，不跑"
else timeout 300 python3 graphics/nvn/tests/t_fold.py > "$LOG/fold.log" 2>&1; r=$?; reg $r "折行贴图：$(tail -1 "$LOG/fold.log")（退出 ${r}）" "$LOG/fold.log"; fi
# NVN 纹理存储布局 / 解块 / 格式对照单测（graphics/nvn/gfx/tex/tests：t_tex 布局与解块、t_fmt_mtl 格式表，几秒）：10-27 前没登记进任何门禁，
#   侍魂晓稀疏纹理布局算小（直连崩）就在它覆盖的面上
if ! need_nvn_tex; then reg 0 "NVN 纹理布局单测：本批没改到纹理布局，不跑"
else timeout 120 make -s -B -C graphics/nvn/gfx/tex/tests run > "$LOG/nvn_tex.log" 2>&1; r=$?; reg $r "NVN 纹理布局单测：$(tail -1 "$LOG/nvn_tex.log")（退出 ${r}）" "$LOG/nvn_tex.log"; fi
mc=$(timeout 200 bash graphics/tools/macrogen/regen.sh check 2>&1); mcr=$?; mc=$(tail -1 < <(printf '%s\n' "$mc"))   # 宏语料 ⊆ 宏表（没有语料目录时跳过、退 0）；总判看退出码 mcr（11-01 审计 P1-63：原先接 tail 只认末行 ✗，生成器失败 / 超时被杀当过）
if has "${GATE_SKIP:-}" pso_cache; then p=0; pc="管线分片缓存反证另跑（GATE_SKIP）"
elif ! need_pso; then p=0; pc="管线分片缓存反证：本批没改到，不跑"
else timeout 60 bash graphics/tools/shbake/tests/t_pso_cache.sh > "$LOG/pso_cache.log" 2>&1; p=$?; pc=$(tail -1 "$LOG/pso_cache.log"); fi   # 管线分片缓存：任一键成员变必须不命中
# 包内特化核对（Ryujinx 0092）：逐字段不符判不符 + 红行、没读过的不判；编 S2A.SpecTest 约 20–60 秒
if has "$RUNG" shbake_net; then
timeout 400 bash graphics/tools/shbake/tests/t_spec_verify.sh > "$LOG/spec_verify.log" 2>&1; sv=$?; svr=$(tail -1 "$LOG/spec_verify.log")
# 包内管线状态合并（PipelineStatePreference）：旧无状态记录 + 新有状态记录同客体时保留有状态、has=0 负控不凭空补 state
timeout 120 bash graphics/tools/shbake/tests/t_pipeline_state.sh > "$LOG/pipeline_state.log" 2>&1; ps=$?; reg $ps "包内管线状态合并：$(tail -1 "$LOG/pipeline_state.log")（退出 ${ps}）" "$LOG/pipeline_state.log"
# 免解读缓存分块存储（Ryujinx 补丁 seg-chunks-native，10-24 帧率能耗线）：按需分块、放满零托管分配、一段不跨块、清空复用；旧写法反证；编 S2A.SegChunksTest 约 20–60 秒
timeout 400 bash graphics/tools/shbake/tests/t_seg_chunks.sh > "$LOG/seg_chunks.log" 2>&1; sgc=$?; sgcr=$(tail -1 "$LOG/seg_chunks.log")
# 多线程渲染器等程序不自旋（Ryujinx 补丁 progq-wait-block，10-24 出图停 60 秒以上）：所等程序后台永不编完也返回、待编队列里的当场建且出队不重建、失败也返回；编 S2A.ProgQueueTest 约 20–60 秒
timeout 400 bash graphics/tools/shbake/tests/t_prog_queue.sh > "$LOG/prog_queue.log" 2>&1; r=$?; reg $r "等程序不自旋：$(tail -1 "$LOG/prog_queue.log")（退出 ${r}）" "$LOG/prog_queue.log"
# 目标设备能力串（TargetCaps.Parse → NxCaps.Build）：缺省保留 BC、实测无 BC 走非压缩、非法串必须抛异常（11-01 审计 P1-64：原先白名单写「没人调」，扫描洗成全绿）
timeout 400 dotnet run -c Release --project graphics/tools/shbake/tests/targetcaps/S2A.TargetCapsTest.csproj --artifacts-path build/targetcaps_test < /dev/null > "$LOG/targetcaps.log" 2>&1; r=$?; reg $r "目标设备能力串：$(tail -1 "$LOG/targetcaps.log")（退出 ${r}）" "$LOG/targetcaps.log"
else sv=0; svr="特化核对：本批没改到 shbake / 其 Ryujinx 依赖，不跑"; sgc=0; sgcr="录段分块：同上不跑"; reg 0 "shbake .NET 组（特化核对 / 录段分块 / 等程序不自旋 / 转计算 / 片元输出 / 实化 / 翻译告警 / seen）：本批没改到 shbake 及其 Ryujinx / NxGalCaps / Widen 依赖，不跑"; fi
if has "$RUNG" frame_pacing; then timeout 400 bash tests/frame_pacing/test.sh < /dev/null > "$LOG/frame_pacing.log" 2>&1; r=$?; reg $r "帧节奏策略与交换间隔：$(tail -1 "$LOG/frame_pacing.log")（退出 ${r}）" "$LOG/frame_pacing.log"
else reg 0 "帧节奏策略：本批没改到 S2A.Gfx 及其 Ryujinx.HLE 依赖，不跑"; fi
# 直连兜底现编 S2A.Dsh（graphics/tools/direct/dsh）对拍动森离线链产物：命令行 spirv-cross 抽 300 键逐字节 / 语义一致、导出入口、内置 SPIRV-Cross 抽 500 键 + Metal 建库、反证、失败路径、逐函数对照；
#   考卷是本机直连库缓存（游戏着色器不分发），gate-host 上跳过、本机另跑（本文件头「# 门禁本机：dsh」）
if has "${GATE_SKIP:-}" dsh; then reg 0 "直连兜底现编对拍另跑（GATE_SKIP）"
elif ! need_dsh; then reg 0 "直连兜底现编对拍：本批没改到 graphics/tools/direct，不跑"
else timeout 300 bash graphics/tools/direct/tests/t_dsh.sh > "$LOG/dsh.log" 2>&1; r=$?; reg $r "直连兜底现编：$(tail -1 "$LOG/dsh.log")（退出 ${r}）" "$LOG/dsh.log"; fi
# OpenGL 前端最小绘制与 MRT / 深度模板真实 GPU 回归（gate-host 上跳过、本机另跑：子项键 gl）。
if has "${GATE_SKIP:-}" gl; then reg 0 "OpenGL 前端最小绘制另跑（GATE_SKIP）"
elif ! need_gl; then reg 0 "OpenGL 前端最小绘制：本批没改到 GL 前端，不跑"
else timeout 120 bash graphics/nvn/tests/gl/t_gl_min.sh > "$LOG/gl.log" 2>&1; r=$?; reg $r "OpenGL 前端最小绘制：$(tail -1 "$LOG/gl.log")（退出 ${r}）" "$LOG/gl.log"
  timeout 300 bash graphics/nvn/tests/gl/t_gpu_mip.sh > "$LOG/gl_gpu_mip.log" 2>&1; r=$?; reg $r "OpenGL 渲染纹理 mip / cube：$(tail -1 "$LOG/gl_gpu_mip.log")（退出 ${r}）" "$LOG/gl_gpu_mip.log"
  timeout 300 bash graphics/nvn/tests/gl/t_gpu_mrt.sh > "$LOG/gl_gpu_mrt.log" 2>&1; r=$?; reg $r "OpenGL MRT：$(tail -1 "$LOG/gl_gpu_mrt.log")（退出 ${r}）" "$LOG/gl_gpu_mrt.log"
  timeout 300 bash graphics/nvn/tests/gl/t_gpu_depth_stencil.sh > "$LOG/gl_gpu_depth_stencil.log" 2>&1; r=$?; reg $r "OpenGL 深度模板：$(tail -1 "$LOG/gl_gpu_depth_stencil.log")（退出 ${r}）" "$LOG/gl_gpu_depth_stencil.log"
  timeout 120 bash graphics/nvn/tests/gl/t_gl_api.sh > "$LOG/gl_api.log" 2>&1; r=$?; reg $r "OpenGL 接口补齐：$(tail -1 "$LOG/gl_api.log")（退出 ${r}）" "$LOG/gl_api.log"
  timeout 60 bash graphics/nvn/tests/gl/t_glsl_es.sh > "$LOG/gl_glsl_es.log" 2>&1; r=$?; reg $r "GLSL 改写层：$(tail -1 "$LOG/gl_glsl_es.log")（退出 ${r}）" "$LOG/gl_glsl_es.log"
  timeout 300 bash graphics/nvn/tests/gl/t_gl_rt.sh > "$LOG/gl_rt.log" 2>&1; r=$?; reg $r "OpenGL 运行时兜底：$(tail -1 "$LOG/gl_rt.log")（退出 ${r}）" "$LOG/gl_rt.log"; fi
if has "${GATE_SKIP:-}" vk; then reg 0 "Vulkan 层另跑（GATE_SKIP）"
elif ! need_vk; then reg 0 "Vulkan 层：本批没改到 Vulkan 前端，不跑"
else run_vk; vi=$?; reg "$vi" "$VK_RESULT"; fi
if has "${GATE_SKIP:-}" present_residency; then reg 0 "上屏驻留集成另跑（GATE_SKIP）"
elif ! need_present_residency; then reg 0 "上屏驻留集成：本批没改到相关路径，不跑"
# 这组开生产 Mac 前端真窗口并激活应用：用例断言窗口可见、键窗口、失焦 / 复焦，不激活就测不真；在有人用的本机上跑会弹窗抢焦点（11-01 维护者 反映）。
#   只在远端门禁机跑（维护方工具 设 S2A_REMOTE_RUN=1；合入后层 GATE_HOST=gate-host）；本机要跑点名 GATE_ONLY=present_residency
elif [ "${S2A_REMOTE_RUN:-}" != 1 ]; then reg 0 "上屏驻留集成：要开真窗口抢焦点，本机不跑，交 gate-host 门禁（本机要跑：GATE_ONLY=present_residency）"
else run_present_residency; pr=$?; reg "$pr" "$PRESENT_RESIDENCY_RESULT"; fi
timeout 30 python3 graphics/nvn/tests/t_gfx_api.py > "$LOG/gfx_api.log" 2>&1; r=$?; reg $r "图形接口判法：$(tail -1 "$LOG/gfx_api.log")（退出 ${r}）" "$LOG/gfx_api.log"
# RE 引擎程序表（SDF 记录 = 程序、KPKA 补丁链取最新版）：抽取要 lz4，Yaz0/SARC 用 graphics/tools/nxfmt.py，用出包同一个 venv
# Yaz0 / SARC（nxfmt）。tools/gate.sh 改到 graphics/ 时派到本钩子；用出包同一个 venv，装了 oead 才做对照
timeout 120 "$PYV" graphics/tools/tests/test_nxfmt.py > "$LOG/nxfmt.log" 2>&1; r=$?; reg $r "Yaz0/SARC nxfmt（出包 venv，装了 oead 才对照）：$(tail -1 "$LOG/nxfmt.log")（退出 ${r}）" "$LOG/nxfmt.log"
timeout 60 "$PYV" graphics/tools/shbake/tests/t_sdf.py > "$LOG/sdf.log" 2>&1; q=$?; qc=$(tail -1 "$LOG/sdf.log")
timeout 60 "$PYV" graphics/tools/shbake/tests/t_spch.py > "$LOG/spch.log" 2>&1; sph_=$?; sphc=$(tail -1 "$LOG/spch.log")   # Monolith SPCH 着色器容器（异度 3）
timeout 60 "$PYV" graphics/tools/shbake/tests/t_nvn_uses.py > "$LOG/nvn_uses.log" 2>&1; u=$?; uc=$(tail -1 "$LOG/nvn_uses.log")   # 透明测试静态判定：RE 引擎取函数指针写法
timeout 60 "$PYV" graphics/tools/shbake/tests/t_trpfs.py > "$LOG/trpfs.log" 2>&1; tpf=$?; reg $tpf "trpfs 容器枚举：$(tail -1 "$LOG/trpfs.log")（退出 ${tpf}）" "$LOG/trpfs.log"   # Trinity / ONEPACK：描述表映射、包表、条目压缩分类、哈希数与条目数不勾要报错（合成容器，不用游戏数据）
timeout 60 "$PYV" graphics/tools/shbake/tests/t_pso_spec_only.py > "$LOG/pso_spec_only.log" 2>&1; r=$?; reg $r "管线归档只出特化表（直连款通用兜底只编社区状态 + 种子）：$(tail -1 "$LOG/pso_spec_only.log")（退出 ${r}）" "$LOG/pso_spec_only.log"
timeout 60 "$PYV" graphics/tools/shbake/tests/t_pso_int_blend.py > "$LOG/pso_int_blend.log" 2>&1; r=$?; reg $r "特化管线整数目标不开混合（与运行时 pso_desc_colors 同规则）：$(tail -1 "$LOG/pso_int_blend.log")（退出 ${r}）" "$LOG/pso_int_blend.log"
# 离线库合编按阶段分子批（gal_offline.py）：只改顶点时片元的 .air 全部命中、分片仍是连续键区间
if has "$RUNG" metal; then
timeout 120 bash graphics/metal/tests/t_offline_stage.sh > "$LOG/offline_stage.log" 2>&1; os_=$?; reg $os_ "离线库按阶段分子批：$(tail -1 "$LOG/offline_stage.log")（退出 ${os_}）" "$LOG/offline_stage.log"
# 离线库大 MSL 单独编 + 编译按内存预算（gal_offline.py，10-26 斯普拉遁3 19.4 MB 那支拖死整批）：反证旧版不单独编
timeout 150 bash graphics/metal/tests/t_offline_big.sh > "$LOG/offline_big.log" 2>&1; ob_=$?; reg $ob_ "离线库大 MSL 单独编：$(tail -1 "$LOG/offline_big.log")（退出 ${ob_}）" "$LOG/offline_big.log"
else reg 0 "离线库按阶段分子批 / 大 MSL 单独编：本批没改到 graphics/metal 及其源码依赖，不跑"; fi
# 着色器包产出指纹（out_fp.py）：只动非内容字节 / 只改运行时源码 → 不变；内容、③④ 脚本、影响产物的开关变 → 变
timeout 60 bash graphics/tools/shbake/tests/t_out_fp.sh > "$LOG/out_fp.log" 2>&1; of_=$?; reg $of_ "着色器包产出指纹（输出不变就不算变）：$(tail -1 "$LOG/out_fp.log")（退出 ${of_}）" "$LOG/out_fp.log"
if has "$RUNG" shbake_net; then
timeout 300 bash graphics/tools/shbake/tests/t_vtg.sh > "$LOG/vtg.log" 2>&1; v=$?; vr=$(grep -o 't_vtg：[0-9]* 项，失败 [0-9]*' "$LOG/vtg.log" | tail -1)   # 转计算程序进缓存（保留布局 / 复合二进制 / 阶段掩码）
# 片元输出类型变体（ShaderBake 5c：按特化管线表的整数目标补 FragmentOutputTypes 变体，片元键对上观测才收）；与 t_vtg 共用编译目录（增量不重编）
T_FOUT_OUT="$PWD/build/t_vtg" timeout 300 bash graphics/tools/shbake/tests/t_fout.sh > "$LOG/fout.log" 2>&1; fo=$?; for_=$(grep -o 't_fout：[0-9]* 项，失败 [0-9]*' "$LOG/fout.log" | tail -1)
# 片元输出按整数位写的静态判定（ShaderBake 5d 用，FoutStatic）：手写 SPIR-V，整数写 → 掩码 5、全浮点反证 → 0；与 t_vtg 共用编译目录
T_VTG_OUT="$PWD/build/t_vtg" timeout 120 bash graphics/tools/shbake/tests/t_fout_static.sh > "$LOG/fout_static.log" 2>&1; fs_=$?; reg $fs_ "片元整数输出静态判定：$(tail -1 "$LOG/fout_static.log")（退出 ${fs_}）" "$LOG/fout_static.log"
# 按需实化不等渲染线程（DiskCacheHostStorage.S2AMaterializeCore：渲染线程卡在一支现编上时实化不被拖住、补查链接失败作废）；与 t_vtg 共用编译目录
T_VTG_OUT="$PWD/build/t_vtg" timeout 120 bash graphics/tools/shbake/tests/t_mat_wait.sh > "$LOG/mat_wait.log" 2>&1; mw=$?; reg $mw "按需实化不等渲染线程：$(grep -o 't_mat_wait：[0-9]* 项，失败 [0-9]*' "$LOG/mat_wait.log" | tail -1) $(grep -o 't_mat_wait 分段：.*' "$LOG/mat_wait.log" | tail -1)（退出 ${mw}）" "$LOG/mat_wait.log"
# 翻译告警分类计数（ShaderBake BakeGpuAccessor.Log → translator_log.tsv）+ 棘轮：手拼样本的告警种类 / 次数 ≤ tests/trlog_baseline.tsv、不许新种类（只减不增）；与 t_vtg 共用编译目录
T_VTG_OUT="$PWD/build/t_vtg" timeout 120 bash graphics/tools/shbake/tests/t_trlog.sh > "$LOG/trlog.log" 2>&1; r=$?; reg $r "翻译告警计数：$(grep -o 't_trlog：[0-9]* 项，失败 [0-9]*' "$LOG/trlog.log" | tail -1) $(grep -o '翻译告警棘轮：.*' "$LOG/trlog.log" | tail -1)（退出 ${r}）" "$LOG/trlog.log"
# #1456 单点诊断门序与写出（S2AGsDiag：门关零读零写、门开三类落盘）；与 t_vtg 共用编译目录
T_GSDIAG_OUT="$PWD/build/t_vtg" timeout 120 bash graphics/tools/shbake/tests/t_gsdiag.sh > "$LOG/gsdiag.log" 2>&1; gd=$?; reg $gd "#1456 诊断单测：$(grep -o 't_gsdiag：[0-9]* 项，失败 [0-9]*' "$LOG/gsdiag.log" | tail -1)（退出 ${gd}）" "$LOG/gsdiag.log"
else v=0; vr="转计算单测：同上不跑"; fo=0; for_="片元输出类型变体单测：同上不跑"; fi
timeout 60 "$PYV" graphics/tools/shbake/tests/t_programs.py > "$LOG/programs.log" 2>&1; w=$?; wc_=$(tail -1 "$LOG/programs.log")   # 外部程序表读取器：同文件配对 / shadernx.cache 只顶点
timeout 60 "$PYV" graphics/tools/shbake/tests/t_ue_programs.py > "$LOG/ue_programs.log" 2>&1; x=$?; xc_=$(tail -1 "$LOG/ue_programs.log")   # UE4 冷冻着色器表配对 + CityHash
timeout 60 "$PYV" graphics/tools/shbake/tests/t_unity.py > "$LOG/unity.log" 2>&1; y=$?; yc_=$(tail -1 "$LOG/unity.log")   # Unity 资源包 / 序列化文件里的 Shader 代码块
timeout 60 "$PYV" graphics/tools/shbake/tests/t_red_static.py > "$LOG/red_static.log" 2>&1; z=$?; zc_=$(tail -1 "$LOG/red_static.log")   # REDengine 静态程序：条目键配方对游戏原值 + 窗口收集
timeout 60 "$PYV" graphics/tools/shbake/tests/t_exe_shtab.py > "$LOG/exe_shtab.log" 2>&1; es=$?; esc=$(tail -1 "$LOG/exe_shtab.log")   # 主程序内嵌着色器程序表：描述符数组 + 组合表（Scaleform 布局）
timeout 120 "$PYV" graphics/tools/shbake/tests/t_unpack_generic.py > "$LOG/unpack_generic.log" 2>&1; ug=$?; ugc=$(tail -1 "$LOG/unpack_generic.log")
# 通用解压表（gzip / xz / LZMA / LZ4 帧 / Yay0 / LZ10 / LZ11 / BLZ）与解不开数据块报告（10-22 第 3 项）
timeout 120 "$PYV" graphics/tools/shbake/tests/t_nxdecomp.py > "$LOG/nxdecomp.log" 2>&1; nd=$?; ndc=$(tail -1 "$LOG/nxdecomp.log")
timeout 120 "$PYV" graphics/tools/shbake/tests/t_undecoded.py > "$LOG/undecoded.log" 2>&1; ud=$?; udc=$(tail -1 "$LOG/undecoded.log")   # 通用解压：zstd 字典 / 不写原长的帧 / BNSH 大文件照扫流 / CRILAYLA / 控制段与机器码分表
timeout 30 python3 graphics/tools/shbake/tests/t_pso_cdc.py > "$LOG/pso_cdc.log" 2>&1; pd=$?; pdc=$(tail -1 "$LOG/pso_cdc.log")   # 管线分片按内容分块：增删一个程序只动 1–2 片的键
timeout 30 python3 graphics/tools/shbake/tests/t_psouse.py > "$LOG/psouse.log" 2>&1; pu=$?; puc=$(tail -1 "$LOG/psouse.log")   # 管线首用表收集器：只收正式局、取各局最早帧
timeout 30 python3 graphics/tools/shbake/tests/t_psowarm.py > "$LOG/psowarm.log" 2>&1; pw=$?; pwc=$(tail -1 "$LOG/psowarm.log")   # 提前热程序表：首用表的函数名串对到包内缓存程序号、按首用帧升序、每组取一个
# 分块共享窗口的连续 deflate 续解（10-23 暗黑3 漏抽）：续解解出原文、整份三块全解开、跨块魔数看得到、不在块链上不报红、块链上坏块报红
timeout 60 "$PYV" graphics/tools/shbake/tests/t_zchain.py > "$LOG/zchain.log" 2>&1; zc=$?; zcc=$(tail -1 "$LOG/zchain.log")
timeout 60 "$PYV" graphics/tools/shbake/tests/t_adj_ghost.py > "$LOG/adj_ghost.log" 2>&1; ag=$?; reg $ag "相邻扫描错位幽灵：$(tail -1 "$LOG/adj_ghost.log")（退出 ${ag}）" "$LOG/adj_ghost.log"   # nxsh_extract scan_adj：无头且线程组为 0 丢弃
timeout 60 "$PYV" graphics/tools/shbake/tests/t_bnsh_slice.py > "$LOG/bnsh_slice.log" 2>&1; bs=$?; reg $bs "BNSH 按头长切片不拷到文件尾：$(tail -1 "$LOG/bnsh_slice.log")（退出 ${bs}）" "$LOG/bnsh_slice.log"   # nxsh_extract _scan_blob（#711 Windows 抽取 MemoryError）
timeout 60 "$PYV" graphics/tools/shbake/tests/t_zsdict_heads.py > "$LOG/zsdict_heads.log" 2>&1; zh=$?; reg $zh "zstd 字典收集按头筛选、有界排队：$(tail -1 "$LOG/zsdict_heads.log")（退出 ${zh}）" "$LOG/zsdict_heads.log"   # nxsh_extract find_zsdicts（#639 用到字典的款整读全部小文件）
timeout 60 "$PYV" -B graphics/tools/shbake/tests/t_container_b.py > "$LOG/container_b.log" 2>&1; r=$?; reg $r "着色器容器 B 组：$(tail -1 "$LOG/container_b.log")（退出 ${r}）" "$LOG/container_b.log"   # kitpak.py / hgpak.py + nxsh_extract work_members、scan_adj 背靠背机器码在前（11-02 Unravel Two / No Man's Sky）
timeout 120 "$PYV" graphics/tools/shbake/tests/t_wwise_skip.py > "$LOG/wwise_skip.log" 2>&1; ww=$?; reg $ww "Wwise 音频包跳过边界：$(tail -1 "$LOG/wwise_skip.log")（退出 ${ww}）" "$LOG/wwise_skip.log"   # nxsh_extract top_wwise：确证 Wwise 包不扫、核查模式数反例
# 旧版 UE4 pak（v1–v9 经典索引，10-23 Blade II v4 一支没抽到；11-02 BRAVELY DEFAULT Ⅱ v8）：v4 / v5 / v1 / v8 / v9 逐字节解出、加密与非 Zlib 拒绝、v9 冻结索引拒绝、条目内 zlib 着色器抽得出
timeout 60 "$PYV" graphics/tools/shbake/tests/t_ue_pak_legacy.py > "$LOG/ue_pak_legacy.log" 2>&1; upk=$?; upkc=$(tail -1 "$LOG/ue_pak_legacy.log")
# zstd 解压入口（zstd_lib：libzstd 流式接口，玩家 App 的 Python 3.12 没有 compression.zstd）：记 / 不记原长的帧、多帧、前缀、字典，截断与非 zstd 报错
timeout 60 "$PYV" graphics/tools/shbake/tests/t_zstd_lib.py > "$LOG/zstd_lib.log" 2>&1; r=$?; reg $r "zstd 解压入口：$(tail -1 "$LOG/zstd_lib.log")（退出 ${r}）" "$LOG/zstd_lib.log"
timeout 120 "$PYV" graphics/tools/shbake/tests/t_keyscan.py > "$LOG/keyscan.log" 2>&1; ks=$?; reg $ks "找钥回退扫描并行：$(tail -1 "$LOG/keyscan.log")（退出 ${ks}）" "$LOG/keyscan.log"   # pak_crypto find_key / _scan：1 路与多路都找到、段尾不漏窗、不打印密钥
# IoStore 容器接入出包链（#247）：合成 .utoc/.ucas 解出全部记录、改前 extract.sh 门禁与改前 ue_pak.py 对纯 .utoc 根抽 0 支、Oodle 块判失败、TOC 3 不猜、加密容器借同包 pak 密钥（无钥判红）
timeout 60 "$PYV" graphics/tools/shbake/tests/t_ue_iostore.py > "$LOG/ue_iostore.log" 2>&1; r=$?; reg $r "IoStore 容器接入：$(tail -1 "$LOG/ue_iostore.log")（退出 ${r}）" "$LOG/ue_iostore.log"
# UE pak 版本 9 冻结索引（11-02 鬼灭之刃 / 轩辕剑柒）：合成内存映像 pak 读名字 / 原文、uepak 与 ue_pak.py 两层、越界 / 缺名 / 加密三种判红、改前实现反证
timeout 60 "$PYV" graphics/tools/shbake/tests/t_ue_pak_frozen.py > "$LOG/ue_pak_frozen.log" 2>&1; r=$?; reg $r "UE pak 冻结索引：$(tail -1 "$LOG/ue_pak_frozen.log")（退出 ${r}）" "$LOG/ue_pak_frozen.log"
timeout 60 "$PYV" graphics/tools/shbake/tests/t_uepak_legacy_v7.py > "$LOG/uepak_v7.log" 2>&1; r=$?; reg $r "旧版 pak 5–7 版 + zlib：$(tail -1 "$LOG/uepak_v7.log")（退出 ${r}）" "$LOG/uepak_v7.log"
# 社区 / 用户自带客体着色器缓存读取器（10-27 王国之泪 yuzu v10）：合成缓存正例 + 截断 / 文件头反证 + 本机有真文件时的正对照
timeout 120 "$PYV" graphics/tools/shbake/tests/t_guest_cache.py > "$LOG/guest_cache.log" 2>&1; r=$?; reg $r "客体着色器缓存读取器：$(tail -1 "$LOG/guest_cache.log")（退出 ${r}）" "$LOG/guest_cache.log"
# 着色器缓存键「烘焙脚本」项只算代码行（10-23 换键批）：加注释 / 空行键不变、改代码 / 加 #include 键变、按 HEAD、改名变
timeout 30 bash graphics/tools/shbake/tests/t_key_norm.sh > "$LOG/key_norm.log" 2>&1; kn=$?; knc=$(tail -1 "$LOG/key_norm.log")
# 首用表按客体指纹重定位（10-23）：程序哈希公式对得上运行时真行、旧键换本包同指纹程序并重算哈希、对照里没有 / 哈希核不上的不改写
timeout 30 python3 graphics/tools/shbake/tests/t_psoremap.py > "$LOG/psoremap.log" 2>&1; pm=$?; pmc=$(tail -1 "$LOG/psoremap.log")
timeout 60 python3 graphics/tools/shbake/tests/t_refpso.py > "$LOG/refpso.log" 2>&1; rp=$?; rpc=$(tail -1 "$LOG/refpso.log")   # 社区管线状态换算：动森 212 行 yuzu5 一致 195 / 不一致 0、合并 199
if has "${GATE_SKIP:-}" shdist; then pr=0; prc="shbake 分发组：另跑（子项 shdist）"; dt=0; dtc="翻译器重试另跑（shdist）"; pl2=0; pl2c="分片清单另跑（shdist）"
elif need_shdist; then run_shdist
else pr=0; prc="管线分片分发：本批没改到 shbake / 远端分发，不跑"; dt=0; dtc="翻译器重试：本批没改到 shbake，不跑"; pl2=0; pl2c="分片清单：本批没改到 shbake，不跑"; fi
# 直连着色器库合并抽取（双轨 §12.3）：直连口径重算键、S2Arm 独有键补进直连包目录与表、记录读回原字节、表键与记录不符报红
timeout 30 python3 graphics/tools/direct/tests/t_run_pairs.py > "$LOG/run_pairs.log" 2>&1; rc_=$?; reg $rc_ "跑局配对并入：$(tail -1 "$LOG/run_pairs.log")（退出 ${rc_}）" "$LOG/run_pairs.log"   # P 行 → shader_pairs.tsv（run_pairs.py）
timeout 30 python3 graphics/tools/direct/tests/t_run_knowledge.py > "$LOG/run_knowledge.log" 2>&1; rc_=$?; reg $rc_ "跑局知识快照：$(tail -1 "$LOG/run_knowledge.log")（退出 ${rc_}）" "$LOG/run_knowledge.log"   # 审计 #1534 P1-54：pso_seed/ → 四张归一化表（run_knowledge.py），与旧流程直读来源产出等价
timeout 300 python3 graphics/tools/direct/tests/t_fout_want.py > "$LOG/fout_want.log" 2>&1; rc_=$?; reg $rc_ "输出类型变体请求：$(tail -1 "$LOG/fout_want.log")（退出 ${rc_}）" "$LOG/fout_want.log"   # R 行 → fout_want.tsv（fout_want.py）+ ft_masks 过滤
timeout 30 python3 graphics/tools/direct/tests/t_rt_collect.py > "$LOG/rt_collect.log" 2>&1; rc_=$?; reg $rc_ "现编回收线索表：$(tail -1 "$LOG/rt_collect.log")（退出 ${rc_}）" "$LOG/rt_collect.log"   # 现编回收 R1（rt_collect.py）：两台设备拉回目录取并集、坏文件不进表
timeout 60 "$PYV" graphics/tools/direct/tests/t_rt_recover.py > "$LOG/rt_recover.log" 2>&1; r=$?; reg $r "现编回收：$(tail -1 "$LOG/rt_recover.log")（退出 ${r}）" "$LOG/rt_recover.log"
timeout 30 python3 graphics/tools/direct/tests/t_pso_seed.py > "$LOG/pso_seed.log" 2>&1; ps_=$?; reg $ps_ "管线种子表零配置生成：$(tail -1 "$LOG/pso_seed.log")（退出 ${ps_}）" "$LOG/pso_seed.log"   # pso_seed.py：只有 game.tsv 的款出库时从真跑 pso_user.tsv 合并
timeout 120 "$PYV" graphics/tools/direct/tests/t_lib_pack.py > "$LOG/lib_pack.log" 2>&1; lp_=$?; reg $lp_ "直连库容器打包：$(tail -1 "$LOG/lib_pack.log")（退出 ${lp_}）" "$LOG/lib_pack.log"   # C# LibPack.PackFiles（dsh_batch --libpack pack）：按种类号排、逐段字节相符、切片能建库（10-26 tools/test_wired_lint.py 扫出原先没登记）
timeout 120 "$PYV" graphics/tools/direct/tests/t_lib_pack_vk.py > "$LOG/lib_pack_vk.log" 2>&1; lv_=$?; reg $lv_ "直连库容器 Vulkan 种类：$(tail -1 "$LOG/lib_pack_vk.log")（退出 ${lv_}）" "$LOG/lib_pack_vk.log"   # #783：_b.spv 种类 52 + 头部 Vulkan 侧指纹，苹果库与改前逐字节相同（不要 xcrun）
if need_dsh_vk; then timeout 300 bash graphics/tools/direct/tests/t_dsh_vk.sh > "$LOG/dsh_vk.log" 2>&1; dv_=$?; reg $dv_ "出包 Vulkan 产物：$(tail -1 "$LOG/dsh_vk.log")（退出 ${dv_}）" "$LOG/dsh_vk.log"
else reg 0 "出包 Vulkan 产物：本批没改到 S2A.Dsh / 翻译器 / SPIRV-Cross，不跑"; fi
if need_dsh_vklib; then timeout 300 bash graphics/tools/direct/tests/t_dsh_vklib.sh > "$LOG/dsh_vklib.log" 2>&1; dl_=$?; reg $dl_ "出包 Vulkan 独立入口：$(tail -1 "$LOG/dsh_vklib.log")（退出 ${dl_}）" "$LOG/dsh_vklib.log"
else reg 0 "出包 Vulkan 独立入口：本批没改到 S2A.Dsh / vklib / 翻译器 / SPIRV-Cross，不跑"; fi
timeout 30 python3 graphics/tools/direct/tests/t_merge_extract.py > "$LOG/merge_extract.log" 2>&1; mx_=$?; mxc=$(tail -1 "$LOG/merge_extract.log")
# Metal 3 二进制归档出包 → 运行时命中（#116 第二批 / #378）：合成 MSL → PSO_M3=1 pso_gen → pso_chunk（metal-tt）→ 老接口按完整描述 FailOnBinaryArchiveMiss 命中，换格式 / 写掩码反证不命中
if has "${GATE_SKIP:-}" m3pack; then reg 0 "Metal 3 归档出包到命中：另跑（子项 m3pack）"
elif ! has "$RUNG" m3pack; then reg 0 "Metal 3 归档出包到命中 / 运行时包归档：本批没改到 graphics/metal / shbake 出包脚本，不跑"
else run_m3pack; reg $? "$M3PACK_RESULT"; fi
# 正式 GLSL 出包 → GAL 运行时归档：两程序 × 两颜色格式真命中，改变混合 / 写掩码真未命中及像素读回。
if has "$RUNG" m3pack; then timeout 300 make -s -C graphics/metal test-m3archive > "$LOG/m3archive.log" 2>&1; r=$?; reg $r "Metal 3 运行时包归档：$(tail -1 "$LOG/m3archive.log")（退出 ${r}）" "$LOG/m3archive.log"; fi
# Unity ComputeShader 各版本的 kernel 变体布局（shader_split.kernel_variants）：2022.3 / 2020.3 / 2018.4（#379 Moving Out）三种认得、未知布局报红
timeout 30 python3 graphics/tools/direct/tests/t_unity_kernels.py > "$LOG/unity_kernels.log" 2>&1; r=$?; reg $r "Unity 计算着色器布局：$(tail -1 "$LOG/unity_kernels.log")（退出 ${r}）" "$LOG/unity_kernels.log"
timeout 30 "$PYV" graphics/tools/direct/tests/t_unity55_layout.py > "$LOG/unity55_layout.log" 2>&1; r=$?; reg $r "Unity 5.5 精确布局：$(tail -1 "$LOG/unity55_layout.log")（退出 ${r}）" "$LOG/unity55_layout.log"
timeout 30 "$PYV" graphics/tools/direct/tests/t_bnsh_bounds.py > "$LOG/bnsh_bounds.log" 2>&1; r=$?; reg $r "BNSH 指针越界跳过：$(tail -1 "$LOG/bnsh_bounds.log")（退出 ${r}）" "$LOG/bnsh_bounds.log"   # shader_split.py bnsh_shaders（10-30 超级机器人大战 X）
timeout 30 "$PYV" graphics/tools/direct/tests/t_ndsr_bare.py > "$LOG/ndsr_bare.log" 2>&1; r=$?; reg $r "NDSR 条目流 + 裸 NVN2 程序：$(tail -1 "$LOG/ndsr_bare.log")（退出 ${r}）" "$LOG/ndsr_bare.log"   # shader_split.py ndsr_shaders / ns2_shaders.py bare_programs（11-06 时之笛开局 12 支计算着色器）
timeout 30 "$PYV" graphics/tools/direct/tests/t_mtarc_width.py > "$LOG/mtarc_width.log" 2>&1; r=$?; reg $r "MT ARC 条目宽度：$(tail -1 "$LOG/mtarc_width.log")（退出 ${r}）" "$LOG/mtarc_width.log"   # shader_split.py mtarc_members（11-02 生化危机6：路径 64 字节）
timeout 60 "$PYV" graphics/tools/direct/tests/t_nlg4.py > "$LOG/nlg4.log" 2>&1; r=$?; reg $r "NLG 新版档案：$(tail -1 "$LOG/nlg4.log")（退出 ${r}）" "$LOG/nlg4.log"   # shader_split.py nlg4_shaders（11-02 马力欧激战前锋 1.3.2）
timeout 60 "$PYV" graphics/tools/direct/tests/t_source_path_posix.py > "$LOG/source_path.log" 2>&1; r=$?; reg $r "来源列路径一律 /：$(tail -1 "$LOG/source_path.log")（退出 ${r}）" "$LOG/source_path.log"   # shader_split.py / nxsh_extract.py 来源串（11-05 Windows 出包机勇者斗恶龙 XI S 来源列反斜杠、分组全落 *_other）
timeout 120 "$PYV" graphics/tools/direct/tests/t_list_arg.py > "$LOG/list_arg.log" 2>&1; r=$?; reg $r "资源目录列表文件：$(tail -1 "$LOG/list_arg.log")（退出 ${r}）" "$LOG/list_arg.log"   # extract.sh / shader_split.py / nxsh_extract.py 的 @<列表文件>（11-05 Windows 出包机怪猎崛起 273 个追加内容超过 Windows 命令行上限）
timeout 30 "$PYV" graphics/tools/direct/tests/t_mtspk.py > "$LOG/mtspk.log" 2>&1; r=$?; reg $r "MT SPK 两种排法：$(tail -1 "$LOG/mtspk.log")（退出 ${r}）" "$LOG/mtspk.log"   # shader_split.py mtspk_shaders（11-02 启示录2：控制段在前）
timeout 30 "$PYV" graphics/tools/direct/tests/t_ue_oodle_inline.py > "$LOG/ue_oodle_inline.log" 2>&1; r=$?; reg $r "Unreal 内嵌 Oodle 着色器：$(tail -1 "$LOG/ue_oodle_inline.log")（退出 ${r}）" "$LOG/ue_oodle_inline.log"   # shader_split.py ue_inline_shaders / oodle_frames（11-01 无主之地3）
timeout 30 "$PYV" graphics/tools/direct/tests/t_split_oodle_default.py > "$LOG/split_oodle_default.log" 2>&1; r=$?; reg $r "直连抽取解码器缺省：$(tail -1 "$LOG/split_oodle_default.log")（退出 ${r}）" "$LOG/split_oodle_default.log"   # shader_split.py oodle_defaults（11-07 勇者斗恶龙 XI S 私有根出包 LZ5 红）
timeout 30 "$PYV" graphics/tools/direct/tests/t_split_ctl_magic.py > "$LOG/split_ctl_magic.log" 2>&1; r=$?; reg $r "直连包代码区含控制段魔数：$(tail -1 "$LOG/split_ctl_magic.log")（退出 ${r}）" "$LOG/split_ctl_magic.log"   # shader_split.py pkg_record（#477 一支含魔数整款离线库 0 支）
timeout 30 "$PYV" graphics/tools/direct/tests/t_split_file_skip.py > "$LOG/split_file_skip.log" 2>&1; r=$?; reg $r "直连抽取按文件降级：$(tail -1 "$LOG/split_file_skip.log")（退出 ${r}）" "$LOG/split_file_skip.log"   # shader_split scan_counted（v0.3.1 拿不准不停 ⑦）
timeout 30 "$PYV" graphics/tools/direct/tests/t_ue3_dnbc.py > "$LOG/ue3_dnbc.log" 2>&1; r=$?; reg $r "UE3 包着色器：$(tail -1 "$LOG/ue3_dnbc.log")（退出 ${r}）" "$LOG/ue3_dnbc.log"   # shader_split.py ue3_package / ue3_dnbc_shaders（11-02 BioShock Infinite：LZ4 块里的 DNBC 记录）
# Unity 无类型树的序列化文件（unityfs.shader_layout，10-29）：按版本生成的 Shader 布局与四份对过真树的金样等价、2017.1–2022.3 合成资源能解、版本错 / 多字节响亮停、计算着色器免树找 kernel、空 / 坏程序块跳过计数
timeout 60 "$PYV" graphics/tools/direct/tests/t_unity_layouts.py > "$LOG/unity_layouts.log" 2>&1; r=$?; reg $r "Unity 无树布局：$(tail -1 "$LOG/unity_layouts.log")（退出 ${r}）" "$LOG/unity_layouts.log"
# 直连库整体替换（direct_lib.sh ⑥）：齐全判定的反例逐条不过、交换后新旧互换
timeout 120 python3 graphics/tools/direct/tests/t_lib_swap.py > "$LOG/lib_swap.log" 2>&1; r=$?; reg $r "直连库发布核验：$(tail -1 "$LOG/lib_swap.log")（退出 ${r}）" "$LOG/lib_swap.log"
# 编译时盘写满整次停、不当成单支编不过（#265，Build.cs Metal.DiskFull；假 xcrun 注入编译器输出）
timeout 120 python3 graphics/tools/direct/tests/t_metal_nospace.py > "$LOG/metal_nospace.log" 2>&1; r=$?; reg $r "编译盘写满：$(tail -1 "$LOG/metal_nospace.log")（退出 ${r}）" "$LOG/metal_nospace.log"
# 预编头熔断：带预编头连续编不过、一支没成就整次关掉，不每支编两遍（Build.cs Metal.PchTrip；假 xcrun 注入）
timeout 120 python3 graphics/tools/direct/tests/t_pch_breaker.py > "$LOG/pch_breaker.log" 2>&1; r=$?; reg $r "预编头熔断：$(tail -1 "$LOG/pch_breaker.log")（退出 ${r}）" "$LOG/pch_breaker.log"
# 直连库成批合编（dmsh_build.py unity_flush，10-26）：一批只合编一次、每键 fn_prefix / fn_lib、批编不过逐键退回且日志写明、带额外入口的去掉重编；打包时一批只存一段（lib_pack.py）
timeout 300 python3 graphics/tools/direct/tests/t_unity.py > "$LOG/unity.log" 2>&1; r=$?; reg $r "直连库成批合编：$(tail -1 "$LOG/unity.log")（退出 ${r}）" "$LOG/unity.log"
timeout 120 python3 graphics/tools/direct/tests/t_lib_pack.py > "$LOG/lib_pack.log" 2>&1; r=$?; reg $r "直连库打包容器：$(tail -1 "$LOG/lib_pack.log")（退出 ${r}）" "$LOG/lib_pack.log"
# 直连曲面阶段翻译（libdsx nxgal_dmsh_xc_tess，与渲染器同一套曲面改写）：手算槽号、Metal 编过、非曲面阶段反证
if has "$RUNG" direct_link; then
has "$RUNG" metal || { G=$(pwd -P)/build/gal; "${S2A_PY:-python3}" tools/nostall.py --watch build/gal 300 -- make -s -j"${S2A_CPU_GATE:-$(sysctl -n hw.ncpu 2> /dev/null || echo 8)}" -C graphics/metal "$G/t_tess/vs.spv" "$G/t_tess/tcs.spv" "$G/t_tess/tes.spv" "$G/t_tess/fs.spv" "$G/t_tess/tesatom.spv" > "$LOG/direct_link_build.log" 2>&1 || reg 1 "直连链接版组预编 t_tess：$(tail -1 "$LOG/direct_link_build.log")"; }
make -s -C graphics/dsx "$(pwd -P)/build/dsx/libdsx.dylib" > "$LOG/direct_link_dsx.log" 2>&1 || reg 1 "直连链接版组预编 libdsx：$(tail -1 "$LOG/direct_link_dsx.log")" "$LOG/direct_link_dsx.log"
timeout 60 python3 graphics/tools/direct/tests/t_dmsh_tess.py build/dsx/libdsx.dylib build/gal/t_tess > "$LOG/dmsh_tess.log" 2>&1; dt_=$?; reg $dt_ "直连曲面阶段翻译：$(tail -1 "$LOG/dmsh_tess.log")（退出 ${dt_}）" "$LOG/dmsh_tess.log"
# 直连计算着色器共享内存溢出（libdsx nxgal_dmsh_spill + S2A.Dsh NxgalSpvCross.SpillFix，10-26 怪猎脸黑）：超限改写、Metal 编过、不超限原样、认不出报错（编 dsh_cmp 冷编约 1 分钟）
timeout 300 python3 graphics/tools/direct/tests/t_dmsh_spill.py build/dsx/libdsx.dylib > "$LOG/dmsh_spill.log" 2>&1; ds_=$?; reg $ds_ "直连共享内存溢出：$(tail -1 "$LOG/dmsh_spill.log")（退出 ${ds_}）" "$LOG/dmsh_spill.log"
timeout 300 python3 graphics/tools/direct/tests/t_alpha_ms.py > "$LOG/alpha_ms.log" 2>&1; am_=$?; reg $am_ "直连片元 Alpha 测试 / 多重采样关常量：$(tail -1 "$LOG/alpha_ms.log")（退出 ${am_}）" "$LOG/alpha_ms.log"
# 整份直连出库（C# dsh_batch build）缓存复用 / 只出一侧 / 发布形态：真跑翻译器与 metal，计算着色器共享内存改写要 build/dsx/libdsx.dylib，放在上面预编之后（10-30 原先排在预编前，新工作树的 gate-host 上 3 支全失败、出库 0 个库）
timeout 180 python3 graphics/tools/direct/tests/t_dmsh_reuse.py > "$LOG/dmsh_reuse.log" 2>&1; r=$?; reg $r "整份直连出库缓存复用与出库形态：$(tail -1 "$LOG/dmsh_reuse.log")（退出 ${r}）" "$LOG/dmsh_reuse.log"
timeout 60 python3 tests/se_want_test.py > "$LOG/se_want.log" 2>&1; r=$?; reg $r "采样模拟变体请求表：$(tail -1 "$LOG/se_want.log")（退出 ${r}）" "$LOG/se_want.log"   # se_want.py 挑键（缺口族 31）；整份出库按表出 <键>_se 由 t_dmsh_reuse 守
else reg 0 "直连曲面阶段翻译 / 共享内存溢出 / 只出 iOS 与复用：本批没改到 graphics/metal / graphics/tools / 直连出库脚本，不跑"; fi
# 直连巨型着色器阶梯压平（S2A.Dsh DshFlat.GiantFix / Flatten，10-27 斯普拉遁3 冷启 31 秒停帧）：深度阈值、return 断链、版式不对原样、压不平退不优化、GPU 差分 24 支逐位相同（约 2 分钟）
# 巨型着色器阶梯压平（约 70 秒：24 支计算核原版 / 压平版各编一份上 GPU 差分）只测 S2A.Dsh 压平（graphics/tools/direct/dsh/Flat.cs，经 dsh_cmp --fn）：10-28 gate-host 列车每批 70–75 秒、改 gfx 一行也跑（gfx_timing.tsv）
if need_dmsh_giant; then   # 前缀见 need_dmsh_giant
  timeout 300 python3 graphics/tools/direct/tests/t_dmsh_giant.py > "$LOG/dmsh_giant.log" 2>&1; dg_=$?; reg $dg_ "直连巨型着色器阶梯压平：$(tail -1 "$LOG/dmsh_giant.log")（退出 ${dg_}）" "$LOG/dmsh_giant.log"
else reg 0 "直连巨型着色器阶梯压平：本批没改到压平 / 出库脚本，不跑"; fi
timeout 120 python3 graphics/tools/direct/tests/t_dmsh_ushare.py > "$LOG/dmsh_ushare.log" 2>&1; du_=$?; reg $du_ "直连整数输出入口编译期共用函数体：$(tail -1 "$LOG/dmsh_ushare.log")（退出 ${du_}）" "$LOG/dmsh_ushare.log"   # C# Unity.Share（dsh_batch --unity share）
# 双轨覆盖率 seen 记录（Ryujinx 补丁 direct-seen）：客体哈希查键表、一码多键全写、表外写 code:、跨局去重、坏表报错不记；编 S2A.SeenTest 约 20–60 秒
if has "$RUNG" shbake_net; then timeout 400 bash graphics/tools/direct/tests/t_seen.sh > "$LOG/seen.log" 2>&1; r=$?; reg $r "seen 记录：$(tail -1 "$LOG/seen.log")（退出 ${r}）" "$LOG/seen.log"; fi
# .air 缓存命中（真工具链）：命中刷新条目修改时间（gc 按最近使用删靠它）、条目克隆不了时退回现编不崩
if has "$RUNG" metal; then timeout 60 bash graphics/metal/tests/t_air_cache.sh > "$LOG/air_cache.log" 2>&1; ac=$?; acc=$(tail -1 "$LOG/air_cache.log")
else ac=0; acc=".air 缓存命中：本批没改到 graphics/metal，不跑"; fi
timeout 30 python3 graphics/tools/shbake/tests/t_fbrvars.py > "$LOG/fbrvars.log" 2>&1; fv=$?; fvc=$(tail -1 "$LOG/fbrvars.log")   # 读帧缓冲变体请求收集：真日志行收进表、并集去重、坏行不收、只收正式局
# 特化管线表收集（specpipe.py）：v2 / b2 行收、坏行不收；不给目录时只收正式局（实验局 BUNDLE=io.s2arm-exp.* 跳过）
timeout 30 python3 graphics/tools/shbake/tests/t_specpipe.py > "$LOG/specpipe.log" 2>&1; sp=$?; spc=$(tail -1 "$LOG/specpipe.log")
if has "$RUNG" track_c; then
tr=$(grep -o 't_track：[0-9]* 项，失败 [0-9]*' "$LOG/track.log" | tail -1)
# 失败项当场带出：第一条 ✗ 行（项名 + 期望 / 真结果），门禁红行里直接看到是哪一项
trx=$(grep -m1 '✗' "$LOG/track.log" | tr -s ' ' | cut -c1-160); [ -n "$trx" ] && tr="${tr}｜首个失败：$trx"
else tr="写跟踪单测不跑"; fi
if has "$RUNG" metal; then mr=$(grep -cE '通过|全过' "$LOG/metal.log"); else mr="不跑"; fi
if has "$RUNG" track_net; then
cr=$(grep -oE '(不一致|一致)：种子 [0-9]+，[0-9]+ 轮' "$LOG/ryucmp.log" | tail -1)
fr=$(grep -o 'fifodrain：[0-9]* 项，失败 [0-9]*' "$LOG/fifodrain.log" | tail -1)
far=$(grep -o 'flushlock：[0-9]* 项，失败 [0-9]*' "$LOG/flushlock.log" | tail -1)
plr=$(grep -o 'partial：[0-9]* 项，失败 [0-9]*' "$LOG/partial.log" | tail -1); kar=$(grep -o 'keepact：[0-9]* 项，失败 [0-9]*' "$LOG/keepact.log" | tail -1); zpr=$(grep -o 'zcpolicy：[0-9]* 项，失败 [0-9]*' "$LOG/zcpolicy.log" | tail -1); vsr=$(grep -o 'vrcsplit：[0-9]* 项，失败 [0-9]*' "$LOG/vrcsplit.log" | tail -1); tpr=$(grep -o 'texprecise：[0-9]* 项，失败 [0-9]*' "$LOG/texprecise.log" | tail -1)
else cr="不跑"; fr="排空时机单测不跑"; far="回写锁顺序单测不跑"; plr="部分回写换算单测不跑"; kar="保留回写动作单测不跑"; zpr="零拷贝用法规则单测不跑"; vsr="多段映射不压段单测不跑"; tpr="贴图精确跳过单测不跑"; fi
if has "$RUNG" cntdead; then cdr=$(grep -o 't_cntdead：[0-9]* 项，失败 [0-9]*' "$LOG/cntdead.log" | tail -1); else cdr="计数回调单测：本批没改到 graphics/metal 及 NxGal 依赖，不跑"; fi
OKV=("t:写跟踪单测 t_track" "pb:渲染器预编 test-deps" "m:渲染器单测 make test" "c:写跟踪对拍 ryucmp" "fd:排空时机 fifodrain" "fa:回写锁顺序 flushlock" "pl:部分回写 partial" "ka:保留回写 keepact" "zp:零拷贝用法 zcpolicy" "vs:多段映射 vrcsplit" "tp:贴图精确 texprecise" "cd_:计数回调 t_cntdead" "p:管线分片缓存 t_pso_cache" "sv:特化核对 t_spec_verify" "sgc:录段分块 t_seg_chunks" "q:t_sdf" "sph_:t_spch" "u:t_nvn_uses" "v:t_vtg" "fo:t_fout" "w:t_programs" "x:t_ue_programs" "y:shbake t_unity" "z:t_red_static" "es:t_exe_shtab" "ug:t_unpack_generic" "nd:t_nxdecomp" "ud:t_undecoded" "pd:t_pso_cdc" "pu:t_psouse" "pw:t_psowarm" "zc:t_zchain" "kn:t_key_norm" "pm:t_psoremap" "rp:t_refpso" "pr:管线分片分发 t_pso_dist" "dt:翻译器重试 t_pso_tt_retry" "ac:t_air_cache" "fv:t_fbrvars" "sp:t_specpipe" "pl2:分片清单 t_pso_list" "upk:t_ue_pak_legacy" "mx_:t_merge_extract" "mcr:宏表 regen.sh check")   # 总判的各项退出码 = 变量名:项名，单一来源：总判按它算、判红按它点名（加新项只在这里加一条）
OKLOG=(t:track.log pb:metal_build.log m:metal.log c:ryucmp.log fd:fifodrain.log fa:flushlock.log pl:partial.log ka:keepact.log zp:zcpolicy.log vs:vrcsplit.log tp:texprecise.log cd_:cntdead.log p:pso_cache.log sv:spec_verify.log sgc:seg_chunks.log q:sdf.log sph_:spch.log u:nvn_uses.log v:vtg.log fo:fout.log w:programs.log x:ue_programs.log y:unity.log z:red_static.log es:exe_shtab.log ug:unpack_generic.log nd:nxdecomp.log ud:undecoded.log pd:pso_cdc.log pu:psouse.log pw:psowarm.log zc:zchain.log kn:key_norm.log pm:psoremap.log rp:refpso.log pr:pso_dist.log dt:pso_tt.log ac:air_cache.log fv:fbrvars.log sp:specpipe.log pl2:pso_list.log upk:ue_pak_legacy.log mx_:merge_extract.log)   # OKV 各变量自己那条命令写的日志（红了打进证据）
ok=$(( r4 == 0 )); for e_ in "${OKV[@]}"; do v_=${e_%%:*}; [ "${!v_:-0}" = 0 ] || { ok=0; REGBAD="${REGBAD:+${REGBAD}；}${e_#*:}（退出 ${!v_}）"; for l_ in "${OKLOG[@]}"; do [ "${l_%%:*}" = "$v_" ] && ev 1 "$LOG/${l_#*:}"; done; }; done
[ $REGOK = 1 ] || ok=0
[ $ok = 1 ] || evidence
echo "期望 写跟踪单测 0 失败 / 渲染器 7 组全过 / 对拍一致 / 排空时机单测 0 失败 / 回写锁顺序单测 0 失败 / 计数回调单测 0 失败 / MTL4 直接调用 ≤ $b4 / 管线分块单测与并行编单测全过 → 真结果 ${tr:-无输出}（退出 ${t}）/ 渲染器通过行 ${mr}（退出 ${m}${mx}）/ 对拍 ${cr:-无输出}（退出 ${c}）/ ${fr:-排空时机单测无输出}（退出 ${fd}）/ ${far:-回写锁顺序单测无输出}（退出 ${fa}） / ${plr:-部分回写换算单测无输出}（退出 ${pl}）/ ${kar:-保留回写动作单测无输出}（退出 ${ka}） / ${zpr:-零拷贝用法规则单测无输出}（退出 ${zp}） / ${vsr:-多段映射不压段单测无输出}（退出 ${vs}） / ${tpr:-贴图精确跳过单测无输出}（退出 ${tp}）/ ${cdr:-计数回调单测无输出}（退出 ${cd_}）/ MTL4 $n4 处 / 宏表：${mc#*真结果 } / ${pc:-管线缓存反证无输出} / 特化核对：${svr:-无输出} / 录段分块：${sgcr:-无输出} / ${qc:-RE 程序表单测无输出} / ${sphc:-SPCH 单测无输出} / ${uc:-nvn_uses 单测无输出} / ${vr:-转计算单测无输出}（退出 ${v}）/ ${for_:-片元输出类型变体单测无输出}（退出 ${fo}）/ ${wc_:-程序表读取器单测无输出} / ${xc_:-UE 冷冻表单测无输出} / ${yc_:-Unity 单测无输出} / ${zc_:-REDengine 静态单测无输出} / ${esc:-内嵌着色器程序表单测无输出} / ${ugc:-通用解压单测无输出} / ${ndc:-解压表单测无输出} / ${udc:-解不开数据块单测无输出} / ${pdc:-分块单测无输出} / ${puc:-首用表单测无输出} / ${pwc:-提前热程序表单测无输出} / ${zcc:-分块续解单测无输出} / ${upkc:-旧版 pak 单测无输出} / ${knc:-缓存键规范化单测无输出} / ${pmc:-首用表重定位单测无输出} / ${rpc:-社区管线状态单测无输出} / ${prc:-并行编单测无输出} / ${dtc:-metal-tt 重试单测无输出} / ${pl2c:-分片清单单测无输出}（退出 ${pl2}） / ${mxc:-合并抽取单测无输出}（退出 ${mx_}） / ${acc:-.air 缓存命中单测无输出} / ${fvc:-变体请求收集单测无输出} / ${spc:-特化管线收集单测无输出}，${REGS}，用时 $(( $(date +%s) - T0 )) 秒 $([ $ok = 1 ] && echo ✓ || echo "✗ 判红：${REGBAD:-（没有记下判红项：总判逻辑漏登记，查 OKV / reg）}")"
[ $ok = 1 ]
