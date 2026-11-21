// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Darwin

/// 手机上 S2Arm 占了多少、花在哪（设置 →「存储」，#1606 存储总览）：只读整个沙盒（不含签名的 App 包本身），按类别累计，不删任何东西。
///   目录描述符 + O_NOFOLLOW 遍历：不顺着链接走进别处；不读文件内容。硬链接只算一次实际占用（一款一份资源：Mac 运行版本与 iPhone 资源包共用块）。
///   分类按宿主的真实位置（S2ArmShellHostModel.packGamesRoot / runtime/include/s2a_docs.h）：
///     资源包 <家>/Library/Application Support/S2Arm/games/<号>/资源包（备用位置 Library/S2Arm/games，旧位置 Documents/games/<号>/资源包）、
///     程序包 同目录 program/、存档 Documents/games/<号>/S2A 与 SaveData*、正在后台删的 Documents/games/.deleting。
public struct S2ArmStorage: Sendable {
    public struct Item: Identifiable, Sendable, Equatable {
        public var id: String
        public var logicalBytes: UInt64 = 0
        public var allocatedBytes: UInt64 = 0
        public var files: UInt64 = 0
    }
    public struct Report: Sendable, Equatable {
        public var items: [Item]
        public var incomplete: Bool
        public var logicalBytes: UInt64 { items.reduce(0) { $0 + $1.logicalBytes } }
        public var allocatedBytes: UInt64 { items.reduce(0) { $0 + $1.allocatedBytes } }
    }
    public static let liveRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    /// 相对沙盒根的路径 → 类别：game:<号>（资源包、程序包、这款的其余文件）、save:<号>（存档）、upload:<号>（正在推进来、还没解开的）、
    ///   deleting（后台正在删）、cache、application（其余 Library）、systemTemporary（tmp）、trash、documentsOther、other。只是记账标签，不是删除依据
    static func category(_ path: [String]) -> String {
        guard let first = path.first else { return "other" }
        let rest = Array(path.dropFirst())
        if first == "tmp" { return "systemTemporary" }
        if first == "Library" {
            if rest.first == "Caches" { return "cache" }
            for base in [["Application Support", "S2Arm", "games"], ["S2Arm", "games"]] where rest.starts(with: base) && rest.count > base.count + 1 {
                return packCategory(Array(rest.dropFirst(base.count)))
            }
            return "application"
        }
        guard first == "Documents" else { return "other" }
        if rest.first == ".Trash" { return "trash" }
        guard rest.first == "games", rest.count >= 3 else { return "documentsOther" }
        let gid = rest[1]
        if gid == ".deleting" { return "deleting" }
        let inside = Array(rest.dropFirst(2))
        if inside.first == "资源包" { return packCategory(Array(rest.dropFirst())) }
        if inside.first == "S2A" || inside.first?.hasPrefix("SaveData") == true { return "save:\(gid)" }
        return "game:\(gid)"
    }
    /// <号>/… 在资源包所在的游戏目录里：.incoming 是推进来还没解开的，其余（资源包、程序包）算这款的游戏数据
    private static func packCategory(_ path: [String]) -> String {
        let gid = path[0]
        return path.dropFirst().starts(with: ["资源包", ".incoming"]) ? "upload:\(gid)" : "game:\(gid)"
    }

    /// 「存储」页的行：每款合成一行（游戏数据、存档、推送中分开记），按总占用从大到小；其余类别各一行，同样从大到小
    public struct GameRow: Identifiable, Sendable, Equatable { public let id: String; public var game: UInt64 = 0, saves: UInt64 = 0, incoming: UInt64 = 0 }

    /// 每款合成一行（按游戏数据 + 存档 + 推送中 从大到小），其余类别各一行
    public static func rows(_ report: S2ArmStorage.Report) -> (games: [GameRow], others: [Item]) {
        var games: [String: GameRow] = [:]
        var others: [Item] = []
        for item in report.items {
            let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { others.append(item); continue }
            var row = games[parts[1]] ?? GameRow(id: parts[1])
            switch parts[0] {
            case "save": row.saves += item.allocatedBytes
            case "upload": row.incoming += item.allocatedBytes
            default: row.game += item.allocatedBytes
            }
            games[parts[1]] = row
        }
        return (games.values.sorted { ($0.game + $0.saves + $0.incoming, $1.id) > ($1.game + $1.saves + $1.incoming, $0.id) },
                others.sorted { $0.allocatedBytes > $1.allocatedBytes })
    }
    /// 整个沙盒（root 一般是 liveRoot）。读不了的目录跳过、记 incomplete（界面说「有的目录没算进来」），不中断
    public static func scan(root: URL, cancelled: @Sendable () -> Bool = { false }) throws -> Report {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var items: [String: Item] = [:]
        var seen: Set<String> = []
        var incomplete = false
        func walk(_ directory: Int32, _ path: [String], _ depth: Int) {
            if cancelled() || depth > 128 { incomplete = true; return }
            let copy = dup(directory)
            guard copy >= 0 else { incomplete = true; return }
            guard let stream = fdopendir(copy) else { close(copy); incomplete = true; return }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { incomplete = true }; break }
                if cancelled() { incomplete = true; return }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
                let type = info.st_mode & S_IFMT
                let next = path + [name]
                if type == S_IFDIR {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { incomplete = true; continue }
                    walk(child, next, depth + 1)
                    close(child)
                } else if type == S_IFREG {
                    let key = category(next)
                    var item = items[key] ?? Item(id: key)
                    item.files += 1
                    item.logicalBytes += UInt64(max(0, info.st_size))
                    if seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                        item.allocatedBytes += UInt64(max(0, info.st_blocks)) * 512
                    }
                    items[key] = item
                }   // 链接、设备文件等：不算占用，也不顺着走
            }
        }
        walk(fd, [], 0)
        return Report(items: items.values.sorted { $0.id < $1.id }, incomplete: incomplete)
    }
}
