// S2Arm：补丁 0003 的检查（tools/plumesign_build.py 编之前跑）。Apple 在登录 init 回包的 "sp" 里选口令协议：
// s2k = PBKDF2-HMAC-SHA256(SHA256(密码))，s2k_fo = PBKDF2-HMAC-SHA256(SHA256(密码) 的小写十六进制串)。
// 期望值由 Python hashlib.pbkdf2_hmac 独立算出（不经被测实现）；负对照：s2k_fo 照上游当 s2k 算，结果必须不同。
use plume_core::auth::account::srp_password_key;

fn hex(b: &[u8]) -> String { b.iter().map(|x| format!("{x:02x}")).collect() }

fn main() {
    let salt1: Vec<u8> = (0u8..16).collect();
    let cases = [
        ("correct horse 密码", &salt1[..], 20000u32, "s2k", "a04c9539ff00b4be6c346486ad7b52b5eedd6fe6c2eb7ac1fa54e2cc6b7e0103"),
        ("correct horse 密码", &salt1[..], 20000, "s2k_fo", "6a071c8883c0ed505e0de18e831a913eb1872a17cbec2f00a85b0321888c6a6a"),
        ("Abc123!@", &[0xaau8; 16][..], 1000, "s2k", "b4fc078be4ef0af5614fab4b3b739a62883a7da5836892ad0fa235a9d00d6ccb"),
        ("Abc123!@", &[0xaau8; 16][..], 1000, "s2k_fo", "cbeb375543436ffc49e73ea0e42d7b5df582d13324c6e95070080f5969b3d6b6"),
    ];
    for (pw, salt, it, sp, want) in cases {
        let got = hex(&srp_password_key(pw, sp, salt, it).expect("known protocol"));
        assert_eq!(got, want, "{sp} {pw}");
    }
    // 负对照：上游对 s2k_fo 账号也按 s2k 算，口令钥匙对不上（Apple 回 -22406）
    assert_ne!(hex(&srp_password_key("Abc123!@", "s2k", &[0xaa; 16], 1000).unwrap()), cases[3].4);
    // 不认识的协议：具名报错，不静默按 s2k 算
    let e = srp_password_key("x", "s2k_new", &[0; 16], 1).unwrap_err().to_string();
    assert!(e.contains("S2A_SRP_PROTOCOL") && e.contains("s2k_new"), "{e}");
    println!("srp_protocol_check: 4 个协议用例 + 负对照 + 未知协议 全过");
}
