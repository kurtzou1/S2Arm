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

    /// 玩家槽位（下标 0..7 = P1..P8，nil = 该槽手柄暂时断开 / 空位；尾部的 nil 自动裁掉）
    private(set) var slots: [Unit?] = []
    /// 当前在线的玩家单元（不含空槽；供只需看在线列表与人数的调用方使用）
    var units: [Unit] { slots.compactMap { $0 } }
    /// 断开手柄的身份 → 断开前占的玩家槽（不存偏好）：重连回到原槽，不把其他玩家挤乱
    private enum SlotIdentity: Hashable {
        case ns2(String)
        case system(String, Int)
        case gen1(String)
        case keyboard
    }
    private var disconnectedSlots: [SlotIdentity: Int] = [:]
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
    /// 用 SL + SR 登记成单只（横握一位）的 Joy-Con 2（设备 id）：同组另一侧之后接上时不自动跟它拼成一对，新来的自己排一位
    ///   （玩家已经明确要单只横握，不用再按一次 SL + SR 拆开）。没按过 SL + SR、只是先接上自动排进来的单只，照旧自动拼成一对
    private(set) var sideways: [String] = []
    private var pendingHalf: (id: String, kind: Int, at: TimeInterval)?
    /// 系统合成的一代 Joy-Con 断了一只 / 接回一只时，系统给的名字会变（「Joy-Con (L/R)」↔「Joy-Con (L)」），旧的那一位消失、新的另算一只。
    ///   记下它原来排第几，下一只新出现的一代系统手柄接回这个位置（同 Joy-Con 2：一对断一只剩单只、接回来拼回原位，不跑到最后）。不存偏好
    /// 上一次对完时，系统给的每一位一代里是哪几只（设备 id）。系统的「同名第几只」号码会挪，玩家位照里面的实体手柄跟着走。不存偏好
    private var gen1Last: [SystemKey: Set<String>] = [:]
    /// 按设备读的一对断了一只：剩下那只 → 断开的那只。同一只接回来就在原位并回一对（同 Joy-Con 2 一对断一只、接回拼回原位）；
    ///   剩下那只按过 SL + SR（明确要横握单只）或也断开了就忘掉。不存偏好
    private var gen1Partner: [String: String] = [:]
    /// 同上，Joy-Con 2：一对（含跨套按 L + R 拼的）断了一只，剩下那只 → 断开的那只；那只接回来原位并回（不限同一组）
    private var ns2Partner: [String: String] = [:]

    /// 横握记号（sideways）与断连原槽记忆（disconnectedSlots）不存偏好：只管这次开着的期间；重开 App 后第一次连上照常排
    ///   （11-20：存进偏好后，模拟手柄重开 App 后同样的 id 第一次连上也不拼了）
    enum CodingKeys: String, CodingKey { case slots, units, dropped, droppedDevices, droppedGen1, splitCombined, generation }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedSlots = try c.decodeIfPresent([Unit?].self, forKey: .slots) {
            slots = decodedSlots
        } else {
            slots = (try c.decodeIfPresent([Unit].self, forKey: .units) ?? []).map { Optional($0) }
        }
        trimTrailingEmptySlots()
        dropped = try c.decodeIfPresent([SystemKey].self, forKey: .dropped) ?? []
        droppedDevices = try c.decodeIfPresent([String].self, forKey: .droppedDevices) ?? []
        droppedGen1 = try c.decodeIfPresent([String].self, forKey: .droppedGen1) ?? []
        splitCombined = try c.decodeIfPresent([SystemKey].self, forKey: .splitCombined) ?? []
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slots, forKey: .slots)
        try c.encode(units, forKey: .units)
        try c.encode(dropped, forKey: .dropped)
        try c.encode(droppedDevices, forKey: .droppedDevices)
        try c.encode(droppedGen1, forKey: .droppedGen1)
        try c.encode(splitCombined, forKey: .splitCombined)
        try c.encode(generation, forKey: .generation)
    }
    static func == (a: PlayerAssignment, b: PlayerAssignment) -> Bool {
        a.slots == b.slots && a.dropped == b.dropped && a.droppedDevices == b.droppedDevices && a.droppedGen1 == b.droppedGen1 && a.splitCombined == b.splitCombined && a.generation == b.generation   // sideways / disconnectedSlots 只管这次开着的期间、不存偏好，不算在比对里
    }

    private mutating func trimTrailingEmptySlots() {
        while slots.last == Optional<Unit>.none { slots.removeLast() }
    }
    private static func identities(of unit: Unit) -> [SlotIdentity] {
        switch unit {
        case let .pair(l, r): return [.ns2(l), .ns2(r)]
        case let .single(id, _), let .whole(id, _): return [.ns2(id)]
        case let .system(name, index): return [.system(name, index)]
        case .keyboard: return [.keyboard]
        case let .gen1(id, _): return [.gen1(id)]
        case let .gen1Pair(l, r): return [.gen1(l), .gen1(r)]
        }
    }
    private mutating func rememberDisconnected(_ unit: Unit, at slot: Int) {
        guard slot >= 0, slot < Self.maxPlayers else { return }
        for id in Self.identities(of: unit) { disconnectedSlots[id] = slot }
    }
    private mutating func forgetDisconnected(_ unit: Unit) {
        for id in Self.identities(of: unit) { disconnectedSlots[id] = nil }
    }
    private mutating func setSlot(_ index: Int, _ unit: Unit) {
        guard index >= 0, index < Self.maxPlayers else { return }
        if index >= slots.count { slots.append(contentsOf: repeatElement(nil, count: index - slots.count + 1)) }
        slots[index] = unit
        forgetDisconnected(unit)
        // 该槽已被新的在线单元占用：清掉占着同槽的旧断连记忆（其他槽不动）
        disconnectedSlots = disconnectedSlots.filter { $0.value != index }
    }
    /// 放进玩家槽：同一身份优先回到断开前的原槽；新身份选最小空槽，全满不分配
    private mutating func place(_ unit: Unit) {
        for id in Self.identities(of: unit) {
            if let preferred = disconnectedSlots[id], preferred >= 0, preferred < Self.maxPlayers,
               preferred >= slots.count || slots[preferred] == nil {
                setSlot(preferred, unit)
                return
            }
        }
        if let free = (0..<Self.maxPlayers).first(where: { $0 >= slots.count || slots[$0] == nil }) {
            setSlot(free, unit)
        }
    }
    /// 找一个空槽：若指定了 preferred 且为空则优先用它；否则取最小空槽；8 槽全满返回 nil
    private func freeSlot(preferring preferred: Int? = nil) -> Int? {
        if let preferred, preferred >= 0, preferred < Self.maxPlayers,
           preferred >= slots.count || slots[preferred] == nil {
            return preferred
        }
        return (0..<Self.maxPlayers).first { $0 >= slots.count || slots[$0] == nil }
    }
    /// 拆分一对 Joy-Con 时给另一只找空槽：优先用紧挨着的空槽，否则找最小空槽；绝不挤动其他玩家，8 槽全满返回 nil（不拆）
    private func splitSlot(after index: Int) -> Int? {
        let next = index + 1
        if next < Self.maxPlayers, next >= slots.count || slots[next] == nil { return next }
        return (0..<Self.maxPlayers).first { $0 != index && ($0 >= slots.count || slots[$0] == nil) }
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
        followGen1(system: system, gen1: gen1)
        for unit in units { if case let .gen1Pair(l, r) = unit, g1.contains(l) != g1.contains(r) { gen1Partner[g1.contains(l) ? l : r] = g1.contains(l) ? r : l } }
        gen1Partner = gen1Partner.filter { g1.contains($0.key) }
        for unit in units { if case let .pair(l, r) = unit, ids.contains(l) != ids.contains(r) { ns2Partner[ids.contains(l) ? l : r] = ids.contains(l) ? r : l } }
        ns2Partner = ns2Partner.filter { ids.contains($0.key) }
        for i in slots.indices {
            guard let unit = slots[i] else { continue }
            if let kept = reconciled(unit, ids: ids, keys: keys, g1: g1) {
                slots[i] = kept
            } else {
                rememberDisconnected(unit, at: i)
                slots[i] = nil
            }
        }
        trimTrailingEmptySlots()
        reconcileRest(devices: devices, mergedGroups: mergedGroups, system: system, gen1: gen1, ids: ids, keys: keys, g1: g1)
        trimTrailingEmptySlots()
        gen1Last = gen1Owners(system: system, gen1: gen1).mapValues { Set($0.values) }
        return self != before
    }
    /// 系统给的一代那几位各是哪几只（一代 Joy-Con 的唯一对应表：拆开、找另一只、去重、后接上的那一侧都照它）：
    ///   1. 按过 L + R 学到的（combinedHalves）最准，先用；
    ///   2. 其余照连上的先后对——系统手柄表与 HID 表都按连接顺序排，同侧还没对上的系统位第 n 个 ↔ HID 同侧第 n 只。
    ///   系统给的名字带「同名第几只」，别的同名手柄断开后号码会挪（第 2 只变第 1 只），光看名字认不出是哪一只。
    ///   某一侧数对不上（两张表一前一后更新的那一下）那一侧就不对，不猜
    func gen1Owners(system: [SystemKey], gen1: [Gen1Device], learned: Bool = true) -> [SystemKey: [Int: String]] {
        var out: [SystemKey: [Int: String]] = [:]
        var usedIDs = Set<String>(), usedKeys = Set<SystemKey>()
        for (key, ids) in combinedHalves where learned && system.contains(key) {
            for id in ids { if let d = gen1.first(where: { $0.id == id }) { out[key, default: [:]][d.side] = id; usedIDs.insert(id) } }
            usedKeys.insert(key)
        }
        for side in [0, 1] {
            let keys = system.filter { Self.isGen1JoyCon($0.name) && Self.gen1Sides($0.name).contains(side) && !usedKeys.contains($0) }
            let devs = gen1.filter { $0.side == side && !usedIDs.contains($0.id) }
            guard keys.count == devs.count else { continue }
            for (k, d) in zip(keys, devs) { out[k, default: [:]][side] = d.id }
        }
        return out
    }
    /// 系统给的一代那几位跟着里面的实体手柄走（号码挪了 / 名字从「(L/R)」变「(L)」也认得是同一套）：
    ///   玩家位、手动拿掉的（dropped）、学到的两只（combinedHalves）都照这次的对应表换成新号码；
    ///   里面的手柄都不在了 → 玩家位拿掉；对应表这一下对不上但手柄还连着（两张表一前一后更新）→ 先不动
    private mutating func followGen1(system: [SystemKey], gen1: [Gen1Device]) {
        let pure = gen1Owners(system: system, gen1: gen1, learned: false)
        combinedHalves = combinedHalves.filter { key, v in pure[key].map { Set($0.values) == Set(v) } ?? system.contains(key) }   // 号码挪了：学到的不再可靠，以先后为准
        guard !gen1Last.isEmpty else { return }
        let now = gen1Owners(system: system, gen1: gen1).mapValues { Set($0.values) }
        let present = Set(gen1.map(\.id))
        func follow(_ key: SystemKey) -> SystemKey?? {   // nil = 不认得（照旧）；.some(nil) = 里面的都不在了
            guard Self.isGen1JoyCon(key.name), let old = gen1Last[key], !old.isEmpty else { return nil }
            if let best = now.filter({ !$0.value.isDisjoint(with: old) }).max(by: { $0.value.intersection(old).count < $1.value.intersection(old).count })?.key { return .some(best) }
            return old.isDisjoint(with: present) ? .some(nil) : nil
        }
        var taken = Set<SystemKey>()
        for i in slots.indices {
            guard case let .system(name, index) = slots[i] else { continue }
            let key = SystemKey(name: name, index: index)
            switch follow(key) {
            case .none: taken.insert(key)
            case .some(.none):
                rememberDisconnected(.system(name: name, index: index), at: i)
                slots[i] = nil
            case .some(.some(let next)):
                if taken.insert(next).inserted { slots[i] = .system(name: next.name, index: next.index) }
                else { slots[i] = nil }
            }
        }
        trimTrailingEmptySlots()
        dropped = dropped.compactMap { key in
            switch follow(key) { case .none: return key; case .some(.none): return nil; case .some(.some(let next)): return next }
        }
    }
    /// 这一位里已按设备登记的那几侧 / 还没登记的那几只
    private func gen1Split(_ key: SystemKey, owners: [SystemKey: [Int: String]]) -> (covered: Bool, free: [Gen1Device]) {
        let mine = owners[key] ?? [:]
        let taken = mine.filter { registeredGen1.contains($0.value) || droppedGen1.contains($0.value) }   // × 掉的（连着、没有玩家位）也算这一位拆开过
        let free = mine.filter { !registeredGen1.contains($0.value) && !droppedGen1.contains($0.value) }.map { Gen1Device(id: $0.value, side: $0.key) }.sorted { $0.side < $1.side }
        return (!taken.isEmpty, free)
    }
    /// 已经排着、但里面的一代已按设备登记的系统那一位：整位都登记了就拿掉；只登记了一侧（例如左只按过 SL + SR，右只后来接上）就在原位换成另一侧自己一位
    private mutating func dropGen1Duplicates(owners: [SystemKey: [Int: String]]) {
        for i in slots.indices {
            guard case let .system(name, index) = slots[i], Self.isGen1JoyCon(name) else { continue }
            let key = SystemKey(name: name, index: index)
            let (covered, free) = gen1Split(key, owners: owners)
            guard covered else { continue }
            slots[i] = nil
            if let first = free.first {
                setSlot(i, .gen1(id: first.id, side: first.side))
                for d in free.dropFirst() { place(.gen1(id: d.id, side: d.side)) }
            }
            if !free.isEmpty && !splitCombined.contains(key) { splitCombined.append(key) }
        }
        trimTrailingEmptySlots()
    }
    private func reconciled(_ unit: Unit, ids: Set<String>, keys: Set<SystemKey>, g1: Set<String>) -> Unit? {
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
    private mutating func reconcileRest(devices: [Device], mergedGroups: Set<Int>, system: [SystemKey], gen1: [Gen1Device], ids: Set<String>, keys: Set<SystemKey>, g1: Set<String>) {
        droppedGen1.removeAll { !g1.contains($0) }
        splitCombined.removeAll { !keys.contains($0) }   // 合成的那一位断开 / 系统拆了：下次连上照常排
        combinedHalves = combinedHalves.filter { keys.contains($0.key) }
        dropped.removeAll { !keys.contains($0) }
        droppedDevices.removeAll { !ids.contains($0) }
        // 横握记号断开也留着（11-20：拆开的一对，一只一只断开重连后又拼回一组）：要拼回一对就按 L + R（regroup 会清掉）
        var fresh = devices.filter { !registeredIDs.contains($0.id) && !droppedDevices.contains($0.id) }
        // 断开过的那只接回：原来跟它一对的那只还是单只，就原位并回一对（跨套拼的也一样）
        for d in fresh where d.kind == 2 || d.kind == 3 {
            guard let host = ns2Partner.first(where: { $0.value == d.id })?.key,
                  let i = slots.firstIndex(where: { if case let .single(x, k) = $0 { return x == host && k != d.kind }; return false }) else { continue }
            setSlot(i, d.kind == 2 ? .pair(left: d.id, right: host) : .pair(left: host, right: d.id))
            ns2Partner[host] = nil
            fresh.removeAll { $0.id == d.id }
        }
        for group in mergedGroups.sorted() {
            let inGroup = devices.filter { $0.group == group }
            // 一对连着、合成一位：登记过单只的那只配上同组新来的另一只，原位并成一对——
            //   那只若是按 SL + SR 登记的横握单只（sideways）就不拼：新来的自己排一位，传输层照分配拆开（wantsSplit → sendPlan）
            if let other = fresh.first(where: { $0.group == group && ($0.kind == 2 || $0.kind == 3) && !sideways.contains($0.id) }),
               let at = slots.firstIndex(where: { if case let .single(id, k) = $0 { return k != other.kind && (k == 2 || k == 3) && inGroup.contains { $0.id == id } && !sideways.contains(id) }; return false }),
               case let .single(id, _) = slots[at] {
                setSlot(at, other.kind == 2 ? .pair(left: other.id, right: id) : .pair(left: id, right: other.id))
                fresh.removeAll { $0.id == other.id }
            }
            if let l = fresh.first(where: { $0.group == group && $0.kind == 2 && !sideways.contains($0.id) }), let r = fresh.first(where: { $0.group == group && $0.kind == 3 && !sideways.contains($0.id) }) {
                place(.pair(left: l.id, right: r.id)); fresh.removeAll { $0.id == l.id || $0.id == r.id }
            }
        }
        for d in fresh { place(d.kind == 1 ? .whole(id: d.id, kind: 1) : .single(id: d.id, kind: d.kind)) }
        let owners = gen1Owners(system: system, gen1: gen1)
        dropGen1Duplicates(owners: owners)
        // 一代的「拆开过」照这次谁按设备登记了重算（不留旧号码；给游戏的顺序表照它不读系统那一位）
        splitCombined = splitCombined.filter { !Self.isGen1JoyCon($0.name) } + system.filter { Self.isGen1JoyCon($0.name) && gen1Split($0, owners: owners).covered }
        dropped.removeAll { Self.isGen1JoyCon($0.name) && splitCombined.contains($0) }   // 旧版按完成时记进去的（同 finish 的说明）
        for key in system where !dropped.contains(key) && (Self.isGen1JoyCon(key.name) || !splitCombined.contains(key)) && !units.contains(.system(name: key.name, index: key.index)) {
            // 这一位里有一只已按设备登记：这一位是重复的，不排（不记成拆开过：号码会挪，下次照当时的对应再算）；
            //   另一侧还没登记的（例如左只按过 SL + SR 横握，右只后来接上）自己排一位（同 Joy-Con 2 横握单只配上新来的另一只）
            if Self.isGen1JoyCon(key.name) {
                let (covered, free) = gen1Split(key, owners: owners)
                if covered {
                    for d in free {
                        // 原来跟它一对、只是断开过的那只：原位并回一对；否则放进空槽（断开重连回原槽）
                        if let host = gen1Partner.first(where: { $0.value == d.id })?.key,
                           let i = slots.firstIndex(where: { if case let .gen1(x, _) = $0 { return x == host }; return false }) {
                            setSlot(i, d.side == 1 ? .gen1Pair(left: host, right: d.id) : .gen1Pair(left: d.id, right: host))
                            gen1Partner[host] = nil
                        } else { place(.gen1(id: d.id, side: d.side)) }
                    }
                    continue
                }
            }
            place(.system(name: key.name, index: key.index))
        }
    }
    /// 清掉一位（玩家列表的 ×，#520 讨论）：分配中只是空出这一位（其他玩家留原位）；平时还要记成 dropped——手柄保持连接、没有玩家位、不再自动排回来（下次分配按键加入）
    mutating func remove(at index: Int, keepConnectedWithoutSlot: Bool) {
        guard slots.indices.contains(index), let unit = slots[index] else { return }
        slots[index] = nil
        forgetDisconnected(unit)
        trimTrailingEmptySlots()
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
    private mutating func register(_ unit: Unit, preferredSlot: Int? = nil) {
        undrop(unit)
        forgetDisconnected(unit)
        if let free = freeSlot(preferring: preferredSlot) {
            setSlot(free, unit)
        }
    }
    private mutating func markSideways(_ id: String) { if !sideways.contains(id) { sideways.append(id) } }

    /// 分配完成：在线却没登记的记成 dropped（保持连接、没有玩家位）；显式重分配清掉旧的断连原槽记忆
    mutating func finish(presentSystem: [SystemKey], devices: [Device], gen1: [Gen1Device] = []) {
        generation += 1
        disconnectedSlots.removeAll()
        trimTrailingEmptySlots()
        // 拆开过的一代合成那一位不算「拿掉」：它照「谁按设备登记了」自己不排（splitCombined）；记成拿掉的话，
        //   之后同一套断一只再接回，接回的那只就永远排不进来（11-20 日志：拆第 2 套、按完成、左只断开再接回，左只消失）
        dropped = presentSystem.filter { !units.contains(.system(name: $0.name, index: $0.index)) && !(Self.isGen1JoyCon($0.name) && splitCombined.contains($0)) }
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
    mutating func ns2(id: String, kind: Int, gesture: Int, at time: TimeInterval, targetSlot: Int? = nil) {
        guard !id.isEmpty else { return }
        if registeredIDs.contains(id) { regroup(id: id, kind: kind, gesture: gesture, at: time); return }
        guard freeSlot(preferring: targetSlot) != nil else { return }
        switch gesture {
        case 1: register(.whole(id: id, kind: kind), preferredSlot: targetSlot)
        case 2: register(.single(id: id, kind: kind), preferredSlot: targetSlot); markSideways(id)
        case 3:
            if let half = pendingHalf, half.id != id, half.kind != kind, time - half.at <= Self.pairWindow, !registeredIDs.contains(half.id) {
                let (left, right) = kind == 2 ? (id, half.id) : (half.id, id)
                register(.pair(left: left, right: right), preferredSlot: targetSlot)
                pendingHalf = nil
            } else {
                pendingHalf = (id, kind, time)
            }
        default: break
        }
    }

    /// 已经有玩家位的 Joy-Con 2 再按（#520 讨论：不用先 ×）：一对里的一只同按 SL + SR → 需要有空槽才拆开（这只留原位、另一只放空槽，不挤动其他玩家；满 8 位时不拆）；
    ///   两位单只左只按 L、右只按 R（0.5 秒内）→ 合成一对，占两位里前面那一位、空出后面那一位。其他手势照旧不动
    private mutating func regroup(id: String, kind: Int, gesture: Int, at time: TimeInterval) {
        switch gesture {
        case 2:
            ns2Partner[id] = nil   // 明确要横握单只：断开过的另一只接回来不再并
            // 已经是单只的再按 SL + SR：位置不动，记成横握（之后另一侧接上不自动拼）
            if units.contains(where: { if case let .single(sid, _) = $0 { return sid == id }; return false }) { markSideways(id); return }
            guard let i = slots.firstIndex(where: { if case let .pair(l, r) = $0 { return l == id || r == id }; return false }),
                  case let .pair(l, r) = slots[i] else { return }
            guard let otherSlot = splitSlot(after: i) else { return }   // 无空槽不拆：需先 × 清除该对再单只按 SL + SR 加入
            let other = l == id ? r : l
            // 两只都记成横握：明确拆开的一对，哪一只断开再接回都不自动拼回（11-20：只记按的那只时，按的那只断开重连会和另一只并回一组）
            setSlot(i, .single(id: id, kind: kind)); markSideways(id); markSideways(other)
            setSlot(otherSlot, .single(id: other, kind: l == id ? 3 : 2))
        case 3:
            func singleAt(_ x: String) -> Int? { slots.firstIndex { if case let .single(sid, _) = $0 { return sid == x }; return false } }
            if let half = pendingHalf, half.id != id, half.kind != kind, time - half.at <= Self.pairWindow,
               let a = singleAt(half.id), let b = singleAt(id) {
                let (left, right) = kind == 2 ? (id, half.id) : (half.id, id)
                setSlot(min(a, b), .pair(left: left, right: right))
                slots[max(a, b)] = nil
                trimTrailingEmptySlots()
                sideways.removeAll { $0 == left || $0 == right }   // 又按 L + R 拼回一对
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
    /// 一代 Joy-Con 的分配手势（D2；启动器 HID 读，Gen1HIDWatcher）：id 哪一只、side 0 左只 / 1 右只；gesture 2 = SL + SR、3 = 肩键 L / R。同原机「更改握法 / 顺序」，几套各管各的：
    ///   SL + SR：这只在按设备读的一对里 → 拆开，这只留原位、另一只排在后面；在系统合成的那一位里 → 只拆这一套：这只顶替那一位、同一套的另一只排在它后面，
    ///     别的套照旧由系统合成、各一位；还没登记 → 登记成单只（满 8 位时另一只连着、没有玩家位）。
    ///   两位单只（一左一右）各按 L / R（0.5 秒内）→ 合成一位（竖握），占两位里前面那一位。
    ///   系统合成的那一位按 L + R（L1 + R1，system）的同一刻 HID 看到的左只 L、右只 R 就是它里面的两只（learnHalves），拆的时候认得出是哪一套。
    ///   present：现在连着的一代（按设备）；system：现在连着的系统手柄
    private var pendingGen1: (id: String, side: Int, at: TimeInterval)?
    mutating func gen1(id: String, side: Int, gesture: Int, at time: TimeInterval, present: [Gen1Device], system: [SystemKey] = [], targetSlot: Int? = nil) {
        func pairAt(_ x: String) -> Int? { slots.firstIndex { if case let .gen1Pair(l, r) = $0 { return l == x || r == x }; return false } }
        func singleAt(_ x: String) -> Int? { slots.firstIndex { if case let .gen1(sid, _) = $0 { return sid == x }; return false } }
        switch gesture {
        case 2:
            gen1Partner[id] = nil   // 明确要横握单只：断开过的另一只接回来不再并
            if let i = pairAt(id), case let .gen1Pair(l, r) = slots[i] {
                guard let otherSlot = splitSlot(after: i) else { return }   // 无空槽不拆
                let other = l == id ? r : l
                setSlot(i, .gen1(id: id, side: side))
                setSlot(otherSlot, .gen1(id: other, side: 1 - side))
                return
            }
            guard singleAt(id) == nil else { return }
            undrop(.gen1(id: id, side: side))
            // 这只在系统的哪一位里、同一套的另一只是谁：都照对应表（gen1Owners）
            let owners = gen1Owners(system: system, gen1: present)
            guard let k = owners.first(where: { $0.value.values.contains(id) })?.key else {   // 对不上（两张表还没对齐）：只登记这只，日志记一笔
                register(.gen1(id: id, side: side), preferredSlot: targetSlot)
                NSLog("[分配玩家] 一代 Joy-Con %@ 认不出在系统的哪一位里，只登记这一只", id)
                return
            }
            let partner = owners[k]?[1 - side]
            if let i = slots.firstIndex(of: .system(name: k.name, index: k.index)) {
                if let partner, !registeredGen1.contains(partner) {
                    guard let otherSlot = splitSlot(after: i) else { return }   // 无空槽不拆
                    if !splitCombined.contains(k) { splitCombined.append(k) }
                    setSlot(i, .gen1(id: id, side: side))
                    setSlot(otherSlot, .gen1(id: partner, side: 1 - side))
                } else {
                    if !splitCombined.contains(k) { splitCombined.append(k) }
                    setSlot(i, .gen1(id: id, side: side))
                }
            } else if freeSlot(preferring: targetSlot) != nil {
                if !splitCombined.contains(k) { splitCombined.append(k) }
                register(.gen1(id: id, side: side), preferredSlot: targetSlot)
                if let partner, let i = singleAt(id), !registeredGen1.contains(partner), let otherSlot = splitSlot(after: i) {
                    setSlot(otherSlot, .gen1(id: partner, side: 1 - side))
                }
            }
        case 3:
            recentShoulder.append((id, side, time)); learnHalves(now: time)
            // 单只的一位：按设备读的单只，或系统给的单只「Joy-Con (L)」/「(R)」（两套各连一只时系统不合成，各是一位；同 Joy-Con 2 两位单只照样能合）
            let owners = gen1Owners(system: system, gen1: present)
            func singleSlot(_ x: String, _ s: Int) -> (index: Int, key: SystemKey?)? {
                if let i = singleAt(x) { return (i, nil) }
                guard let k = owners.first(where: { $0.value == [s: x] })?.key,
                      let i = slots.firstIndex(of: .system(name: k.name, index: k.index)) else { return nil }
                return (i, k)
            }
            guard let half = pendingGen1, half.id != id, half.side != side, time - half.at <= Self.pairWindow,
                  let a = singleSlot(id, side), let b = singleSlot(half.id, half.side), a.index != b.index else {
                pendingGen1 = (id, side, time); return
            }
            let unit = side == 0 ? Unit.gen1Pair(left: id, right: half.id) : .gen1Pair(left: half.id, right: id)
            setSlot(min(a.index, b.index), unit)
            slots[max(a.index, b.index)] = nil
            trimTrailingEmptySlots()
            for k in [a.key, b.key].compactMap({ $0 }) where !splitCombined.contains(k) { splitCombined.append(k) }   // 这两只改按设备读，系统那一位不再排进来
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
            guard let i = slots.firstIndex(where: { if case .pair = $0 { return true }; if case .gen1Pair = $0 { return true }; return false }),
                  let otherSlot = splitSlot(after: i) else { return false }
            switch slots[i] {
            case let .pair(l, r): setSlot(i, .single(id: l, kind: 2)); setSlot(otherSlot, .single(id: r, kind: 3))
            case let .gen1Pair(l, r): setSlot(i, .gen1(id: l, side: 0)); setSlot(otherSlot, .gen1(id: r, side: 1))
            default: return false
            }
            return true
        }
        func mergeOne() -> Bool {
            let group = Dictionary(devices.map { ($0.id, $0.group) }, uniquingKeysWith: { a, _ in a })
            for (a, ua) in slots.enumerated() {
                guard let ua else { continue }
                for (b, ub) in slots.enumerated() where b != a {
                    guard let ub else { continue }
                    var merged: Unit?
                    if case let .single(l, 2) = ua, case let .single(r, 3) = ub, group[l] == group[r] { merged = .pair(left: l, right: r) }
                    if case let .gen1(l, 0) = ua, case let .gen1(r, 1) = ub { merged = .gen1Pair(left: l, right: r) }
                    guard let merged else { continue }
                    setSlot(Swift.min(a, b), merged)
                    slots[Swift.max(a, b)] = nil
                    trimTrailingEmptySlots()
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
    mutating func keyboard(targetSlot: Int? = nil) {
        guard freeSlot(preferring: targetSlot) != nil, !units.contains(.keyboard) else { return }
        register(.keyboard, preferredSlot: targetSlot)
    }

    /// 系统手柄同按 L1 + R1
    mutating func system(name: String, index: Int, at time: TimeInterval = 0, targetSlot: Int? = nil) {
        if Self.isGen1JoyCon(name) { recentCombined = (SystemKey(name: name, index: index), time); learnHalves(now: time) }   // 认它里面是哪几只
        // 拆开过的那一位不再登记：两只已按设备读，各按 L / R 时 HID 那一路自己合成一位（同原机），这里再登记就重复了
        guard freeSlot(preferring: targetSlot) != nil, !units.contains(.system(name: name, index: index)), !splitCombined.contains(SystemKey(name: name, index: index)) else { return }
        register(.system(name: name, index: index), preferredSlot: targetSlot)
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

    /// 玩家灯（同原机，手柄上的灯跟着玩家位）：第几位的灯型，位 0–3 = 四颗灯（playerLights 同一套）；没有位 = 0
    static func lightMask(player number: Int) -> Int {
        playerLights(number).enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
    }
    /// 每只手柄该亮的灯型（设备 id → 灯型）：Joy-Con 2 / NS2 Pro 与按设备读的一代 Joy-Con（一对两只同一位）；系统手柄另走 systemPlayers
    func lightMasks() -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, unit) in slots.enumerated() {
            guard let unit else { continue }
            let mask = Self.lightMask(player: i + 1)
            switch unit {
            case let .pair(l, r), let .gen1Pair(l, r): out[l] = mask; out[r] = mask
            case let .single(id, _), let .whole(id, _), let .gen1(id, _): out[id] = mask
            case .system, .keyboard: continue
            }
        }
        return out
    }
    /// 系统手柄（GameController）各是第几位（1 起）
    func systemPlayers() -> [SystemKey: Int] {
        var out: [SystemKey: Int] = [:]
        for (i, unit) in slots.enumerated() { if case let .system(name, index) = unit { out[SystemKey(name: name, index: index)] = i + 1 } }
        return out
    }

    /// 给游戏的顺序表：NS2 手柄按通道玩家号（登记了的照顺序 0、1…，没分配的排在后面、列进 dropped）、系统手柄按名字 + 第几只；
    ///   空槽写 type = "empty" 占位，保持后面玩家在原位不变；dropped 的游戏不读（保持连接、没有玩家位）
    /// playerOf：设备 id → 通道玩家号（连接程序报的、第二个连接程序的 +2）；没给时照登记顺序 0、1…（只有一组时两者相同）
    func orderFile(playerOf: [String: Int] = [:]) -> [String: Any] {
        var player = 0
        func number(_ id: String) -> Int { if let p = playerOf[id] { return p }; defer { player += 1 }; return player }
        let order: [[String: Any]] = slots.map { unit in
            guard let unit else { return ["type": "empty"] }
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
