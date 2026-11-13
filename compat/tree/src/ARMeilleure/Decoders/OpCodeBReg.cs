namespace ARMeilleure.Decoders
{
    class OpCodeBReg : OpCode
    {
        public int Rn { get; }

        public new static OpCode Create(InstDescriptor inst, ulong address, int opCode) => new OpCodeBReg(inst, address, opCode);

        // S2Arm（#854）：ARMv8.3 指针认证的 braa / blraa / retaa 等，最低 5 位是修饰寄存器（或 11111），不按普通 br / blr / ret 要求为 0
        public static OpCode CreatePac(InstDescriptor inst, ulong address, int opCode) => new OpCodeBReg(inst, address, opCode, pac: true);

        public OpCodeBReg(InstDescriptor inst, ulong address, int opCode) : this(inst, address, opCode, pac: false) { }

        private OpCodeBReg(InstDescriptor inst, ulong address, int opCode, bool pac) : base(inst, address, opCode)
        {
            int op4 = (opCode >> 0) & 0x1f;
            int op2 = (opCode >> 16) & 0x1f;

            if (op2 != 0b11111 || (op4 != 0b00000 && !pac))
            {
                Instruction = InstDescriptor.Undefined;

                return;
            }

            Rn = (opCode >> 5) & 0x1f;
        }
    }
}
