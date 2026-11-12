"""Stable job error codes. Diagnose at the failure site, never by guessing prose."""
from __future__ import annotations

import errno
import os
import re
from pathlib import Path


RECOVERY = {
    "ios_install_dir_unwritable": "重新打开 S2Arm（会自动修好），再从电脑推送一次。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_no_space": "清出空间后点「重试」。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_img_format": "更新 iPhone 上的 S2Arm，再打开这款游戏。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_img_corrupt": "从电脑重新装到 iPhone，会接着已传的部分续传。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_pack_truncated": "重新连电脑推送，会自动补齐。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_files_missing": "从电脑重新装到 iPhone。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_manifest_bad": "从电脑重新装到 iPhone。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_write_failed": "重新打开 S2Arm 后点「重试」；还不行就导出诊断包发给我们。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_import_img_failed": "检查文件是否拷完整，再打开 S2Arm。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "ios_install_unknown": "导出诊断包发给我们。",   # iOS 端装机 / 导入失败：手机上的 S2Arm 报码、按码显示（11-11 维护者「补上说人话的原因」）
    "rewrite_gap": "之前已经装到 iPhone 上的这款可以照常接着玩。点「复制错误摘要」发给我们，修好后更新 S2Arm 再出一次包。",
    "update_failed": "检查网络后重试；还是不行就到下载页下载新版覆盖安装，当前版本和存档不受影响。",
    "glslc_windows_unavailable": "这款游戏的着色器编译目前只能在 Mac 上完成，Windows 版暂不支持；请改用 Mac 版 S2Arm 出包。",
    "win_host_unsupported": "请改用64位Windows主机运行S2Arm，确认后点「重新检查」。",
    "win_metal_missing": "用自己的Apple ID登录苹果开发者下载页（https://developer.apple.com/download/），下载安装官方Metal Developer Tools for Windows，装好后点「重新检查」。",
    "win_apple_devices_missing": "从Microsoft Store安装Apple Devices或iTunes（https://support.apple.com/118290），装好后点「重新检查」。",
    "win_apple_service_stopped": "在Windows「服务」中启动Apple Mobile Device Service；若没有该服务，从Microsoft Store安装Apple Devices或iTunes，完成后点「重新检查」。",
    "win_icloud_missing": "从Microsoft Store安装官方iCloud for Windows（https://support.apple.com/103232），装好后点「重新检查」。",
    "win_anisette_source": "选择本机官方iCloud或我方自建来源；公共服务器仅可手动作为备选，选中仍不判就绪，配置后点「重新检查」。",
    "win_disk_budget_unknown": "先在游戏库选择游戏并生成出包计划，再点「重新检查」。",
    "win_check_failed": "本次环境探测失败；按诊断检查工具安装和权限，处理后点「重新检查」。",
    "impactor_missing": "S2Arm Windows 版自带的签名工具 Impactor 不在了（安装包不完整）：重新下载并完整解压 S2Arm Windows 版，用里面的 S2Arm.exe 打开后再试。",   # 11-07 起发版随包带原版 Impactor（维护者：不让玩家跳转下载）；缺 = 安装包不完整。源码树的说法见 DEVELOPMENT_RECOVERY；引导 pack/jobs/impactor_guide.json
    "impactor_version_untested": "换成实测过的 Impactor 2.7.2（官方发布页 https://github.com/claration/impactor/releases/tag/v2.7.2）；别的版本可能丢掉「提高内存上限」权限，大游戏会闪退。",   # Windows 签装交给玩家自装的 Impactor（11-04 维护者）；引导 pack/jobs/impactor_guide.json
    "apple_id_wrong": "Apple ID 或密码不对：把输入法切到英文后重新登录（全角字符会被判错）；密码只发给 Apple。",   # Windows 签装交给玩家自装的 Impactor（11-04 维护者）；引导 pack/jobs/impactor_guide.json
    "two_factor_wrong": "两步验证码不对或已过期：重新获取验证码后输入；短信收码目前常失败，用受信任设备上弹出的验证码。",   # Windows 签装交给玩家自装的 Impactor（11-04 维护者）；引导 pack/jobs/impactor_guide.json
    "login_identity_rejected": "密码已通过，但苹果拒绝了这台电脑的登录身份：在 Impactor「设置」里点「Reset Anisette Data」后重新添加账号；仍不行就换一台电脑或稍后再试。",   # Windows 签装交给玩家自装的 Impactor（11-04 维护者）；引导 pack/jobs/impactor_guide.json
    "ipa_needs_repack": "这个包是旧版 S2Arm 出的（zip64 或中文显示名），侧载工具读不了：更新 S2Arm 后重新出包再装。",   # Windows 签装交给玩家自装的 Impactor（11-04 维护者）；引导 pack/jobs/impactor_guide.json
    "job_failed": "查看本任务的具体日志，修复提示的问题后重试；反馈时复制已脱敏的错误摘要。",
    "tool_exit": "查看本任务日志和失败阶段，按提示修复后重试；反馈时复制错误摘要。",
    "game_crashed": "再启动一次试试；还是这样，就在「环境检查」导出诊断包，到 GitHub 发帖附上，我们按崩溃现场修。",   # Mac 起局：游戏进程中途非 0 退出（build.launch）
    "keys_missing": "在「设置 → 玩家密钥」导入自行导出的 prod.keys，然后重新导入游戏。",
    "keys_invalid": "重新选择完整的 prod.keys 文本文件，不要手工补写密钥值；原有密钥保持不变。",
    "content_unreadable": "检查文件和票据是否完整；若另行确认 Switch 密钥版本不足，可重新导出并到「设置 → 玩家密钥」重新导入。",
    "ticket_missing": "核对源文件是否含有所需票据。",
    "content_truncated": "从原始位置重新复制完整的游戏文件，再重新导入。",
    "keys_outdated": "用系统版本更新的 Switch 重新导出 prod.keys，再到「设置 → 玩家密钥」重新导入。",
    "input_type_unsupported": "选择 NSP、XCI 文件或包含它们的文件夹，然后重新导入。",
    "input_empty": "确认所选文件夹包含 NSP 或 XCI 文件，再重新导入。",
    "input_permission": "打开「系统设置 › 隐私与安全性 › 文件与文件夹」（外接盘看「可移除的宗卷」），允许本应用读取游戏文件所在位置，或把游戏文件拷到「下载」之外的本机文件夹，然后重试。",
    "input_unreadable": "确认游戏文件所在磁盘已连接、文件没有损坏（换一个位置拷一份再放），然后重试；反馈时复制错误摘要。",
    "input_missing": "接上游戏原件所在的磁盘，确认文件仍在原位置且可读取；原件挪了位置就把它重新放进来一次。",
    "input_base_missing": "将对应的游戏本体 NSP 或 XCI 一并导入；仅更新或 DLC 不能单独打包。",
    "guest_isa_unsupported": "这款游戏的 32 位 ARM 程序暂不支持，重试无法解决；请选择 64 位 ARM 游戏。",
    "content_invalid": "检查原始游戏文件是否完整，重新导入后再试；仍失败时复制错误摘要并保留对应日志。",
    "library_not_apfs": "游戏原件放哪块盘都行，导出时的工作数据（游戏库）要放在 APFS 或 exFAT 格式的磁盘上：在「设置 → 游戏库与玩家数据」改用这台 Mac 上的默认位置（内置盘），或选一块 APFS / exFAT 外接盘，再重试；FAT32 等格式不适合做游戏库。游戏原件不用挪。",
    "library_in_cloud": "游戏库在云盘同步目录里（iCloud 云盘、OneDrive、Dropbox 等）：出包时会写几十 GB 中间文件，云盘会上传它们、换成占位文件，出包中途会读不到。在「设置 → 游戏库与玩家数据」把游戏库改到本机磁盘上不同步的位置（例如默认位置），再重试；游戏原件放在哪都行。",
    "library_folder_not_empty": "选的文件夹里已有别的文件：确认「仍然继续」就照用这个文件夹，S2Arm 只在自己建的文件和子文件夹里读写，不改也不删它们；不想这样就选一个空文件夹。",
    "library_bad_format": "可以点「仍然用这里」照用这块盘（出包会多占空间）；想省空间就从下面列出的 NTFS 盘里选一块，点「放到这里」。",
    "fat32_file_too_large": "在出包页「存放位置」换到 NTFS 格式的盘（上面列出了这台电脑上可用的），再出包；游戏原件放在哪都行。",
    "library_move_failed": "游戏库还在原来的位置，什么都没有丢：按上面的原因处理后再搬一次。",
    "batch_record_failed": "批次记录（数据目录下的 batch.json）写不进：检查数据目录所在磁盘的空间与权限，处理后在批量出包页点「继续」；已出好的包都在。",
    "library_busy": "等正在用游戏库的那个任务结束（或在任务列表里取消它）再重试；什么都没有改动。",
    "downstream_ineligible": "这个下游方案只支持某一版更新（上面写了是哪一版）：导入那一版更新后再导出；不换更新就在确认页选「仍用原版方案」。",
    "download_failed": "检查这台电脑的网络（能打开 s2arm.com）后再点一次；下了一半的不会被当成好的用。",
    "disk_full": "释放任务所在磁盘的空间，检查游戏库和应用数据所在磁盘后重试；不要删除存档或上次成功的运行版本。",
    "out_of_memory": "关掉其它占内存的程序（浏览器、游戏等）后重试；还不行就在 Windows 设置里调大虚拟内存（页面文件），或换一台内存更大的电脑出包。已做完的步骤下次会复用。",
    "permission_denied": "检查文件和目录权限；若位于桌面、文稿、下载或外接磁盘，请在「系统设置 → 隐私与安全性 → 文件与文件夹」允许 S2Arm 访问，再重试。",
    "volume_ops_unsupported": "游戏存放位置或游戏库所在的盘不支持 S2Arm 需要的文件操作（常见于 exFAT / FAT 格式的外接盘）：把这款游戏的存放位置换到 APFS 格式的盘（Mac 内置盘就是；外接盘可在「磁盘工具」里另分一个 APFS 分区），再重试；游戏原件不用挪。",
    "architecture_unsupported": "当前路径需要 Apple Silicon Mac，请换用支持的设备；重试不会改变硬件兼容性。",
    "os_unsupported": "当前游戏路径需要 macOS 15 或更新版本；在支持的系统上重新检查环境后再试。",
    "xcode_unavailable": "去 App Store 安装 Xcode，装好打开一次并完成必要组件安装，回来点「重新检查」。",
    "xcode_setup_required": "打开 Xcode，同意许可并完成首次设置，回来点「重新检查」。",
    "metal_unavailable": "在设置中安装 Metal 编译组件，完成后重新检查环境并重试。",
    "ios_platform_missing": "在设置里点「iOS 平台组件」的「一键下载」（苹果官方，约 8 GB），下完自动重新检查后重试；也可以打开 Xcode → 设置 → Components 装上与 Xcode 配套的 iOS 平台。",
    "ios_platform_unregistered": "iOS 平台组件已经下载，只是还没注册到模拟器：点「重新检查」再试；不用重复下载（约 8 GB）。还不行就在 Xcode → 设置 → Components 里确认这一项，或重启这台 Mac 后再点「重新检查」。",
    "dotnet_unavailable": "重新安装完整的 S2Arm，恢复内置运行时后点「重新检查」。",
    "dotnet_sdk_missing": "在「设置」的环境检查中安装 .NET 10 SDK，完成后重新检查，再打 iPhone 包。",
    "reader_unavailable": "重新安装完整的 S2Arm，然后重新导入游戏。",
    "engine_incomplete": "重新安装完整的 S2Arm，然后点「重新检查」。",
    "engine_toolchain_newer": "把 S2Arm 更新到最新版（新版认得你的 Xcode），然后再点一次。",
    "graphics_api_unsupported": "这款暂时打不了包，换一款官方游戏试试；如果确定是正版游戏，点「复制错误摘要」发给我们。",   # #222：同人移植把图形库静态链进程序，判不出图形接口   # 11-07 联合开发者：beta.4 遇 Xcode 27.2（metal 比锁新）直连库「链号前后不一」
    "game_structure_unsupported": "这款暂时打不了包，换一款官方游戏试试；如果确定是正版游戏，点「复制错误摘要」发给我们。",   # v0.3.1：直连配置推导不认这款的程序结构（⑪ 照停、说人话）
    "tool_missing": "重新安装完整的 S2Arm，点「重新检查」后重试。",
    "target_unsupported": "这台设备的 GPU 或系统不在当前支持范围内，重试无法解决；需要 A14 / M1 或更新芯片及 iOS / iPadOS 18 或更新系统。",
    "xcode_sdk_too_old": "把 Xcode 更新到最新版，装好打开一次，回来点「重新检查」，再打 iPhone 包。",
    "runtime_invalid": "重新打包这款游戏以恢复完整运行文件；保留原有存档，打包成功后再启动。",
    "xcode_team_pending": "在装机页点「解决办法」打开引导项目，在 Xcode 里选 Personal Team，连上手机点运行一次，再点一次「装到 iPhone」。也可以先到 Xcode › Settings › Apple Accounts 看团队列表有没有显示。",
    "signing_certificate_missing": "打开 Xcode，点菜单 Xcode › Settings › Apple Accounts，选中账号后点 Manage Certificates，点 + 选 Apple Development，再点一次「装到 iPhone」。",
    "xcode_account_missing": "打开 Xcode →「设置」→「账户」，点「+」登录你的 Apple ID（免费的就可以），再点一次「装到 iPhone」；不想登录 Xcode 也可以改用 AltStore 安装。",
    "device_not_ready": "按上面的提示做完，再点一次安装。",
    "device_not_connected": "让你选的那台 iPhone / iPad 连上这台电脑：插上数据线，或解锁后和电脑连同一个 Wi-Fi；第一次连要在设备上点「信任」，并在「设置 → 隐私与安全性 → 开发者模式」打开开发者模式，然后再试。",
    "device_required": "在装机页选好要装到哪台 iPhone / iPad，再点装机。",
    "signing_failed": "查看本任务日志里签名那一步的报错；确认 Xcode 能用你的账号给这台 iPhone 签名，或改用 AltStore 安装。",
    "device_locked": "解锁这台 iPhone（保持亮屏、停在主屏幕），再点一次「装到 iPhone」；装机过程中别锁屏。",
    "free_app_limit": "免费 Apple ID 在每台设备上最多同时装 3 个自签 App，这台 iPhone 已经装满：在 iPhone 上长按删掉一个不再玩的自签 App 后重试；或改用付费 Apple 开发者账号（没有这个上限）。",
    "free_appid_limit": "这是 Apple 对免费 Apple ID 的限制：7 天内最多注册 10 个包名，这个账号已经用满；在手机上删 App 不会退还额度。办法：等几天，最早那批包名注册满 7 天就会恢复；或在 Xcode / Impactor 里换一个 Apple ID 登录后再装；或改用付费 Apple 开发者账号（没有这个限制）。",   # Apple 错误 9120；与 free_app_limit（设备上同时 3 个）是两件事，删 App 无效
    "app_id_taken": "苹果拒绝注册这个包名（Apple 错误 9401：同一个包名在苹果那边已被占用）。请在 Impactor（Mac 上是 Xcode）里确认登录的是当初装 S2Arm 用的那个 Apple ID 再装；付费开发者账号也可以到 developer.apple.com 的「Certificates, Identifiers & Profiles → Identifiers」删掉 io.s2arm.games 开头的旧包名后重试。还不行请导出诊断包反馈。",   # Apple 错误 9401；Windows 装机先用大小写两种包名各试一次（install_win.install_app），都被拒才报这个码
    "app_other_signer": "手机上已经有一个用别的签名装的 S2Arm（包名相同、签名不同），系统不让覆盖。二选一：继续用你原来的签名工具更新它；或者在 iPhone 上长按 S2Arm 删掉它（里面的存档会一起删，先在 S2Arm 里导出存档），再点「装到 iPhone」。",   # 玩家先自签装过同包名的 S2Arm（11-11 反馈）：installation_proxy MismatchedApplicationIdentifierEntitlement
    "bundle_id_switched": "这个包名之前被别的签名用过（多半是你自己签名装 S2Arm 时用了同一个包名），这次已自动换成新包名装好。手机上可能有两个 S2Arm：新装的这个里有这台电脑装的游戏；旧的那个不再需要的话可以删掉（先导出存档）。",   # 包名被占（9401）时 Mac 自动换 <包名>.s2 装好（install.MacPhone.install），黄字说明
    "apple_session_expired": "Apple ID 登录已过期，请重新登录后再装：在装机页点「打开 Impactor」→「设置」，选中你的 Apple ID 点「移除账号」，再点「添加账号」用同一个 Apple ID 重新登录（邮箱、密码、手机上的验证码，输入前切到英文输入法），然后回来再点一次「装到 iPhone」。密码只在 Impactor 里输，S2Arm 不经手。",   # Windows plumesign 恢复保存的会话时 Apple 1100（impactor.explain）；Mac 同类原文归 xcode_account_missing（去 Xcode 重新登录）
    "aoc_missing": "本体已出好，照常安装即可；没解出的追加内容不在包里，游戏里用不到那部分内容。请导出诊断反馈，解码支持后重新打包即可带上。",
    "direct_offline_empty": "游戏照常能玩，只是开头几次进新场景会卡一下（着色器现编，编过的会记住）。请导出诊断反馈给我们，修好后重新出包就能提前编好。",
    "sibling_clone_failed": "已改从解包目录准备，本次照常完成，只是多花一些时间；游戏库放在 APFS 格式的磁盘上（Mac 内置盘或格式化为 APFS 的外接盘）时，各平台导出可以共用已准备好的游戏数据。",
    "iml_missing": "用 Xcode（免费 Apple ID 即可）或 AltStore Classic v2.3 重新签名安装这款游戏；SideStore 0.7.0 免费账号重签会丢这项权限。已装的也可以用 GetMoreRam 给 App ID 补上权限后重装。",
    "manual_unpack_required": "资源包已经在手机上，不用重推：在 iPhone 上打开 S2Arm，选这款游戏，保持在前台别锁屏，等它导入完就能玩。",
    "usb_slow": "换一根支持 USB 3 的 USB-C 数据线，直接插 Mac 上的 USB-C / 雷雳口（不经扩展坞、集线器、显示器上的口），再装下一款；iPhone 15 Pro 及更新的 Pro 机型才支持 USB 3，其它机型只能 USB 2.0。",
    "devcert_password": "重新输入导出 .p12 时设的密码（区分大小写）；还不行就重新导出一份 .p12 再导入。",   # 开发者证书签名（pack/jobs/devcert.py，v0.2.4）
    "devcert_invalid": "选导出的 .p12 证书和开发者网站下载的 .mobileprovision 描述文件，再导入一次。",   # 开发者证书签名（pack/jobs/devcert.py，v0.2.4）
    "devcert_mismatch": "在开发者网站重新生成描述文件并勾上这张证书，下载后和证书一起重新导入。",   # 开发者证书签名（pack/jobs/devcert.py，v0.2.4）
    "devcert_missing": "在出包页「我的开发者证书」里重新导入证书和描述文件，或切回「Apple ID 签名」。",   # 开发者证书签名（pack/jobs/devcert.py，v0.2.4）
    "devcert_keychain": "解锁登录钥匙串并允许 S2Arm 访问后，重新导入证书。",   # 开发者证书签名（pack/jobs/devcert.py，v0.2.4）
    "shell_sdk_old": "装好的包能用；要在 iPhone Duo 等新机型上铺满全屏，把 Xcode 更新到不低于这台 iPhone 系统大版本的版本（如 iOS 27 用 Xcode 27），在启动器里选它后重新打 iPhone 包再装。",
    'configuration_failed': '检查当前阶段的配置推导错误，保留原始游戏输入；更新完整引擎后重新准备，仍失败时反馈错误摘要。',
    'shader_extract_failed': '检查着色器抽取的具体错误；确认游戏输入完整且版本一致，重新准备后仍失败时反馈摘要。',
    'compilation_failed': '按编译错误检查 Xcode、Metal 组件和 .NET SDK；完成环境检查后重试，保留原有成功版本与存档。',
    'rewrite_failed': '检查程序改写的首个错误；保留原始游戏文件，更新完整引擎后重试，仍失败时反馈摘要。',
    'resource_preparation_failed': '检查资源准备错误和输入目录权限，确认资源完整后重新准备；不要删除存档或上次成功的包。',
    'package_failed': '这一步的失败还没归类：错误摘要里有失败阶段、退出码和错误原文，点「复制错误摘要」发给我们。',   # 11-07 维护者：失败摘要不再带阶段 / 红行原文（只进复制诊断），原句「看摘要里的阶段」已无从看起
    'device_install_failed': '按安装错误检查设备连接与包的有效性；保持手机解锁后重试，保留原 App 和存档。',
    'resource_transfer_failed': '解锁手机并检查数据线及剩余空间后重试资源传输；保留已有 App、存档和电脑上的资源包。',
    'developer_mode_required': '在 iPhone「设置 → 隐私与安全性 → 开发者模式」按系统提示开启开发者模式，再重新安装。',
    'device_pairing_required': '重新用数据线连接并解锁 iPhone，在手机上确认「信任此电脑」，然后重新检查设备并安装。',
    'provisioning_expired': '开发描述文件已过期；在 Xcode 重新登录签名账号、重新申请描述文件并签名安装，保留原 App 存档。',
    'compiler_cache_incomplete': '已完成的安装包可以保留；检查磁盘余量与缓存目录权限后再清理缓存，不要删除游戏或存档。',
    'stage_timeout': '当前阶段已超时；检查该阶段日志和设备连接，确认原因后重试，不要同时重复启动同一任务。',
    'target_unknown': '重新选择可识别的目标机型与系统版本，或连接并解锁目标设备后重新检查。',
    'job_no_request': '任务缺少请求记录，无法安全接续；返回游戏库重新发起操作，不要手工修改任务记录。',
    'job_not_ours': '此进程不属于当前任务，未发送停止信号；返回任务列表检查目标任务，不要强行结束其他进程。',
    'job_pid_reused': '原任务进程已经结束，当前进程号属于另一进程；刷新任务列表，不要按旧进程号停止任务。',
    'job_unknown': '当前私有目录里没有这条任务；刷新任务列表并确认使用原游戏库，必要时重新发起操作。',
    'journal_write_failed': '任务记录写入失败；检查磁盘空间和目录权限，保留产物与日志，恢复可写后重新检查任务。',
    'save_backup': '存档备份未完成，原存档保持不动；检查备份目录权限与空间后重新备份。',
    'save_changed': '备份期间存档发生变化；先正常退出游戏，再重新检查并备份存档。',
    'save_cleanup': '存档恢复已完成但事务清理未完成；保留备份和事务记录，检查目录权限后再检查恢复状态。',
    'save_destination': '选择游戏库和应用私有目录之外、可写且有足够空间的备份目的地。',
    'save_empty': '当前没有可备份的存档；先在游戏中正常保存并退出，再重新检查。',
    'save_exists': '目标备份已经存在；选择新文件名或新目录，不要覆盖已有备份。',
    'save_game_id': '存档缺少有效的游戏程序号；重新选择原始备份，不要手工改写存档元数据。',
    'save_invalid': '这份文件不是可识别的存档备份；重新选择由 S2Arm 导出的完整备份。',
    'save_no_target': '这款游戏尚未建立存档目录；先启动游戏并正常保存退出，再恢复备份。',
    'save_recovery': '存档回退没完成：事务记录与副本都保留着。可以先在存档页备份当前存档；确认可能丢掉没做完的导入 / 恢复后，可选「仍要启动」。不要删除事务目录。',
    'container_would_drop': '确认后再点一次：点名的游戏会暂时不能玩（存档和资源包留在手机上），到装它们的那台电脑上再「装到 iPhone」一次就回来；不想这样就先别装。',
    'save_backup_failed': '确认后再点一次就照装：存档没备份，万一覆盖出问题可能丢档；想先备份就把手机解锁、数据线插稳后再点一次。',
    'container_stale': '先给点名的游戏各「打 iPhone 包」一次，再装到 iPhone；也可以确认后这次先不带它们照装，它们的存档和资源留在手机上，重新出包再装就回来。',
    'container_incompatible': '这款没法和手机上已有的游戏放进同一个 App：先从 iPhone 删掉不兼容的那款。',
    'container_purge_failed': '手机解锁、数据线插稳后再删一次；不影响其他游戏。',
    'keychain_prompt': '在这台 Mac 屏幕上的钥匙串弹窗里点「始终允许」（需要的话输入 Mac 登录密码），再点一次「装到 iPhone」。',
    'windows_path_too_long': '路径太长：把游戏库搬到盘符根目录附近的短路径（比如 D:\\S2Arm），再打一次包；反馈时请带上错误摘要。',
    'pack_missing': '没找到这款的资源包目录：重新「打 iPhone 包」后再装到 iPhone。',
    'save_recovery_overridden': '已按你的确认跳过存档回退启动游戏；事务记录保留，下次启动会再试恢复。',
    'save_space': '释放备份目的地的磁盘空间后重试；不要删除原存档或唯一的备份。',
    'save_unsafe_path': '存档路径含符号链接或不安全目录；选择普通目录中的完整备份，不要绕过路径保护。',
    'save_user': '存档用户信息缺失或无效；重新选择游戏用户与原始备份，不要修改用户标识兜底。',
    'save_version': '备份与当前游戏版本或 DLC 不一致；使用匹配版本的游戏和备份后重试。',
    'save_wrong_game': '这份备份属于另一款游戏；回到对应游戏恢复，或选择当前游戏的备份。',
    'save_wrong_user': '这份备份属于另一用户；选择对应用户或该用户自己的备份后重试。',
}


DEVELOPMENT_RECOVERY = {
    "impactor_missing": "先装 Impactor：在 S2Arm 里点「打开官方页面」打开官方发布页（https://github.com/claration/impactor/releases/tag/v2.7.2），下载免安装版放到桌面，再点「重新检查」。",   # 源码树 / 命令行：没有随包件，照旧让开发者自己放 Impactor（11-04 引导）
    "dotnet_unavailable": "安装 .NET 10 SDK，然后点「重新检查」。",
    "reader_unavailable": "在设置中重新准备引擎工具，然后重新导入游戏。",
    "engine_incomplete": "重新选择完整的 S2Arm 源码目录，然后点「重新检查」。",
    "tool_missing": "查看任务日志中缺少的工具，补齐构建依赖后重试。",
}


def recovery(code, *, packaged):
    if not packaged and code in DEVELOPMENT_RECOVERY:
        return DEVELOPMENT_RECOVERY[code]
    return RECOVERY.get(code, RECOVERY["job_failed"])


class Failure(Exception):
    """message 是上屏的那句；internal 是只进诊断 detail（「复制错误摘要」带走）的内部原文：阶段、rc、构建号、红行。"""
    def __init__(self, message, *, code="job_failed", internal="", holder=None, facts=None):
        super().__init__(message)
        self.code = code
        self.internal = internal
        self.holder = holder   # library_busy：占着游戏库锁的任务（filelock 旁挂文件里记的那份），其余为 None
        self.facts = facts     # 机读的失败事实（cause_facts：改写失败的模块 / 缺口数 / 缺口类别），前端按字段显示，不解析中文；没有为 None


def _under(path, roots):
    # 两边都按真实路径比（macOS 的 /var 实为 /private/var、外接盘挂载点软链：请求里记的与报错带的写法可能不同；删掉的文件 realpath 照样解析父目录）
    try:
        p = os.path.realpath(os.fspath(path))
    except TypeError:
        return False
    for r in roots:
        r = os.path.realpath(os.fspath(r))
        if p == r or p.startswith(r.rstrip(os.sep) + os.sep):
            return True
    return False


def explain(error, sources=(), library=None):
    """OSError 按 errno 归码，不猜原文；「原件不见了」「去系统设置授权」只给确知是玩家这边的路径（启动器剃刀 H8，11-11）：
    sources = 这次作业的原件（导入的路径、这款登记的原件），library = 游戏库根。
    ENOENT 出在原件下，或游戏库根整个不在（外接盘没插）→ input_missing；EACCES / EPERM / EROFS 出在原件或游戏库下 → permission_denied；
    其余（私有目录的日志 / 任务记录、并发竞态删掉的临时文件、不带路径的）→ job_failed，原文与路径进 internal（坑记录：两个作业同时收日志的
    ENOENT 被说成原件缺失，玩家被指去接磁盘）"""
    if isinstance(error, Failure):
        return error
    if isinstance(error, OSError):
        if error.errno in (errno.ENOSPC, errno.EDQUOT):
            return Failure("任务所在磁盘空间不足。", code="disk_full")
        paths = [p for p in (error.filename, error.filename2) if p]
        internal = f"{type(error).__name__} errno {error.errno}：{error.strerror or error}" + ("；路径 " + " → ".join(map(str, paths)) if paths else "")
        if error.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
            if any(_under(p, [*sources, *([library] if library else [])]) for p in paths):
                return Failure("文件或目录不可访问或不可写。", code="permission_denied", internal=internal)
            return Failure("本地任务失败：S2Arm 自己的文件读写不了，请导出诊断发给我们。", internal=internal)
        if error.errno == errno.ENOENT:
            if any(_under(p, sources) for p in paths) or (library is not None and not os.path.isdir(library)):
                return Failure("任务所需的文件或目录不存在。", code="input_missing", internal=internal)
            return Failure("本地任务失败：S2Arm 自己的文件找不到了，请重试；还不行请导出诊断发给我们。", internal=internal)
        return Failure("本地任务失败，请检查日志和输入。", internal=internal)
    return Failure("本地任务失败，请检查日志和输入。")


# 实际阶段或命令确定分类，不从错误 prose 猜编译器/输入的根因（日志里有确凿根因字样的先由 LOG_CAUSES 判，见 classify_failure）。
# direct（直连库出库，pack/stage_direct.sh → graphics/tools/direct/direct_lib.sh）：内容缺口退 3 走黄、到不了这里；其余非零按 stage_direct.sh 注
#   是「基础设施出错」——dsh_batch（.NET）翻译 + Metal 编库，归编译失败（恢复口径＝检查 Xcode / Metal 组件 / .NET SDK）。
STAGE_CODES = {
    "unpack": "content_invalid", "configure": "configuration_failed",
    "rewrite": "rewrite_failed", "sh_extract": "shader_extract_failed",
    "host": "compilation_failed", "sign": "signing_failed",
    "install": "device_install_failed", "seed": "resource_preparation_failed",
    # direct（直连库：.NET 翻译 + Metal 编库 + 打包写库）不设阶段默认码：根因日志读不到时说不清是哪一步，
    #   按 package_failed 让玩家「复制错误摘要」发给我们（11-07 维护者：判不出不猜；发版应用也已不要 .NET SDK，「检查 SDK」会误导）
}

# 出包 / 准备失败上屏的那一句（11-07 维护者：阶段 id、rc、构建号、红行原文不上屏，只进复制诊断）。
# 口径取 launchers/shared/experience.v1.json errors 该码的 title / detail：detail 是「…具体原因见本任务的错误摘要」的只用 title，
#   否则「title：detail」（单测 test_job_failure_codes.PlayerSummary 逐条对照；英文在 Mac 启动器 Localizable.json）。
PLAYER_REASON = {
    "disk_full": "磁盘空间不够：准备这个游戏需要更多空余空间。",
    "out_of_memory": "电脑内存不够：出包时内存用完了。",
    "rewrite_gap": "暂时出不了包：这款游戏里有程序代码我们的改写器还不支持，我们正在修。",
    "glslc_windows_unavailable": "着色器编译暂不支持：这款游戏的着色器编译目前只能在 Mac 上完成。",
    "metal_unavailable": "缺少 Metal 组件：编着色器要用的 Metal 组件没装上。",
    "ios_platform_missing": "缺少 iOS 平台组件：Xcode 的 iOS 平台还没装，打不了 iPhone 包。",
    "engine_toolchain_newer": "这版 S2Arm 不认识你的 Xcode：你的 Xcode 比这版 S2Arm 新。",
    "graphics_api_unsupported": "这款游戏暂不支持：没找到任天堂官方图形接口（NVN / Vulkan / OpenGL），多见于自制或移植的程序。",
    "game_structure_unsupported": "这款游戏暂不支持：程序的结构我们还不认识，多见于自制或移植的程序。",
    "tool_missing": "缺少工具：这条链上有个工具没装。",
    "content_invalid": "文件内容不对：文件结构校验没通过，可能没下完整。",
    "volume_ops_unsupported": "存放位置所在磁盘格式不支持：这块盘不支持出包需要的文件操作（常见于 exFAT / FAT 格式的外接盘）。",
    "signing_failed": "签名没成：用你的 Apple ID 给这台 iPhone 签名没成功。",
    "configuration_failed": "配置推导失败。",
    "shader_extract_failed": "着色器抽取失败。",
    "compilation_failed": "编译失败。",
    "rewrite_failed": "程序改写失败。",
    "resource_preparation_failed": "资源准备失败。",
    "device_install_failed": "设备安装失败。",
    "package_failed": "出包未完成。",
}


def player_reason(code):
    return PLAYER_REASON.get(code, PLAYER_REASON["package_failed"])


# 按日志确凿字样归因，先于阶段映射：按本表顺序，证据里第一个命中的码胜出（盘满最先：写盘失败后面常跟一串连带错误）。
# 只收工具 / 系统原样会打的字样，不从散文猜。
LOG_CAUSES = (
    (r"WinError 206|filename or extension is too long|文件名或扩展名太长", "windows_path_too_long"),
    (r"No space left on device|\bENOSPC\b|\[Errno 28\]|\berrno\s*[=:]?\s*28\b"          # POSIX / Python OSError / .NET IOException（Mac）
     r"|There is not enough space on the disk|\bDisk full\b|WinError 112|ERROR_DISK_FULL|0x80070070"   # Windows / .NET
     r"|STATUS_DISK_FULL|磁盘空间不足", "disk_full"),                                       # Windows 退出码注（direct_lib.sh 127）/ 我方字样
    # 内存用完（#711：Windows 16 GB 抽取按核数开满进程池，Python 子进程 MemoryError）：Python / .NET / Windows 提交上限原样字样
    (r"(?m:^\s*MemoryError\b)|OutOfMemoryException|\[WinError 1455\]|paging file is too small|页面文件太小|Cannot allocate memory|\bENOMEM\b", "out_of_memory"),
    # 盘不支持某种文件操作（exFAT 外接盘不支持原子改名 / 克隆 / 硬链接，实测 errno 45）：出包写入的这块盘格式不对，说清换 APFS 盘（11-10 网友：存放位置设到外接盘写入失败）
    (r"\[Errno 45\] Operation not supported|\bENOTSUP\b|Operation not supported on socket", "volume_ops_unsupported"),
    # cp 被系统拒绝（拷字体等，pack/stages/sysdata.sh 红行带 cp 原文）：macOS 隐私授权没给（桌面 / 文稿 / 下载 / 外接盘）或目录没写权限 → 提示去系统设置授权
    (r"\bcp: .*: (?:Operation not permitted|Permission denied)", "permission_denied"),
    # 直连库出库前核链号对不上：旧引擎（≤ beta.4，direct_lib.sh 把 dmsh_chain.py --build-env 的 stderr 一起收进链号）遇到 metal 比锁新的 Xcode，
    #   编译器提示「note: …」被当成链号读（eb4b5c964 已修）。玩家能做的就是更新 S2Arm
    (r"链号前后不一", "engine_toolchain_newer"),
    # 直连配置推导判不出图形接口（graphics/nvn/tools/direct_profile.py；gfx_api.py 只认动态导入的 NVN / Vulkan / EGL）：
    #   同人移植多把 deko3d / Mesa 静态链进程序（#222 程序号 05F4…，不是官方 0100 段），通用 GPU 模拟路径已拆（11-07 只有直连），这类按现行设计不支持
    (r"unsupported graphics API: unknown", "graphics_api_unsupported"),
    # v0.3.1 拿不准不停 ⑪ / ⑧：物理做不下去的照停，但要说人话。直连配置推导不认本款的程序结构（main 不是 NSO / 动态符号表 / RomFS 符号链接等；图形接口那类上一行先认）
    (r"配置推导不支持本款", "game_structure_unsupported"),
    # 直连库 Metal 一份都没出（Build.cs Metal.Tally）：这台机器上的 Metal 编译器用不了
    (r"Metal 库一份都没出", "metal_unavailable"),
    # 直连库原生库缺导出 / 缺库（Build.cs）：S2Arm 安装不全，不是游戏内容
    (r"原生库缺件（出包机环境", "tool_missing"),
    # 改写停住：v0.3.1 起有缺口照出产物、降级继续（pack/stage_rewrite.sh 记 degrade.rewrite.tsv），日志里留着「PFRW … gaps=N」不再说明失败在改写；
    #   只有缺口加上补丁区放不下（stage_rewrite.sh 这句红行）才是改写停住。按 PFRW 认会把之后别的阶段的失败错归成改写缺口
    (r"需要的改写空间超过了能放下的上限", "rewrite_gap"),
    # Windows 出包期 GLSLC 工具模式缺失（exitCode 75）
    (r"Windows 还没有 GLSLC 工具模式|要出包期离线编 GLSLC.*Windows", "glslc_windows_unavailable"),
    (r"unable to find utility \"metal(?:lib)?\"|cannot execute tool '?metal(?:lib)?'?|missing Metal Toolchain"
     r"|【红】环境缺件 metal：", "metal_unavailable"),   # 后者：Windows 出包预检（pack/orch/oneclick_win.py env_items）找不到 Metal Developer Tools
    (r"is not installed\. (?:To use with Xcode, first download and install the platform|Please download and install the platform)", "ios_platform_missing"),   # xcodebuild 原文（11-07 gate-host Xcode 26.6）
    (r"unable to find utility \"|: command not found|is not recognized as an internal or external command", "tool_missing"),
)
_RED = ("【红】", "🔴", "[RED]")
# 红行里点名的子日志（如直连库 <缓存>/work.stage.N/build.log）：绝对路径（可含空格，如「Application Support」），以 .log / .out 结尾
_LOG_PATH_ANY = re.compile(r"((?:[A-Za-z]:[\\/]|/)[^\s'\"（）()，,；;]+)")   # 命中行里点名的绝对路径（核盘满用：不限 .log）
_LOG_PATH = re.compile(r"(?:(?<=[\s（(：:，,=])|^)((?:[A-Za-z]:[\\/]|/)[^（）()，,；;\"'\r\n]*?\.(?:log|out))(?=$|[\s）)，,；;:\"'])")
EVIDENCE_MAIN_BYTES = 16000   # 主日志（refresh / 一键出包输出）尾部
EVIDENCE_SUB_BYTES = 32000    # 每份子日志尾部（.NET 未处理异常连调用栈约 4–10 KB）
EVIDENCE_SUB_FILES = 4        # 最多跟几份子日志（refresh.log → build.log 这样逐层跟）


def _tail_text(path, limit):
    try:
        with open(path, "rb") as stream:
            stream.seek(0, 2)
            stream.seek(max(0, stream.tell() - limit))
            return stream.read().decode("utf-8", errors="replace")
    except OSError:
        return None


def _log_paths(text, red_only=True):
    import os
    for line in text.splitlines():
        if red_only and not any(mark in line for mark in _RED):
            continue
        for m in _LOG_PATH.finditer(line):
            raw = m.group(1)
            if os.name == "nt" and re.match(r"^/[A-Za-z]/", raw):   # MSYS 风格 /c/… 换成 Windows 路径
                raw = raw[1].upper() + ":" + raw[2:]
            yield raw


def gather_evidence(log, texts=()):
    """有界读取失败证据：调用方给的原因文本 + 主日志尾 EVIDENCE_MAIN_BYTES，再跟红行（原因文本整段）里点名的子日志，
    最多 EVIDENCE_SUB_FILES 份、每份尾 EVIDENCE_SUB_BYTES，子日志的红行可再往下跟。返回 [(来源, 文本)]。"""
    from pathlib import Path
    chunks = [("原因", t) for t in texts if t]
    queue = [p for t in texts if t for p in _log_paths(t, red_only=False)]
    seen = set()
    if log:
        seen.add(str(log))
        main = _tail_text(log, EVIDENCE_MAIN_BYTES)
        if main is not None:
            chunks.append((Path(log).name, main))
            queue += list(_log_paths(main))
    followed = 0
    while queue and followed < EVIDENCE_SUB_FILES:
        path = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        text = _tail_text(path, EVIDENCE_SUB_BYTES)
        if text is None:
            continue
        followed += 1
        chunks.append((path, text))
        queue += list(_log_paths(text))
    return chunks


# 环境类的码（盘满、缺工具）字样只是候选：工具重试、可选探测（`command -v x || …`）都会打出同样字样却与这次失败无关
#   （坑记录 11-09：Windows 出库 rc=127 被一律译成盘满，玩家照提示删了 37 GB）。启动器剃刀 H9：候选要当场核事实才定码，核不实不采信，
#   字样与未采信的理由进 internal。其余码的字样只有出错的那个工具自己会打（改写缺口、链号、图形接口、预检缺件、xcrun / xcodebuild 原文），照旧直接定码
DISK_FULL_FREE = 5 << 30   # 盘满候选的核实线：命中行点名的路径或日志所在的盘，剩余空间低于它才算真满（工具失败后常会删掉自己的临时文件，留出余量）


def _free_bytes(path):
    """path（可不存在：往上找到存在的那层）所在盘的剩余字节；读不到为 None"""
    import os
    import shutil
    p = os.path.abspath(path)
    while p and not os.path.exists(p):
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    try:
        return shutil.disk_usage(p).free
    except OSError:
        return None


def _tool_present(name):
    import shutil
    return shutil.which(name) is not None


def _confirm(code, line, log):
    """候选码的事实核对 → (是否采信, 依据)。只核环境类的码，其余直接采信"""
    if code == "disk_full":
        paths = [m.group(1) for m in _LOG_PATH_ANY.finditer(line)] + ([str(Path(log).parent)] if log else [])
        free = [(p, f) for p, f in ((p, _free_bytes(p)) for p in paths) if f is not None]
        if not free:
            return True, "读不到所在盘的剩余空间，按字样"
        path, least = min(free, key=lambda pf: pf[1])
        gib = least / (1 << 30)
        if least < DISK_FULL_FREE:
            return True, "核实：%s 所在盘只剩 %.1f GB" % (path, gib)
        return False, "所在盘还剩 %.1f GB（%s），不是盘满" % (gib, path)
    if code == "tool_missing":
        m = re.search(r"([\w.+-]+): command not found", line)
        if m and _tool_present(m.group(1)):
            return False, "「%s」现在找得到，不是没装" % m.group(1)
    return True, ""


def log_cause(chunks, log=None):
    """证据里有确凿根因字样、且（环境类的码）核实了 → (码, 来源, 命中行, 核对说明)；没有 → (None, 未采信的候选说明列表)。"""
    rejected = []
    for pattern, code in LOG_CAUSES:
        for label, text in chunks:
            m = re.search(pattern, text, re.I)
            if m:
                start = text.rfind("\n", 0, m.start()) + 1
                end = text.find("\n", m.end())
                line = text[start:end if end >= 0 else None].strip()[:300]
                ok, why = _confirm(code, line, log)
                if ok:
                    return code, label, line, why
                rejected.append("候选 %s 未采信：%s 里「%s」，%s" % (code, label, line, why))
                break   # 同一个码事实已核过，别的来源同样字样不再重复核
    return None, rejected


def refresh_stop_phase(red):
    """refresh.sh 的终止红行「【红】<款> 刷新停在 <子阶段>…」→ STAGE_CODES 的阶段；未登记的子阶段给 None（保持宽码，不从更早的红行猜）。"""
    stop = re.match(r"^【红】[^\r\n]+? 刷新停在\s*(.*)", red or "")
    if not stop:
        return None
    substep = stop.group(1)
    for prefix, phase in (("直连配置推导", "configure"), ("rewrite 阶段", "rewrite"), ("抽取阶段", "sh_extract"), ("direct 阶段", "direct")):
        if substep.startswith(prefix):
            return phase
    return None


_PFRW = re.compile(r"PFRW\s+mod=(\S+)\s+need=(\d+)\s+gaps=(\d+)(?:\s+fatal=(-?\d+))?")   # 改写器统计行（runtime/rewriter/rewriter.c 打的机读格式）
_GAP_KIND = re.compile(r"0x[0-9a-fA-F]+|\b[0-9a-f]{8}\b|#-?\w+|S\d_\d_C\d+_C\d+_\d|\b[xw]\d+\b")   # 同 core.write_rewrite_digest 的归类：去掉地址、寄存器号、立即数
GAP_KINDS_MAX = 5


def cause_facts(code, log, texts=()):
    """失败的机读事实（剃刀 G5 / H9）→ dict 或 None。改写类（rewrite_gap / rewrite_failed）：同一份有界证据（gather_evidence）里
    改写器自己打的最后一条统计行 PFRW → {"module", "need", "gaps", "fatal"}；证据里有 GAP 行再加 gapKinds = 前 GAP_KINDS_MAX 类 [{"kind", "count"}]（按次数降序）。
    其余码、证据里没有统计行 → None（不猜）"""
    if code not in ("rewrite_gap", "rewrite_failed"):
        return None
    chunks = gather_evidence(log, texts)
    last, kinds = None, {}
    for _, text in chunks:
        for m in _PFRW.finditer(text):
            last = m
        for line in text.splitlines():
            if line.startswith("GAP\t"):
                kind = _GAP_KIND.sub("_", line.split("\t", 3)[-1])[:80]
                kinds[kind] = kinds.get(kind, 0) + 1
    if not last:
        return None
    facts = {"module": last.group(1), "need": int(last.group(2)), "gaps": int(last.group(3))}
    if last.group(4) is not None:
        facts["fatal"] = int(last.group(4))
    if kinds:
        facts["gapKinds"] = [{"kind": k, "count": n} for k, n in sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))[:GAP_KINDS_MAX]]
    return facts


def classify_failure(phase, log, texts=()):
    """Mac 准备（build_tool_failure）与 iPhone 打包（ipa.oneclick_failure，Mac / Windows 同一份）共用：
    日志确凿根因优先，其次阶段映射，判不出 package_failed。返回 (码, 写进 internal 的归因说明)。"""
    chunks = gather_evidence(log, texts)
    read = "；".join("%s（尾 %d 字节）" % (label, len(text.encode("utf-8"))) for label, text in chunks if label != "原因") or "无日志"
    hit = log_cause(chunks, log)
    if hit[0]:
        code, label, line, why = hit
        return code, "归因 %s：%s 里「%s」%s；读过 %s" % (code, label, line, "（" + why + "）" if why else "", read)
    code = STAGE_CODES.get(phase, "package_failed")
    return code, "归因 %s：按阶段 %s；%s读过 %s" % (code, phase or "未识别", "".join(r + "；" for r in hit[1]), read)


def tool_reason(log):
    """有界读取真实输出；原文在 Context 产生诊断时统一脱敏。"""
    if log:
        try:
            with open(log, "rb") as stream:
                stream.seek(0, 2)
                stream.seek(max(0, stream.tell() - 16000))
                lines = stream.read().decode("utf-8", errors="replace").splitlines()
            # 作业层自己往工具日志里追加的记录（[s2a] 开头，如收掉残留进程）不是工具的报错，不当失败原因（#711：真报错被它盖住）
            nonempty = [line.strip() for line in lines if line.strip() and not line.strip().startswith("[s2a] ")]
            red = [line for line in nonempty if "【红】" in line]
            if nonempty:
                return (red or nonempty)[-1][-1500:]
        except OSError:
            pass
    return "工具未提供错误详情，请保留本阶段日志。"


def last_output_lines(log, limit=5):
    """日志末尾最有用的几行（红行优先，保持原顺序），每行截到 300 字；脱敏由调用方（Context.redact）做"""
    if not log:
        return []
    try:
        with open(log, "rb") as stream:
            stream.seek(0, 2)
            stream.seek(max(0, stream.tell() - 16000))
            lines = [line.strip() for line in stream.read().decode("utf-8", errors="replace").splitlines() if line.strip()]
    except OSError:
        return []
    reds = [i for i, line in enumerate(lines) if "【红】" in line or "error" in line.lower()][-2:]
    keep = sorted(set(reds) | set(range(max(0, len(lines) - (limit - len(reds))), len(lines))))
    return [lines[i][-300:] for i in keep]


def failure_summary(stage, exit_code, lines):
    """错误摘要里的失败事实（英文标签，中英文玩家转发都能读；原文已脱敏）。前端原样显示这段"""
    out = ["Failed stage: " + (stage or "unknown")]
    if exit_code is not None:
        out.append("Exit code: %s" % exit_code)
    if lines:
        out += ["Last output:"] + ["  " + line for line in lines]
    return "\n".join(out)


def build_tool_failure(args, milestone, log):
    """只供 Mac build 的非零退出分支调用；其余 operation 的 run 契约不变。"""
    from pathlib import Path
    executable = Path(args[0]).name
    script = Path(args[1]).name if len(args) > 1 else ""
    phase = None
    reason = tool_reason(log)
    if executable == "codesign":
        phase = "sign"
    elif executable == "make" and "host" in args[1:]:
        phase = "host"
    elif executable in ("bash", "sh"):
        if script == "seed_root.sh":
            phase = "seed"
        elif script == "refresh.sh":
            # 只采用本次 refresh 的终止红行（日志末条红行），不允许 host/unpack/sign 等上一条命令的标签参与本次归因。
            phase = refresh_stop_phase(reason) or "refresh"
    elif executable == "dotnet" and milestone == "unpack":
        phase = "unpack"
    code, why = classify_failure(phase, log)
    # 上屏只放玩家话术；阶段 / rc / 构建号 / 红行原文进 internal → 诊断 detail（「复制错误摘要」带走）；机读事实进 facts（前端按字段显示）
    return Failure(player_reason(code), code=code, internal="Mac 准备失败（" + (phase or "未识别阶段") + "）：" + reason + "\n" + why,
                   facts=cause_facts(code, log))
