// Joy-Con 2（runtime/ns2pro/NS2JoyCon.c）：型号识别、SL / SR、单只横握视角、六轴、震动包、左右拼对。期望按协议文档与映射表手算，未在实机验证。
#include "NS2Transport.h"
#include <stdio.h>
#include <string.h>
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
enum { A, B, X, Y, LS, RS, L, R, ZL, ZR, PLUS, MINUS, LEFT, UP, RIGHT, DOWN, HOME, CAPTURE };
#define BIT(n) (1ull << (n))
int main(void) {
    const uint8_t pro[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x69, 0x20}, jl[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x67, 0x20}, jr[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x66, 0x20};
    const uint8_t other[9] = {0x4c, 0x00, 1, 0, 3, 0x7e, 0x05, 0x69, 0x20};
    CK(ns2_kind_from_manufacturer(pro, 9) == NS2_KIND_PRO && ns2_kind_from_manufacturer(jl, 9) == NS2_KIND_JOYCON_L && ns2_kind_from_manufacturer(jr, 9) == NS2_KIND_JOYCON_R,
       "① 广播产品号：0x2069 Pro、0x2067 左只、0x2066 右只");
    CK(ns2_kind_from_manufacturer(other, 9) == NS2_KIND_NONE && ns2_kind_from_manufacturer(pro, 8) == NS2_KIND_NONE && ns2_kind_from_manufacturer(NULL, 9) == NS2_KIND_NONE,
       "② 公司号不对 / 不够 9 字节 / 空：不认");
    uint8_t rep[64] = {0}; rep[4] = 0x20; rep[6] = 0x10;   // 按键字段第 0 字节 0x20 = 右只 SL，第 2 字节 0x10 = 左只 SR
    CK(ns2_decode_side_buttons(rep, sizeof rep) == (NS2_SIDE_SL_R | NS2_SIDE_SR_L) && ns2_decode_side_buttons(rep, 6) == 0, "③ SL / SR：右只 SL + 左只 SR；太短返回 0");
    ns2_state l = {BIT(UP) | BIT(MINUS) | BIT(CAPTURE) | BIT(L) | BIT(ZL), 100, 200, 7, 8};
    ns2_joycon_sideways(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L, &l);
    CK(l.buttons == (BIT(Y) | BIT(PLUS) | BIT(HOME) | BIT(L)) && l.lx == -200 && l.ly == 100 && l.rx == 0 && l.ry == 0,
       "④ 左只横握：上 → Y、Minus → Plus、Capture → Home、SL → L，原 L / ZL 不出；摇杆 (100,200) → (−200,100)，右摇杆 0（实 %llx %d,%d,%d,%d）", (unsigned long long)l.buttons, l.lx, l.ly, l.rx, l.ry);
    ns2_state r = {BIT(X) | BIT(RS) | BIT(HOME) | BIT(R) | BIT(ZR), 5, 6, 300, -400};
    ns2_joycon_sideways(NS2_KIND_JOYCON_R, NS2_SIDE_SR_R, &r);
    CK(r.buttons == (BIT(A) | BIT(LS) | BIT(HOME) | BIT(R)) && r.lx == -400 && r.ly == -300 && r.rx == 0 && r.ry == 0,
       "⑤ 右只横握：X → A、右摇杆按下 → 左摇杆按下、Home 照旧、SR → R，原 R / ZR 不出；摇杆 (300,−400) → (−400,−300)（实 %llx %d,%d）", (unsigned long long)r.buttons, r.lx, r.ly);
    ns2_state r2 = {BIT(A) | BIT(B) | BIT(Y), 0, 0, 0, 0}; ns2_joycon_sideways(NS2_KIND_JOYCON_R, 0, &r2);
    ns2_state l2 = {BIT(RIGHT) | BIT(DOWN) | BIT(LEFT), 0, 0, 0, 0}; ns2_joycon_sideways(NS2_KIND_JOYCON_L, 0, &l2);
    CK(r2.buttons == (BIT(B) | BIT(Y) | BIT(X)) && l2.buttons == (BIT(X) | BIT(A) | BIT(B)), "⑥ 其余面键：右只 A → B、B → Y、Y → X；左只 右 → X、下 → A、左 → B");
    ns2_state p = {BIT(ZL) | BIT(A), 1, 2, 3, 4}; ns2_joycon_sideways(NS2_KIND_PRO, NS2_SIDE_SL_L, &p);
    CK(p.buttons == (BIT(ZL) | BIT(A)) && p.lx == 1 && p.ry == 4, "⑦ Pro：原样不动");
    ns2_motion ml = {.acceleration_x = 1, .acceleration_z = 2, .gyro_x = 3, .gyro_z = 4}, mr = ml, mp = ml;
    ns2_joycon_sideways_motion(NS2_KIND_JOYCON_L, &ml); ns2_joycon_sideways_motion(NS2_KIND_JOYCON_R, &mr); ns2_joycon_sideways_motion(NS2_KIND_PRO, &mp);
    CK(ml.acceleration_x == 2 && ml.acceleration_z == -1 && ml.gyro_x == 4 && ml.gyro_z == -3 && mr.acceleration_x == -2 && mr.acceleration_z == 1 && mr.gyro_x == -4 && mr.gyro_z == 3 && mp.acceleration_x == 1,
       "⑧ 六轴：左只 (x,z) → (z,−x)、右只 → (−z,x)，Pro 不动");
    ns2_vibration v[2] = {{0.2f, 160, 0.1f, 320}, {0.5f, 160, 0.4f, 320}};
    uint8_t jrp[42], ref[42], prop[42], prop2[42]; ns2_vibration one[2] = {v[1], {0}};
    ns2_encode_rumble_for(NS2_KIND_JOYCON_R, v, 3, 1, jrp); ns2_encode_rumble(one, 3, 1, ref);
    int tail0 = 1; for (int i = 17; i < 42; i++) tail0 &= jrp[i] == 0;
    ns2_encode_rumble_for(NS2_KIND_PRO, v, 3, 1, prop); ns2_encode_rumble(v, 3, 1, prop2);
    CK(!memcmp(jrp, ref, 17) && tail0 && (jrp[1] & 0xf0) == 0x50 && !memcmp(prop, prop2, 42), "⑨ 震动：右只只放一块（取右侧值）、第二块起全 0；Pro 与原编码逐字节相同");
    // 拼对（竖握）：期望按「并集 + 左摇杆取左只 + 右摇杆取右只 + 不转向」手算
    ns2_state pl = {BIT(UP) | BIT(L) | BIT(ZL) | BIT(MINUS) | BIT(LS) | BIT(CAPTURE), 1000, -2000, 5, 6};
    ns2_state pr = {BIT(A) | BIT(R) | BIT(ZR) | BIT(PLUS) | BIT(RS) | BIT(HOME), 7, 8, -3000, 4000}, po;
    ns2_joycon_pair_state(&pl, &pr, &po);
    CK(po.buttons == (BIT(UP) | BIT(L) | BIT(ZL) | BIT(MINUS) | BIT(LS) | BIT(CAPTURE) | BIT(A) | BIT(R) | BIT(ZR) | BIT(PLUS) | BIT(RS) | BIT(HOME)) &&
       po.lx == 1000 && po.ly == -2000 && po.rx == -3000 && po.ry == 4000,
       "⑩ 拼对：按键取并集、上仍是上（不转横握）；左摇杆 (1000,−2000) 取左只、右摇杆 (−3000,4000) 取右只，左只第二字段 / 右只第一字段丢弃（实 %llx %d,%d,%d,%d）",
       (unsigned long long)po.buttons, po.lx, po.ly, po.rx, po.ry);
    ns2_joycon_pair_state(&pl, NULL, &po); ns2_state pn; ns2_joycon_pair_state(NULL, &pr, &pn);
    CK(po.buttons == pl.buttons && po.lx == 1000 && po.ly == -2000 && po.rx == 0 && po.ry == 0 &&
       pn.buttons == pr.buttons && pn.lx == 0 && pn.ly == 0 && pn.rx == -3000 && pn.ry == 4000, "⑪ 拼对一侧为空（还没报告 / 在恢复）：那一侧按全 0 算");
    uint8_t left05[64] = {0}; left05[6] = 0x22;   // 按键字段第 2 字节：0x02 = 上（报告位 17），0x20 = 左只 SL（报告位 21）
    ns2_raw_input raw; ns2_decode_input_report(5, left05, sizeof left05, &raw);
    CK(raw.buttons == BIT(UP) && ns2_decode_side_buttons(left05, sizeof left05) == NS2_SIDE_SL_L,
       "⑫ SL / SR 不进按键位：左只按住上 + SL，按键只有上，SL 只在横握专用的 side 位里（实 %llx）", (unsigned long long)raw.buttons);
    // 扫描策略（11-11 实机：记着左只、左只没开机，右只长按 SYNC 连不上）。期望按「另一侧能不能在直连等待期间被找到」手算：
    //   只剩一只 Joy-Con、还在连（没就绪、没失败）也要扫另一侧；失败了就不扫；Pro / 空不扫另一侧；Joy-Con 失败不停扫描、Pro 失败照旧停
    CK(ns2_scan_wants_other_side(NS2_KIND_JOYCON_L, 0, 0) && ns2_scan_wants_other_side(NS2_KIND_JOYCON_R, 0, 0) && ns2_scan_wants_other_side(NS2_KIND_JOYCON_L, 1, 0),
       "⑬ 只有一只 Joy-Con：还在连（未就绪）也继续扫另一侧，已就绪照旧扫");
    CK(!ns2_scan_wants_other_side(NS2_KIND_JOYCON_L, 0, 1) && !ns2_scan_wants_other_side(NS2_KIND_PRO, 1, 0) && !ns2_scan_wants_other_side(NS2_KIND_NONE, 0, 0),
       "⑭ 那一只已失败 / 是 Pro / 没有型号：不扫另一侧");
    CK(!ns2_link_failure_stops_scan(NS2_KIND_JOYCON_L) && !ns2_link_failure_stops_scan(NS2_KIND_JOYCON_R) && ns2_link_failure_stops_scan(NS2_KIND_PRO),
       "⑮ 链路失败：Joy-Con 不停扫描（另一侧还在窗口里），Pro 照旧停");
    // 对外输出型号（#520）：期望按「两只都在出输入且一左一右才算一对」手算
    CK(ns2_output_kind(NS2_KIND_JOYCON_L, 1, NS2_KIND_JOYCON_R, 1) == NS2_KIND_JOYCON_PAIR && ns2_output_kind(NS2_KIND_JOYCON_R, 1, NS2_KIND_JOYCON_L, 1) == NS2_KIND_JOYCON_PAIR,
       "⑯ 左右都在出输入：一对（槽位顺序无关）");
    CK(ns2_output_kind(NS2_KIND_JOYCON_L, 1, NS2_KIND_JOYCON_R, 0) == NS2_KIND_JOYCON_L && ns2_output_kind(NS2_KIND_JOYCON_L, 0, NS2_KIND_JOYCON_R, 1) == NS2_KIND_JOYCON_R,
       "⑰ 另一只还在连 / 已失败：只报在出输入的那只");
    CK(ns2_output_kind(NS2_KIND_PRO, 1, NS2_KIND_NONE, 0) == NS2_KIND_PRO && ns2_output_kind(NS2_KIND_NONE, 0, NS2_KIND_NONE, 0) == NS2_KIND_NONE &&
       ns2_output_kind(NS2_KIND_JOYCON_L, 1, NS2_KIND_JOYCON_L, 1) == NS2_KIND_JOYCON_L,
       "⑱ Pro 照报 Pro；都没有报 NONE；两只同侧不算一对");
    // 单只原始方向（#520 A）：期望按「照真机，按键 / 摇杆不动、只把这只的 SL / SR 放进扩展位 21 / 22」手算
    ns2_state rr = {BIT(X) | BIT(RS) | BIT(PLUS), 5, 6, 300, -400};
    ns2_joycon_raw(NS2_KIND_JOYCON_R, NS2_SIDE_SL_R | NS2_SIDE_SR_L, &rr);
    CK(rr.buttons == (BIT(X) | BIT(RS) | BIT(PLUS) | BIT(NS2_BUTTON_SL)) && rr.lx == 5 && rr.ly == 6 && rr.rx == 300 && rr.ry == -400,
       "⑲ 右只原始方向：键 / 摇杆原样，只收自己的 SL（左只的 SR 不算）（实 %llx）", (unsigned long long)rr.buttons);
    ns2_state lr = {BIT(UP) | BIT(MINUS), 100, 200, 0, 0};
    ns2_joycon_raw(NS2_KIND_JOYCON_L, NS2_SIDE_SR_L, &lr);
    CK(lr.buttons == (BIT(UP) | BIT(MINUS) | BIT(NS2_BUTTON_SR)) && lr.lx == 100 && lr.ly == 200, "⑳ 左只原始方向：SR → 扩展位 22");
    ns2_state pro2 = {BIT(A), 1, 2, 3, 4}; ns2_joycon_raw(NS2_KIND_PRO, NS2_SIDE_SL_L, &pro2);
    CK(pro2.buttons == BIT(A) && pro2.lx == 1, "㉑ Pro：原始方向不动");
    // 原始方向再转横握 = 直接横握（宿主退回 Pro 时用；同 ④ / ⑤ 的输入）
    ns2_state a1 = {BIT(UP) | BIT(MINUS) | BIT(CAPTURE) | BIT(L) | BIT(ZL), 100, 200, 7, 8}, a2 = a1;
    ns2_joycon_raw(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L, &a1); ns2_joycon_raw_to_sideways(NS2_KIND_JOYCON_L, &a1);
    ns2_joycon_sideways(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L, &a2);
    ns2_state b1 = {BIT(X) | BIT(RS) | BIT(HOME) | BIT(R) | BIT(ZR), 5, 6, 300, -400}, b2 = b1;
    ns2_joycon_raw(NS2_KIND_JOYCON_R, NS2_SIDE_SR_R, &b1); ns2_joycon_raw_to_sideways(NS2_KIND_JOYCON_R, &b1);
    ns2_joycon_sideways(NS2_KIND_JOYCON_R, NS2_SIDE_SR_R, &b2);
    CK(!memcmp(&a1, &a2, sizeof a1) && !memcmp(&b1, &b2, sizeof b1) && a1.buttons == (BIT(Y) | BIT(PLUS) | BIT(HOME) | BIT(L)),
       "㉒ 原始方向再转横握：与传输层直接横握一致（左只 SL → L、右只 SR → R），扩展位不留");
    // 两只拼着时拆成各一位玩家（#520 D）：只有这一只自己的 SL 和 SR 同时按着才拆；
    //   负对照：只按一个、按的是另一只的 SL / SR（位不属于这一只）、Pro / 没型号都不拆
    CK(ns2_joycon_split_wanted(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L | NS2_SIDE_SR_L) && ns2_joycon_split_wanted(NS2_KIND_JOYCON_R, NS2_SIDE_SL_R | NS2_SIDE_SR_R),
       "㉓ 拼着时同按这一只的 SL + SR：拆成各一位玩家");
    CK(!ns2_joycon_split_wanted(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L) && !ns2_joycon_split_wanted(NS2_KIND_JOYCON_L, NS2_SIDE_SL_R | NS2_SIDE_SR_R) &&
       !ns2_joycon_split_wanted(NS2_KIND_JOYCON_R, NS2_SIDE_SR_R) && !ns2_joycon_split_wanted(NS2_KIND_PRO, 15) && !ns2_joycon_split_wanted(NS2_KIND_NONE, 15),
       "㉔ 负对照：只按一个 / 按的不是自己那侧 / Pro / 没型号都不拆");
    // 分配玩家的登记手势（#520 E）：手算真机规则——整只 L + R、单只 SL + SR、左只 L / 右只 R 是「半边」（两只同时各按一边才合成一对）
    CK(ns2_assign_gesture_of(NS2_KIND_PRO, BIT(L) | BIT(R), 0) == NS2_ASSIGN_WHOLE && ns2_assign_gesture_of(NS2_KIND_JOYCON_PAIR, BIT(L) | BIT(R) | BIT(A), 0) == NS2_ASSIGN_WHOLE,
       "㉕ Pro / 一对同按 L + R：整只登记");
    CK(ns2_assign_gesture_of(NS2_KIND_JOYCON_L, 0, NS2_SIDE_SL_L | NS2_SIDE_SR_L) == NS2_ASSIGN_SINGLE &&
       ns2_assign_gesture_of(NS2_KIND_JOYCON_R, BIT(R), NS2_SIDE_SL_R | NS2_SIDE_SR_R) == NS2_ASSIGN_SINGLE,
       "㉖ 单只同按自己的 SL + SR：单只登记（顺带压到 R 也算单只）");
    CK(ns2_assign_gesture_of(NS2_KIND_JOYCON_L, BIT(L), 0) == NS2_ASSIGN_HALF && ns2_assign_gesture_of(NS2_KIND_JOYCON_R, BIT(R), 0) == NS2_ASSIGN_HALF,
       "㉗ 左只按 L / 右只按 R：半边（等另一只配成一对）");
    CK(ns2_assign_gesture_of(NS2_KIND_PRO, BIT(L), 0) == NS2_ASSIGN_NONE && ns2_assign_gesture_of(NS2_KIND_JOYCON_L, BIT(R), 0) == NS2_ASSIGN_NONE &&
       ns2_assign_gesture_of(NS2_KIND_JOYCON_R, BIT(L), NS2_SIDE_SL_L | NS2_SIDE_SR_L) == NS2_ASSIGN_NONE && ns2_assign_gesture_of(NS2_KIND_NONE, ~0ull, 15) == NS2_ASSIGN_NONE,
       "㉘ 负对照：Pro 只按 L / 左只按 R / 右只按左边的 SL + SR / 没型号都不算");
    printf("%s test_joycon：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
