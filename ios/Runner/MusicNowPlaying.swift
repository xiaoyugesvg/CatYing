// MusicNowPlaying.swift
// 锁屏 / 控制中心 / 耳机按键 的**系统媒体控制**接入
// -----------------------------------------------------------------------------
// 用户 2026 要求：「苹果系统层次不能控制呢？没有实时活动功能？不能在控制中心控制？」
//
// 原状：全项目 **0 处** `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`
//   → 锁屏和控制中心**完全看不到音乐**，也没法控制 ✗
//
// 本文件补上两件事（**都用系统公开 API，无需新增任何三方依赖**）：
//   ① `MPNowPlayingInfoCenter` —— 让锁屏/控制中心显示：
//        歌名、歌手、专辑、封面、进度、时长、播放/暂停态
//   ② `MPRemoteCommandCenter` —— 让控制中心/锁屏/耳机按键能：
//        播放、暂停、上一首、下一首、拖动进度
//
// ── 为什么放在**已有**的 `BackgroundAudio` 体系旁边，而不是新建 SDK/插件 ──
// TrollStore 侧载约束：**不能新增原生插件**（会要求 pod install / 改 pbxproj）。
// 所以本文件必须作为 `ios/Runner/` 下的普通 Swift 源文件加入
//（与 `AvEngine.swift` / `NodeJSBridge.swift` / `PipManager.swift` 同一类），
// 由 `AppDelegate` 在引擎初始化时注册 —— 这与项目里既有做法完全一致。
//
// ── ⚠️ 与 BackgroundAudio（静音保活）的关系（重要）─────────────────────
// `BackgroundAudio` 为了保活会在后台**持续播放静音 buffer**。
// 那会让 iOS 认为"这个 App 一直在放音频"。
// 本文件只负责**写入 nowPlayingInfo**（元数据）并接收远程控制，
// **不碰** 静音 buffer 的播放 —— 两者互不干扰：
//   · 静音 buffer → 维持进程存活（后台不被 SIGKILL）
//   · nowPlayingInfo → 锁屏/控制中心显示什么、按了键做什么
//
// ── ⚠️ 已知边界（如实记录，避免以后被当成 bug）────────────────────────
//   · iOS 的 `MPNowPlayingInfoCenter` **只在"系统认为有音频 App 在播放"时
//     才在锁屏/控制中心露出内容**。侧载（TrollStore）+ 后台进程的场景下
//     iOS 的策略比 App Store 包更保守，所以**不保证一定显示**。
//   · 远程控制**回调**能否送达，同样取决于 iOS 是否把本 App 视为
//     "当前音频焦点持有者"。`MPRemoteCommandCenter` 的 handler 一旦注册，
//     系统就会在用户按键时调用 —— 但如果媒体_kit 与静音引擎的
//     AVAudioSession 互相抢占，可能出现"按了没反应"。
//     这种情况下用 `debugState()` 看日志里 `canPlay=true` 之类即可判断。
//   · **灵动岛 / 实时活动（Live Activities / Dynamic Island）**：
//     需要 `ActivityKit` + 一个独立的 **Widget Extension target**
//     （`NSSupportsLiveActivities` + `ActivityAttributes` + UI），
//     **不是** 加一个 Swift 文件就能做到的，必须动 Xcode 工程结构。
//     本文件**不包含**它（见类末尾 `liveActivitiesSupported` 的说明）。

import Foundation
import MediaPlayer
import UIKit

/// 锁屏 / 控制中心 媒体控制
@objc class MusicNowPlaying: NSObject {

    @objc static let shared = MusicNowPlaying()

    private static let channelName = "tvbox/music_now_playing"

    private var channel: FlutterMethodChannel?
    private var commandsRegistered = false

    /// 由 `AppDelegate` 在引擎初始化时调用（与 `PipManager.shared.register` 同款）
    @objc func register(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = ch
        registerRemoteCommands()
        NSLog("[MusicNowPlaying] registered (channel=\(Self.channelName))")
    }

    // MARK: - Flutter → Native

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {

        case "update":
            updateNowPlaying(args)
            result(nil)

        case "setPlaying":
            // 只改播放态，不重建整份 info（避免封面闪一下）
            let playing = args["playing"] as? Bool ?? false
            setPlaybackState(playing)
            result(nil)

        case "clear":
            clearNowPlaying()
            result(nil)

        case "debugState":
            // 排查用：把系统当前认知的状态回给 Dart（写日志）
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info["_rate"] = MPNowPlayingInfoCenter.default().playbackState.rawValue
            result([
                "hasInfo": !(MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]).isEmpty,
                "playbackState": MPNowPlayingInfoCenter.default().playbackState.rawValue,
                "commandsRegistered": commandsRegistered,
            ])

        case "liveActivitiesSupported":
            // 灵动岛/实时活动需要 Widget Extension target，本文件没做
            result(false)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func updateNowPlaying(_ args: [String: Any]) {
        var info: [String: Any] = [:]

        if let title = args["title"] as? String, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist = args["artist"] as? String, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = args["album"] as? String, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        // 时长（秒）
        if let duration = args["duration"] as? Double, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // 当前进度（秒）
        if let position = args["position"] as? Double, position >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        // 播放速率：1.0 = 在播，0.0 = 暂停
        // ⚠️ 这个字段决定锁屏上显示"播放"还是"暂停"按钮
        if let playing = args["playing"] as? Bool {
            info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        }
        info[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue

        // ── 封面 ──────────────────────────────────────────────────────
        // Dart 侧把封面**下载好并以字节**传过来（而不是传 URL）：
        //   · 锁屏要的是 `MPMediaItemArtwork`（UIImage）
        //   · 让 Dart 下载可以复用 App 里已有的图片缓存与请求头
        //     （很多音源封面要 UA/Referer，原生直接 GET 会 403）
        if let bytes = args["artwork"] as? FlutterStandardTypedData,
           let image = UIImage(data: bytes.data) {
            // `requestHandler` 让系统在需要不同尺寸时自行缩放
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let playing = args["playing"] as? Bool {
            setPlaybackState(playing)
        }
    }

    private func setPlaybackState(_ playing: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        if var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
            center.nowPlayingInfo = info
        }
        // iOS 13+：显式告知系统"在播/暂停"，锁屏按钮图标依赖它
        if #available(iOS 13.0, *) {
            center.playbackState = playing ? .playing : .paused
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        NSLog("[MusicNowPlaying] cleared")
    }

    // MARK: - 远程控制 → Flutter

    private func registerRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let c = MPRemoteCommandCenter.shared()

        // 播放
        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            self?.send("play")
            return .success
        }
        // 暂停
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in
            self?.send("pause")
            return .success
        }
        // 播放/暂停（耳机单击、控制中心那个大按钮）
        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.send("toggle")
            return .success
        }
        // 上一首 / 下一首
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.send("previous")
            return .success
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.send("next")
            return .success
        }
        // 拖动进度条
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.send("seek", extra: ["position": e.positionTime])
            return .success
        }

        NSLog("[MusicNowPlaying] remote commands registered")
    }

    private func send(_ action: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["action": action]
        payload.merge(extra) { _, new in new }
        NSLog("[MusicNowPlaying] remote → \(action)")
        // ⚠️ 必须在**主线程**回调（`channel.invokeMethod` 要求）
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("remote", arguments: payload)
        }
    }
}
