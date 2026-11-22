using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("S2A.Services.Tests")]
// 存档迁移的两个测试工程本地编 SaveTransfer*.cs、经工程引用用服务层其余部分：导入其他工具的存档（#2070，SaveTransferCommunity.cs）
//   调 SaveFolder.Detect（internal），要对它们可见
[assembly: InternalsVisibleTo("SaveTransferInterop")]
[assembly: InternalsVisibleTo("SaveTransferTest")]
