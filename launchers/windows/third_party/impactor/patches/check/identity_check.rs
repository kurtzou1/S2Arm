// S2Arm：补丁 0005「开通与登录用同一份机器身份」的检查（tools/plumesign_build.py 编之前跑）。
// 苹果 11-21 起只信任「开通 anisette 时的机器身份 = 登录时发的身份」：用服务器自己的身份开通、用本机身份登录，
// 验证码之后那次登录报 SRP -22410（SideStore/SideStore#1749 重置开通数据、两边一致后恢复）。核：
// ① 开通用的身份就是之后每个发给苹果的请求带的那份（不管服务器报什么）
// ② 登录 / 验证码 / 开发者服务请求头里的 X-Mme-Client-Info 与 User-Agent 来源相同
// ③ 开通状态文件按身份分开：名字带身份指纹，旧版的 state.plist / state-<host>.plist 不再被沿用；同一身份名字固定
use omnisette::identity::{apple_client_info, apple_user_agent, identity_tag};
use omnisette::remote_anisette_v3::provisioning_identity;
use omnisette::*;
use std::collections::HashMap;

fn main() {
    let mut bad = Vec::new();
    let mut ok = |cond: bool, what: &str| { println!("{} {what}", if cond { "✓" } else { "✗" }); if !cond { bad.push(what.to_string()); } };

    // ① 服务器报旧机型旧系统，开通照样用本机身份
    let server = ("<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0");
    let (info, agent) = provisioning_identity(server.0, server.1);
    ok(info == apple_client_info() && agent == apple_user_agent(), "① 开通身份 = 登录身份（不用服务器报的旧值）");
    ok(info.contains("<Mac OS X;") && !info.contains("<macOS;"), "① 系统名是 Mac OS X;（macOS; 会被苹果边缘层 503）");

    // ② 登录侧：AnisetteData 生成的请求头里 X-Mme-Client-Info 换成同一份身份
    let mut base = HashMap::new();
    base.insert("X-Mme-Client-Info".to_string(), server.0.to_string());
    base.insert("X-Apple-I-MD".to_string(), "otp".to_string());
    base.insert("X-Apple-I-MD-M".to_string(), "mid".to_string());
    let data = plume_core::auth::anisette_data::AnisetteData {
        base_headers: base, generated_at: std::time::SystemTime::now(), config: AnisetteConfiguration::new() };
    let h = data.generate_headers(false, true, true);
    ok(h.get("X-Mme-Client-Info").map(String::as_str) == Some(info.as_str()), "② 发给苹果的 X-Mme-Client-Info = 开通身份");
    ok(plume_core::auth::anisette_data::apple_user_agent() == agent, "② 登录 User-Agent = 开通 User-Agent");

    // ③ 状态文件名
    let d = state_file_name(DEFAULT_ANISETTE_URL_V3);
    let f = state_file_name(FALLBACK_ANISETTE_URL_V3);
    let tag = identity_tag();
    ok(tag.len() == 8 && d == format!("state-{tag}.plist"), "③ 默认服务器的状态文件带身份指纹");
    ok(f.contains(&tag) && f != d, "③ 备用服务器的状态文件也带身份指纹、与默认分开");
    ok(d != "state.plist" && f != "state-ani.sidestore.io.plist", "③ 旧版按服务器身份开通的状态文件不再沿用");
    ok(state_file_name(DEFAULT_ANISETTE_URL_V3) == d, "③ 同一身份名字固定（不会每次重新开通）");

    if !bad.is_empty() { eprintln!("✗ 身份一致性检查：{} 项不通", bad.len()); std::process::exit(1); }
    println!("✓ 身份一致性检查全部通过（8 项）");
}
