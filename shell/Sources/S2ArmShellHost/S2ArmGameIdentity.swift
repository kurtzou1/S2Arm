import Foundation
import ShellUI
#if canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit
#endif

/// 这台 iPhone 上玩家给某款游戏改的显示名和封面（Documents/games/<游戏号>/identity.json + 它指向的封面文件）。
/// 只改显示；优先于电脑端写进包里的名字和封面，重装 App 后还在。
/// 名字和封面一次提交：identity.json 记名字和封面文件名，原子写它就是提交点（见 save）。
public struct GameIdentity: Equatable {
    public var name: String
    public var cover: URL?
}

public struct GameIdentityStore {
    public var root: URL
    public init(root: URL) { self.root = root }
    public static var live: GameIdentityStore {
        let env = ProcessInfo.processInfo.environment["S2A_SHELL_DOCS"]   // 只给单测
        let docs = env.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return GameIdentityStore(root: docs)
    }
    private func folder(_ id: String) -> URL { root.appendingPathComponent("games", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    private func record(_ id: String) -> URL { folder(id).appendingPathComponent("identity.json") }
    /// 早先版本的封面固定叫这个名字、identity.json 里不记文件名
    private static let legacyCover = "identity-cover.jpg"

    private func saved(_ id: String) -> [String: Any]? {
        (try? Data(contentsOf: record(id))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    /// 当前生效的封面文件名：identity.json 记的；没记（早先版本）就是固定名
    private func coverName(_ id: String, _ saved: [String: Any]?) -> String? {
        let name = (saved?["cover"] as? String) ?? Self.legacyCover
        return FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(name).path) ? name : nil
    }

    public func load(_ id: String) -> GameIdentity? {
        let saved = saved(id)
        let name = (saved?["name"] as? String) ?? ""
        let cover = coverName(id, saved).map { folder(id).appendingPathComponent($0) }
        return name.isEmpty && cover == nil ? nil : GameIdentity(name: name, cover: cover)
    }

    /// name 去掉首尾空白后为空 = 用默认名；cover 为 nil = 不动封面。
    /// 名字和封面一起生效或都不生效：新封面先写成新文件名（失败什么都没变）→ 原子写 identity.json 指向它（提交点，失败删掉新封面、旧的原样）
    /// → 提交后才删旧封面。抛错时这台手机上的名字和封面仍是上一次的。
    public func save(_ id: String, name: String, cover: Data?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)   // 不截长度（11-13 不许堵门：原先悄悄截到 64 字）
        let old = coverName(id, saved(id))
        var record: [String: Any] = ["name": trimmed]
        var staged: URL?
        if let cover {
            let file = "identity-cover-" + UUID().uuidString + ".jpg"
            let url = folder(id).appendingPathComponent(file)
            try cover.write(to: url, options: .atomic)
            staged = url; record["cover"] = file
        } else if let old {
            record["cover"] = old
        }
        do { try JSONSerialization.data(withJSONObject: record).write(to: self.record(id), options: .atomic) }
        catch { if let staged { try? fm.removeItem(at: staged) }; throw error }
        if staged != nil, let old { try? fm.removeItem(at: folder(id).appendingPathComponent(old)) }
    }

    public func clear(_ id: String) {
        let fm = FileManager.default
        let covers = (try? fm.contentsOfDirectory(atPath: folder(id).path))?.filter { $0.hasPrefix("identity-cover") } ?? []
        try? fm.removeItem(at: record(id))
        for c in covers { try? fm.removeItem(at: folder(id).appendingPathComponent(c)) }
    }
}

#if canImport(UIKit)
/// 改名字和封面的编辑页：盖在库界面上，只用触屏。
struct S2ArmGameIdentityView: View {
    let title: String
    let initialName: String
    let hasCustom: Bool
    /// 上次点保存没存成的原因（非空时编辑页不关、显示在按钮上方）
    var error: String? = nil
    let save: (String, Data?) -> Void
    let reset: () -> Void
    let close: () -> Void
    @State private var name = ""
    @State private var item: PhotosPickerItem?
    @State private var cover: Data?
    @State private var preview: UIImage?
    /// 选的图用不了（读不出 / 不是图片 / 转不成 JPEG）：原先静默不换，现在说清楚（11-13 真失败报真实原因）
    @State private var coverProblem: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                Text(shellText("Name and Cover")).font(.title2.weight(.heavy)).foregroundStyle(.white).accessibilityIdentifier("identity.title")
                TextField(title, text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("identity.name")
                HStack(spacing: 14) {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFill().frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    PhotosPicker(selection: $item, matching: .images) { Text(shellText("Choose Cover from Photos")) }
                        .buttonStyle(.bordered).accessibilityIdentifier("identity.cover")
                }
                if let coverProblem {
                    Text(coverProblem).font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("identity.coverError")
                }
                if let error {
                    Text(shellText("Couldn’t save; the name and cover weren’t changed: \(error)")).font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("identity.error")
                }
                HStack {
                    if hasCustom { Button(shellText("Reset to default"), role: .destructive) { reset() }.accessibilityIdentifier("identity.reset") }
                    Spacer()
                    Button(shellText("Cancel")) { close() }.accessibilityIdentifier("identity.cancel")
                    Button(shellText("Save")) { save(name, cover) }.buttonStyle(.borderedProminent).accessibilityIdentifier("identity.save")
                }
            }
            .padding(24).frame(maxWidth: 480)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .onAppear { name = initialName }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                let problem: String?
                var jpeg: Data?
                do {
                    if let data = try await picked.loadTransferable(type: Data.self) {
                        if let image = UIImage(data: data) {
                            jpeg = Self.coverJPEG(image)
                            problem = jpeg == nil ? shellText("This picture couldn’t be converted for the cover. Try another one.") : nil
                        } else { problem = shellText("This file isn’t a picture the cover can use. Try another one.") }
                    } else { problem = shellText("Photos didn’t hand over this picture. Try another one.") }
                } catch { problem = shellText("Couldn’t read this picture: \(error.localizedDescription)") }
                await MainActor.run {
                    coverProblem = problem
                    if let jpeg { cover = jpeg; preview = UIImage(data: jpeg) }
                }
            }
        }
    }

    /// 长边压到 1280，封面不需要原图那么大。
    private static func coverJPEG(_ image: UIImage) -> Data? {
        let scale = min(1, 1280 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
    }
}
#endif
