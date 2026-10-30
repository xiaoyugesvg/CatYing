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
        // ⚠️ 有歌在播就必须把音频会话切到「独占」模式，否则控制中心/锁屏
        //    根本不会显示这份元数据（根因见 BackgroundAudio.exclusiveMode）
        syncSessionMode(exclusive: true)
        if let playing = args["playing"] as? Bool {
            setPlaybackState(playing)
        }
    }

    // MARK: - 音频会话模式

    /// 让系统承认「本 App 是 Now Playing 所有者」。
    ///
    /// 三件事缺一不可（2026-10-30 用户报「控制中心/锁屏看不到音乐」后补）：
    ///   ① `AVAudioSession` 切成 `.playback` **且不带** `.mixWithOthers`
    ///      —— 混音模式下 iOS 视本 App 为次要音频源，元数据一律不显示
    ///   ② `setActive(true)` —— 会话没激活等于没在放
    ///   ③ `beginReceivingRemoteControlEvents()` —— 老 API，但部分系统版本
    ///      上不调它锁屏的播放/暂停按键收不到
    ///
    /// 清空播放时（[clearNowPlaying]）必须切回混音：静音保活要靠混音才能
    /// 和用户正在听的其它 App 共存。
    private func syncSessionMode(exclusive: Bool) {
        BackgroundAudio.shared.setExclusive(exclusive)
        if exclusive {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } else {
            UIApplication.shared.endReceivingRemoteControlEvents()
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
        // 没歌了 → 回到混音模式，让静音保活能和外部音频共存
        syncSessionMode(exclusive: false)
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

// =============================================================================
// TtsNowPlaying —— 听书（TTS）的锁屏 / 控制中心控制
// -----------------------------------------------------------------------------
// 与上面的 MusicNowPlaying 同款做法（系统公开 API，不新增三方依赖）：
//   ① MPNowPlayingInfoCenter —— 锁屏显示书名、章节、播放/暂停
//   ② MPRemoteCommandCenter  —— 播放 / 暂停 / 上一句 / 下一句 / 停止
//
// ⚠️ 为什么**写在同一个文件里**而不是新建 Swift 文件：
//   本项目是 TrollStore 侧载，新增 Swift 源文件必须改 Xcode 工程（pbxproj）
//   才会被编译；写进已编译的文件里可以零工程改动上线。
//
// ⚠️ 与音乐共用系统级 MPRemoteCommandCenter：
//   本类只在 activate() 注册自己的 target，deactivate() 只移除**自己**的
//   target（保存 addTarget 返回的 token，不用 removeTarget(nil)，避免误删
//   音乐的 handler）。若音乐与听书同时活跃，系统按键会同时送达两边 —— 已知边界。
// =============================================================================

@objc class TtsNowPlaying: NSObject {

    @objc static let shared = TtsNowPlaying()

    private static let channelName = "tvbox/tts_now_playing"

    private var channel: FlutterMethodChannel?
    private var active = false

    /// addTarget 返回的 token；deactivate 时只移除这些
    private var targets: [(MPRemoteCommand, Any)] = []

    @objc func register(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = ch
        NSLog("[TtsNowPlaying] registered (channel=\(Self.channelName))")
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "activate":
            activate()
            result(nil)
        case "deactivate":
            deactivate()
            result(nil)
        case "update":
            update(args)
            result(nil)
        case "setPlaying":
            setPlaying(args["playing"] as? Bool ?? false)
            result(nil)
        case "clear":
            clear()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 元数据

    private func update(_ args: [String: Any]) {
        var info: [String: Any] = [:]
        if let title = args["title"] as? String, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let subtitle = args["subtitle"] as? String, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let duration = args["duration"] as? Int, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration)
        }
        if let position = args["position"] as? Int, position >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(position)
        }
        let playing = args["playing"] as? Bool ?? false
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // 听书同音乐：不切独占会话，锁屏/控制中心不显示（同 MusicNowPlaying）
        BackgroundAudio.shared.setExclusive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setPlaying(playing)
    }

    private func setPlaying(_ playing: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        if var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
            center.nowPlayingInfo = info
        }
        if #available(iOS 13.0, *) {
            center.playbackState = playing ? .playing : .paused
        }
    }

    private func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        BackgroundAudio.shared.setExclusive(false)
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    // MARK: - 远程命令

    private func activate() {
        guard !active else { return }
        active = true
        registerCommands()
    }

    private func deactivate() {
        guard active else { return }
        active = false
        for (cmd, token) in targets {
            cmd.removeTarget(token)
        }
        targets.removeAll()
        clear()
        NSLog("[TtsNowPlaying] deactivated")
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        append(c.playCommand, c.playCommand.addTarget { [weak self] _ in
            self?.send("play")
            return .success
        })

        c.pauseCommand.isEnabled = true
        append(c.pauseCommand, c.pauseCommand.addTarget { [weak self] _ in
            self?.send("pause")
            return .success
        })

        c.togglePlayPauseCommand.isEnabled = true
        append(c.togglePlayPauseCommand, c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.send("toggle")
            return .success
        })

        c.nextTrackCommand.isEnabled = true
        append(c.nextTrackCommand, c.nextTrackCommand.addTarget { [weak self] _ in
            self?.send("next")
            return .success
        })

        c.previousTrackCommand.isEnabled = true
        append(c.previousTrackCommand, c.previousTrackCommand.addTarget { [weak self] _ in
            self?.send("previous")
            return .success
        })

        c.stopCommand.isEnabled = true
        append(c.stopCommand, c.stopCommand.addTarget { [weak self] _ in
            self?.send("stop")
            return .success
        })

        NSLog("[TtsNowPlaying] remote commands registered")
    }

    private func append(_ cmd: MPRemoteCommand, _ token: Any) {
        targets.append((cmd, token))
    }

    private func send(_ action: String) {
        NSLog("[TtsNowPlaying] remote → \(action)")
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("remote", arguments: ["action": action])
        }
    }
}

// MARK: - 文件导出（系统分享面板）

/// 把已下载到沙盒的文件交给 iOS 系统分享面板（存到「文件」/ AirDrop / 其他 App）。
///
/// ⚠️ 故意写进**已编译**的 `MusicNowPlaying.swift`，而不是新建 Swift 文件：
///    TrollStore 侧载工程不跑 `pod install`，新增 Swift 文件必须改 `project.pbxproj`
///    才会参与编译；写进既有文件可零工程改动生效（与 `TtsNowPlaying` 同款原因）。
@objc class FileExport: NSObject {
    @objc static let shared = FileExport()

    private static let channelName = "tvbox/file_export"
    private var channel: FlutterMethodChannel?

    @objc func register(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            guard call.method == "share" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let paths = (args["paths"] as? [String]) ?? []
            self?.share(paths: paths, result: result)
        }
        channel = ch
        NSLog("[FileExport] registered (channel=\(Self.channelName))")
    }

    private func share(paths: [String], result: @escaping FlutterResult) {
        let urls = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            result(false)
            return
        }
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                result(false)
                return
            }
            // 找到栈顶控制器（可能正开着 Flutter 弹窗）
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            // iPad 必须给 popover 锚点，否则直接崩
            if let pop = vc.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(
                    x: top.view.bounds.midX,
                    y: top.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                pop.permittedArrowDirections = []
            }
            top.present(vc, animated: true) {
                result(true)
            }
        }
    }
}
