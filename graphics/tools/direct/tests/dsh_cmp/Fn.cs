// dsh_cmp --fn <用例.json> <结果.json>：逐函数对照的 C# 一侧（t_dsh_fn.py 出用例、用离线链原函数算期望、比结果）。
// 用例 = [{"fn": 名, "args": [...]}]；结果 = [{"ok": 值} | {"err": 类名}]，值的形状与 Python 原函数返回值过 json 后一致（元组 → 列表、bytes → 十六进制）。
using S2A.Dsh;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

static class Fn
{
    public static int Run(string cases, string outPath, ISpvCross nx)
    {
        var all = JsonNode.Parse(File.ReadAllText(cases)).AsArray(); var res = new List<object>();
        string tmp = Path.Combine(Path.GetTempPath(), "dsh_fn_" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(tmp);
        foreach (var c in all)
        {
            string fn = (string)c["fn"]; var a = c["args"].AsArray();
            string S(int i) => (string)a[i];
            byte[] H(int i) => Convert.FromHexString((string)a[i]);
            try
            {
                object v = fn switch
                {
                    "decode_tex" => DshCompiler.DecodeTex(S(0)) is { } d ? new List<object> { d.T, d.S, d.Ty } : null,
                    "const_sampler" => DshCompiler.ConstSampler(S(0)),
                    "decode_ubo_tex" => DshCompiler.DecodeUboTex(S(0)) is { } u ? new List<object> { new List<object> { u.T.Item1, u.T.Item2 }, u.S.Id != null ? new List<object> { "id", u.S.Id } : u.S.Bound != null ? new List<object> { "bound", u.S.Bound } : u.S.Sid ? new List<object> { u.S.Reg, u.S.Off, "sid" } : new List<object> { u.S.Reg, u.S.Off } } : null,
                    "decode_ubo_img" => DshCompiler.DecodeUboImg(S(0)) is { } ui ? new List<object> { ui.Reg, ui.Off } : null,
                    "ubo_sampler" => DshCompiler.UboSampler(S(0)) is { } us ? new List<object> { us.Reg, us.Off, us.Sid } : null,
                    "user_locs" => DshCompiler.UserLocs(S(0), S(1)),
                    "c2_array" => DshCompiler.C2Array(S(0), S(1)),
                    "reflect" => DshCompiler.Reflect(S(0), S(1), a[2].AsObject()),
                    "drv_reads" => DshCompiler.DrvReads(S(0)),
                    "unfillable" => DshCompiler.Unfillable((PyDict)Py.FromJson(a[0]), a.Count > 1 ? S(1) : null),
                    // NVN2 任务 / 网格（MeshStage.cs）：控制段、整个代码区（十六进制）→ 事实 / 阶段内存 / 包装后的 MSL（t_meshstage.py）
                    "mesh_info" => Py.FromJson(MeshStage.Info(H(0), H(1)).ToJson()),
                    "mesh_memory" => MeshStage.Memory(MeshStage.Info(H(0), H(1))) is var (ml, msz) ? new List<object> { ml.Select(v => (object)(long)v).ToList(), (long)msz } : null,
                    "mesh_to_stage" => MeshStage.ToStage(S(0), MeshStage.Info(H(1), H(2))),
                    "mesh_own_shared" => MeshStage.OwnShared(H(0)),
                    "mesh_guard_loops" => MeshStage.GuardLoops(S(0)),
                    "raster_facts" => DshCompiler.RasterFacts(S(0), S(1)),
                    "int_inputs" => DshCompiler.IntInputs(S(0)),
                    "vs_init" => DshCompiler.VsInit(S(0)),
                    "vs_pad_mask" => DshCompiler.VsPadMask(S(0), (uint)a[1]) is var (vp, vm) ? new List<object> { vp, vm.Cast<object>().ToList() } : null,
                    "vs_layer" => DshCompiler.VsLayer(S(0)),
                    "precise" => DshCompiler.Precise(S(0)),
                    // 只有第一个调用做的存储（Dsh.cs FirstStore）：MSL、线程组尺寸 [x, y, z] 或 null → [改写后的 MSL, [[存储缓冲名, 字号, 值], …]]（t_first_store.py）
                    // 计算核线程数声明（Dsh.cs MaxThreads，#2118）：MSL、线程组尺寸 [x, y, z] 或 null → 改写后的 MSL（t_max_threads.py）
                    "max_threads" => DshCompiler.MaxThreads(S(0), a[1] as JsonArray),
                    "first_store" => DshCompiler.FirstStore(S(0), a[1] as JsonArray) is var (fs, st) ? new List<object> { fs, st.Select(x => (object)new List<object> { x.Name, x.Word, x.Value }).ToList() } : null,
                    "color_round" => NxgalSpvCross.ColorRound(S(0)),
                    "fs_uint" => DshCompiler.FsUint(S(0), a.Count > 1 ? S(1) : null) is (string fs, uint um) && fs != null ? new List<object> { fs, (long)um } : null,
                    "fs_typed" => DshCompiler.FsTyped(S(0), (uint)a[1], (uint)a[2]),
                    "topology_pointer" => DshCompiler.TopologyPointer(S(0)),
                    "roll_vb_copy" => DshCompiler.RollVbCopy(S(0)),
                    "geo_tf" => DshCompiler.GeoTf("k", a[0].AsArray(), a[1].AsObject()),
                    "vin_variant" => DshVin.Variant(S(0)) is var (vb, vm2) ? new List<object> { vb, vm2 } : null,
                    "vs_pull" => DshPull.Variant(S(0)) is var (pb, pm) ? new List<object> { pb, pm } : null,   // 拉取式顶点输入变体 _bp → [MSL 或 null, {entry, entry_z, slot, inputs} 或原因串]（t_vs_pull.py）
                    "fetch_variant" => DshFetch.Variant(S(0), a[1].AsArray(), (bool)a[2]) is var (fb, fm) ? new List<object> { fb, fm } : null,
                    "ft_masks" => DshFt.Masks((PyDict)Py.FromJson(a[0]), Pairs(a[1])).Select(m => (object)new List<object> { m.U, m.S }).ToList(),
                    "ft_msl" => DshFt.Msl(S(0), Pairs(a[1])),
                    "capture" => DshCompiler.GeoCapture(S(0)),
                    "vs_depth" => DshCompiler.VsDepth(S(0)) is var (x, y) ? new List<object> { x, y } : null,
                    "vs_tf" => DshCompiler.VsTf(S(0), a[1].AsArray()),
                    "vs_layer_entry" => DshCompiler.VsLayerEntry(S(0)) is var (f, l) ? new List<object> { f, l } : null,
                    "vs_push" => DshCompiler.VsPush(S(0)),
                    "fs_alpha_ms" => DshCompiler.FsAlphaMs(S(0)),
                    "fs_fout" => DshCompiler.FsFout(S(0)),
                    "fs_uvx" => DshCompiler.FsUvx(S(0)),
                    "fs_lb" => DshCompiler.FsLb(S(0)),
                    "fs_rd" => DshCompiler.FsRd(S(0)),
                    "helper_samples" => DshCompiler.HelperSamples(S(0)),
                    // #1204 T1：同一支 SPIR-V 不加固 / 加固（生产 NxgalSpvCross.Harden）各出一份 MSL（设备那条 SPIRV-Cross，选项同出库 XC）
                    "msl_raw" => nx.Msl(H(0), out var e0) ?? throw new InvalidOperationException(e0),
                    "msl_hardened" => nx.Msl(NxgalSpvCross.Harden(H(0)), out var e1) ?? throw new InvalidOperationException(e1),
                    "giant_fix" => DshFlat.GiantFix(S(0)) is var (gm, g0, g1) ? new List<object> { gm, (long)g0, (long)g1 } : null,
                    "tf_layout" => DshCompiler.Ctx.TfLayout("k", H(0)),
                    // 不在答案表的计算着色器：线程组尺寸 / 共享内存从控制段读（11-02 疯狂兔子兜底现编）。返回 [local 数组或 null, shared 或 null, no_facts]
                    "job_cs_nofacts" => ((Func<object>)(() => { string w = Path.Combine(Path.GetTempPath(), "dshfn_job_" + Guid.NewGuid().ToString("N")[..8]); Directory.CreateDirectory(w);
                        try { var (j, _) = new DshCompiler.Ctx { Key = "k", Out = w, W = w, T = DshTables.Empty() }.JobFor("cs", H(0), H(1));
                              return new List<object> { j["local"] is JsonArray la ? la.Select(x => (object)(long)x).ToList() : null, j["shared"] is JsonNode sn ? (long)sn : null, j["no_facts"] != null }; }
                        finally { Directory.Delete(w, true); } }))(),
                    // 域着色器任务的曲面模式（11-05 巫师3：控制段 +0x738 / +0x73c / +0x744 是 GL 枚举，不是打包好的寄存器值）。参数 [代码, 控制段]，返回 tess_mode
                    "job_ds_tess_mode" => ((Func<object>)(() => { string w = Path.Combine(Path.GetTempPath(), "dshfn_job_" + Guid.NewGuid().ToString("N")[..8]); Directory.CreateDirectory(w);
                        try { var (j, _) = new DshCompiler.Ctx { Key = "k", Out = w, W = w, T = DshTables.Empty() }.JobFor("ds", H(0), H(1)); return (long)j["tess_mode"]; }
                        finally { Directory.Delete(w, true); } }))(),
                    // 外壳要出的各域（DshCompiler.Ctx.TessDomains）：参数 [阶段, 模式字, {域: 扫到的模式字}]，返回 [[域, 模式字, 是否扫到], …]
                    "tess_domains" => DshCompiler.Ctx.TessDomains(S(0), (long)a[1], a[2].AsObject().ToDictionary(kv => int.Parse(kv.Key), kv => (uint)(long)kv.Value)).Select(x => (object)new List<object> { (long)x.Dom, (long)x.Mode, x.Seen }).ToList(),
                    "vertex_ab" => DshCompiler.Ctx.VertexAb("k", H(0), H(1)) is { } ab ? new List<object> { Convert.ToHexStringLower(ab.Item1), Convert.ToHexStringLower(ab.Item2) } : null,
                    "geo_records" => DshCompiler.GeoRecords((uint)a[0], a[1].AsObject()) is var (gv, gi) ? new List<object> { (long)gv, (long)gi } : null,
                    "spv_single_lane" => SpvFile(tmp, H(0), p => DshCompiler.SpvSingleLane(p)),
                    "flatten_sets" => SpvFile(tmp, H(0), p => { DshCompiler.FlattenSets(p); return true; }),
                    "gs_slice_glsl" => DshCompiler.Ctx.GsSliceGlsl(S(0)),
                    "glsl_nxgal" => nx.Glsl450(H(0), out var e1) ?? throw new InvalidOperationException(e1),
                    "msl_nxgal" => nx.Msl(H(0), out var e2) ?? throw new InvalidOperationException(e2),
                    // 单测入口（graphics/tools/direct/tests/dshfn.py；t_dmsh_giant / t_dmsh_spill / t_color_round_fetch / screen_uv_test / t_red 调）
                    "flatten" => DshFlat.Flatten(S(0)) is var (fo, fl) ? new List<object> { fo, (long)fl } : null,
                    "spill_fix" => NxgalSpvCross.SpillFix(S(0), (uint)a[1]) is var (so, sb) ? new List<object> { so, (long)sb } : null,   // 要 --dsx
                    "scr_uv_locns" => DshCompiler.ScrUvLocns(S(0)),
                    "scr_pos_locns" => DshCompiler.ScrPosLocns(S(0)),
                    "next_id" => DshCompiler.NextId(S(0)),
                    // 11-01 dsh 收敛：离线链 Python reflect / tex_scales 删了，tests/dmsh_reflect_test.sh、dmsh_tex_scales_test.sh 改测这里（经 dshfn.py）
                    "wide_loads" => DshCompiler.WideLoads(S(0)),   // 存储缓冲逐字读合并（tests/t_dsh_wide.py）
                    "mul_extended" => DshCompiler.MulExtended(S(0)),   // 标量宽乘法离开 optnone 模板（tests/t_dsh_mulext.py）
                    "pool_arrays" => ((Func<object>)(() => { try { return DshCompiler.PoolArrays(S(0)); } catch (DshError de) { return new PyDict { ["err"] = de.Status, ["detail"] = de.Detail }; } }))(),   // 池数组改池指针（PoolArrays）；失败带原因原文
                    "reflect_detail" => ((Func<object>)(() => { try { return DshCompiler.Reflect(S(0), S(1), a[2].AsObject()); } catch (DshError de) { return new PyDict { ["err"] = de.Status, ["detail"] = de.Detail }; } }))(),   // 失败带原因原文（上面 reflect 只回类名）
                    "tex_scales" => typeof(DshCompiler).GetMethod("TexScales", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
                        .Invoke(null, new object[] { a[0].AsObject(), a[0]["tex_scales"].AsArray(), null }),   // 私有：反射调（res 带 tex_scales 表）
                    // tests/ampere_isa（Switch 2 Ampere 指令单测）：一支合成的 NVN2 着色器照出包（DshCompiler.Compile）出一遍。参数 [阶段, 代码区十六进制, 控制段十六进制, 答案 JSON 或 null]；
                    //   返回 [_b.metal 原文, _b.json 原文]，翻不过返回 ["fail", 状态, 原因]（负对照要看到原因原文）
                    "ampere_compile" => AmpereCompile(tmp, S(0), H(1), H(2), a[3] == null ? null : S(3), nx),
                    // 同上、按出包开（PackOut）：另回拉取式顶点输入变体 [_b.metal, _bp.metal 或 null, _bp.json 或 null]（t_vs_pull.py：Dsh.cs 出包那条路真接上了 DshPull）
                    "ampere_compile_pack" => AmpereCompilePack(tmp, S(0), H(1), H(2), nx),
                    _ => throw new ArgumentException("不认识的函数 " + fn),
                };
                res.Add(new PyDict { ["ok"] = v });
            }
            catch (Exception e) { res.Add(new PyDict { ["err"] = e is DshError de ? "DshError:" + de.Status : e.GetType().Name }); }
        }
        File.WriteAllText(outPath, Py.Dumps(res));
        try { Directory.Delete(tmp, true); } catch { }
        return 0;
    }

    static List<object> AmpereCompile(string tmp, string stage, byte[] code, byte[] ctl, string facts, ISpvCross nx)
    {
        const string key = "a5a5a5a5a5a5a5a5";
        string t = Path.Combine(tmp, "amp_" + Guid.NewGuid().ToString("N")[..8]), o = Path.Combine(t, "out"); Directory.CreateDirectory(o);
        File.WriteAllText(Path.Combine(t, "shader_facts.tsv"), facts == null ? "" : key + "\t" + facts + "\n");
        File.WriteAllText(Path.Combine(t, "shader_pairs.tsv"), "");
        try { DshCompiler.Compile(key, stage, code, ctl, o, nx ?? new CliSpvCross(), t, t); }
        catch (DshError de) { return new List<object> { "fail", de.Status, de.Detail }; }
        return new List<object> { File.ReadAllText(Path.Combine(o, key + "_b.metal")), File.ReadAllText(Path.Combine(o, key + "_b.json")) };
    }

    static List<object> AmpereCompilePack(string tmp, string stage, byte[] code, byte[] ctl, ISpvCross nx)
    {
        const string key = "a5a5a5a5a5a5a5a5";
        string t = Path.Combine(tmp, "ampp_" + Guid.NewGuid().ToString("N")[..8]), o = Path.Combine(t, "out"); Directory.CreateDirectory(o);
        File.WriteAllText(Path.Combine(t, "shader_facts.tsv"), ""); File.WriteAllText(Path.Combine(t, "shader_pairs.tsv"), "");
        bool was = DshCompiler.PackOut; DshCompiler.PackOut = true;
        try
        {
            try { DshCompiler.Compile(key, stage, code, ctl, o, nx ?? new CliSpvCross(), t, t); }
            catch (DshError de) { return new List<object> { "fail", de.Status, de.Detail }; }
            return new List<object> { R("_b.metal"), R("_bp.metal"), R("_bp.json") };
        }
        finally { DshCompiler.PackOut = was; }
        string R(string n) => DshCompiler.PackFiles != null && DshCompiler.PackFiles.TryGetValue(key + n, out var x) ? x : null;   // 出包时产物进 PackFiles（BuildXlate.cs 同样从它取）
    }

    static List<(long U, long S)> Pairs(JsonNode n) => n.AsArray().Select(p => ((long)p[0], (long)p[1])).ToList();   // [[无符号, 有符号], …]

    static List<object> SpvFile(string tmp, byte[] spv, Func<string, bool> f)
    {
        string p = Path.Combine(tmp, Guid.NewGuid().ToString("N") + ".spv"); File.WriteAllBytes(p, spv);
        bool r = f(p);
        return new List<object> { r, Convert.ToHexStringLower(File.ReadAllBytes(p)) };
    }
}
