// S2Arm：补丁 0006「手里有私钥的账号证书就复用，不看机器名」的检查（tools/plumesign_build.py 编之前跑）。
// 上游只认机器名 == "AltStore" 的证书：SideStore / AltStore 在手机上建的证书（机器名「SideStore - iPhone」之类）即使私钥在 key.pem 里也认不出，
// plumesign 去新建一张，账号满了苹果撤列表第一张——常常就是那张 SideStore 的证书（#2015）。核：
// ① 公钥对上、机器名是别的（SideStore）→ 认出这张
// ② 公钥对上、机器名是 AltStore → 照旧认出
// ③ 公钥对不上（别人的证书）→ 不认，哪怕机器名是 AltStore
// ④ 列表里有几张时认出的是公钥对上的那张，不是第一张
// ⑤ 版本号带 +s2a-keycert（启动器据此判这个 plumesign 会不会复用导入的证书）
use plist::{Dictionary, Value};
use plume_core::CertificateIdentity;
use plume_core::developer::qh::certs::Cert;
use rcgen::{CertificateParams, KeyPair, PKCS_RSA_SHA256};
use rsa::RsaPrivateKey;
use rsa::pkcs8::EncodePrivateKey;

fn key() -> RsaPrivateKey {
    RsaPrivateKey::new(&mut rand::rngs::OsRng, 2048).unwrap()
}

fn cert(name: &str, machine: &str, k: &RsaPrivateKey) -> Cert {
    let mut p = CertificateParams::new(vec![]);
    p.alg = &PKCS_RSA_SHA256;
    p.key_pair = Some(KeyPair::from_der(k.to_pkcs8_der().unwrap().as_bytes()).unwrap());
    let der = rcgen::Certificate::from_params(p).unwrap().serialize_der().unwrap();
    let mut d = Dictionary::new();
    for (f, v) in [("name", name), ("certificateId", name), ("serialNumber", name), ("status", "Issued"), ("machineName", machine), ("machineId", "m")] {
        d.insert(f.into(), Value::String(v.into()));
    }
    d.insert("statusCode".into(), Value::Integer(0.into()));
    d.insert("expirationDate".into(), Value::Date(std::time::SystemTime::now().into()));
    d.insert("certContent".into(), Value::Data(der));
    plist::from_value(&Value::Dictionary(d)).unwrap()
}

fn main() {
    let mut bad = Vec::new();
    let mut ok = |cond: bool, what: &str| { println!("{} {what}", if cond { "✓" } else { "✗" }); if !cond { bad.push(what.to_string()); } };
    let (mine, other) = (key(), key());
    let found = |certs: &[Cert], k: &RsaPrivateKey| CertificateIdentity::find_by_key(certs, k).unwrap().map(|c| c.name.clone());

    ok(found(&[cert("ss", "SideStore - iPhone", &mine)], &mine).as_deref() == Some("ss"), "① 公钥对上、机器名 SideStore → 认出");
    ok(found(&[cert("alt", "AltStore", &mine)], &mine).as_deref() == Some("alt"), "② 公钥对上、机器名 AltStore → 认出");
    ok(found(&[cert("alt", "AltStore", &other)], &mine).is_none(), "③ 公钥对不上 → 不认（机器名 AltStore 也不认）");
    let list = [cert("first", "AltStore", &other), cert("ss", "SideStore - iPhone", &mine), cert("x", "Xcode", &other)];
    ok(found(&list, &mine).as_deref() == Some("ss"), "④ 几张里认出公钥对上的那张，不是第一张");

    let exe = std::env::var("S2A_CHECK_PLUMESIGN").ok();
    let src = include_str!("../../../plumesign/src/commands/mod.rs");
    ok(src.contains("\"+s2a-keycert\""), "⑤ 版本号带 +s2a-keycert");
    if let Some(exe) = exe {
        let out = std::process::Command::new(exe).arg("--version").output().unwrap();
        ok(String::from_utf8_lossy(&out.stdout).contains("+s2a-keycert"), "⑤ 编出的 plumesign --version 带 +s2a-keycert");
    }

    if !bad.is_empty() { eprintln!("补丁 0006 检查失败：{}", bad.join("；")); std::process::exit(1); }
    println!("补丁 0006 检查全过");
}
