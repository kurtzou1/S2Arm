// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.Translation;

// These fixtures use real AST nodes, use/def bookkeeping and AstOptimizer.Optimize.
// Expectations are policy A, not a second implementation of memory-flow analysis.
static class Program
{
    private static int _passed;
    private static int _failed;
    private static AstOperand Const(int value = 0) => new(OperandType.Constant, value);
    private static AstOperation Op(Instruction inst, StorageKind storage, params IAstNode[] args) =>
        new(inst, storage, false, args, args.Length);
    private static AstOperation Load(StorageKind storage = StorageKind.StorageBuffer) =>
        Op(Instruction.Load, storage, Const(), Const(), Const());
    private static AstOperation Texture(Instruction inst) => new AstTextureOperation(
        inst, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 0, -1, -1, 0, Const(), Const());
    private static AstOperation Store(IAstNode value = null) =>
        Op(Instruction.Store, StorageKind.StorageBuffer, Const(), Const(), Const(99), value ?? Const(42));
    private static AstOperation Sink(IAstNode value) => Store(value);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
    private static void Run(string name, Action test)
    {
        try { test(); _passed++; Console.WriteLine($"PASS {name}"); }
        catch (Exception error) { _failed++; Console.Error.WriteLine($"FAIL {name}: {error.Message}"); }
    }

    private sealed class Fixture
    {
        public readonly StructuredProgramContext Context = new(null,
            new ShaderDefinitions(ShaderStage.Compute, 1, 1, 1), null, false);
        public AstBlock Main => Context.CurrentFunction.MainBlock;
        // #1429 acceptance counter: definitions kept only because of the #1414 rule.
        public int Kept = -1;
        public Fixture() => Context.EnterFunction(1, "test", AggregateType.Void, [], []);
        public AstAssignment Define(IAstNode source, AstBlock block = null)
        {
            AstOperand local = Context.NewTemp(AggregateType.S32);
            AstAssignment assignment = new(local, source);
            (block ?? Main).Add(assignment);
            return assignment;
        }
        public void Optimize()
        {
            AstMemoryOrderStats.Take();
            AstOptimizer.Optimize(Context);
            Kept = AstMemoryOrderStats.Take();
        }
        public void KeptIs(int expected) => Check(Kept == expected, $"memory-order kept count {Kept}, expected {expected}");
        public void Retained(AstAssignment assignment, AstBlock parent, IAstNode source)
        {
            Check(ReferenceEquals(assignment.Parent, parent), "definition moved/removed");
            Check(ReferenceEquals(assignment.Source, source), "definition source changed");
            Check(Context.CurrentFunction.Locals.Contains((AstOperand)assignment.Destination), "local removed");
        }
        public void Removed(AstAssignment assignment)
        {
            Check(assignment.Parent == null, "eligible definition retained");
            Check(!Context.CurrentFunction.Locals.Contains((AstOperand)assignment.Destination), "dead local retained");
        }
    }

    // Real Maxwell binaries (tests/shader_cases, encoded by its run.py) through the
    // production Translator: prints "<case id>\t<memory-order kept count>" per case.
    private sealed class Accessor(byte[] code) : IGpuAccessor
    {
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) =>
            System.Runtime.InteropServices.MemoryMarshal.Cast<byte, ulong>(code.AsSpan(checked((int)address)));
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index + 1);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(3, 0);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(2, 0);
        public int CreateExtraSet() => 4;
        public int QuerySamplerArrayLengthFromPool() => 8;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 8;
        public int QueryTextureArrayLengthFromPool() => 8;
        public GpuGraphicsState QueryGraphicsState() => new(false, InputTopology.Triangles, false, TessPatchType.Triangles,
            TessSpacing.EqualSpacing, false, false, false, true, false, 1f, AlphaTestOp.Always, 0f, default, false, default, false, false, true, false);
        public bool QueryHostStorageWindowClamp() => false;
        public bool QueryS2ARuntimeState() => false;
        public bool QueryHostSupportsShaderFloat64() => false;
        public bool QueryHostSupportsFragmentShaderInterlock() => false;
    }

    private static int Maxwell(string manifest)
    {
        foreach (var item in System.Text.Json.JsonDocument.Parse(File.ReadAllText(manifest)).RootElement.EnumerateArray())
        {
            var flags = item.GetProperty("stage").GetString() == "compute" ? TranslationFlags.Compute : TranslationFlags.None;
            var context = Translator.CreateContext(0, new Accessor(File.ReadAllBytes(item.GetProperty("binary").GetString())),
                new(TargetLanguage.Spirv, TargetApi.Vulkan, flags));
            AstMemoryOrderStats.Take();
            context.Translate();
            Console.WriteLine($"{item.GetProperty("id").GetString()}\t{AstMemoryOrderStats.Take()}");
        }
        return 0;
    }

    // 传播到多处时第二处起是一份拷贝（不共享节点，见 AstOptimizer PropagateExpression）：同结构、不同对象，操作数照用
    private static bool SameTree(IAstNode a, IAstNode b)
    {
        if (a is AstOperation x && b is AstOperation y)
        {
            if (x.Inst != y.Inst || x.SourcesCount != y.SourcesCount || x.StorageKind != y.StorageKind || x.Index != y.Index) return false;
            for (int i = 0; i < x.SourcesCount; i++) if (!SameTree(x.GetSource(i), y.GetSource(i))) return false;
            return true;
        }
        return ReferenceEquals(a, b);
    }
    private static bool CopyOf(IAstNode copy, IAstNode original) => !ReferenceEquals(copy, original) && SameTree(copy, original);

    private static void Straight(IAstNode source, AstOperation effect, bool retain, bool multiple = false)
    {
        Fixture f = new();
        AstAssignment assignment = f.Define(source);
        if (effect != null) f.Main.Add(effect);
        AstOperation first = Sink(assignment.Destination);
        f.Main.Add(first);
        AstOperation second = multiple ? Sink(assignment.Destination) : null;
        if (second != null) f.Main.Add(second);
        f.Optimize();
        IAstNode expected = retain ? assignment.Destination : source;
        f.KeptIs(retain ? 1 : 0);
        Check(ReferenceEquals(first.GetSource(3), expected), "first consumer evaluation location changed");
        if (second != null) Check(retain ? ReferenceEquals(second.GetSource(3), expected) : CopyOf(second.GetSource(3), expected), "second consumer evaluation location changed");
        if (retain)
        {
            f.Retained(assignment, f.Main, source);
            Check(ReferenceEquals(f.Main.First, assignment), "source no longer evaluated first");
            if (effect != null) Check(ReferenceEquals(assignment.LLNode.Next.Value, effect), "effect order changed");
        }
        else f.Removed(assignment);
    }

    private static void Control(AstBlockType type, bool write, bool conditionUse, bool sourceInside = false)
    {
        Fixture f = new();
        IAstNode source = Load();
        AstBlock block = new(type, Const(1));
        AstAssignment assignment;
        if (sourceInside)
        {
            f.Main.Add(block);
            assignment = f.Define(source, block);
        }
        else
        {
            assignment = f.Define(source);
            f.Main.Add(block);
        }
        AstOperation sink = conditionUse ? null : new(Instruction.Add, assignment.Destination, Const(1));
        if (conditionUse) block.Condition = assignment.Destination;
        else block.Add(sink);
        // A write after the first use matters on a loop's next iteration.
        if (write) block.Add(Store());
        else block.Add(new AstOperation(Instruction.Comment));
        f.Optimize();
        bool retain = write;
        f.KeptIs(retain ? 1 : 0);
        IAstNode actual = conditionUse ? block.Condition : sink.GetSource(0);
        Check(ReferenceEquals(actual, retain ? assignment.Destination : source), "control-flow use evaluation changed");
        if (retain) f.Retained(assignment, sourceInside ? block : f.Main, source);
        else f.Removed(assignment);
    }

    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--maxwell") return Maxwell(args[1]);
        (string Name, Func<IAstNode> Make)[] reads =
        [
            ("storage", () => Load()), ("shared", () => Load(StorageKind.SharedMemory)),
            ("local", () => Load(StorageKind.LocalMemory)), ("image", () => Texture(Instruction.ImageLoad)),
        ];
        (string Name, Func<AstOperation> Make)[] effects =
        [
            ("other-address-store", () => Store()),
            ("image-store", () => Texture(Instruction.ImageStore)),
            ("atomic", () => Op(Instruction.AtomicAdd, StorageKind.SharedMemory, Const(), Const(1))),
            ("image-atomic", () => Texture(Instruction.ImageAtomic)),
            ("barrier", () => new(Instruction.Barrier)),
            ("memory-barrier", () => new(Instruction.MemoryBarrier)),
            ("group-memory-barrier", () => new(Instruction.GroupMemoryBarrier)),
            ("call", () => new(Instruction.Call, Const())),
        ];
        foreach (var read in reads)
        {
            Run($"{read.Name}/no-intervening-write", () => Straight(read.Make(), null, false));
            foreach (var effect in effects)
                Run($"{read.Name}/{effect.Name}", () => Straight(read.Make(), effect.Make(), true));
        }
        foreach (Instruction effect in new[] { Instruction.Call, Instruction.AtomicAdd, Instruction.ImageAtomic })
        {
            Run($"source-{effect}/single", () => Straight(new AstOperation(effect, Const()), null, true));
            Run($"source-{effect}/nested-copy-multiple", () => Straight(
                new AstOperation(Instruction.Copy, new AstOperation(Instruction.Negate,
                    new AstOperation(effect, Const()))), null, true, true));
        }
        foreach (Instruction wrapper in new[] { Instruction.Negate, Instruction.Copy })
        {
            Run($"nested-{wrapper}/single", () => Straight(new AstOperation(wrapper, Load()), Store(), true));
            Run($"propagated-{wrapper}/write", () =>
            {
                Fixture f = new();
                AstAssignment first = f.Define(Load());
                AstOperation expression = new(wrapper, first.Destination);
                AstAssignment second = f.Define(expression);
                f.Main.Add(Store());
                AstOperation sink = Sink(second.Destination);
                f.Main.Add(sink);
                f.Optimize();
                f.Removed(first);
                f.Retained(second, f.Main, expression);
                f.KeptIs(1);
                Check(ReferenceEquals(sink.GetSource(3), second.Destination), "newly nested read crossed write");
                Check(ReferenceEquals(expression.GetSource(0), first.Source), "first propagation not exercised");
            });
        }
        Run("copy-load/multiple/write", () => Straight(new AstOperation(Instruction.Copy, Load()), Store(), true, true));
        // Two consuming stores themselves are intervening effects for the second use.
        Run("copy-load/multiple/consumer-write", () => Straight(new AstOperation(Instruction.Copy, Load()), null, true, true));
        foreach (StorageKind storage in new[] { StorageKind.ConstantBuffer, StorageKind.Input, StorageKind.InputPerPatch })
            Run($"readonly-{storage}/write", () => Straight(Load(storage), Store(), false));
        Run("readonly-texture/write", () => Straight(Texture(Instruction.TextureSample), Store(), false));
        Run("readonly-copy/multiple/write", () => Straight(new AstOperation(Instruction.Copy, Load(StorageKind.ConstantBuffer)), Store(), false, true));
        Run("readonly-texture/mutable-coordinate", () => Straight(new AstOperation(Instruction.TextureSample, Load()), Store(), true));
        Run("call-argument-addressable", () =>
        {
            Fixture f = new();
            IAstNode source = Const(7);
            AstAssignment assignment = f.Define(source);
            AstOperation call = new(Instruction.Call, Const(), assignment.Destination);
            f.Main.Add(call);
            f.Optimize();
            f.Retained(assignment, f.Main, source);
            f.KeptIs(0);
            Check(ReferenceEquals(call.GetSource(1), assignment.Destination), "call argument pointer removed");
        });
        Run("copy-load/multiple/no-write", () =>
        {
            Fixture f = new();
            IAstNode source = new AstOperation(Instruction.Copy, Load());
            AstAssignment assignment = f.Define(source);
            AstOperation first = new(Instruction.Add, assignment.Destination, Const(1));
            AstOperation second = new(Instruction.Negate, assignment.Destination);
            f.Main.Add(first);
            f.Main.Add(second);
            f.Optimize();
            f.Removed(assignment);
            f.KeptIs(0);
            Check(ReferenceEquals(first.GetSource(0), source) && CopyOf(second.GetSource(0), source),
                "no-write multi-use did not propagate");
        });
        // 「只用一次」按出现次数算：t 在同一个父节点里出现两次（fma(t, t, c)），Uses 只记一个父节点，原先当成只用一次整棵搬进两个槽位（共享节点）
        Run("occurrences/same-parent-twice-kept", () =>
        {
            Fixture f = new();
            AstAssignment t = f.Define(new AstOperation(Instruction.Add, Const(1), Const(2)));
            AstOperation fma = new(Instruction.FusedMultiplyAdd, t.Destination, t.Destination, Const(3));
            f.Main.Add(Sink(fma));
            f.Optimize();
            Check(ReferenceEquals(fma.GetSource(0), t.Destination) && ReferenceEquals(fma.GetSource(1), t.Destination), "twice-used definition was propagated");
            f.Retained(t, f.Main, t.Source);
        });
        // 一款 Unity 游戏的一支着色器：27 层 t[i+1] = fma(t[i], t[i], c)。原先每层共享整棵下一层、生成 SPIR-V 时按 2^27 展开（几分钟几十 GB）。
        //   期望：每层都保留成局部变量，优化后表达式树节点数随层数线性（不展开）
        Run("occurrences/fma-chain-linear", () =>
        {
            Fixture f = new();
            IAstNode prev = f.Define(new AstOperation(Instruction.Add, Const(1), Const(2))).Destination;
            var defs = new System.Collections.Generic.List<AstAssignment>();
            for (int i = 0; i < 27; i++) { AstAssignment a = f.Define(new AstOperation(Instruction.FusedMultiplyAdd, prev, prev, Const(3))); defs.Add(a); prev = a.Destination; }
            AstOperation sink = Sink(prev);
            f.Main.Add(sink);
            f.Optimize();
            static int Nodes(IAstNode n) { if (n is not AstOperation o) return 1; int c = 1; for (int i = 0; i < o.SourcesCount; i++) c += Nodes(o.GetSource(i)); return c; }
            int total = 0;
            foreach (IAstNode n in f.Main) total += n is AstAssignment a ? Nodes(a.Source) : Nodes(n);
            Check(total < 27 * 8, $"expression nodes {total} after optimize: chain expanded");
        });
        Run("while/body-definition-resets-before-use", () =>
        {
            Fixture f = new();
            AstBlock loop = new(AstBlockType.While, Const(1));
            f.Main.Add(loop);
            IAstNode source = Load();
            AstAssignment assignment = f.Define(source, loop);
            AstOperation sink = new(Instruction.Add, assignment.Destination, Const(1));
            loop.Add(sink);
            loop.Add(Store());
            f.Optimize();
            f.Removed(assignment);
            Check(ReferenceEquals(sink.GetSource(0), source), "per-iteration definition unnecessarily blocked");
        });
        Run("if/no-write-cross-block", () => Control(AstBlockType.If, false, false));
        Run("if/condition-no-write", () => Control(AstBlockType.If, false, true));
        foreach (AstBlockType loop in new[] { AstBlockType.While, AstBlockType.DoWhile })
        {
            Run($"{loop}/no-write", () => Control(loop, false, false));
            Run($"{loop}/backedge-write", () => Control(loop, true, false));
            Run($"{loop}/condition-write", () => Control(loop, true, true));
        }
        Run("do-while/body-definition-condition-write", () => Control(AstBlockType.DoWhile, true, true, true));
        foreach (bool inElse in new[] { false, true })
            Run($"branch-write/{(inElse ? "else" : "if")}", () =>
            {
                Fixture f = new();
                IAstNode source = Load();
                AstAssignment assignment = f.Define(source);
                AstBlock branch = new(AstBlockType.If, Const(1));
                AstBlock alternate = new(AstBlockType.Else);
                branch.Add(inElse ? new AstOperation(Instruction.Comment) : Store());
                alternate.Add(inElse ? Store() : new AstOperation(Instruction.Comment));
                f.Main.Add(branch);
                f.Main.Add(alternate);
                AstOperation sink = Sink(assignment.Destination);
                f.Main.Add(sink);
                f.Optimize();
                f.Retained(assignment, f.Main, source);
                Check(ReferenceEquals(sink.GetSource(3), assignment.Destination), "branch write crossed");
            });
        Run("if/condition-after-write", () =>
        {
            Fixture f = new();
            IAstNode source = Load();
            AstAssignment assignment = f.Define(source);
            f.Main.Add(Store());
            AstBlock branch = new(AstBlockType.If, assignment.Destination);
            branch.Add(new AstOperation(Instruction.Comment));
            f.Main.Add(branch);
            f.Optimize();
            f.Retained(assignment, f.Main, source);
            Check(ReferenceEquals(branch.Condition, assignment.Destination), "condition read moved after write");
        });
        Run("masked-atomic-source", () => Straight(
            new AstOperation(Instruction.AtomicAdd | Instruction.FP32, Const()), null, true));
        Run("else-if/condition-after-write", () =>
        {
            Fixture f = new();
            IAstNode source = Load();
            AstAssignment assignment = f.Define(source);
            f.Main.Add(Store());
            AstBlock branch = new(AstBlockType.If, Const(1));
            branch.Add(new AstOperation(Instruction.Comment));
            AstBlock next = new(AstBlockType.ElseIf, assignment.Destination);
            next.Add(new AstOperation(Instruction.Comment));
            f.Main.Add(branch);
            f.Main.Add(next);
            f.Optimize();
            f.Retained(assignment, f.Main, source);
            Check(ReferenceEquals(next.Condition, assignment.Destination), "else-if condition crossed write");
        });
        Run("dead-local/side-effect-source-kept", () =>
        {
            // 11-07 卡顿线：结果没人用的局部量连同赋值一起删，原先不看右边有没有副作用：图像原子 / 存储原子的返回值没人用时原子本身被删
            //   （ampere_isa_test：SURED.OR / 写记录位图置位 4 例红）。期望（手推）：有副作用的赋值留着、局部量留着；纯读的无用赋值照删
            Fixture f = new();
            AstAssignment atomic = f.Define(new AstOperation(Instruction.AtomicOr, Const(0), Const(1)));
            AstAssignment pure = f.Define(new AstOperation(Instruction.Add, Const(1), Const(2)));
            f.Optimize();
            Check(ReferenceEquals(atomic.Parent, f.Main), "atomic with unused result removed");
            Check(f.Context.CurrentFunction.Locals.Contains((AstOperand)atomic.Destination), "atomic's local removed");
            f.Removed(pure);
        });
        Run("else/nested-if-not-rewritten-to-else-if", () =>
        {
            // 11-07 卡顿线：上游 RemoveEmptyBlocks 把「else 里只剩一个 if（+ else）」改写成 ElseIf，SPIR-V 生成不给 ElseIf 发分支，
            //   else-if 臂不可达被删（关 DebugMode 时旷野之息蒙皮顶点 4 骨骼只剩第 0 根）。期望（手推，不跑被测实现）：嵌套 else { if … else … } 原样保留，全树没有 ElseIf
            Fixture f = new();
            AstBlock outerIf = new(AstBlockType.If, Const(1));
            outerIf.Add(new AstOperation(Instruction.Comment));
            AstBlock outerElse = new(AstBlockType.Else);
            AstBlock innerIf = new(AstBlockType.If, Const(2));
            innerIf.Add(new AstOperation(Instruction.Comment));
            AstBlock innerElse = new(AstBlockType.Else);
            innerElse.Add(new AstOperation(Instruction.Comment));
            outerElse.Add(innerIf);
            outerElse.Add(innerElse);
            f.Main.Add(outerIf);
            f.Main.Add(outerElse);
            f.Optimize();
            Check(ReferenceEquals(innerIf.Parent, outerElse) && innerIf.Type == AstBlockType.If, "inner if moved out of else / retyped");
            Check(ReferenceEquals(innerElse.Parent, outerElse) && innerElse.Type == AstBlockType.Else, "inner else moved out of else");
            Check(ReferenceEquals(outerElse.Parent, f.Main) && outerElse.Type == AstBlockType.Else, "outer else removed");
            static bool AnyElseIf(AstBlock b) { foreach (IAstNode n in b) if (n is AstBlock c && (c.Type == AstBlockType.ElseIf || AnyElseIf(c))) return true; return false; }
            Check(!AnyElseIf(f.Main), "ElseIf block present (SPIR-V generator emits no branch into it)");
        });
        Run("while/continue-write-backedge", () =>
        {
            Fixture f = new();
            IAstNode source = Load();
            AstAssignment assignment = f.Define(source);
            AstBlock loop = new(AstBlockType.While, Const(1));
            AstBlock branch = new(AstBlockType.If, Const(1));
            branch.Add(Store());
            branch.Add(new AstOperation(Instruction.LoopContinue));
            loop.Add(branch);
            AstOperation use = new(Instruction.Add, assignment.Destination, Const(1));
            loop.Add(use);
            f.Main.Add(loop);
            f.Optimize();
            f.Retained(assignment, f.Main, source);
            Check(ReferenceEquals(use.GetSource(0), assignment.Destination), "continue backedge write crossed");
        });
        Console.WriteLine($"AST memory propagation: {_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }
}
