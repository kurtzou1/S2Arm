// S2Arm：补丁 0002 的检查（tools/plumesign_build.py 编之前跑）。
// 一、登录状态机（假登录，不连 Apple）：验证码被接受后最多重登一次；重登又要码就停下报 S2A_2FA_REPEAT，不再要第二次码、不再发第二条短信。
// 二、同一次登录里发给 Apple 的机型 / 系统字段一致：各条请求头取同一个身份，不再出现 anisette 服务器报的旧身份。
use plume_core::Error;
use plume_core::auth::account::{LoginSteps, REPEAT_2FA_MARKER, drive_login};
use plume_core::auth::anisette_data::{AnisetteData, apple_client_info, apple_user_agent};
use plume_core::auth::{LoginState, TrustedPhoneNumber, TwoFactorAction, TwoFactorRequest, VerifyBody};
use std::cell::Cell;

#[derive(Default)]
struct Fake {
    first: Option<LoginState>,  // 第一次登录返回什么
    again: Option<LoginState>,  // 校验通过后重登返回什么
    wrong_code: bool,
    logins: Cell<u32>,
    sms_sent: Cell<u32>,
}

impl LoginSteps for Fake {
    async fn login_email_pass(&mut self, _: &str, _: &str) -> Result<LoginState, Error> {
        self.logins.set(self.logins.get() + 1);
        Ok(if self.logins.get() == 1 { self.first.take().unwrap() } else { self.again.take().unwrap_or(LoginState::NeedsSMS2FA) })
    }
    async fn send_2fa_to_devices(&self) -> Result<LoginState, Error> { Ok(LoginState::Needs2FAVerification) }
    async fn trusted_phone_numbers(&self) -> Vec<TrustedPhoneNumber> { Vec::new() }
    async fn verify_2fa(&self, _: String) -> Result<LoginState, Error> {
        if self.wrong_code { Err(Error::Bad2faCode) } else { Ok(LoginState::NeedsLogin) }
    }
    async fn send_sms_2fa_to_devices(&self, id: u32) -> Result<LoginState, Error> {
        self.sms_sent.set(self.sms_sent.get() + 1);
        Ok(LoginState::NeedsSMS2FAVerification(VerifyBody::sms(id)))
    }
    async fn verify_sms_2fa(&self, _: String, _: VerifyBody) -> Result<LoginState, Error> {
        if self.wrong_code { Err(Error::Bad2faCode) } else { Ok(LoginState::NeedsLogin) }
    }
    fn has_pet(&self) -> bool { false }
}

async fn run(mut f: Fake) -> (Result<(), Error>, u32, u32, u32) {
    let asked = Cell::new(0);
    let tfa = |_: TwoFactorRequest| { asked.set(asked.get() + 1); assert!(asked.get() < 5, "要码超过 4 次：还在循环"); Ok::<_, String>(TwoFactorAction::SubmitCode("123456".into())) };
    let r = drive_login(&mut f, "a@b.c", "pw", &tfa).await;
    (r, f.logins.get(), asked.get(), f.sms_sent.get())
}

fn is_repeat(r: &Result<(), Error>) -> bool {
    matches!(r, Err(Error::AuthSrpWithMessage(_, m)) if m.contains(REPEAT_2FA_MARKER))
}

fn main() {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
        // ① 短信：码被接受 → 重登一次 → 登上（登录 2 次、要码 1 次、短信 1 条）
        let (r, logins, asked, sms) = run(Fake { first: Some(LoginState::NeedsSMS2FA), again: Some(LoginState::LoggedIn), ..Default::default() }).await;
        assert!(r.is_ok()); assert_eq!((logins, asked, sms), (2, 1, 1));
        // ② 短信：码被接受，重登 Apple 又要短信（上游这里无限循环）→ 停下报 S2A_2FA_REPEAT；不发第二条短信、不再要码、不再重登
        let (r, logins, asked, sms) = run(Fake { first: Some(LoginState::NeedsSMS2FA), again: Some(LoginState::NeedsSMS2FA), ..Default::default() }).await;
        assert!(is_repeat(&r), "{r:?}"); assert_eq!((logins, asked, sms), (2, 1, 1));
        // ③ 受信任设备：码被接受，重登又回 409 → 同样停下
        let (r, logins, asked, _) = run(Fake { first: Some(LoginState::NeedsDevice2FA), again: Some(LoginState::Needs2FAVerification), ..Default::default() }).await;
        assert!(is_repeat(&r), "{r:?}"); assert_eq!((logins, asked), (2, 1));
        // ④ 受信任设备：重登又要设备推送 → 停下
        let (r, logins, asked, _) = run(Fake { first: Some(LoginState::NeedsDevice2FA), again: Some(LoginState::NeedsDevice2FA), ..Default::default() }).await;
        assert!(is_repeat(&r), "{r:?}"); assert_eq!((logins, asked), (2, 1));
        // ⑤ 码输错：照上游报 Bad2faCode，不重登
        let (r, logins, asked, _) = run(Fake { first: Some(LoginState::NeedsSMS2FA), wrong_code: true, ..Default::default() }).await;
        assert!(matches!(r, Err(Error::Bad2faCode))); assert_eq!((logins, asked), (1, 1));
        // ⑥ 不用双重认证的账号：登录 1 次、不要码
        let (r, logins, asked, _) = run(Fake { first: Some(LoginState::LoggedIn), ..Default::default() }).await;
        assert!(r.is_ok()); assert_eq!((logins, asked), (1, 0));
        println!("双重认证状态机 6 项全过");
    });

    // ⑦ 身份一致：anisette 服务器报旧身份，发给 Apple 的每种请求头都换成同一个身份
    let stale = "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
    let d = AnisetteData {
        base_headers: [("X-Mme-Client-Info".to_string(), stale.to_string()), ("X-Apple-I-MD".to_string(), "x".to_string())].into(),
        generated_at: std::time::SystemTime::now(),
        config: omnisette::AnisetteConfiguration::new(),
    };
    let ci = apple_client_info();
    let seen = [
        d.get_header("x-mme-client-info").unwrap(),                                      // 登录 SRP、取令牌（login.rs / token.rs）
        d.generate_headers(false, true, true)["X-Mme-Client-Info"].clone(),              // 双重认证、开发者服务（two_factor_auth.rs / session.rs）
        d.generate_headers(true, true, false)["X-Mme-Client-Info"].clone(),
    ];
    assert!(seen.iter().all(|v| v == ci), "{seen:?} vs {ci}");
    // 身份三段齐全、是当代 macOS，UA 的 Darwin 与身份出自同一台机器
    let f: Vec<&str> = ci.split(['<', '>']).filter(|x| !x.trim().is_empty()).collect();
    assert!(f.len() == 3 && f[0].starts_with("Mac") && f[1].starts_with("Mac OS X;") && f[1].split(';').count() == 3, "{ci}");
    let major: u32 = f[1].split(';').nth(1).unwrap().split('.').next().unwrap().parse().unwrap();
    assert!(major >= 14, "{ci}");
    let ua = apple_user_agent();
    assert!(ua.starts_with("akd/1.0 CFNetwork/") && ua.contains(" Darwin/") && !ua.contains("Darwin/18."), "{ua}");
    #[cfg(target_os = "macos")]
    {
        let sh = |c: &str, a: &[&str]| String::from_utf8(std::process::Command::new(c).args(a).output().unwrap().stdout).unwrap().trim().to_string();
        assert!(ci.contains(&format!("<Mac OS X;{};{}>", sh("/usr/bin/sw_vers", &["-productVersion"]), sh("/usr/bin/sw_vers", &["-buildVersion"]))), "{ci}");
        assert!(ua.ends_with(&format!("Darwin/{}", sh("/usr/bin/uname", &["-r"]))), "{ua}");
    }
    // ⑧ 源码里不再有写死的旧身份（发给 Apple 的 User-Agent / Client-Info 只从 anisette_data 取）
    for (name, src) in [
        ("login.rs", include_str!("../../../../crates/plume_core/src/auth/account/login.rs")),
        ("token.rs", include_str!("../../../../crates/plume_core/src/auth/account/token.rs")),
        ("two_factor_auth.rs", include_str!("../../../../crates/plume_core/src/auth/account/two_factor_auth.rs")),
        ("session.rs", include_str!("../../../../crates/plume_core/src/developer/session.rs")),
    ] {
        assert!(!src.contains("Darwin/18") && !src.contains("10.12.6"), "{name} 还写死旧身份");
    }
    println!("发给 Apple 的身份一致：{ci}｜{ua}");
}
