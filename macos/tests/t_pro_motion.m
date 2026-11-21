// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Production HID transport + public-API ownership helper, with no hardware access.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GameController.h>
#include <assert.h>
#include <mach/mach_time.h>
#include <string.h>
#include <math.h>
static uint64_t test_us = 1000000;
static unsigned writes, opens;
static unsigned support_queries;
static int output_pid[128], output_dev[128], output_cmd[128], output_arg[128], output_packet[128];
static void (*write_observer)(IOHIDDeviceRef);
static unsigned references[6], retains, releases;
static IOHIDReportCallback callbacks[6]; static void *contexts[6];
static IOHIDDeviceRef dev(int n) { return (IOHIDDeviceRef)(uintptr_t)n; }
static int index_of(IOHIDDeviceRef d) { return (int)(uintptr_t)d; }
static int pid_of(IOHIDDeviceRef d) { return d == dev(3) || d == dev(5) ? 0x2006 : 0x2009; }   // dev(5)：冒用左 Joy-Con 产品号、名字是 Pro Controller 的第三方 Pro（D-52Z8）
static const uint8_t pad_desc[] = {0x05,1,0x09,4,0xa1,1,0x85,0x30,0x75,8,0x95,63,0x81,2,0x85,1,0x91,2,0xc0};
static const uint8_t vendor_desc[] = {0x06,0x7a,0xff,0x09,1,0xa1,1,0x75,8,0x95,64,0x81,2,0x91,2,0xc0};
static CFTypeRef property(IOHIDDeviceRef d, CFStringRef key) {
    if (CFEqual(key, CFSTR(kIOHIDProductIDKey))) return (__bridge CFTypeRef)(pid_of(d) == 0x2006 ? @0x2006 : @0x2009);
    if (CFEqual(key, CFSTR(kIOHIDProductKey))) return d == dev(5) ? CFSTR("Pro Controller") : d == dev(3) ? CFSTR("Joy-Con (L)") : NULL;
    if (CFEqual(key, CFSTR(kIOHIDSerialNumberKey))) return d == dev(3) ? CFSTR("fixture-left") : d == dev(4) ? CFSTR("fixture-unmanaged") : d == dev(5) ? CFSTR("fixture-clone") : CFSTR("fixture-pro");
    if (CFEqual(key, CFSTR(kIOHIDReportDescriptorKey))) {
        static NSData *pad, *vendor;
        if (!pad) { pad = [NSData dataWithBytes:pad_desc length:sizeof pad_desc]; vendor = [NSData dataWithBytes:vendor_desc length:sizeof vendor_desc]; }
        return (__bridge CFTypeRef)(d == dev(2) ? vendor : pad);
    }
    return NULL;
}
static IOReturn open_device(IOHIDDeviceRef d, IOOptionBits options) { opens++; return kIOReturnSuccess; }
static IOReturn close_device(IOHIDDeviceRef d, IOOptionBits options) { return kIOReturnSuccess; }
static void register_input(IOHIDDeviceRef d, uint8_t *p, CFIndex n, IOHIDReportCallback cb, void *context) { callbacks[index_of(d)] = cb; contexts[index_of(d)] = context; }
static IOReturn output(IOHIDDeviceRef d, IOHIDReportType type, CFIndex id, const uint8_t *p, CFIndex n) {
    assert(writes < 128); output_dev[writes] = index_of(d); output_pid[writes] = pid_of(d); output_cmd[writes] = n > 10 ? p[10] : -1; output_arg[writes] = n > 11 ? p[11] : -1; output_packet[writes] = n > 1 ? p[1] : -1; writes++;
    if (write_observer) write_observer(d);
    return kIOReturnSuccess;
}
__attribute__((unused)) static CFTypeRef retain_value(CFTypeRef value) { references[index_of((IOHIDDeviceRef)value)]++; retains++; return value; }
__attribute__((unused)) static void release_value(CFTypeRef value) { unsigned *n=&references[index_of((IOHIDDeviceRef)value)]; assert(*n); (*n)--; releases++; }
static uint64_t clock_ticks(void) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return test_us * 1000 * tb.denom / tb.numer; }
@interface TestGCBackend : NSObject
+ (BOOL)supportsHIDDevice:(IOHIDDeviceRef)device;
@end
@implementation TestGCBackend
+ (BOOL)supportsHIDDevice:(IOHIDDeviceRef)d { support_queries++; return d==dev(1) || d==dev(2); }
@end
#define IOHIDDeviceGetProperty property
#define IOHIDDeviceOpen open_device
#define IOHIDDeviceClose close_device
#define IOHIDDeviceRegisterInputReportCallback register_input
#define IOHIDDeviceSetReport output
#define CFRetain retain_value
#define CFRelease release_value
#define mach_absolute_time clock_ticks
#define GCController TestGCBackend
#include "../joycon_imu.m"
#undef GCController
#undef CFRetain
#undef CFRelease
#include "../motion_power.h"

@interface TestSensor : NSObject
@property BOOL sensorsRequireManualActivation, hasGravityAndUserAcceleration, hasRotationRate;
@property(nonatomic) BOOL sensorsActive;
@property unsigned requests;
@property GCRotationRate rotationRate;
@property GCAcceleration gravity, userAcceleration, acceleration;
@end
@implementation TestSensor
- (void)setSensorsActive:(BOOL)value { _sensorsActive = value; _requests++; }
@end
@interface TestController : NSObject
@property NSString *productCategory;
@property TestSensor *motion;
@end
@implementation TestController
@end
static TestController *controller(BOOL motion) {
    TestController *c = [TestController new]; c.productCategory = @"Switch Pro Controller";
    if (motion) { c.motion = [TestSensor new]; c.motion.sensorsRequireManualActivation = YES; c.motion.hasRotationRate = YES; }
    return c;
}
static GCMotion *selected_sensor;
static void update(NSArray *list, BOOL wanted) {
    TestController *c = list.firstObject;
    s2a_motion_power_select(&selected_sensor, wanted ? (GCMotion *)c.motion : nil, nil);
}
static void feed(IOHIDDeviceRef d) {
    uint8_t b[64] = {0x30}; b[2] = 0x80; b[42] = 0x10; b[44] = 100;
    callbacks[index_of(d)](contexts[index_of(d)], kIOReturnSuccess, d, kIOHIDReportTypeInput, 0x30, b, sizeof b);
}
static unsigned checks, failed;
#define CHECK(c, text) do { checks++; if (!(c)) { failed++; printf("FAIL %s\n", text); } else printf("PASS %s\n", text); } while (0)
static unsigned unlocked_writes, locked_writes, reader_calls, retained_writes;
static int write_hook_mode;
static void inspect_attach_write(IOHIDDeviceRef device) {
    // The fake synchronous transport must be able to acquire the sampling lock.
    // Never block on the broken implementation: report a failure instead.
    if (pthread_mutex_trylock(&g_mu)) { locked_writes++; return; }
    pthread_mutex_unlock(&g_mu); unlocked_writes++;
    s2a_pad_motion l={0},r={0}; uint32_t buttons; int32_t sticks[4]; int side; uint8_t raw[S2A_JC1_RAW];
    s2a_joycon_imu_read(&l,&r); reader_calls++;
    s2a_joycon_imu_read_id("fixture-left",&l); reader_calls++;
    s2a_joycon_pad_read_id("fixture-left",&buttons,sticks,&side,NULL); reader_calls++;
    s2a_joycon_pad_raw_id("fixture-left",raw); reader_calls++;
    if (references[index_of(device)]) retained_writes++;
    int mode=write_hook_mode;
    if (!mode) return;
    write_observer=NULL; write_hook_mode=0;
    if (mode==1 || mode==2) detach_device(device);
    if (mode==2) attach_device(device);   // same pointer / slot, different attachment
    if (mode==3) atomic_store(&g_want,0);
}
int main(void) { @autoreleasepool {
    g_started = 1;   // Never enumerate/open real controllers in this test.
    attach_device(dev(2)); CHECK(opens == 0, "vendor interface lacking Nintendo report IDs is not opened");
    attach_device(dev(1)); s2a_joycon_imu_set_enabled(1);
    CHECK(writes == 0, "framework-recognized Pro is passive even before public-profile discovery");
    unsigned queries_before=support_queries; attach_device(dev(1));
    CHECK(queries_before==1 && support_queries==queries_before,"framework support is cached per attachment, not re-queried by duplicate callbacks");
    TestController *first = controller(YES); update(@[first], YES);
    CHECK(first.motion.sensorsActive && !first.motion.hasGravityAndUserAcceleration && selected_sensor==(GCMotion *)first.motion, "manual activation does not require calibrated gravity support");
    CHECK(writes == 0, "native Pro activation uses no raw IMU/report-mode commands");
    for (int i=0; i<100; i++) update(@[first], YES);
    CHECK(first.motion.requests == 1, "stable demand does not repeatedly request sensor power");
    feed(dev(1)); s2a_pad_motion l = {0}, r = {0}; int mask = s2a_joycon_imu_read(&l, &r);
    s2a_pad_motion by_id={0};
    CHECK(mask == 2 && r.acceleration_z > .99f && r.acceleration_z < 1.01f && s2a_joycon_imu_read_id("fixture-pro",&by_id) && by_id.acceleration_z>.99f, "passive HID still publishes raw samples through both readers when calibrated values are unusable");
    uint8_t old_report[64] = {0x30};
    callbacks[1](contexts[1],kIOReturnSuccess,dev(2),kIOHIDReportTypeInput,0x30,old_report,sizeof old_report);
    callbacks[1](contexts[1],kIOReturnError,dev(1),kIOHIDReportTypeInput,0x30,old_report,sizeof old_report);
    CHECK(s2a_joycon_imu_read(&l,&r)==2 && r.acceleration_z>.99f, "retired-interface or failed callbacks cannot replace the current sample");
    test_us += 250000; CHECK(s2a_joycon_imu_read(&l, &r) == 2, "sample remains valid at 250 ms boundary");
    test_us++; CHECK(s2a_joycon_imu_read(&l, &r) == 0 && !s2a_joycon_imu_read_id("fixture-pro", &r), "stale samples are not advertised as live through either reader");
    detach_device(dev(1)); update(@[], YES); unsigned before = writes;
    CHECK(!first.motion.sensorsActive, "retired public profile is released on disconnect");
    attach_device(dev(1)); CHECK(writes == before, "framework backend remains passive across HID reattach before public-profile discovery");
    TestController *second = controller(YES); update(@[second], YES); feed(dev(1));
    CHECK(second.motion.sensorsActive && s2a_joycon_imu_read(&l,&r) == 2 && writes == before, "reconnect uses new public motion profile and passive raw data");
    attach_device(dev(2)); s2a_joycon_info list[16]; int count = s2a_joycon_list(list,16);
    CHECK(count == 1 && writes == before, "duplicate VID/PID vendor collection cannot enter device IDs or receive configuration");
    s2a_joycon_imu_set_enabled(0); update(@[second], NO);
    CHECK(!second.motion.sensorsActive && writes == before, "native shutdown releases public request without raw disable or mode changes");
    update(@[second],YES); s2a_joycon_imu_set_enabled(1); before = writes;
    TestController *legacy = controller(NO); update(@[legacy],YES);
    CHECK(!second.motion.sensorsActive && writes == before,
          "temporary absence of a selected public profile does not switch the chosen HID backend");
    before = writes; TestController *third = controller(YES); update(@[third],YES);
    CHECK(third.motion.sensorsActive && writes == before, "handoff to native control never sends raw disable after public enable");
    attach_device(dev(4)); CHECK(writes==before+2 && output_dev[before]==4 && output_cmd[before]==0x40 && output_arg[before]==1 && output_cmd[before+1]==3,
          "unmanaged Pro retains raw initialization even while another Pro uses native control");
    before=writes; attach_device(dev(3)); CHECK(writes==before+2 && output_pid[before]==0x2006, "legacy Joy-Con raw initialization remains independent of Pro ownership");
    before = writes; s2a_joycon_imu_set_enabled(0); update(@[third],NO);
    BOOL only_legacy=writes==before+4;
    for (unsigned i=before;i<writes;i++) only_legacy &= output_dev[i]==3 || output_dev[i]==4;
    CHECK(only_legacy && !third.motion.sensorsActive, "shutdown only sends raw control to legacy-owned devices");
    before=writes; s2a_joycon_pad_set_enabled(1);
    BOOL only_legacy_pad=writes==before+2;
    for (unsigned i=before;i<writes;i++) only_legacy_pad &= output_dev[i]==3 || output_dev[i]==4;
    CHECK(only_legacy_pad,"button-only report-mode requests also respect the chosen per-device backend");
    s2a_joycon_pad_set_enabled(0);
    TestController *other = controller(YES); other.productCategory=@"DualSense"; update(@[other],YES);
    CHECK(other.motion.sensorsActive && !third.motion.sensorsActive, "public sensor selection is capability-based, not controller-name based");
    TestController *variant=controller(YES); variant.productCategory=@"Nintendo Switch Pro Controller"; update(@[variant],YES);
    CHECK(variant.motion.sensorsActive && !other.motion.sensorsActive,"changing selected public profile releases only the previous source");
    variant.motion.sensorsActive=NO; unsigned requested=variant.motion.requests;
    update(@[variant],YES);
    CHECK(variant.motion.sensorsActive && variant.motion.requests==requested+1,"same public profile can restore a reset activation request without HID commands");
    GCMotion *shared=nil; requested=variant.motion.requests;
    s2a_motion_power_select(&shared,(GCMotion *)variant.motion,selected_sensor);
    s2a_motion_power_select(&shared,nil,selected_sensor);
    CHECK(variant.motion.sensorsActive && variant.motion.requests==requested,"secondary-slot changes cannot toggle a shared primary sensor request");
    update(@[variant],NO);
    TestController *automatic=controller(YES); automatic.motion.sensorsRequireManualActivation=NO;
    update(@[automatic],YES); update(@[],NO);
    CHECK(automatic.motion.requests==0,"automatically managed profiles never receive forced sensor power settings");
    const uint8_t input_only[]={0x85,0x30,0x81,2}, simple_only[]={0x85,0x3f,0x81,2}, output_only[]={0x85,1,0x91,2};
    CHECK(nintendo_reports(input_only,sizeof input_only)==1 && nintendo_reports(simple_only,sizeof simple_only)==1 && nintendo_reports(output_only,sizeof output_only)==0,
          "read capability accepts full or simple Nintendo input, including input-only interfaces");
    const uint8_t push_pop[]={0x85,0x30,0xa4,0x85,1,0xb4,0x81,2};
    CHECK(nintendo_reports(push_pop,sizeof push_pop)==1,"descriptor global PUSH / POP preserves report identity");
    const uint8_t long_item[]={0xfe,4,1,0x85,0x30,0x81,2};
    CHECK(nintendo_reports(long_item,sizeof long_item)==0,"long-item payload cannot masquerade as Nintendo input items");
    const uint8_t short_item[]={0x85}, bad_pop[]={0xb4}; uint8_t deep[33]; memset(deep,0xa4,sizeof deep);
    CHECK(nintendo_reports(NULL,0)==-1 && nintendo_reports(short_item,sizeof short_item)==-1 && nintendo_reports(bad_pop,sizeof bad_pop)==-1 && nintendo_reports(deep,sizeof deep)==-1,
          "unknown / truncated / excessive descriptor state is not falsely classified unsupported");

    // #1092 review: connection-time synchronous output must not hold the lock
    // used by game-thread motion/button readers, or reuse a retired attachment.
    detach_device(dev(1)); detach_device(dev(3)); detach_device(dev(4));
    atomic_store(&g_want,1); atomic_store(&g_pad_want,0);
    before=writes; write_observer=inspect_attach_write; attach_device(dev(3)); write_observer=NULL;
    CHECK(unlocked_writes==2 && locked_writes==0 && reader_calls==8,
          "attachment output leaves all four production readers outside the transport wait");
    CHECK(retained_writes==2 && retains>0 && retains==releases && !references[3],
          "each unlocked attachment output retains its target only until the write returns");
    CHECK(writes==before+2 && output_cmd[before]==0x40 && output_arg[before]==1 && output_cmd[before+1]==3 && output_arg[before+1]==0x30 &&
          output_packet[before+1]==((output_packet[before]+1)&15),
          "unlocked attachment preserves legacy command bytes and packet sequence");

    detach_device(dev(3)); before=writes; write_hook_mode=1; write_observer=inspect_attach_write;
    attach_device(dev(3)); write_observer=NULL;
    CHECK(writes==before+1 && s2a_joycon_list(list,16)==0 && !references[3],
          "detach during first attachment write cancels the remaining command");

    detach_device(dev(3)); before=writes; write_hook_mode=2; write_observer=inspect_attach_write;
    attach_device(dev(3)); write_observer=NULL;
    CHECK(writes==before+3 && output_cmd[before]==0x40 && output_cmd[before+1]==0x40 && output_cmd[before+2]==3 &&
          (g_dev[0].pkt&15)==((output_packet[before+2]+1)&15) && !references[3],
          "same-device slot reuse cannot consume or send the retired attachment's next command");

    detach_device(dev(3)); before=writes; write_hook_mode=3; write_observer=inspect_attach_write;
    attach_device(dev(3)); write_observer=NULL;
    CHECK(writes==before+1,"motion demand ending during attachment cancels the pending full-report request");

    detach_device(dev(3)); atomic_store(&g_want,0); atomic_store(&g_pad_want,1); before=writes; unlocked_writes=0; locked_writes=0;
    write_hook_mode=0; write_observer=inspect_attach_write; attach_device(dev(3)); write_observer=NULL;
    CHECK(writes==before+1 && output_cmd[before]==3 && output_arg[before]==0x30 && unlocked_writes==1 && !locked_writes,
          "button-only attachment also writes outside the sampling lock");

    detach_device(dev(3)); atomic_store(&g_pad_want,0); atomic_store(&g_want,1); before=writes; attach_device(dev(1));
    CHECK(writes==before && retains==releases && !references[1] && !references[3],
          "attachment snapshots preserve the passive Pro backend and balance all target references");
    detach_device(dev(1)); atomic_store(&g_want,0);
    // 六轴样本：DualSense 只给角速度 + 总加速度（不分离重力）也要出样本，排在 HID 之后（返回 1）；分离了重力的校准样本返回 2
    TestSensor *ds = [TestSensor new]; ds.hasRotationRate = YES;
    ds.acceleration = (GCAcceleration){0, 0, -1}; ds.rotationRate = (GCRotationRate){M_PI, 0, 0};
    s2a_pad_motion sample = {0};
    CHECK(s2a_gc_motion_sample((GCMotion *)ds, &sample) == 1 && sample.acceleration_z == 1.0f && sample.acceleration_x == 0.0f && fabsf(sample.gyro_x - 180.0f) < 1e-3f,
          "rotation plus total acceleration (DualSense) yields an acceleration-only sample");
    TestSensor *cal = [TestSensor new]; cal.hasRotationRate = YES; cal.hasGravityAndUserAcceleration = YES;
    cal.gravity = (GCAcceleration){0, -1, 0}; cal.userAcceleration = (GCAcceleration){0.5, 0, 0}; cal.acceleration = (GCAcceleration){9, 9, 9};
    CHECK(s2a_gc_motion_sample((GCMotion *)cal, &sample) == 2 && sample.acceleration_x == -0.5f && sample.acceleration_y == 1.0f && sample.acceleration_z == 0.0f,
          "separated gravity plus user acceleration wins over total acceleration");
    TestSensor *none = [TestSensor new]; none.hasGravityAndUserAcceleration = YES;
    CHECK(s2a_gc_motion_sample((GCMotion *)none, &sample) == 0 && s2a_gc_motion_sample(nil, &sample) == 0, "no rotation rate, no sample");
    // #1671：服务层只在会话号非 0 时建反馈对象、开六轴；关了震动 / 没有能震的手柄也要非 0，且不是 P1 一代 Joy-Con 的 HID 震动会话（MAC_RUMBLE_BASE | 0xffffffff）
    CHECK(s2a_mac_feedback_session(0) != 0 && s2a_mac_feedback_session(0) != 0x534d0000ffffffffull, "rumble off / no rumble device still gives a motion-only feedback session");
    CHECK(s2a_mac_feedback_session(0x534d000000000003ull) == 0x534d000000000003ull, "a live rumble session passes through unchanged");
    // D-52Z8：冒用左 Joy-Con 产品号（0x2006）的第三方 Pro 按 Pro 认：列表报 0x2009，六轴按 Pro 轴向（加速度 x = -原始 y），不按左只侧握（x = +原始 y）
    atomic_store(&g_want,1); before=writes; attach_device(dev(5));
    { s2a_joycon_info jl[16]; int jn=s2a_joycon_list(jl,16), pro=0; for (int i=0;i<jn;i++) if (!strcmp(jl[i].id,"fixture-clone")) pro=jl[i].pid==0x2009;
      CHECK(pro && writes==before+2 && output_cmd[before]==0x40, "Joy-Con product id with a Pro Controller name is listed as Pro and still gets raw IMU enabled"); }
    { uint8_t b[64]={0x30}; b[39]=0x00; b[40]=0x10;   // 原始加速度 y = 0x1000 计数 = 0.999 g
      callbacks[5](contexts[5],kIOReturnSuccess,dev(5),kIOHIDReportTypeInput,0x30,b,sizeof b);
      s2a_pad_motion c={0}; CHECK(s2a_joycon_imu_read_id("fixture-clone",&c) && c.acceleration_x < -0.99f && c.acceleration_x > -1.01f && c.acceleration_y == 0.0f,
            "clone Pro motion uses Pro axes, not sideways Joy-Con (L) axes"); }
    detach_device(dev(5)); atomic_store(&g_want,0);
    printf("pro_motion: %u checks, %u failures\n",checks,failed); return failed ? 1 : 0;
} }
