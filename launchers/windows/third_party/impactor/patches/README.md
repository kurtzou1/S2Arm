# 随包 Impactor / plumesign 的补丁（基于上游 claration/Impactor v2.7.3 的修改版）

随包的 Impactor 与 plumesign 由 `tools/plumesign_build.py` 从上游 v2.7.3 源码（标签提交 2ba32ea4，源码树 7e4416b8）
打上本目录的补丁后编出；许可照上游：Impactor 为 MIT（`../LICENSE-Impactor-MIT.txt`），内嵌的 apple-codesign 0.29.0 为
MPL-2.0（`../LICENSE-apple-codesign-MPL-2.0.txt`）。

## 0001-anisette-v3-server.patch

- 现象：Windows / Mac 上用随包 Impactor 登录 Apple ID，部分账号被 Apple 拒绝：
  `Authentication SRP error -23782: A Mac with macOS 10.13 or later is required`。
- 原因：上游写死的 anisette v3 服务器 `mac-ani.jkcoxson.com` 的 `/v3/client_info` 报
  `<MacBookPro13,3> <Mac OS X;10.12.6;16G29>`，plumesign 把它原样作为 `X-Mme-Client-Info` 发给 Apple；
  Apple 对部分账号要求 macOS 10.13 以上。v2.7.2 时这个值被转成小写，Apple 解析不了，回 HTTP 403；
  v2.7.3（上游 PR #317）改成原样发送后，就变成上面的 -23782。
- 为什么不直接整体换服务器：Apple 把登录会话和 anisette 服务器绑在一起，换服务器后所有已登录的账号都要重新输密码和验证码
  （11-18 实测：同一份数据目录，官方 2.7.3 照常，换了服务器的版本两个账号都报「会话已过期」，沿用旧开通数据也一样）。
- 改法（被拒才换）：
  1. `3rdparty/omnisette/src/lib.rs`：默认服务器不动；新增备用服务器 `https://ani.sidestore.io`（其 `client_info` 报 `<macOS;13.1;22C65>`）。
     数据目录里有 `anisette-v3-url` 文件时改用文件里的服务器；开通状态按服务器分文件（默认服务器仍是 `state.plist`，已有数据照常有效，
     备用服务器是 `state-ani.sidestore.io.plist`）。
  2. `3rdparty/omnisette/src/remote_anisette_v3.rs`：开通状态文件名按服务器取（同上）。
  3. `crates/plume_core/src/auth/account/login.rs`：登录在默认服务器上被 Apple 以 SRP -23782 拒绝时，在数据目录记下备用服务器、
     写一行日志（哪个账号、从哪台换到哪台、原因），用第一次拿到的账号密码在备用服务器上重试一次（-23782 出在 SRP 这一步，
     在双重认证之前，玩家不会多输一次验证码）；之后这个数据目录一直用备用服务器。别的错误、已在备用服务器上又被拒，都不重试。
     控制流抽成 `login_with_anisette_fallback`（`account/mod.rs` 导出），`check/login_fallback_check.rs` 用假的登录模拟上面五种情况，
     `tools/plumesign_build.py` 编之前跑。
  4. `apps/plumeimpactor/src/screen/settings.rs`：「重置 anisette 数据」删掉各服务器的开通状态文件。

## 0002-2fa-coherent-identity-no-loop.patch

- 现象：部分账号（多见只用短信收验证码的）在 Mac 启动器和 Impactor 里输完验证码，苹果回成功，几秒后又要一个新的短信验证码，一直循环（玩家诊断里同一次登录连要 3 次「Enter the code sent via SMS」）。
  上游同一个问题见 claration/Impactor#218，其他签名工具也有同样的帖子（altstoreio/AltStore#1772、franklintra/splice#25）。
- 原因：验证码通过后，plumesign 照协议重新登录一次，好拿到已被信任的会话。苹果只信任「机型 / 系统 / 版本号」前后一致的机器；
  我们发给苹果的 `X-MMe-Client-Info` 照抄 anisette 服务器报的值（默认服务器是 `<MacBookPro13,3> <Mac OS X;10.12.6;16G29>`，备用服务器是 macOS 13.1），
  `User-Agent` 写死 `Darwin/18.7.0`（macOS 10.14），几项互相对不上。苹果接受了验证码，却不信任这台机器，重登时又回「要验证码」（`secondaryAuth` / 409），上游的登录循环就无限要码。
  AltStore#1772 的作者逐项对比实测过：只把这一项换成当前、一致的值，同一流程重登就返回 200。
- 改法：
  1. `crates/plume_core/src/auth/anisette_data.rs`：发给苹果的 `X-Mme-Client-Info` 与 akd `User-Agent` 统一取 `apple_client_info()` / `apple_user_agent()`。
     macOS 上取本机自己的机型、系统版本、版本号、CFNetwork 与 Darwin 版本（就是苹果自家 AuthKit 发的那一组）；Windows 和读不到时用一台真 Mac 上一起读出的固定一组。
     和 anisette 服务器之间的开通（provisioning）照旧用服务器自己的值，已登录的会话不受影响（换开通身份会让所有账号重登，见 0001）。
     `login.rs` / `token.rs` 里写死的 `Darwin/18.7.0` 改用同一个来源。
  2. `crates/plume_core/src/auth/account/login.rs`：登录状态机抽成 `drive_login`（步骤是 `LoginSteps` trait，`Account` 实现）。
     验证码被接受后最多重登一次；重登又要验证码（设备推送、409、短信任一种），就以 `S2A_2FA_REPEAT` 报错退出，不再让玩家输第二次、不再发第二条短信。验证码输错照上游报 `Bad2faCode`。
  3. `crates/plume_core/src/auth/mod.rs`：`VerifyBody::sms(id)` 构造函数（检查程序要用）。
- 检查：`check/two_factor_check.rs`（`tools/plumesign_build.py` 编之前跑）。用假登录走 6 种情形：短信通过、短信通过后又要码、设备通过后 409、设备通过后又要推送、码输错、不用双重认证；
  核登录次数、要码次数、短信条数。再核发给苹果的各类请求头（登录、取令牌、双重认证、开发者服务）用的是同一个身份、不是服务器的旧值，以及 UA 的 Darwin 版本与本机一致。
  负对照：去掉「最多重登一次」，检查程序当场报「要码超过 4 次：还在循环」。
- 启动器侧（`pack/jobs/apple_login.py`）兜底：同一次登录里交过一次 6 位码后又看到要码提示，或 plumesign 报 `S2A_2FA_REPEAT`，就停下，报 `login_identity_rejected` 和一句说明（`SAY_2FA_REPEAT`）。
- 没有在真账号上实测（要账号本人的密码和验证码）：判据是上面的检查加上同类工具的实测记录。

- 11-20 起：苹果 GSA 边缘层拒收 `X-Mme-Client-Info` 系统名写成 `macOS;` 的请求，一律回 HTTP 503（约 0.2 秒、在核账号之前；同行 SideStore/SideStore#1745）。
  本补丁原先按 `<机型> <macOS;版本;版本号>` 拼，随包 plumesign 每台机器登录都 503（玩家「换网络、开热点都不行」）。系统名改成 `Mac OS X;`，
  机型 / 版本 / 版本号照旧取本机、前后一致不变。实测（不带账号、只改这一段）：`macOS;` → 503，`Mac OS X;` + `com.apple.akd/1.0` → 过边缘层（401 / 404）。

## 0003-srp-password-protocol-s2k-fo.patch

- 现象：部分玩家确认密码正确（浏览器能登、复制粘贴也一样），S2Arm / Impactor 登录每次都报
  `Authentication SRP error -22406: Enter the correct password for this Apple Account`（#1794 等）。
- 原因：登录第一步（init）我们向 Apple 声明支持 `s2k` 和 `s2k_fo` 两种口令协议，Apple 在回包的 `sp` 里按账号选一种。
  上游不读 `sp`，一律按 `s2k` 算口令钥匙：PBKDF2-HMAC-SHA256(SHA256(密码))。`s2k_fo` 要的是对 SHA256(密码) 的**小写十六进制串**做 PBKDF2，
  所以 Apple 选了 `s2k_fo` 的账号，密码再对也算不出同一把钥匙，Apple 只能回 -22406。同类实现（如 pypush 的 gsa.py）都按 `sp` 分支。
- 改法：`crates/plume_core/src/auth/account/login.rs` 读 `sp`（缺省 `s2k`，同上游），口令钥匙抽成 `srp_password_key`（`account/mod.rs` 导出）：
  `s2k` 照旧，`s2k_fo` 用十六进制串，不认识的协议具名报错（`S2A_SRP_PROTOCOL unsupported …`），不静默按 `s2k` 算。
  每次登录写一行日志 `S2A_SRP_PROTOCOL <协议>`，诊断里能看到这个账号走的是哪种。
- 检查：`check/srp_protocol_check.rs`。两组密码 / 盐 / 迭代次数 × 两种协议，期望值由 Python `hashlib.pbkdf2_hmac` 独立算出；
  负对照：`s2k_fo` 分支改回上游算法（原始摘要）时检查红；未知协议具名报错。
- 没有在 `s2k_fo` 的真账号上实测（要账号本人的密码；也不知道玩家账号 Apple 选的是哪种，上面那行日志就是为此加的）。

## 0004-gui-log-file-and-login-outcome.patch

- 现象：Windows 上 Apple ID 是在 Impactor 窗口里登录的，登录失败的原因只显示在窗口上；窗口程序没有控制台，`env_logger` 写到标准错误的日志也全丢了。
  玩家报「登录不了」时，诊断包里看不到当时 Impactor 报了什么、试了几次、间隔多久（Mac 端同类问题靠作业日志查出了失败后不到 1 秒就连发重试）。
- 改法（只改窗口版 `apps/plumeimpactor`，plumesign 不变）：
  1. `src/main.rs`：环境变量 `S2A_IMPACTOR_LOG` 给了文件路径时，日志追加写进这个文件（带毫秒时间戳；缺省级别：Impactor 自己和 `plume_core` 记 info，其余库只记 warn）；没给时照上游写标准错误。
  2. `src/screen/windows/login_window.rs`：提交登录记 `S2A_LOGIN_SUBMIT`、成功记 `S2A_LOGIN_OK`、失败记 `S2A_LOGIN_FAILED two_factor=<是否在验证码这步> <原因>`。不记邮箱和密码。
- S2Arm 启动器打开随包 Impactor 时把 `S2A_IMPACTOR_LOG` 设成 `<私有目录>/logs/impactor-gui.log`（超过 1 MB 先改名为 `.old.log`，只留两份），诊断包照收 `logs/*.log`、同一套脱敏。

## 0005-provision-with-login-identity.patch

- 现象（11-21 起）：Mac 启动器 / Windows Impactor 登录 Apple ID，密码通过、验证码也输了，随后报
  `Authentication SRP error -22410: This action could not be completed. Please try again.`（#1794；诊断 D-R2TK 的 plumesign 原始输出：
  `S2A_SRP_PROTOCOL s2k` → 要验证码 → 输完码 → -22410，被拒的是验证码之后那次重新登录）。同一天 SideStore / GetMoreRam 也在报同一个码
  （SideStore/SideStore#1749、#1744）。
- 原因：苹果只信任「开通 anisette 时的机器身份」与「登录时发的 `X-Mme-Client-Info`」是同一台机器。我们和 anisette 服务器开通（start / end provisioning）
  时用的是服务器自己报的身份（默认服务器 `<MacBookPro13,3> <Mac OS X;10.12.6;16G29>`），而 0002 起登录、验证码、开发者服务发给苹果的是本机身份
  （Mac 读本机机型和系统，Windows 用一台固定的真 Mac），两边从来不一致；11-21 前苹果不核，之后核了。SideStore#1749 有人逐步实测：改了 Client Info
  却没重新开通（adi.pb 是旧身份开的）→ -22410；重置开通数据、在同一份身份下重新开通 → 登录成功。
- 改法：
  1. 机器身份（`apple_client_info()` / `apple_user_agent()`）从 `plume_core` 挪进 `3rdparty/omnisette/src/identity.rs`，`plume_core::auth::anisette_data`
     原名转出——开通和之后每个发给苹果的请求只有这一个来源。
  2. `remote_anisette_v3.rs`：取到服务器的 `client_info` 后改用同一份本机身份开通（`provisioning_identity`），开通后生成的头也是它；
     日志写一行 `S2A_ANISETTE_IDENTITY server <服务器报的> replaced by <实际用的>`。
  3. `lib.rs` `state_file_name`：开通状态按服务器 + 身份分文件（`state-<身份指纹>.plist`、`state-<主机>-<身份指纹>.plist`，指纹是身份串与 UA 的
     SHA-256 前 4 字节）。旧版按服务器身份开的 `state.plist` 不再沿用（文件留着不删），身份变了（换机器、升级系统）自动重新开通，
     等于替玩家做一次 SideStore 的「Reset adi.pb」。代价：升级后已登录的账号要重新输一次密码和验证码（本来也登不上了）。
  4. Impactor 设置里「重置 anisette 数据」照旧删 `state*.plist`（注释更新）。
- 检查：`check/identity_check.rs`（8 项）：开通身份 = 登录身份（服务器报什么都不用）；发给苹果的 `X-Mme-Client-Info` / UA 与开通的同源；
  状态文件名带身份指纹、默认与备用分开、旧名不再沿用、同一身份名字固定。负对照：开通改回用服务器身份时 ①② 三项红。
- 协议层自测（不带账号）：全新数据目录用测试邮箱登录，开通在默认服务器上以本机身份走通、生成 `state-<指纹>.plist`，SRP init 照常拿到苹果回包；
  拿旧版开通过的数据目录跑新版，旧 `state.plist` 原样不动、另开一份按身份命名的状态。
- 没有在真账号上实测（要账号本人的密码和验证码）：判据是上面的检查、协议层自测和 SideStore 的同类实测记录。

## 自编产物（v2.7.3-s2a6，补丁 0001 + 0002 + 0003 + 0004 + 0005；s2a6 加 0005，plumesign 与 Impactor 两端都重编）

| 平台 | 文件 | SHA-256 | Rust |
|---|---|---|---|
| Windows | plumesign-windows-x86_64.exe | 0fd734c19fe9fa47f7a2605ce7f227437f6b9df6f7835b8bb0c777015d26c31f | 1.99.1 |
| Windows | Impactor-windows-x86_64-portable.exe | 188e49ea40f0384c0a32988909efc3fe95dbd05842a3293db28917b23ada212f | 1.99.1 |
| macOS | plumesign-macos-universal | a4c94b2132a7b6bc8e583d03b10831ca48aa91187ff2f5a61a39534ec1bfc19a | 1.94.0 |

两端编之前补丁检查程序（login_fallback_check、srp_protocol_check、two_factor_check、identity_check）均全过；两端产物各用测试邮箱登录一次，
日志 `S2A_ANISETTE_IDENTITY` 显示开通改用本机身份（Windows 是固定的那台真 Mac），开通在默认服务器上走通、生成按身份命名的状态文件。

## 自编产物（v2.7.3-s2a5，补丁 0001 + 0002 + 0003 + 0004；s2a5 只加 0004，只改窗口版 Impactor）

| 平台 | 文件 | SHA-256 | Rust |
|---|---|---|---|
| Windows | plumesign-windows-x86_64.exe | cea743fe70f07b672a2be38c5663978055b863fcbd29c75e87e13d367970c8c4 | 1.99.1 |
| Windows | Impactor-windows-x86_64-portable.exe | 3d503f75d3a5bc63fc4555c92e0e8eacb9e64d776f5c4319d7fd6a988e714922 | 1.99.1 |
| macOS | plumesign-macos-universal | 6b719c8839e219f9e8c94606330a3a3c54fcf983910f3c9b2ca24d195b1d12cf | 1.94.0 |

可重复编译的做法同 s2a1（同一台机器、两个工作目录各编一次，Mac 先清空固定编译目录，11-18 核过逐字节相同）；s2a3 两端各只编了一次，没有重做这项核对。
s2a5 只在 Windows 实机重编：0004 不碰 plumesign，Windows plumesign 编出来与 s2a4 逐字节相同（同一 SHA-256），Mac plumesign 沿用 s2a4 的产物。
两端编之前补丁检查程序（login_fallback_check、srp_protocol_check、two_factor_check）均全过。

## 0006-reuse-cert-by-key.patch

- 现象（#2015）：手机上用 SideStore / AltStore 装过 App 的免费 Apple ID 玩家，用 S2Arm 签名时被提示「要新建证书，满了会撤掉 SideStore 那张」。
  玩家从 SideStore 导出了那张证书的 .p12（私钥在手），S2Arm 仍然没法复用它：免费 Apple ID 拿不到描述文件，开发者证书导入路径走不通；
  Apple ID 签名路径里 plumesign 只认自己建的证书。
- 原因：`crates/plume_core/src/utils/certificate.rs` 的 `find_certificate` 要求两样都对上：证书公钥 = keys/<团队>/key.pem 的公钥，**且**机器名 == `"AltStore"`。
  SideStore 在手机上建的证书机器名是「SideStore - <设备名>」之类，即使把它的私钥放进 key.pem 也认不出，plumesign 就去新建一张；账号满了，苹果撤列表第一张。
- 改法：
  1. `certificate.rs`：认证书只比公钥（新增 `CertificateIdentity::find_by_key`，`find_certificate` 改用它），不看机器名。手里有私钥就是能用的证书。
     描述文件本来就按 App ID 申请团队描述文件（`qh_get_profile` → downloadTeamProvisioningProfile），不点名证书，不用改。
  2. `apps/plumesign/src/commands/mod.rs`：`--version` 输出带 `+s2a-keycert`。启动器（`pack/orch/install_win.py keycert`）据此判这个 plumesign 会不会复用导入的证书：
     原版只认 AltStore 机器名，启动器的撤证书检查（cert_check）和手机自签身份（plume_identity）按原版口径；带标记的按公钥口径，三处与 plumesign 自己选的证书一致。
- 启动器侧：证书导入弹窗只选 .p12（不选描述文件）时，作业层（`pack/jobs/devcert.py adopt`）核这张证书在当前登录的 Apple ID 证书列表里，
  把私钥换成 PKCS#8 写进 keys/<团队>/key.pem（原来那把不同就先留 key.pem.bak-<时刻>），之后 Apple ID 签名复用它、不新建、不撤。
- 检查：`check/keycert_check.rs`（`tools/plumesign_build.py` 编之前跑）。现场造 RSA 私钥和证书，核：机器名 SideStore / AltStore 公钥对上都认、公钥对不上不认、
  几张里认出的是公钥对上的那张（不是第一张）、版本号带标记。没打本补丁时检查程序编不过（没有 `find_by_key`）。
- 没有在真账号上实测（要账号本人登录）。
