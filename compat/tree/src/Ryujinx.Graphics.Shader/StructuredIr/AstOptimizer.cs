// S2Arm: preserve mutable-memory read ordering and effectful expression definitions (#1414).
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System.Collections.Generic;
using System.Linq;

using static Ryujinx.Graphics.Shader.StructuredIr.AstHelper;

namespace Ryujinx.Graphics.Shader.StructuredIr
{
    // S2Arm (#1429 acceptance): per-thread count of definitions kept in place
    // only because of the #1414 memory-order rule. Translation of one shader
    // runs on one thread, so callers take the count right after translating it.
    public static class AstMemoryOrderStats
    {
        [System.ThreadStatic] internal static int Kept;

        public static int Take()
        {
            int kept = Kept;
            Kept = 0;
            return kept;
        }
    }

    static class AstOptimizer
    {
        public static void Optimize(StructuredProgramContext context)
        {
            AstBlock mainBlock = context.CurrentFunction.MainBlock;

            // When debug mode is enabled, we disable expression propagation
            // (this makes comparison with the disassembly easier).
            if (!context.DebugMode)
            {
                AstBlockVisitor visitor = new(mainBlock);
                MemoryPropagation memoryPropagation = null;

                foreach (IAstNode node in visitor.Visit())
                {
                    if (node is AstAssignment assignment && assignment.Destination is AstOperand propVar)
                    {
                        // S2Arm: preserve addressable locals used as SPIR-V call arguments.
                        // StructuredProgram creates these temporaries for GetLocalPointer;
                        // propagating even a constant would remove that pointer boundary.
                        bool isCallArgument = propVar.Uses.Any(use => use is AstOperation { Inst: Instruction.Call });
                        // S2Arm：「只用一次」按出现次数算，不按父节点个数（Uses 是父节点的集合，fma(t, t, c) 只记一个）；
                        //   出现多次的照旧只传播 IsWorthPropagating 的表达式，但各处一份深拷贝（PropagateExpression），只拷小树（CloneSize）
                        int occurrences = Occurrences(propVar);
                        bool isWorthPropagating = !isCallArgument &&
                            (occurrences == 1 || (IsWorthPropagating(assignment.Source) && CloneSize(assignment.Source) <= MaxCloneNodes));

                        if (propVar.Defs.Count == 1 && isWorthPropagating)
                        {
                            int effects = GetMemoryEffects(assignment.Source);
                            if ((effects & (MemoryEffect | LaneDependent)) == 0 &&
                                ((effects & MutableRead) == 0 ||
                                    (memoryPropagation ??= new(mainBlock)).CanPropagate(assignment, propVar)))
                            {
                                PropagateExpression(propVar, assignment.Source);
                            }
                            else if (propVar.Uses.Count > 0 && (effects & LaneDependent) == 0)
                            {
                                // Only branch where #1414 changes output: the old code propagated here.
                                AstMemoryOrderStats.Kept++;
                            }
                        }

                        // S2Arm 11-07: a dead local is removed together with its assignment, so only when the source has no side
                        // effect. An atomic / call whose result is unused (image atomic OR into a write-log bitmap, SURED.OR) was
                        // dropped with it once DebugMode no longer skipped this loop (ampere_isa_test: 5 of 85 red).
                        if (propVar.Type == OperandType.LocalVariable && propVar.Uses.Count == 0 &&
                            (GetMemoryEffects(assignment.Source) & MemoryEffect) == 0)
                        {
                            visitor.Block.Remove(assignment);

                            context.CurrentFunction.Locals.Remove(propVar);
                        }
                    }
                }
            }

            RemoveEmptyBlocks(mainBlock);
        }

        // S2Arm (#1414): expressions are evaluated where they are used, not where
        // their former local was assigned. Keep writes/calls at their definition,
        // and only move mutable reads along paths with no intervening memory effect.
        private const int MutableRead = 1;
        private const int MemoryEffect = 2;
        // S2Arm: a subgroup operation's result depends on which lanes are active where it runs. Moved to its use it can land after
        //   the other lanes returned (a task shader's "leader lane writes popcount(ballot)": the ballot of the leader alone, one
        //   mesh group instead of 32 — 04008E001F098000 near sea), so it stays at its definition. Removing an unused one is fine.
        private const int LaneDependent = 4;

        private static int GetMemoryEffects(IAstNode node)
        {
            if (node is not AstOperation operation)
            {
                return 0;
            }

            Instruction inst = operation.Inst & Instruction.Mask;
            int effects = 0;
            if (inst == Instruction.ImageLoad ||
                (inst == Instruction.Load && operation.StorageKind is not
                    (StorageKind.ConstantBuffer or StorageKind.Input or StorageKind.InputPerPatch)))
            {
                effects |= MutableRead;
            }

            if (inst is Instruction.Ballot or Instruction.VoteAll or Instruction.VoteAllEqual or Instruction.VoteAny or
                Instruction.Shuffle or Instruction.ShuffleDown or Instruction.ShuffleUp or Instruction.ShuffleXor)
            {
                effects |= LaneDependent;
            }

            if (inst.IsAtomic() || inst is Instruction.ImageAtomic or Instruction.Call or
                Instruction.Store or Instruction.ImageStore or Instruction.Barrier or
                Instruction.MemoryBarrier or Instruction.GroupMemoryBarrier)
            {
                effects |= MemoryEffect;
            }

            for (int index = 0; index < operation.SourcesCount; index++)
            {
                effects |= GetMemoryEffects(operation.GetSource(index));
            }

            return effects;
        }

        private static bool ContainsOperand(IAstNode node, AstOperand operand)
        {
            if (node == operand)
            {
                return true;
            }

            if (node is AstOperation operation)
            {
                for (int index = 0; index < operation.SourcesCount; index++)
                {
                    if (ContainsOperand(operation.GetSource(index), operand))
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        private sealed class MemoryPropagation
        {
            private readonly Dictionary<IAstNode, IAstNode[]> _successors = new();
            // S2Arm 11-07: per-node memory-effect bits, computed once. A node's expression only changes when PropagateExpression
            // replaces an operand by a source with no MemoryEffect (Optimize only propagates such sources), so whether it writes
            // memory never changes; recomputing it at every node of every query was quadratic (geometry emulation, DebugMode off:
            // 1.3-2.1 GB per shader). Queue / visited set are reused across queries.
            private readonly Dictionary<IAstNode, (bool Mem, bool NestedMem)> _effects = new();
            private readonly Queue<(IAstNode Node, bool Dirty)> _pending = new();
            private readonly HashSet<(IAstNode Node, bool Dirty)> _visited = new();

            private static IAstNode ExpressionOf(IAstNode node) => node switch
            {
                AstAssignment assignment => assignment.Source,
                AstBlock block => block.Condition,
                _ => node,
            };

            private (bool Mem, bool NestedMem) Effects(IAstNode node)
            {
                if (!_effects.TryGetValue(node, out var e))
                {
                    bool mem = (GetMemoryEffects(ExpressionOf(node)) & MemoryEffect) != 0;
                    bool nested = mem;
                    if (node is AstOperation operation)
                    {
                        nested = false;
                        for (int index = 0; index < operation.SourcesCount && !nested; index++)
                        {
                            nested = (GetMemoryEffects(operation.GetSource(index)) & MemoryEffect) != 0;
                        }
                    }
                    _effects[node] = e = (mem, nested);
                }
                return e;
            }

            public MemoryPropagation(AstBlock mainBlock)
            {
                AddBlock(mainBlock, null, null, null);
            }

            // Build execution edges, not AstBlockVisitor's lexical DFS order.
            // A block node denotes evaluation of its condition. Else bodies have
            // no condition; loop conditions have explicit backedges and exits.
            private IAstNode AddBlock(AstBlock block, IAstNode next, IAstNode loopExit, IAstNode loopContinue)
            {
                IAstNode alternative = null;
                foreach (IAstNode node in block.Reverse())
                {
                    if (node is AstBlock child)
                    {
                        switch (child.Type)
                        {
                            case AstBlockType.Else:
                                alternative = AddBlock(child, next, loopExit, loopContinue);
                                break;
                            case AstBlockType.If:
                            case AstBlockType.ElseIf:
                                _successors[child] = [AddBlock(child, next, loopExit, loopContinue), alternative ?? next];
                                if (child.Type == AstBlockType.ElseIf)
                                {
                                    alternative = child;
                                }
                                else
                                {
                                    next = child;
                                    alternative = null;
                                }
                                break;
                            case AstBlockType.While:
                            case AstBlockType.DoWhile:
                                IAstNode body = AddBlock(child, child, next, child);
                                _successors[child] = [body, next];
                                next = child.Type == AstBlockType.While ? child : body;
                                break;
                        }
                    }
                    else
                    {
                        Instruction inst = node is AstOperation operation ? operation.Inst & Instruction.Mask : 0;
                        _successors[node] = inst switch
                        {
                            Instruction.LoopBreak => [loopExit],
                            Instruction.LoopContinue => [loopContinue],
                            Instruction.Return or Instruction.Discard => [],
                            _ => [next],
                        };
                        next = node;
                    }
                }

                return next;
            }

            public bool CanPropagate(AstAssignment definition, AstOperand operand)
            {
                // Same answer as walking every (node, dirty) state from the definition and failing at a use reached dirty or with a
                // nested memory effect: containment is only looked up where it can change the answer, and a node already reached
                // dirty is not walked again clean (the dirty walk reaches every use the clean one would, and fails there)
                Queue<(IAstNode Node, bool Dirty)> pending = _pending; HashSet<(IAstNode Node, bool Dirty)> visited = _visited;
                pending.Clear(); visited.Clear();
                foreach (IAstNode next in _successors[definition])
                {
                    pending.Enqueue((next, false));
                }

                while (pending.TryDequeue(out var state))
                {
                    IAstNode node = state.Node;
                    // Re-executing the definition refreshes the read, so writes
                    // from a preceding iteration cannot taint that new value.
                    if (node == null || node == definition || (!state.Dirty && visited.Contains((node, true))) || !visited.Add(state))
                    {
                        continue;
                    }

                    bool dirty = state.Dirty;
                    // Earlier propagation can remove assignments. Their edges
                    // stay valid, but their obsolete expression is not executed.
                    if (node.Parent != null)
                    {
                        var (mem, nestedMem) = Effects(node);
                        // Root Store/Call effects happen after evaluating their
                        // operands. Nested effects have backend-dependent operand
                        // order, so do not move reads into those expressions.
                        if ((dirty || nestedMem) && ContainsOperand(ExpressionOf(node), operand))
                        {
                            return false;
                        }

                        dirty |= mem;
                    }

                    foreach (IAstNode next in _successors[node])
                    {
                        pending.Enqueue((next, dirty));
                    }
                }

                return true;
            }
        }

        private static bool IsWorthPropagating(IAstNode source)
        {
            if (source is not AstOperation srcOp)
            {
                return false;
            }

            if (!InstructionInfo.IsUnary(srcOp.Inst))
            {
                return false;
            }

            return srcOp.GetSource(0) is AstOperand || srcOp.Inst == Instruction.Copy;
        }

        // S2Arm：同一个表达式节点不许塞进多个使用处。共享的节点里引用的局部变量只记一次使用（Uses 按父节点计），
        //   之后它的定义会被当成「只用一次」继续传播进这个共享节点——一层套一层，生成 SPIR-V 时每个使用处都把整棵共享子树
        //   重新生成一遍，指令数按共享层数指数增长（一款 Unity 游戏一支着色器 27 层乘加链，几分钟几十 GB、永远翻不完）。
        //   出现多次的（Optimize 里判过可拷）第一处用原节点、其余各用一份深拷贝
        // 传播到多处时拷贝的上限（节点数）：只拷小树，「Copy 套 Copy」一层层用两次的链拷贝也不会指数长；超过就保留成局部变量
        private const int MaxCloneNodes = 8;

        // 可拷的树的节点数：只认普通 AstOperation（贴图运算等带额外字段的子类不拷）与操作数；拷不了返回 int.MaxValue
        private static int CloneSize(IAstNode node)
        {
            if (node is AstOperand)
            {
                return 1;
            }

            if (node is not AstOperation op || op.GetType() != typeof(AstOperation))
            {
                return int.MaxValue;
            }

            int size = 1;

            for (int index = 0; index < op.SourcesCount && size <= MaxCloneNodes; index++)
            {
                int child = CloneSize(op.GetSource(index));
                size = child == int.MaxValue ? int.MaxValue : size + child;
            }

            return size;
        }

        // 这个局部变量在各使用处一共出现几次（同一父节点的多个槽位分别算）
        private static int Occurrences(AstOperand propVar)
        {
            int count = 0;

            foreach (IAstNode use in propVar.Uses)
            {
                if (use is AstOperation op)
                {
                    for (int index = 0; index < op.SourcesCount; index++)
                    {
                        if (op.GetSource(index) == propVar)
                        {
                            count++;
                        }
                    }
                }
                else
                {
                    count++;
                }
            }

            return count;
        }

        // 深拷贝（只用于 CloneSize 认得的小树）：每个运算节点新建，操作数照用、其中的局部变量多记一次使用
        private static IAstNode CloneTree(IAstNode node)
        {
            if (node is not AstOperation op)
            {
                return node;
            }

            IAstNode[] sources = new IAstNode[op.SourcesCount];

            for (int index = 0; index < sources.Length; index++)
            {
                sources[index] = CloneTree(op.GetSource(index));
            }

            return new AstOperation(op.Inst, op.StorageKind, op.ForcePrecise, op.Index, sources, sources.Length);
        }

        private static void PropagateExpression(AstOperand propVar, IAstNode source)
        {
            IAstNode[] uses = propVar.Uses.ToArray();
            bool first = true;
            // 每一次出现各取一份：同一父节点的两个槽位（x * x）也不共享
            IAstNode Next()
            {
                IAstNode value = first ? source : CloneTree(source);
                first = false;
                return value;
            }

            foreach (IAstNode useNode in uses)
            {

                if (useNode is AstBlock useBlock)
                {
                    useBlock.Condition = Next();
                }
                else if (useNode is AstOperation useOperation)
                {
                    for (int srcIndex = 0; srcIndex < useOperation.SourcesCount; srcIndex++)
                    {
                        if (useOperation.GetSource(srcIndex) == propVar)
                        {
                            useOperation.SetSource(srcIndex, Next());
                        }
                    }
                }
                else if (useNode is AstAssignment useAssignment)
                {
                    useAssignment.Source = Next();
                }
            }
        }

        private static void RemoveEmptyBlocks(AstBlock mainBlock)
        {
            Queue<AstBlock> pending = new();

            pending.Enqueue(mainBlock);

            while (pending.TryDequeue(out AstBlock block))
            {
                foreach (IAstNode node in block)
                {
                    if (node is AstBlock childBlock)
                    {
                        pending.Enqueue(childBlock);
                    }
                }

                AstBlock parent = block.Parent;

                if (parent == null)
                {
                    continue;
                }

                AstBlock nextBlock = Next(block) as AstBlock;

                bool hasElse = nextBlock != null && nextBlock.Type == AstBlockType.Else;

                bool isIf = block.Type == AstBlockType.If;

                if (block.Count == 0)
                {
                    if (isIf)
                    {
                        if (hasElse)
                        {
                            nextBlock.TurnIntoIf(InverseCond(block.Condition));
                        }

                        parent.Remove(block);
                    }
                    else if (block.Type == AstBlockType.Else)
                    {
                        parent.Remove(block);
                    }
                }
                // S2Arm 11-07: upstream turned "else { if (c) {...} [else {...}] }" into an ElseIf block here. The SPIR-V generator
                // (SpirvGenerator BlockEntered) only takes an immediately following Else as the false target of an If and emits no branch
                // into an ElseIf block, so the else-if arm became unreachable and was dropped. With DebugMode on every Else holds comment
                // nodes and never got rewritten; with it off, propagation empties the Else and the arm vanished (BotW skinning vertex shader
                // 0068dfb7db3baf9a kept bone 0 of 4). ElseIf only prettifies GLSL; the nested else { if } has the same meaning, so keep it.
            }
        }
    }
}
