// 独立 Switch 2 Pro BLE 传输；只有显式 start 才会扫描或连接。
// Independent Switch 2 Pro BLE transport; only explicit start scans or connects.
#ifndef NS2_TRANSPORT_H
#define NS2_TRANSPORT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; } ns2_state;
typedef struct { uint64_t buttons; uint16_t lx, ly, rx, ry; } ns2_raw_input;
// 纯输入解码：report_id 为 5 或 9，四轴为未校准 12-bit 原始值；BLE 数据不含 report ID 前缀。
// Pure input decoding: report_id is 5 or 9, axes are uncalibrated 12-bit values; BLE data omits the report-ID prefix.
int ns2_decode_input_report(unsigned report_id, const uint8_t *bytes, size_t length, ns2_raw_input *out);
// 型号（广播厂商数据产品号）与 Joy-Con 2 单只横握（NS2JoyCon.c；协议依据见该文件开头，未在我方实机验证）
// 型号；NS2_KIND_JOYCON_PAIR 只用于「对外输出形态」（左右两只拼成一对），广播 / 链路上不会出现
typedef enum { NS2_KIND_NONE, NS2_KIND_PRO, NS2_KIND_JOYCON_L, NS2_KIND_JOYCON_R, NS2_KIND_JOYCON_PAIR } ns2_kind;
enum { NS2_SIDE_SL_L = 1, NS2_SIDE_SR_L = 2, NS2_SIDE_SL_R = 4, NS2_SIDE_SR_R = 8 };
ns2_kind ns2_kind_from_manufacturer(const uint8_t *manufacturer, size_t length);
// report05（不含报告号前缀）里 Joy-Con 的 SL / SR；返回 NS2_SIDE_* 位
int ns2_decode_side_buttons(const uint8_t *bytes, size_t length);
typedef struct { float low_amp, low_freq, high_amp, high_freq; } ns2_vibration;
typedef struct { uint16_t low, high; } ns2_rumble_amplitudes;
typedef struct {
    uint8_t known;
    uint32_t device_timestamp_us, report_counter;
    uint64_t host_timestamp_us;
    float acceleration_x, acceleration_y, acceleration_z;
    float gyro_x, gyro_y, gyro_z;
    float temperature_celsius;
} ns2_motion;
// report05 默认量程：加速度 g、角速度 °/s，轴序保持设备原值；不套用未知的工厂运动校准。
// Report05 default ranges: acceleration in g and angular velocity in degrees/s, preserving device axes without unknown factory motion calibration.
int ns2_decode_report05_motion(const uint8_t *bytes, size_t length, ns2_motion *out);
// 单只 Joy-Con 横握：把已校准的状态 / 六轴换成横握视角（按键随朝向转、SL / SR 当 L / R、唯一的摇杆当左摇杆）；Pro 不动
void ns2_joycon_sideways(ns2_kind kind, int side_buttons, ns2_state *state);
void ns2_joycon_sideways_motion(ns2_kind kind, ns2_motion *motion);
// 单只 Joy-Con 原始方向（#520 A，照真机：游戏收 JoyLeft / JoyRight 就报这个样式，由游戏按 NpadJoyHoldType 自己转）：
//   按键 / 摇杆 / 六轴不动，只把这只的 SL / SR 放进扩展位 NS2_BUTTON_SL / NS2_BUTTON_SR；Pro / 一对不动
enum { NS2_BUTTON_SL = 21, NS2_BUTTON_SR = 22 };
void ns2_joycon_raw(ns2_kind kind, int side_buttons, ns2_state *state);
// 原始方向的状态再换成横握视角（宿主发现游戏不收单只样式、退回 Pro 手柄时用）：取出扩展位的 SL / SR 后同 ns2_joycon_sideways
void ns2_joycon_raw_to_sideways(ns2_kind kind, ns2_state *state);
// 传输层对单只 Joy-Con 出哪种：0 = 横握视角（缺省，同改前；iPhone / iPad 用）、1 = 原始方向（Mac 连接程序开，宿主按游戏样式决定转不转）
void ns2_set_joycon_raw(int raw);
// Joy-Con 2 左右拼成一对（竖握）：输入是两只各自已校准、未转横握的状态；按键取并集，左摇杆取左只、右摇杆取右只，不转向；NULL 当全 0
void ns2_joycon_pair_state(const ns2_state *left, const ns2_state *right, ns2_state *out);
// 两只拼着时要不要拆成各一位玩家（#520 D，纯函数）：这一只（kind 左 / 右）同时按着自己的 SL 和 SR（side_buttons 同 ns2_decode_side_buttons）
int ns2_joycon_split_wanted(ns2_kind kind, int side_buttons);
// 分配玩家的登记手势（#520 E，同原机「更改握法 / 顺序」；纯函数）：buttons 是这一条链路已校准、未转向的状态（单只 Joy-Con 照原始方向），
//   side_buttons 同 ns2_decode_side_buttons。整只（Pro / 已拼成的一对）同按 L + R → WHOLE；单只 Joy-Con 同按自己的 SL + SR → SINGLE；
//   左只按 L / 右只按 R → HALF（两只同时各按一边 = 合成一对，由调用方配）。都没有 → NONE
typedef enum { NS2_ASSIGN_NONE, NS2_ASSIGN_WHOLE, NS2_ASSIGN_SINGLE, NS2_ASSIGN_HALF } ns2_assign_gesture;
ns2_assign_gesture ns2_assign_gesture_of(ns2_kind kind, uint64_t buttons, int side_buttons);
// 扫描策略（纯函数，NS2Transport.m 的 NS2Bridge 调）：
//   只有一条链路时还要不要扫另一侧——那一只是 Joy-Con 且没失败就要（还在连也算：重连记住的那只时它可能没开机，直连要等 30 秒超时）
int ns2_scan_wants_other_side(ns2_kind only, int only_ready, int only_failed);
//   一条链路失败时停不停扫描——Pro 停（同改前）；Joy-Con 不停，另一侧可能正在扫描窗口里等着被找到
int ns2_link_failure_stops_scan(ns2_kind failed);
// 对外输出形态（纯函数）：两条链路都在出输入且一左一右 → 一对；否则取在出输入的那条的型号；都没有 → NONE。
//   与 NS2Transport.m 的 pair_locked / 单只横握判断同一条规则，宿主据此显示型号、选手柄样式（#520）
ns2_kind ns2_output_kind(ns2_kind a, int a_present, ns2_kind b, int b_present);
// 连上就别自己断（NS2Keep.c）：没有应答也能往下走的握手步骤、校准缺省值、输入长度、应答匹配、震动能不能写、保活节奏
enum { NS2_CAL_DEFAULT_CENTER = 2048, NS2_CAL_DEFAULT_TRAVEL = 1200, NS2_INPUT_MIN = 63, NS2_INPUT_MAX = 80 };
#define NS2_KEEPALIVE_NS (3ull * 1000000000ull)
// 握手第 step 步没有应答时是否只能断开：只有功能位设定 / 开启（第 4、6 步）；其余步骤跳过、记日志
int ns2_step_required(unsigned step);
int ns2_calibration_valid(const unsigned center[2], const unsigned above[2], const unsigned below[2]);
void ns2_calibration_default(unsigned center[2], unsigned above[2], unsigned below[2]);
// 输入通知（report05 / report09）的合理长度；更长的是同一特征上的音频包，更短的解不出来，都跳过不断开
int ns2_input_length_ok(size_t length);
// 应答属于这条指令：指令号与子指令号相同。ns2_ack_usual：方向 / 传输 / 第 5 字节是常见值（不是也照收，只记日志）
int ns2_ack_matches(const uint8_t *reply, size_t length, const uint8_t *request, size_t request_length);
int ns2_ack_usual(const uint8_t *reply, size_t length);
// 震动特征在、单次写入放得下 42 字节的震动包才写震动；否则这只手柄不震，输入照常
int ns2_rumble_writable(int has_characteristic, size_t max_write);
// 上次写入之后过了 NS2_KEEPALIVE_NS：写一次玩家灯，免得主机长时间不写入时手柄自己断开
int ns2_keepalive_due(uint64_t last_write_ns, uint64_t now_ns);
// 当前对外输出形态（线程安全，读传输层两条链路的现状）
ns2_kind ns2_get_output_kind(void);
// 主机绑定（「记住这台设备」，NS2Bond.c；协议依据见该文件开头）：
//   广播里手柄要唤醒的主机：PAIRING = 长按 SYNC 的配对广播（主机全 0）、US = 唤醒 our_host、OTHER = 唤醒别的主机、UNKNOWN = 厂商数据不够 18 字节或不是认得出的手柄型号
typedef enum { NS2_WAKE_UNKNOWN, NS2_WAKE_PAIRING, NS2_WAKE_US, NS2_WAKE_OTHER } ns2_wake;
ns2_wake ns2_advert_wake(const uint8_t *manufacturer, size_t length, const uint8_t *our_host);
enum { NS2_BOND_STEPS = 4, NS2_BOND_COMMAND_MAX = 25 };
//   第 step（0..3）条绑定指令：01 主机地址、04 钥匙一、02 钥匙二、03 结束；返回帧长，参数不对返回 0
size_t ns2_bond_command(unsigned step, const uint8_t host[6], const uint8_t key1[16], const uint8_t key2[16], uint8_t out[NS2_BOND_COMMAND_MAX]);
//   是不是绑定指令（0x15）的应答
int ns2_bond_reply(const uint8_t *reply, size_t length);
//   "aa:bb:cc:dd:ee:ff" / "aa-bb-…" → 小端 6 字节；格式不对或全 0 返回 0
int ns2_parse_bt_address(const char *text, uint8_t le[6]);
// 断线后接回（NS2Bond.c）：用着（握手完成、没失败）的手柄断开就重新挂上不设期限的直连，绑定与否都挂；
//   挂着等（waits_for_wake 且还没握手、系统没连上）的链路不占位：照样能扫描、能接别的手柄
int ns2_rearm_after_disconnect(int stream_ready, int session_failed);
int ns2_link_idle(int waits_for_wake, int stream_ready, int connected);
// 开启绑定：start 之前调；host 是本机蓝牙地址（小端），NULL 关闭。开启后：
//   - 配对广播（长按 SYNC）连上的手柄，握手后写入绑定（失败只记日志，连接照常可用）；
//   - 绑定过的手柄直连不设期限、断开后自动重新等待，玩家按任一键即可连上。
void ns2_set_bond_host(const uint8_t *host);
// 复制最近运动样本，超过 250 ms 或断开后清空；不产生设备访问。
// Copy the latest motion sample, clearing it after 250 ms or disconnection without accessing hardware.
void ns2_get_motion(ns2_motion *out);
// Joy-Con 2 左右拼成一对时左只的六轴（ns2_get_motion 给的是右只的）；不在拼对 / 没开 / 过期时全 0
void ns2_get_motion_left(ns2_motion *out);
// Joy-Con 2 光学鼠标（report05 0x10–0x17，功能位 0x10）：x / y 是绝对坐标（16 位、会回绕，用的一方自己求差），
//   surface 未知含义（研究资料写「表面质量？」），distance = 离开桌面的距离（0x17 一个字节，0 = 贴在桌面上）。kind 是读数来自哪一只（左 / 右）
typedef struct {
    uint8_t known;
    ns2_kind kind;
    int16_t x, y;
    uint16_t surface, distance;
    uint64_t host_timestamp_us;
} ns2_mouse;
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md#input-report-0x05
int ns2_decode_report05_mouse(const uint8_t *bytes, size_t length, ns2_mouse *out);
// 指定一侧（0 左、1 右，拼成一对时两只各一份）最近一笔 Joy-Con 2 鼠标读数；Pro / 断开 / 那一侧没有 / 超过 250 毫秒没更新 → 全 0
void ns2_get_mouse_side(int side, ns2_mouse *out);
typedef struct {
    uint8_t connected, ready;
    uint8_t battery_known;
    uint16_t battery_millivolts;
    uint8_t charging_raw_known, charging_raw;
    uint8_t charging_known, charging;
    uint8_t battery_level_known, battery_level;
    uint8_t external_power_known, external_power;
    uint8_t rssi_known;
    int32_t rssi_dbm;
    char name[128];
    char identifier[64];
    char telemetry_error[160];
    uint8_t nfc_state_known, nfc_state;
    uint8_t headset_state_known, headset_state;
    uint8_t headset_connected_known, headset_connected;
    uint8_t headset_microphone_known, headset_microphone;
} ns2_info;
// 轮询仅复制最后收到的数据，不触发扫描、连接或 RSSI 请求；RSSI 来自发现广播。
// Polling only copies the latest received data without scanning, connecting or requesting RSSI; RSSI comes from discovery advertisements.
void ns2_get_info(ns2_info *out);
// report05 为毫伏与原始充电字节；report09 为固件上报等级 0..9、充电及外接电源标志，均不是精确百分比。
// Report05 provides millivolts and a raw charge byte; report09 provides firmware levels 0..9, charging and external-power flags, never exact percentages.
// 纯解码只更新各自字段，保留另一种 report 的数据；无效输入返回 0 并清除本 report 的有效标志和值。
// Pure decoders update only their own fields and preserve the other report's data; invalid input returns 0 and clears this report's flags and values.
int ns2_decode_report05_telemetry(const uint8_t *bytes, size_t length, ns2_info *out);
int ns2_decode_report09_telemetry(const uint8_t *bytes, size_t length, ns2_info *out);
// 只读取 NFC 处理器和耳机插入状态；不代表读卡、音频播放或麦克风传输已启用。
// Read NFC processor and headset insertion state only, without implying tag reading, playback or microphone transport.
int ns2_decode_report05_accessories(const uint8_t *bytes, size_t length, ns2_info *out);
int ns2_decode_report09_accessories(const uint8_t *bytes, size_t length, ns2_info *out);
typedef enum {
    NS2_STATUS_IDLE, NS2_STATUS_SCANNING, NS2_STATUS_CONNECTING,
    NS2_STATUS_INITIALIZING, NS2_STATUS_READY, NS2_STATUS_DISCONNECTED,
    NS2_STATUS_UNAVAILABLE, NS2_STATUS_ERROR, NS2_STATUS_STOPPED,
    NS2_STATUS_SCAN_FINISHED, NS2_STATUS_SUSPENDING, NS2_STATUS_PAUSED,
    NS2_STATUS_RESUMING
} ns2_status;
enum { NS2_CAP_LEFT = 1, NS2_CAP_RIGHT = 2, NS2_STICK_MAX = 32767 };
// Nintendo 位序：A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down；Y 向上为正。
// Nintendo bit order: A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down; positive Y is up.
// 扩展位16..20：Home Capture C GL GR；标准 Xbox 输出仅映射前两项。
// Extended bits16..20: Home Capture C GL GR; standard Xbox output maps only the first two.
// 回调在串行 BLE 队列调用；指针仅本次有效。context 必须存活到 shutdown 返回。
// Callbacks run on the serial BLE queue; pointers are valid only during the call. Keep context alive until shutdown returns.
typedef void (*ns2_state_callback)(const ns2_state *state, void *context);
// 两只 Joy-Con 各一位玩家（#520 D）：玩家 2 起的按键 / 摇杆走这个回调（player 从 0 起，现在只有 1；kind 是那只的型号；
//   state 为 NULL = 这位玩家不在了）。玩家 1 照旧走 ns2_state_callback。不设就不出玩家 2
typedef void (*ns2_player_state_callback)(int player, ns2_kind kind, const ns2_state *state, void *context);
void ns2_set_player_callback(ns2_player_state_callback callback);
// 两只 Joy-Con 怎么用的面板设定：0 = 拼成一对、1 位玩家（缺省）；1 = 各一位玩家。拼着时同按一只的 SL + SR 也会拆开，一对拆散后回到这个设定
void ns2_set_joycon_split(int split);
int ns2_get_joycon_split(void);   // 现在是不是两只各一位玩家
// 分配玩家（#520 E）：开着时每条链路的登记手势一变就回调（link 是链路槽 0 / 1、identifier 是 CoreBluetooth 设备 id），
//   拼着时 SL + SR 不再自动拆（完成时调用方照分配 ns2_set_joycon_split / ns2_set_player_order / ns2_disconnect_device）
typedef void (*ns2_assign_callback)(int link, ns2_kind kind, ns2_assign_gesture gesture, const char *identifier, void *context);
void ns2_set_assign_callback(ns2_assign_callback callback);
void ns2_set_assign_mode(int on);
void ns2_set_player_order(int first_link);   // 两只拆开时哪条链路是玩家 1（缺省 0）
typedef struct { int link; ns2_kind kind; char identifier[64]; } ns2_device;
int ns2_get_devices(ns2_device out[2]);   // 已就绪的链路（最多 2），返回几条
int ns2_disconnect_device(const char *identifier);   // 断开这一只（分配时没登记的，同原机）；找到返回 1
// 可选的「收不收这台」（#520 E 最多 4 只：Mac 上第二个连接程序管第二组，两边别抢同一台）：扫到 NS2 手柄时问一次，回 0 就不连。
//   不设（iOS / 只有一个连接程序时）= 同改前
typedef int (*ns2_accept_filter)(ns2_kind kind, const char *identifier, void *context);
void ns2_set_accept_filter(ns2_accept_filter filter);
// 两只 Joy-Con 拆开时玩家 2 那只的六轴（原始方向；#520 每位玩家都有体感）；没拆 / 没开 / 太旧全 0
void ns2_get_partner_motion(ns2_motion *out);
typedef void (*ns2_status_callback)(ns2_status status, const char *message, void *context);
typedef void (*ns2_motion_callback)(const ns2_motion *motion, void *context);

// 成功返回 1；重复启动或非法 NS2PRO_RUMBLE_GAIN 返回 0，尚未代表连接成功。
// Returns 1 on accepted start; duplicate start or invalid NS2PRO_RUMBLE_GAIN returns 0, without implying a connection.
// 优先有界直连上次 READY 的系统外设标识；无可取回外设时开启十秒扫描。
// Prefer a bounded direct connection to the last READY system peripheral identifier; scan for ten seconds if none can be retrieved.
int ns2_start(ns2_state_callback state, ns2_status_callback status, void *context);
// 显式开启新的十秒前台扫描窗口；已连接、正在连接或尚未 start 时返回 0。断线后不自动重扫。
// Explicitly open a new ten-second foreground scan window; return 0 while connected, connecting or not started. Never rescan automatically after disconnection.
int ns2_rescan(void);
// 仅保留已初始化且仍物理连接的链路，1表示异步请求已接受，非完成或后台保链保证；其余返回0。
// Retain only an initialized, physically connected link; 1 means asynchronously accepted, not completion or guaranteed background retention.
// suspend立即清空逻辑输入/运动/震动；PAUSED表示零包提交、IMU关闭ACK及power退订完成，保留report05但不发布。
// suspend immediately invalidates logical input/motion/rumble; PAUSED follows zero submission, IMU-off ACK and power unsubscription, retaining report05 without publishing.
int ns2_suspend(void);
// resume保留原callback/context和input订阅；丢弃首个候选，后续report05计数前进才READY，超时或订阅失效显式ERROR。
// resume retains callbacks/context and input subscription; discard the first candidate and require an advancing report05 counter before READY, or ERROR on timeout/inactive subscription.
int ns2_resume(void);
// 非空 motion 回调启用 IMU 并独占 report05；report09 的压缩运动格式尚未实现，因此不订阅它。
// A non-null motion callback enables IMU and uses report05 exclusively; report09's packed motion format is not implemented and is not subscribed.
int ns2_start_with_motion(ns2_state_callback state, ns2_status_callback status, ns2_motion_callback motion, void *context);
// 在运动会话中按需开关 IMU，不重连、不订阅 report09；关闭立即清空样本，开启需等待 ACK 与新通知。
// Toggle IMU within a motion session without reconnecting or subscribing to report09; disable clears samples immediately.
void ns2_set_motion_enabled(int enabled);
void ns2_set_active(int active);
unsigned ns2_caps(void);
unsigned ns2_device_caps(void);
// side 为 0 左、1 右；幅度 0..1，频率 Hz，有限正载频限于 40..1252 Hz。
// side is 0 left or 1 right; amplitudes are 0..1, frequencies in Hz, with finite positive carriers clamped to 40..1252 Hz.
void ns2_send(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq);
// BLE 队列独立执行有效期；0停止，最大1000ms。普通 send 使用1000ms。
// The BLE queue independently enforces expiry; 0 stops, maximum1000ms. Plain send uses1000ms.
void ns2_send_lease(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq, unsigned duration_ms);
// 一次原子更新两侧并共用租约截止时间；0停止，最大1000ms，NULL不操作。每侧独立校验，非法值只停止该侧。
// Atomically update both sides with a shared expiry; 0 stops, maximum1000ms, NULL does nothing. Invalid values stop only that side.
// 静音转有效可写即发，持续活动15ms发送；停止优先，背压仅保留最新值，不保证每个游戏阶段均提交。
// Send silent-to-active onsets when writable and sustained activity on a 15 ms cadence; stops take priority and backpressure keeps only latest values, without guaranteeing every game phase is submitted.
void ns2_send_pair_lease(const ns2_vibration values[2], unsigned duration_ms);
void ns2_actual(unsigned side, ns2_vibration *out);
// 立即清空两侧 mailbox；仅已提交有效幅码的侧安排一次停止，不撤销连接。
// Clear both mailboxes immediately; stop previously submitted active sides once without disconnecting.
void ns2_stop_rumble(void);
// 返回 1 仅表示无连接或零包已交给 CoreBluetooth，不是电机确认。允许之后重新 start。
// Returns 1 only for no connection or a zero packet submitted to CoreBluetooth, never motor acknowledgement. A later start is allowed.
int ns2_shutdown(const char *reason, unsigned timeout_ms);
// 纯编码函数，不连接设备；完整 42-byte 双侧 report。
// Pure codec without device access; produces a complete 42-byte report for both sides.
void ns2_encode_rumble(const ns2_vibration values[2], uint8_t sequence, float gain, uint8_t out[42]);
// 按型号编码：Pro 同 ns2_encode_rumble；Joy-Con 2 只放一块（这只那一侧的值），第二块全 0（NS2JoyCon.c）
void ns2_encode_rumble_for(ns2_kind kind, const ns2_vibration values[2], uint8_t sequence, float gain, uint8_t out[42]);
// 返回编码器实际使用的幅码，包含增益校验、量化和载频有效性；两码全零即静音。
// Return the codec's amplitude codes after gain validation, quantization and carrier validation; both zero means silent.
ns2_rumble_amplitudes ns2_rumble_amplitude_codes(ns2_vibration value, float gain);

#ifdef __cplusplus
}
#endif
#endif
