// swift-tools-version: 6.0
import PackageDescription

/// 依赖都在仓库里现成编好的：
/// - `core/target/release/libdvplayer_media.dylib`：共享媒体核心（Rust，C ABI）
/// - `prefix-vk/bin/mpv`：gpu-next + Vulkan 的 mpv，**以子进程方式运行**，不在编译期链接
///   （macOS 上只有 mpv 自己的窗口能走 gpu-next，Dolby Vision 整形也在这里）
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

        // 壳。
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
