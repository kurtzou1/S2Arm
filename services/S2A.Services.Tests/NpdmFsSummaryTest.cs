using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using S2A.Services;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 程序元数据摘要（NpdmFsSummary，D-6BQ7 组诊断补行）：按公开的 NPDM FS Access Control 布局手拼字节，期望字符串手写，不跑被测实现推：
        //   ① ACI：版本 1、权限 0x8000000000000801、内容属主 1 个、存档属主 2 个（读写 / 读，可访问性 2 字节后补齐 2 字节再接号）
        //   ② ACID：版本 1、权限全 1、内容属主号范围、存档属主号范围、各列 1 个
        //   ③ 段太短：ACI 16 字节、ACID 0x20 字节 → 「段不全（N 字节）」；④ 存档属主信息偏移越界 → 「存档属主 段不全」
        [SoloTest("--npdm-fs-summary")]
        private static int NpdmFsSummaryTest()
        {
            const ulong A = 0x0100554023408000, B = 0x010034D02340E000;
            byte[] aci = new byte[0x40];
            aci[0] = 1;
            BinaryPrimitives.WriteUInt64LittleEndian(aci.AsSpan(4), 0x8000000000000801);
            BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0xC), 0x1C); BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0x10), 12);
            BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0x14), 0x28); BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0x18), 24);
            BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0x1C), 1); BinaryPrimitives.WriteUInt64LittleEndian(aci.AsSpan(0x20), A);
            BinaryPrimitives.WriteUInt32LittleEndian(aci.AsSpan(0x28), 2); aci[0x2C] = 3; aci[0x2D] = 1;   // 0x2E–0x2F 补齐
            BinaryPrimitives.WriteUInt64LittleEndian(aci.AsSpan(0x30), A); BinaryPrimitives.WriteUInt64LittleEndian(aci.AsSpan(0x38), B);

            byte[] acid = new byte[0x3C];
            acid[0] = 1; acid[1] = 1; acid[2] = 1;
            BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(4), ulong.MaxValue);
            BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0xC), A); BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0x14), A);
            BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0x1C), 0x0100000000000000); BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0x24), 0x01FFFFFFFFFFFFFF);
            BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0x2C), A); BinaryPrimitives.WriteUInt64LittleEndian(acid.AsSpan(0x34), B);

            byte[] bad = (byte[])aci.Clone(); BinaryPrimitives.WriteUInt32LittleEndian(bad.AsSpan(0x14), 0x38);   // 存档属主信息 0x38 + 24 越过 0x40

            var rows = new List<(string N, string E, string A)>
            {
                ("① ACI", "ACI 版本 1 权限 0x8000000000000801，内容属主 1 个：0x0100554023408000，存档属主 2 个：0x0100554023408000（读写）、0x010034D02340E000（读）",
                    NpdmFsSummary.Aci(aci)),
                ("② ACID", "ACID 版本 1 权限 0xFFFFFFFFFFFFFFFF，内容属主号范围 0x0100554023408000–0x0100554023408000，存档属主号范围 0x0100000000000000–0x01FFFFFFFFFFFFFF，"
                    + "列出内容属主 1 个：0x0100554023408000，列出存档属主 1 个：0x010034D02340E000", NpdmFsSummary.Acid(acid)),
                ("③ ACI 段太短", "ACI 段不全（16 字节）", NpdmFsSummary.Aci(aci.AsSpan(0, 16))),
                ("③ ACID 段太短", "ACID 段不全（32 字节）", NpdmFsSummary.Acid(acid.AsSpan(0, 0x20))),
                ("④ 存档属主越界", "ACI 版本 1 权限 0x8000000000000801，内容属主 1 个：0x0100554023408000，存档属主 段不全", NpdmFsSummary.Aci(bad)),
            };
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
