// swift-tools-version: 6.0
import PackageDescription

/// 依赖都在仓库里现成编好的：
/// - `core/target/release/libdvplayer_media.dylib`：共享媒体核心（Rust，C ABI）
/// - `prefix/lib/libmpv.2.dylib`：M0 编的 libmpv（render API 出画）
///
/// 用 `-L` 相对路径而不是绝对路径，换了机器目录也能编。
let repo = "../../.."

let package = Package(
    name: "DvPlayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DvPlayer", targets: ["DvPlayer"]),
    ],
    targets: [
        // C 头文件目标：把 core 的 dv_* 导出声明给 Swift。
        .target(name: "DvCoreC", path: "Sources/DvCoreC"),

        // 核心绑定 + 数据模型 + 本地配置。
        .target(
            name: "DvCore",
            dependencies: ["DvCoreC"],
            path: "Sources/DvCore",
            linkerSettings: [
                .unsafeFlags(["-L\(repo)/core/target/release", "-ldvplayer_media"]),
            ]
        ),

        // 壳。mpv 等播放页落地时再链，先留着 rpath 让 dylib 从 .app 里找。
        .executableTarget(
            name: "DvPlayer",
            dependencies: ["DvCore"],
            path: "Sources/DvPlayer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
