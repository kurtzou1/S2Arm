// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S2ArmLauncher",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "S2ArmLauncher", targets: ["S2ArmLauncher"]),
               // S2Arm × NX2Apple：NX2Apple 派生前端（launchers/macos/frontend）+ S2Arm 适配层（launchers/macos/adapter）。
               // 11-07 起是发版缺省（build_app.py / frontend_layout.py）；旧 S2ArmLauncher 留作回退（S2A_APP_FRONTEND=launcher）。
               .executable(name: "S2ArmApple", targets: ["S2ArmApple"])],
    dependencies: [.package(path: "frontend"), .package(path: "adapter")],
    targets: [
        // 作业层文字的翻译（BackendText：Localizable.json + 共享体验规格）在适配层，新旧前端共用一份
        .executableTarget(name: "S2ArmLauncher",
                          dependencies: [.product(name: "S2ArmAppleAdapter", package: "adapter")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "S2ArmLauncherTests", dependencies: ["S2ArmLauncher"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "S2ArmApple",
                          dependencies: [.product(name: "NX2AppleUI", package: "frontend"),
                                         .product(name: "S2ArmAppleAdapter", package: "adapter")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          // Sparkle.framework 在 App 的 Contents/Frameworks（build_app.py 放进去）
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "S2ArmAppleAdapterTests", dependencies: [.product(name: "S2ArmAppleAdapter", package: "adapter")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        // 新前端的本机控制口命令表（NX2Apple/S2ArmControl.swift，11-07）
        .testTarget(name: "S2ArmAppleTests", dependencies: [.product(name: "NX2AppleUI", package: "frontend"),
                                                            .product(name: "S2ArmAppleAdapter", package: "adapter")],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
