// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Combine
import Foundation
import GameController
import LauncherPadBridge
import NXLauncher

enum ControllerFaceFamily: String, CaseIterable {
    case playstation, xbox, nintendo, other

    init(_ family: SystemControllers.Family) {
        switch family {
        case .playstation: self = .playstation
        case .xbox: self = .xbox
        case .gen1Left, .gen1Right, .gen1Pair, .nintendoPro: self = .nintendo
        case .other: self = .other
        }
    }
    static func of(_ controller: GCController) -> Self {
        Self(SystemControllers.family(category: controller.productCategory, vendor: controller.vendorName,
            xbox: controller.extendedGamepad is GCXboxGamepad,
            playstation: controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad) ?? .nintendoPro)
    }
    func symbol(source: Int) -> String {
        self == .playstation ? ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"][source]
            : ["a.circle", "b.circle", "x.circle", "y.circle"][source]
    }
    func label(source: Int) -> String {
        self == .playstation ? ["×", "○", "□", "△"][source] : ControllerFaceMapping.labels[source]
    }
    var diamond: [Int] { self == .nintendo ? [2, 3, 1, 0] : [3, 2, 0, 1] } // top, left, bottom, right
}

struct ControllerFaceMapping: Equatable {
    static let labels = ["A", "B", "X", "Y"]
    static let identity = Self(code: 0xe4)!
    let code: Int32
    init?(code: Int32) {
        guard s2a_launcher_face_valid(code) != 0 else { return nil }
        self.code = code
    }
    func source(for target: Int) -> Int { Int(s2a_launcher_face_source(code, Int32(target))) }
    func target(for source: Int) -> Int { (0..<4).first { self.source(for: $0) == source }! }
    func apply(_ buttons: UInt64) -> UInt64 { s2a_launcher_face_apply(buttons, code) }
    func assigning(source: Int, to target: Int) -> Self {
        var order = (0..<4).map { self.source(for: $0) }
        order.swapAt(self.target(for: source), target)
        return Self(code: order.enumerated().reduce(0) { $0 | Int32($1.element << ($1.offset * 2)) })!
    }
    static func switchPosition(for family: ControllerFaceFamily) -> Self {
        family == .nintendo ? .identity : Self(code: 0xb1)!
    }
    /// Nintendo pads report A/B/X/Y by label (east/south/north/west); the Xbox
    /// layout puts confirm on the bottom button, as iOS s2a_pad_abxy_order does.
    static func xboxPosition(for family: ControllerFaceFamily) -> Self {
        family == .nintendo ? Self(code: 0xb1)! : .identity
    }
    func symbols(for family: ControllerFaceFamily) -> [PadShortcut: String] {
        var symbols = Dictionary(uniqueKeysWithValues: zip([PadShortcut.primary, .back, .secondary, .tertiary], 0..<4).map {
            ($0.0, family.symbol(source: source(for: $0.1)))
        })
        switch family {
        case .playstation:
            symbols[.leftTrigger] = "l2.rectangle.roundedtop"
            symbols[.rightTrigger] = "r2.rectangle.roundedtop"
        case .nintendo:
            symbols[.leftTrigger] = "zl.rectangle.roundedtop"
            symbols[.rightTrigger] = "zr.rectangle.roundedtop"
        case .xbox, .other:
            symbols[.leftTrigger] = "lt.rectangle.roundedtop"
            symbols[.rightTrigger] = "rt.rectangle.roundedtop"
        }
        return symbols
    }
}

/// This file is also read live by the game host. Publish only after its atomic
/// write succeeds, so the launcher cannot advertise a mapping the game cannot read.
@MainActor final class ControllerFaceMapStore: ObservableObject {
    // Schema 2 stores one permutation shared by every non-Nintendo controller,
    // plus an optional Nintendo permutation (absent = native label layout).
    struct Document: Codable {
        var schema = 2
        var mapping: Int32? = nil
        var nintendo: Int32? = nil
        var profiles: [String: Int32]? = nil // schema 1, read only
    }
    let fileURL: URL
    @Published private(set) var sharedMapping: ControllerFaceMapping = .identity
    @Published private(set) var nintendoMapping: ControllerFaceMapping = .identity
    @Published private(set) var problem: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            let code: Int32
            var nintendo = ControllerFaceMapping.identity
            switch document.schema {
            case 1:
                guard let profiles = document.profiles, profiles.values.allSatisfy({ ControllerFaceMapping(code: $0) != nil }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Use a stable precedence when old brand preferences disagree;
                // the launcher and game host must select the same permutation.
                code = ["playstation", "xbox", "other"].compactMap { profiles[$0] }.first ?? ControllerFaceMapping.identity.code
            case 2:
                guard let mapping = document.mapping else { throw CocoaError(.fileReadCorruptFile) }
                code = mapping
                if let value = document.nintendo {
                    guard let map = ControllerFaceMapping(code: value) else { throw CocoaError(.fileReadCorruptFile) }
                    nintendo = map
                }
            default: throw CocoaError(.fileReadCorruptFile)
            }
            guard let mapping = ControllerFaceMapping(code: code) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sharedMapping = mapping; nintendoMapping = nintendo
        } catch { problem = error.localizedDescription }
    }
    func mapping(for family: ControllerFaceFamily) -> ControllerFaceMapping {
        family == .nintendo ? nintendoMapping : sharedMapping
    }
    func set(_ mapping: ControllerFaceMapping?, for family: ControllerFaceFamily) {
        let next = mapping ?? .identity
        let shared = family == .nintendo ? sharedMapping : next, nintendo = family == .nintendo ? next : nintendoMapping
        do {
            let data = try JSONEncoder().encode(Document(mapping: shared.code, nintendo: nintendo == .identity ? nil : nintendo.code))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            sharedMapping = shared; nintendoMapping = nintendo; problem = nil
            if fileURL == PlayerAssignment.orderFileURL.deletingPathExtension().appendingPathExtension("face.json") {
                DistributedNotificationCenter.default().postNotificationName(.init("org.s2arm.controller-face-map.changed"), object: nil,
                    userInfo: nil, deliverImmediately: true)
            }
        } catch { problem = error.localizedDescription }
    }
}

extension PlayerAssignment {
    /// The assignment, rather than the last device to produce input, owns hints.
    func primarySystem(in pads: [GCController]) -> GCController? {
        guard let unit = slots.first ?? nil else { return units.isEmpty ? pads.first : nil }
        guard case let .system(name, index) = unit else { return nil }
        let matches = pads.filter { ($0.vendorName ?? $0.productCategory) == name }
        return matches.indices.contains(index) ? matches[index] : nil
    }
    func primaryPad(in pads: [SystemControllers.Pad]) -> SystemControllers.Pad? {
        pad(forPlayer: 0, in: pads)
    }
    func pad(forPlayer player: Int, in pads: [SystemControllers.Pad]) -> SystemControllers.Pad? {
        guard !units.isEmpty else { return pads.indices.contains(player) ? pads[player] : nil }
        guard slots.indices.contains(player), let unit = slots[player] else { return nil }
        guard case let .system(name, index) = unit else { return nil }
        let matches = pads.filter { $0.name == name }
        return matches.indices.contains(index) ? matches[index] : nil
    }
    var primaryIsNintendo: Bool { isNintendo(player: 0) }
    func isNintendo(player: Int) -> Bool {
        guard slots.indices.contains(player), let unit = slots[player] else { return false }
        switch unit { case .pair, .single, .whole, .gen1, .gen1Pair: return true; default: return false }
    }
}
