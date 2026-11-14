// S2Arm（不是上游文件）：分配玩家（#520 E，同原机「更改握法 / 顺序」）。纯逻辑，单测：
//   NS2 手柄的手势由连接程序报（NS2Transport.h ns2_assign_gesture：1 整只 L + R、2 单只 SL + SR、3 半边 L / R），系统手柄 L1 + R1 由启动器自己读；
//   登记的顺序就是 P1、P2…（最多 8 位）。完成时给连接程序一份计划（拼 / 拆、谁是玩家 1、留下哪些），给游戏一份顺序表（pad-order.json）
import Foundation

struct PlayerAssignment: Equatable, Codable {
    /// 系统手柄的身份：名字 + 同名第几只（跨进程认同一只；宿主 front_mac.m 同一套）
    struct SystemKey: Codable, Hashable { let name: String; let index: Int }
    /// 连着的 NS2 手柄（连接程序 devices：id + 型号 1 Pro / 2 左 / 3 右）
    /// player = 通道玩家号（游戏认的那个）；group = 哪个连接程序管（0 第一个、1 第二个，最多 4 只时，#520）
    struct Device: Equatable {
        let id: String, kind: Int, player: Int, group: Int
        init(id: String, kind: Int, player: Int = 0, group: Int = 0) { self.id = id; self.kind = kind; self.player = player; self.group = group }
    }
    enum Unit: Equatable, Codable {
        case pair(left: String, right: String)   // 两只 Joy-Con 2 合成一对
        case single(id: String, kind: Int)       // 单只 Joy-Con 2（横握）
        case whole(id: String, kind: Int)        // NS2 Pro
        case system(name: String, index: Int)    // 系统手柄：名字 + 同名第几只（跨进程认同一只）
        case keyboard                            // 键盘（含鼠标）：分配时按任一键登记；没登记时照旧并进 P1
        case gen1(id: String, side: Int)         // 一代 Joy-Con 单只（D2：按设备 id 认，0 左只、1 右只；系统合成的那个不再占位）
        case gen1Pair(left: String, right: String)   // 一代 Joy-Con 按设备读的一对（D2：多套一代时每对一位，竖握）
    }
    /// 连着的一代 Joy-Con（启动器 Gen1HIDWatcher 按设备看）：id = 序列号（蓝牙地址），side 0 左只 / 1 右只
    struct Gen1Device: Equatable, Hashable { let id: String; let side: Int }
    static let maxPlayers = 8   // 同原机最多 8 位玩家
    static let pairWindow: TimeInterval = 0.5   // 两只各按 L / R 算「同时」的间隔

    private(set) var units: [Unit] = []
    /// 分配完成时在线却没登记的手柄：保持连接、只是没有玩家位（下次分配直接按键加入，不用重连）；
    ///   它断开再连上时拿掉，照常自动排进来。系统手柄按名字 + 第几只、NS2 手柄按设备 id
    private(set) var dropped: [SystemKey] = []
    private(set) var droppedDevices: [String] = []
    private(set) var droppedGen1: [String] = []   // 按设备读一代时 × 掉的那几只（设备 id）：连着、没有玩家位
    /// 拆开过的系统合成一代 Joy-Con（GameController 那一位）：连着、不再占位（顺序表列进 dropped，宿主不读它），两只改按设备读
    private(set) var splitCombined: [SystemKey] = []
    /// 系统合成的那一位里是哪几只（设备 id；分配中按 L + R 登记它的那一刻，HID 看到的左只 L、右只 R 就是它）。同名第几只重连会变，不存偏好
    private(set) var combinedHalves: [SystemKey: [String]] = [:]
    private var recentShoulder: [(id: String, side: Int, at: TimeInterval)] = []
    private var recentCombined: (key: SystemKey, at: TimeInterval)?
    /// 第几次「分配玩家」完成：只有它变了游戏才整个重排；新手柄自动排进来不改它，已在玩的人留在原位、新来的接在后面（第二只 PS5 接上把原来那只挤到 P3）
    private(set) var generation = 0
    private var pendingHalf: (id: String, kind: Int, at: TimeInterval)?

    enum CodingKeys: String, CodingKey { case units, dropped, droppedDevices, droppedGen1, splitCombined, generation }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        units = try c.decodeIfPresent([Unit].self, forKey: .units) ?? []
        dropped = try c.decodeIfPresent([SystemKey].self, forKey: .dropped) ?? []
        droppedDevices = try c.decodeIfPresent([String].self, forKey: .droppedDevices) ?? []
        droppedGen1 = try c.decodeIfPresent([String].self, forKey: .droppedGen1) ?? []
        splitCombined = try c.decodeIfPresent([SystemKey].self, forKey: .splitCombined) ?? []
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
    }
    static func == (a: PlayerAssignment, b: PlayerAssignment) -> Bool {
        a.units == b.units && a.dropped == b.dropped && a.droppedDevices == b.droppedDevices && a.droppedGen1 == b.droppedGen1 && a.splitCombined == b.splitCombined && a.generation == b.generation
    }

    /// 两只 Joy-Con 要不要拆开：没登记成一对、又连着两只 Joy-Con（各一位，或一只没分配）
    func wantsSplit(devices: [Device]) -> Bool {
        let joycons = devices.filter { $0.kind == 2 || $0.kind == 3 }
        let ids = Set(joycons.map(\.id))
        return joycons.count >= 2 && !units.contains { if case let .pair(l, r) = $0 { return ids.contains(l) || ids.contains(r) }; return false }
    }

    /// 照现在连着的手柄整理（#520 E，#520 讨论「接入手柄后要自动分配」）：断开的拿掉（一对少了一只就剩单只）；
    ///   新连上的排到后面——一对 Joy-Con 缺省一位（mergedPair）、单只登记过的那只配上另一只也并成一对；系统手柄没被 dropped 的照排。
    ///   返回有没有变
    @discardableResult
    mutating func reconcile(devices: [Device], mergedPair: Bool, system: [SystemKey], gen1: [Gen1Device] = []) -> Bool {
        reconcile(devices: devices, mergedGroups: mergedPair ? Set(devices.map(\.group)) : [], system: system, gen1: gen1)
    }
    /// mergedGroups：哪几组现在是「两只拼成一位」（传输层缺省）；新连上的左 + 右只在同一组里才配成一对
    @discardableResult
    /// gen1：按设备看到的一代 Joy-Con（多套各认各的）
    mutating func reconcile(devices: [Device], mergedGroups: Set<Int>, system: [SystemKey], gen1: [Gen1Device] = []) -> Bool {
        let before = self
        let ids = Set(devices.map(\.id)), keys = Set(system), g1 = Set(gen1.map(\.id))
        units = units.compactMap { unit in
            switch unit {
            case let .pair(l, r):
                if ids.contains(l) && ids.contains(r) { return unit }
                if ids.contains(l) { return .single(id: l, kind: 2) }
                if ids.contains(r) { return .single(id: r, kind: 3) }
                return nil
            case let .single(id, _), let .whole(id, _): return ids.contains(id) ? unit : nil
            case let .system(name, index): return keys.contains(SystemKey(name: name, index: index)) ? unit : nil
            case .keyboard: return unit   // 键盘一直在
            case let .gen1(id, _): return g1.contains(id) ? unit : nil
            case let .gen1Pair(l, r):   // 一对少了一只就剩单只（同 Joy-Con 2）
                if g1.contains(l) && g1.contains(r) { return unit }
                if g1.contains(l) { return .gen1(id: l, side: 0) }
                if g1.contains(r) { return .gen1(id: r, side: 1) }
                return nil
            }
        }
        droppedGen1.removeAll { !g1.contains($0) }
        splitCombined.removeAll { !keys.contains($0) }   // 合成的那一位断开 / 系统拆了：下次连上照常排
        combinedHalves = combinedHalves.filter { keys.contains($0.key) }
        dropped.removeAll { !keys.contains($0) }
        droppedDevices.removeAll { !ids.contains($0) }
        var fresh = devices.filter { !registeredIDs.contains($0.id) && !droppedDevices.contains($0.id) }
        for group in mergedGroups.sorted() {
            let inGroup = devices.filter { $0.group == group }
            // 一对连着、合成一位：登记过单只的那只配上同组新来的另一只，原位并成一对
            if let other = fresh.first(where: { $0.group == group && ($0.kind == 2 || $0.kind == 3) }),
               let at = units.firstIndex(where: { if case let .single(id, k) = $0 { return k != other.kind && (k == 2 || k == 3) && inGroup.contains { $0.id == id } }; return false }),
               case let .single(id, _) = units[at] {
                units[at] = other.kind == 2 ? .pair(left: other.id, right: id) : .pair(left: id, right: other.id)
                fresh.removeAll { $0.id == other.id }
            }
            if let l = fresh.first(where: { $0.group == group && $0.kind == 2 }), let r = fresh.first(where: { $0.group == group && $0.kind == 3 }) {
                append(.pair(left: l.id, right: r.id)); fresh.removeAll { $0.id == l.id || $0.id == r.id }
            }
        }
        for d in fresh { append(d.kind == 1 ? .whole(id: d.id, kind: 1) : .single(id: d.id, kind: d.kind)) }
        for key in system where !dropped.contains(key) && !splitCombined.contains(key) && !units.contains(.system(name: key.name, index: key.index)) {
            append(.system(name: key.name, index: key.index))
        }
        return self != before
    }
    /// 清掉一位（玩家列表的 ×，#520 讨论）：分配中只是空出这一位；平时还要记成 dropped——手柄保持连接、没有玩家位、不再自动排回来（下次分配按键加入）
    mutating func remove(at index: Int, keepConnectedWithoutSlot: Bool) {
        guard units.indices.contains(index) else { return }
        let unit = units.remove(at: index)
        guard keepConnectedWithoutSlot else { return }
        switch unit {
        case let .pair(l, r): droppedDevices += [l, r]
        case let .single(id, _), let .whole(id, _): droppedDevices.append(id)
        case let .system(name, index): dropped.append(SystemKey(name: name, index: index))
        case .keyboard: break   // 键盘 × 掉就回到并进 P1
        case let .gen1(id, _): droppedGen1.append(id)
        case let .gen1Pair(l, r): droppedGen1 += [l, r]
        }
    }
    /// 分配中按键登记：之前 × 掉 / 没分配的那只重新登记，就不再算 dropped
    private mutating func undrop(_ unit: Unit) {
        switch unit {
        case let .pair(l, r): droppedDevices.removeAll { $0 == l || $0 == r }
        case let .single(id, _), let .whole(id, _): droppedDevices.removeAll { $0 == id }
        case let .system(name, index): dropped.removeAll { $0 == SystemKey(name: name, index: index) }
        case .keyboard: break
        case let .gen1(id, _): droppedGen1.removeAll { $0 == id }
        case let .gen1Pair(l, r): droppedGen1.removeAll { $0 == l || $0 == r }
        }
    }
    private mutating func register(_ unit: Unit) { undrop(unit); units.append(unit) }
    private mutating func append(_ unit: Unit) { if units.count < Self.maxPlayers { units.append(unit) } }

    /// 分配完成：在线却没登记的记成 dropped（保持连接、没有玩家位）
    mutating func finish(presentSystem: [SystemKey], devices: [Device], gen1: [Gen1Device] = []) {
        generation += 1
        dropped = presentSystem.filter { !units.contains(.system(name: $0.name, index: $0.index)) }   // 含拆开过的合成一对
        droppedDevices = devices.map(\.id).filter { !registeredIDs.contains($0) }
        droppedGen1.removeAll { id in !gen1.contains { $0.id == id } }
    }

    var registeredIDs: Set<String> {
        Set(units.flatMap { unit -> [String] in
            switch unit {
            case let .pair(l, r): return [l, r]
            case let .single(id, _), let .whole(id, _): return [id]
            case .system, .keyboard, .gen1, .gen1Pair: return []
            }
        })
    }
    /// 登记了的一代 Joy-Con（设备 id）
    var registeredGen1: Set<String> {
        Set(units.flatMap { unit -> [String] in
            switch unit {
            case let .gen1(id, _): return [id]
            case let .gen1Pair(l, r): return [l, r]
            default: return []
            }
        })
    }


    /// NS2 手柄的一次手势（连接程序 assign 行）
    mutating func ns2(id: String, kind: Int, gesture: Int, at time: TimeInterval) {
        guard !id.isEmpty else { return }
        if registeredIDs.contains(id) { regroup(id: id, kind: kind, gesture: gesture, at: time); return }
        guard units.count < Self.maxPlayers else { return }
        switch gesture {
        case 1: register(.whole(id: id, kind: kind))
        case 2: register(.single(id: id, kind: kind))
        case 3:
            if let half = pendingHalf, half.id != id, half.kind != kind, time - half.at <= Self.pairWindow, !registeredIDs.contains(half.id) {
                let (left, right) = kind == 2 ? (id, half.id) : (half.id, id)
                register(.pair(left: left, right: right))
                pendingHalf = nil
            } else {
                pendingHalf = (id, kind, time)
            }
        default: break
        }
    }

    /// 已经有玩家位的 Joy-Con 2 再按（#520 讨论：不用先 ×）：一对里的一只同按 SL + SR → 拆开，这只留原位、另一只排在它后面；
    ///   两位单只左只按 L、右只按 R（0.5 秒内）→ 合成一对，占两位里前面那一位。其他手势照旧不动
    private mutating func regroup(id: String, kind: Int, gesture: Int, at time: TimeInterval) {
        switch gesture {
        case 2:
            guard let i = units.firstIndex(where: { if case let .pair(l, r) = $0 { return l == id || r == id }; return false }),
                  case let .pair(l, r) = units[i] else { return }
            let other = l == id ? r : l
            units[i] = .single(id: id, kind: kind)
            if units.count < Self.maxPlayers { units.insert(.single(id: other, kind: l == id ? 3 : 2), at: i + 1) }
            else { droppedDevices.append(other) }   // 满 8 位：另一只连着、没有玩家位
        case 3:
            func singleAt(_ x: String) -> Int? { units.firstIndex { if case let .single(sid, _) = $0 { return sid == x }; return false } }
            if let half = pendingHalf, half.id != id, half.kind != kind, time - half.at <= Self.pairWindow,
               let a = singleAt(half.id), let b = singleAt(id) {
                let (left, right) = kind == 2 ? (id, half.id) : (half.id, id)
                units[min(a, b)] = .pair(left: left, right: right)
                units.remove(at: max(a, b))
                pendingHalf = nil
            } else if singleAt(id) != nil {
                pendingHalf = (id, kind, time)
            }
        default: break
        }
    }

    /// 一代 Joy-Con（不是 Joy-Con 2）：按系统给的名字认
    nonisolated static func isGen1JoyCon(_ name: String) -> Bool {
        let t = name.lowercased(); return t.contains("joy-con (") && !t.contains("joy-con 2")
    }
    /// 系统给的一代名字里有哪几侧：「Joy-Con (L/R)」两侧、「Joy-Con (L)」左、「Joy-Con (R)」右
    nonisolated static func gen1Sides(_ name: String) -> [Int] {
        let t = name.lowercased()
        guard isGen1JoyCon(name) else { return [] }
        if t.contains("(l/r)") || t.contains("(l + r)") { return [0, 1] }
        return t.contains("(l)") ? [0] : t.contains("(r)") ? [1] : []
    }
    /// 学：系统那一位按了 L + R（或单只按了肩键）的同一刻（0.3 秒内）HID 看到哪几只按了肩键，就是它里面的那几只
    private mutating func learnHalves(now: TimeInterval) {
        recentShoulder.removeAll { now - $0.at > 1 }
        guard let c = recentCombined, abs(now - c.at) <= 0.3 else { return }
        var halves: [String] = []
        for side in Self.gen1Sides(c.key.name) {
            let hits = recentShoulder.filter { $0.side == side && abs($0.at - c.at) <= 0.3 }
            guard hits.count == 1 else { return }   // 两套同时按：分不出，不猜
            halves.append(hits[0].id)
        }
        guard !halves.isEmpty else { return }
        for (k, v) in combinedHalves where k != c.key && v.contains(where: halves.contains) { combinedHalves[k] = nil }   // 这几只挪到别的那一位了
        combinedHalves[c.key] = halves
    }
    /// 这只在系统合成的哪一位里：学到的；没学到时，同侧的候选（没学到 / 学到含它）只有一个就是它
    private func combinedContaining(_ id: String, side: Int, system: [SystemKey]) -> SystemKey? {
        if let k = combinedHalves.first(where: { $0.value.contains(id) })?.key, system.contains(k) { return k }
        let candidates = system.filter { Self.gen1Sides($0.name).contains(side) && !splitCombined.contains($0) && combinedHalves[$0] == nil }
        return candidates.count == 1 ? candidates[0] : nil
    }
    /// 一代 Joy-Con 的分配手势（D2；启动器 HID 读，Gen1HIDWatcher）：id 哪一只、side 0 左只 / 1 右只；gesture 2 = SL + SR、3 = 肩键 L / R。同原机「更改握法 / 顺序」，几套各管各的：
    ///   SL + SR：这只在按设备读的一对里 → 拆开，这只留原位、另一只排在后面；在系统合成的那一位里 → 只拆这一套：这只顶替那一位、同一套的另一只排在它后面，
    ///     别的套照旧由系统合成、各一位；还没登记 → 登记成单只（满 8 位时另一只连着、没有玩家位）。
    ///   两位单只（一左一右）各按 L / R（0.5 秒内）→ 合成一位（竖握），占两位里前面那一位。
    ///   系统合成的那一位按 L + R（L1 + R1，system）的同一刻 HID 看到的左只 L、右只 R 就是它里面的两只（learnHalves），拆的时候认得出是哪一套。
    ///   present：现在连着的一代（按设备）；system：现在连着的系统手柄
    private var pendingGen1: (id: String, side: Int, at: TimeInterval)?
    mutating func gen1(id: String, side: Int, gesture: Int, at time: TimeInterval, present: [Gen1Device], system: [SystemKey] = []) {
        func pairAt(_ x: String) -> Int? { units.firstIndex { if case let .gen1Pair(l, r) = $0 { return l == x || r == x }; return false } }
        func singleAt(_ x: String) -> Int? { units.firstIndex { if case let .gen1(sid, _) = $0 { return sid == x }; return false } }
        switch gesture {
        case 2:
            if let i = pairAt(id), case let .gen1Pair(l, r) = units[i] {
                let other = l == id ? r : l
                units[i] = .gen1(id: id, side: side)
                if units.count < Self.maxPlayers { units.insert(.gen1(id: other, side: 1 - side), at: i + 1) } else { droppedGen1.append(other) }
                return
            }
            guard singleAt(id) == nil else { return }
            undrop(.gen1(id: id, side: side))
            guard let k = combinedContaining(id, side: side, system: system) else {   // 认不出在哪一位里（没学到、又有好几套）：只登记这只，日志记一笔
                if units.count < Self.maxPlayers { units.append(.gen1(id: id, side: side)) }
                NSLog("[分配玩家] 一代 Joy-Con %@ 认不出在系统合成的哪一位里，只登记这一只", id)
                return
            }
            if !splitCombined.contains(k) { splitCombined.append(k) }
            // 同一套的另一只：学到的；没学到时，连着、没登记、不在别的学到的那一位里的另一侧只有一只就是它
            let known = Set(combinedHalves.filter { $0.key != k }.flatMap(\.value))
            let others = present.filter { $0.side != side && !registeredGen1.contains($0.id) && !known.contains($0.id) }
            let partner = combinedHalves[k]?.first { $0 != id } ?? (Self.gen1Sides(k.name).count == 2 && others.count == 1 ? others[0].id : nil)
            if let i = units.firstIndex(of: .system(name: k.name, index: k.index)) { units[i] = .gen1(id: id, side: side) }
            else if units.count < Self.maxPlayers { units.append(.gen1(id: id, side: side)) }
            else { return }
            if let partner, let i = singleAt(id), !registeredGen1.contains(partner) {
                if units.count < Self.maxPlayers { units.insert(.gen1(id: partner, side: 1 - side), at: i + 1) } else { droppedGen1.append(partner) }
            }
        case 3:
            recentShoulder.append((id, side, time)); learnHalves(now: time)
            guard let half = pendingGen1, half.id != id, half.side != side, time - half.at <= Self.pairWindow,
                  let a = singleAt(id), let b = singleAt(half.id) else {
                pendingGen1 = (id, side, time); return
            }
            let unit = side == 0 ? Unit.gen1Pair(left: id, right: half.id) : .gen1Pair(left: half.id, right: id)
            units[min(a, b)] = unit
            units.remove(at: max(a, b))
            pendingGen1 = nil
        default: break
        }
    }

    /// 游戏的手柄设置画面要的样式（Ryujinx ControllerType 位：Pro 1、一对 4、左只 8、右只 16；Joy-Con 2 位 bit 12 一对 / 13 左只 / 14 右只）
    struct GameWants: Equatable {
        let styles: Int, min: Int, max: Int
        var pair: Bool { styles & (1 | 4 | 1 << 12) != 0 }      // 一对 / Pro（两者游戏那边会互换）
        var single: Bool { styles & (8 | 16 | 1 << 13 | 1 << 14) != 0 }
    }
    private func isSingle(_ unit: Unit) -> Bool {
        switch unit {
        case .single, .gen1: return true
        case let .system(name, _): return Self.gen1Sides(name).count == 1
        default: return false
        }
    }
    /// 照游戏的手柄设置画面自动拆 / 拼，不弹面板（同原机：玩家拿着的手柄够、样式对就直接过）：
    ///   只收单只 → 一对都拆开；人数不够 → 拆一对补人数；人数超过上限、或只收一对 → 一左一右的单只（Joy-Con 2 同一组 / 一代任意）拼成一位。
    ///   单只当一对也收（真机双手模式只接一侧、直握）。返回够不够——够就直接回游戏，不够才弹面板让玩家接手柄 / 按键。devices：NS2 手柄（同组才拼得起来）
    @discardableResult
    mutating func autoFit(_ wants: GameWants, devices: [Device]) -> Bool {
        let minimum = Swift.max(wants.min, 1), maximum = wants.max > 0 ? wants.max : Self.maxPlayers
        func splitOne() -> Bool {
            guard let i = units.firstIndex(where: { if case .pair = $0 { return true }; if case .gen1Pair = $0 { return true }; return false }) else { return false }
            switch units[i] {
            case let .pair(l, r): units[i] = .single(id: l, kind: 2); units.insert(.single(id: r, kind: 3), at: i + 1)
            case let .gen1Pair(l, r): units[i] = .gen1(id: l, side: 0); units.insert(.gen1(id: r, side: 1), at: i + 1)
            default: return false
            }
            return true
        }
        func mergeOne() -> Bool {
            let group = Dictionary(devices.map { ($0.id, $0.group) }, uniquingKeysWith: { a, _ in a })
            for (a, ua) in units.enumerated() {
                for (b, ub) in units.enumerated() where b != a {
                    var merged: Unit?
                    if case let .single(l, 2) = ua, case let .single(r, 3) = ub, group[l] == group[r] { merged = .pair(left: l, right: r) }
                    if case let .gen1(l, 0) = ua, case let .gen1(r, 1) = ub { merged = .gen1Pair(left: l, right: r) }
                    guard let merged else { continue }
                    units[Swift.min(a, b)] = merged
                    units.remove(at: Swift.max(a, b))
                    return true
                }
            }
            return false
        }
        if wants.single && !wants.pair { while splitOne() {} }
        while units.count < minimum, wants.single || wants.pair, splitOne() {}
        while units.count > maximum || (wants.pair && !wants.single && units.contains(where: isSingle) && units.count > minimum), mergeOne() {}
        guard units.count >= minimum else { return false }
        return units.prefix(maximum).allSatisfy { isSingle($0) ? (wants.single || wants.pair) : wants.pair }
    }

    /// 键盘：分配中按任一键（#520 讨论，不用提示）
    mutating func keyboard() {
        guard units.count < Self.maxPlayers, !units.contains(.keyboard) else { return }
        register(.keyboard)
    }

    /// 系统手柄同按 L1 + R1
    mutating func system(name: String, index: Int, at time: TimeInterval = 0) {
        if Self.isGen1JoyCon(name) { recentCombined = (SystemKey(name: name, index: index), time); learnHalves(now: time) }   // 认它里面是哪几只
        // 拆开过的那一位不再登记：两只已按设备读，各按 L / R 时 HID 那一路自己合成一位（同原机），这里再登记就重复了
        guard units.count < Self.maxPlayers, !units.contains(.system(name: name, index: index)), !splitCombined.contains(SystemKey(name: name, index: index)) else { return }
        register(.system(name: name, index: index))
    }

    /// 给连接程序的计划（`assign done {json}`，macos/ns2_connection_helper.m apply_assignment）：拼 / 拆、谁是玩家 1；
    ///   keep = 连着的全部（没分配的也不断开，只是游戏不给它玩家位）
    func helperPlan(devices: [Device]) -> [String: Any] {
        var first: String?
        let ids = Set(devices.map(\.id))   // 只看这一组（这个连接程序）的手柄
        for unit in units {
            switch unit {
            case let .pair(l, _) where ids.contains(l): first = l
            case let .single(id, _) where ids.contains(id), let .whole(id, _) where ids.contains(id): first = id
            default: continue
            }
            break
        }
        var plan: [String: Any] = ["split": wantsSplit(devices: devices), "keep": devices.map(\.id).sorted()]
        if let first { plan["first"] = first }
        return plan
    }

    /// 给游戏的顺序表：NS2 手柄按通道玩家号（登记了的照顺序 0、1…，没分配的排在后面、列进 dropped）、系统手柄按名字 + 第几只；
    ///   dropped 的游戏不读（保持连接、没有玩家位）
    /// playerOf：设备 id → 通道玩家号（连接程序报的、第二个连接程序的 +2）；没给时照登记顺序 0、1…（只有一组时两者相同）
    func orderFile(playerOf: [String: Int] = [:]) -> [String: Any] {
        var player = 0
        func number(_ id: String) -> Int { if let p = playerOf[id] { return p }; defer { player += 1 }; return player }
        let order: [[String: Any]] = units.map { unit in
            switch unit {
            case .system(let name, let index): return ["type": "system", "name": name, "index": index]
            case .keyboard: return ["type": "keyboard"]
            case let .gen1(id, side): return ["type": "gen1", "id": id, "side": side]
            case let .gen1Pair(l, r): return ["type": "gen1pair", "left": l, "right": r]
            case let .pair(l, _): return ["type": "ns2", "player": number(l)]
            case let .single(id, _), let .whole(id, _): return ["type": "ns2", "player": number(id)]
            }
        }
        var gone: [[String: Any]] = (dropped + splitCombined.filter { !dropped.contains($0) }).map { ["type": "system", "name": $0.name, "index": $0.index] }
            + droppedGen1.map { ["type": "gen1", "id": $0] }
        var seen = Set(order.compactMap { $0["type"] as? String == "ns2" ? $0["player"] as? Int : nil })
        for id in droppedDevices { let p = number(id); if seen.insert(p).inserted { gone.append(["type": "ns2", "player": p]) } }
        return ["order": order, "dropped": gone, "generation": generation]
    }

    static var orderFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/S2Arm/pad-order.json")
    }
}
