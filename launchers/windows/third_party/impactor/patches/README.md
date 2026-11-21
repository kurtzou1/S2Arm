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

## 自编产物（v2.7.3-s2a3，补丁 0001 + 0002 + 0003）

| 平台 | 文件 | SHA-256 | Rust |
|---|---|---|---|
| Windows | plumesign-windows-x86_64.exe | dbfb5603a7f4bd0db87fd8a81bb41d5ca0d883553f6e9a21e19e0661df9a679c | 1.99.1 |
| Windows | Impactor-windows-x86_64-portable.exe | fb5f89b659436e22ce690f28236d02a2c541de065f609e31baf95c34d9bca419 | 1.99.1 |
| macOS | plumesign-macos-universal | f3f8be40ebb05abc0e732e09a846bbbcbefaded87f9fd6bfe857adf8d100bcd9 | 1.94.0 |

可重复编译的做法同 s2a1（同一台机器、两个工作目录各编一次，Mac 先清空固定编译目录，11-18 核过逐字节相同）；s2a3 两端各只编了一次，没有重做这项核对。
两端编之前补丁检查程序（login_fallback_check、srp_protocol_check、two_factor_check）均全过。
