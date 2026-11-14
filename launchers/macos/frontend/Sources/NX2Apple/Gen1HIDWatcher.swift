// S2Arm（不是上游文件）：按设备看一代 Joy-Con（#520 D2）。macOS 把两只一代 Joy-Con 合成一个手柄，GameController 分不出是哪一只、
//   也分不出是第几套，所以这里另开 IOHID（共享打开，不抢 GameController）：
//   · 一直看哪几只连着（设备 id = 序列号即蓝牙地址；宿主 joycon_imu.m s2a_joycon_device_id 同一套），给分配玩家对「谁还在」；
//   · 分配中读每只的输入报告认手势：标准全报告 0x30（左只按键在第 3 字节 SL 0x20 / SR 0x10 / L 0x40，右只在第 1 字节同位）、
//     简单报告 0x3F（第 1 字节 SL 0x10 / SR 0x20，第 2 字节肩键 0x40）。
//   位照公开协议（dekuNukem Nintendo_Switch_Reverse_Engineering；宿主同一份 runtime/src/pad.c s2a_joycon1_decode）。同按那一刻报一次
import Foundation
import IOKit.hid

final class Gen1HIDWatcher {
    private var manager: IOHIDManager?
    private var onGesture: ((String, Int, Int) -> Void)?
    private var onDevices: (([PlayerAssignment.Gen1Device]) -> Void)?
    private var held: [String: Int] = [:]   // 设备 id → 上一笔的手势（只在变成新手势时报）
    private var present: [IOHIDDevice] = []
    private var reading = false

    /// 解析一笔报告的手势（纯函数，单测）：2 = SL + SR 同按、3 = 肩键（左只 L / 右只 R）、0 = 没有
    static func gesture(pid: Int, report: [UInt8]) -> Int {
        guard let first = report.first else { return 0 }
        let off = first == 0x30 || first == 0x3f ? 1 : 0
        let full = off == 1 ? first == 0x30 : report.count >= 48
        var sl = false, sr = false, shoulder = false
        if full {
            guard report.count >= off + 5 else { return 0 }
            let b = report[off + 2 + (pid == 0x2006 ? 2 : 0)]
            sl = b & 0x20 != 0; sr = b & 0x10 != 0; shoulder = b & 0x40 != 0
        } else {
            guard report.count >= off + 2 else { return 0 }
            sl = report[off] & 0x10 != 0; sr = report[off] & 0x20 != 0; shoulder = report[off + 1] & 0x40 != 0
        }
        return sl && sr ? 2 : shoulder ? 3 : 0
    }

    /// 设备 id（纯函数，单测）：序列号优先，没有用 LocationID（loc-十六进制）——宿主 s2a_joycon_device_id 同一套，两边认同一只
    static func deviceID(serial: String?, location: UInt32?) -> String? {
        if let serial, !serial.isEmpty { return serial }
        if let location { return "loc-" + String(location, radix: 16) }
        return nil
    }
    private static func deviceID(_ device: IOHIDDevice) -> String? {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
        return deviceID(serial: serial, location: location)
    }
    private static func side(_ device: IOHIDDevice) -> Int {
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
        return pid == 0x2006 ? 0 : pid == 0x2007 ? 1 : -1
    }

    /// 一直看哪几只连着（启动器开着就开）；连上 / 断开就报一次现在的全部
    func observe(_ handler: @escaping ([PlayerAssignment.Gen1Device]) -> Void) {
        onDevices = handler
        ensureManager()
        publish()
    }
    /// 分配中认手势：(设备 id, 0 左只 / 1 右只, 手势)；nil 停
    func watchGestures(_ handler: ((String, Int, Int) -> Void)?) {
        onGesture = handler; held = [:]
        ensureManager()
        guard let m = manager, (handler != nil) != reading else { return }
        reading = handler != nil
        if reading {
            IOHIDManagerRegisterInputReportCallback(m, { context, _, sender, _, _, report, length in
                guard let context, let sender else { return }
                let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                watcher.handle(device: device, report: Array(UnsafeBufferPointer(start: report, count: length)))
            }, Unmanaged.passUnretained(self).toOpaque())
        } else {
            IOHIDManagerRegisterInputReportCallback(m, nil, nil)
        }
    }

    private func ensureManager() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [0x2006, 0x2007].map { [kIOHIDVendorIDKey: 0x057e, kIOHIDProductIDKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            if !watcher.present.contains(where: { $0 === device }) { watcher.present.append(device); watcher.publish() }
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.present.removeAll { $0 === device }; watcher.publish()
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
    private func publish() {
        onDevices?(present.compactMap { d in
            let side = Self.side(d)
            guard side >= 0, let id = Self.deviceID(d) else { return nil }
            return PlayerAssignment.Gen1Device(id: id, side: side)
        })
    }
    private func handle(device: IOHIDDevice, report: [UInt8]) {
        let side = Self.side(device)
        guard side >= 0, let id = Self.deviceID(device) else { return }
        let g = Self.gesture(pid: side == 0 ? 0x2006 : 0x2007, report: report)
        if g != held[id] { held[id] = g; if g != 0 { onGesture?(id, side, g) } }
    }
    deinit {
        guard let m = manager else { return }
        IOHIDManagerRegisterInputReportCallback(m, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
