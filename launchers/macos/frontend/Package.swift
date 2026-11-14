// swift-tools-version: 6.0
import PackageDescription

// NX2Apple 前端快照（来源、取用与改动见 UPSTREAM.md）。分层同上游 ARCHITECTURE.md：
// NXCore（Foundation）→ NXModel（NXCore）→ NXLauncher（视图与样式）→ NX2AppleUI（上游 app target 里依赖 app 类型的视图，换成 S2Arm 适配层类型）。
// 上游各 target 之间用 package 访问级别；对外（launchers/macos 的 S2ArmApple）只露 NX2AppleUI 的 public 入口。
// 同上游：全部按 Swift 5 语言模式编（上游 Package.swift:5 记的两处并发问题未解）。
let package = Package(
    name: "NX2AppleFrontend",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NX2AppleUI", targets: ["NX2AppleUI"])],
    dependencies: [.package(path: "../adapter"), .package(path: "../../shared/SaveSync")],
    targets: [
        .target(name: "NXCore", path: "Sources/NXCore"),
        .target(name: "NXModel", dependencies: ["NXCore"], path: "Sources/NXModel"),
        .target(name: "NXLauncher", dependencies: ["NXModel", "NXCore"], path: "Sources/NXLauncher"),
        .target(name: "NX2AppleUI",
                dependencies: ["NXLauncher", "NXModel", "NXCore", .product(name: "S2ArmAppleAdapter", package: "adapter"),
                               .product(name: "SaveSync", package: "SaveSync"), "Sparkle"],
                path: "Sources/NX2Apple"),
        // 应用内更新（v0.3.10 维护者拍板：换成业界标准的 Sparkle 2，不再自写换版）：官方 SwiftPM 二进制包原样随仓库放在 Vendor/
        //   （上游 2.10.1 的 Sparkle-for-Swift-Package-Manager.zip，sha256 4c2e48a3…023a，MIT 许可见 Vendor/Sparkle-LICENSE.txt）。
        //   原先按 URL 现下：每个新的出包工作目录都要连 GitHub 下一次，v0.3.10 候选在出包机上卡在下载 14 分钟被停（构建不该依赖网络）。
        //   build_app.py 把 Sparkle.framework 放进 Contents/Frameworks；S2ArmApple 的 rpath 指到那里（launchers/macos/Package.swift）
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle-2.10.1.zip"),
        // 界面语言跟随系统 / 记住选择的单测（tests/launcher_language_test.sh 跑；NXCore 是 package 访问级别，只能在本包里测）
        .testTarget(name: "NXCoreTests", dependencies: ["NXCore"], path: "Tests/NXCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
