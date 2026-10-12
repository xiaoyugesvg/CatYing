// swift-tools-version: 5.10
// 本地 vendored AetherEngine（源自 superuser404notfound/AetherEngine 上游快照）。
// 与上游的差异：
// 1. 平台下限 iOS 18 → 16（上游本体代码无 17/18 强制 API，仅为包声明门槛；
//    全部 available 注解均为 iOS 26/visionOS 2 可选增强且带降级路径）
// 2. 移除 LibTrueHD 依赖（其 xcframework 平台下限 iOS 18）：
//    删除 Audio/Spatial/TrueHDObjectAudioDecoder.swift，TrueHD Atmos 对象音频
//    渲染路径随之禁用，TrueHD 音轨退化为 FFmpeg 通道桥解码（上游降级语义一致）
// 3. 移除 AetherEngineSMB / aetherctl 目标（SMB 网盘与 CLI 本项目不需要）
import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AetherEngine",
            targets: ["AetherEngine"]
        ),
    ],
    dependencies: [
        // 最小 FFmpeg 构建（avcodec/avformat/avutil/swresample），3.0.0 起
        // 全部符号带 Aether 前缀 + 动态框架，可与 App 内既有 FFmpeg（KSPlayer）共存
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", .upToNextMinor(from: "3.7.0")),
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            path: "Sources/AetherEngine",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
