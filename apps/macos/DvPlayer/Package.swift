// swift-tools-version: 6.0
import PackageDescription

/// 依赖都在仓库里现成编好的：
/// - `core/target/release/libdvplayer_media.dylib`：共享媒体核心（Rust，C ABI）
/// - `prefix/lib/libmpv.dylib`：**编译期链接**，视频用 render API 画进我们自己的
///   `NSOpenGLView`（单窗口，和 Windows 的 libmpv 嵌入同构）。
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

        // libmpv 的 C 头文件（client / render / render_gl），供 Swift 调用。
        //
        // 头文件在包外（`prefix/include`），SwiftPM 的 `headerSearchPath` 不允许
        // 包外路径，`cSettings` 的 `-I` 又赶不上 module map 解析，所以直接写进
        // 头文件里（见 Sources/MpvC/include/mpv_bridge.h 的说明）。
        .target(name: "MpvC", path: "Sources/MpvC"),

        // 核心绑定 + 数据模型 + 本地配置。
        .target(
            name: "DvCore",
            dependencies: ["DvCoreC"],
            path: "Sources/DvCore",
            linkerSettings: [
                .unsafeFlags(["-L\(repo)/core/target/release", "-ldvplayer_media"]),
            ]
        ),

        // 壳。
        .executableTarget(
            name: "DvPlayer",
            dependencies: ["DvCore", "MpvC"],
            path: "Sources/DvPlayer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-L\(repo)/prefix/lib", "-lmpv"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
