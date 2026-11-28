using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System;

namespace Ryujinx.Graphics.Shader.Translation.Optimizations
{
    static class BranchElimination
    {
        public static bool RunPass(BasicBlock block)
        {
            BasicBlock nextBlock = Next(block);

            if (block.HasBranch && IsRedundantBranch(block, (Operation)block.GetLastOp(), nextBlock))
            {
                block.Branch = null;

                return true;
            }

            return false;
        }

        private static bool IsRedundantBranch(BasicBlock block, Operation current, BasicBlock nextBlock)
        {
            // Here we check that:
            // - The current block ends with a branch.
            // - The next block only contains a branch.
            // - The branch on the next block is unconditional.
            // - Both branches are jumping to the same location.
            // - Target block has no PhiNode distinguishing direct jump from block vs fallthrough via nextBlock.
            // In this case, the branch on the current block can be removed,
            // as the next block is going to jump to the same place anyway.

            if (nextBlock?.Operations.First?.Value is not Operation next)
            {
                return false;
            }

            if (next.Inst != Instruction.Branch)
            {
                return false;
            }

            return current.Dest == next.Dest && !HasPhiConflict(block, nextBlock, block.Branch);
        }

        private static bool HasPhiConflict(BasicBlock block, BasicBlock nextBlock, BasicBlock target)
        {
            if (target == null)
            {
                return false;
            }

            foreach (INode node in target.Operations)
            {
                if (node is not PhiNode phi)
                {
                    if (node is CommentNode)
                    {
                        continue;
                    }

                    break;
                }

                Operand blockSrc = null;
                Operand nextSrc = null;

                for (int i = 0; i < phi.SourcesCount; i++)
                {
                    BasicBlock pred = phi.GetBlock(i);

                    if (pred == block)
                    {
                        blockSrc = phi.GetSource(i);
                    }
                    else if (pred == nextBlock)
                    {
                        nextSrc = phi.GetSource(i);
                    }
                }

                if ((blockSrc != null || nextSrc != null) &&
                    (blockSrc == null || nextSrc == null || !Utils.IsSameOperand(blockSrc, nextSrc)))
                {
                    return true;
                }
            }

            return false;
        }

        private static BasicBlock Next(BasicBlock block)
        {
            block = block.Next;

            while (block != null && block.Operations.Count == 0)
            {
                if (block.HasBranch)
                {
                    throw new InvalidOperationException("Found a bogus empty block that \"ends with a branch\".");
                }

                block = block.Next;
            }

            return block;
        }
    }
}
