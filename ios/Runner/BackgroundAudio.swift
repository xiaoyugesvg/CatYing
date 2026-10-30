// BackgroundAudio.swift
// iOS Background Audio 模式 - 让 Node.js 进程在 app 后台 / 锁屏时不被 iOS SIGKILL
// -----------------------------------------------------------------------------
// **方案 A (2026-07-08)**:
//   原理: 在 app 启动时激活 AVAudioSession + 用 AVAudioEngine 持续播放
//   静音 buffer. iOS 检测到 app 在播放 audio, 维持 app 在 active 状态,
//   不会因为进入后台或锁屏而杀 embed library (Node.js 进程).
//
//   这是 Apple 官方允许的 background mode 之一 (Info.plist UIBackgroundModes
//   包含 'audio'). iOS 把 app 当作"audio app"对待, 保持后台运行.
//
//   副作用:
//     - 锁屏时 control center / status bar 会显示 app 正在播放 audio
//     - 持续播放约 30 分钟后 iOS 17+ 可能会向用户发提示 (本地巨魔安装不受影响)
//     - 极小 CPU 电量消耗 (纯静音 buffer 调度)
//
// **iOS SIGKILL 场景的根因**:
//   iOS 17+ 在 app 长时间 (7-8 分钟) 后台后会 SIGKILL embed library (Node.js 进程).
//   此时 Swift `node_start` 阻塞不返回 + isRunning 卡 true + onNodeExit 不发.
//   用 background audio 模式, app 不会被 iOS 当作"已挂起", 进程继续运行.
//   Node.js 的 V8 isolate + uv loop + listen socket 都活着, 切回前台时
//   数据还在.
//
// **实现**:
//   - AVAudioSession .playback category (不请求 microphone 权限)
//   - AVAudioEngine 持续 schedule 静音 PCM buffer (loops)
//   - 在 app 进入后台 / 锁屏前再次激活 session (保险)
//   - 在 app 回前台时也保持播放 (避免被 iOS 重新评估)

import Foundation
import AVFoundation
import UIKit

class BackgroundAudio {

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isStarted = false
    private let queue = DispatchQueue(label: "com.tvbox.background-audio")

    /// **本 App 是否在"独占播放"模式**（音乐/听书正在放）。
    ///
    /// ── 为什么需要这个开关（2026-10-30 修）──────────────────────────
    /// 用户原话：「音乐模块的播放不能在 iOS 的下拉控制中心播放？还不能在
    /// 锁屏页面播放么？」
    ///
    /// 根因就出在下面 `startLocked()` 里的 `.mixWithOthers`：
    /// 带这个选项时 iOS 把本 App 当**次要音频源**，
    /// `MPNowPlayingInfoCenter` 写进去的元数据**一律不显示**在控制中心/锁屏
    /// —— 于是 `MusicNowPlaying.swift` 那套「推歌名/封面/接远程按键」的代码
    /// 一直在跑，却永远看不见效果 ✗。
    ///
    /// 所以：有音乐在播时切到**不带 mix 的 `.playback`**（成为 Now Playing
    /// 所有者，控制中心才认），音乐清空后切回混音（不抢别人音频焦点，
    /// 静音保活继续跑）✓。
    private var exclusiveMode = false

    static let shared = BackgroundAudio()

    private init() {}

    /// 启动 silent audio playback.
    /// **按需保活**：仅在 Node 已启动 / 需要后台运行时调用，
    /// 避免始终占用 audio session、与其它播放器冲突、空耗电。
    func start() {
        // ⚠️ 整段包 TvBoxTryCatch，这是**加载源闪退**的最后一道防线。
        //
        // 调用链：NodeJSBridge.startNodeJS（主线程）→ start()。
        // startLocked() 里的 AVAudioEngine.attach/connect/start 与
        // player.play() 在音频会话状态不合法时抛 **Objective-C 异常**；
        // 下面 do{}catch 只能接 Swift 错误，接不住 ObjC 异常 →
        // 冒泡到 std::terminate → abort()（SIGABRT）→ App 闪退。
        //
        // 兜住之后，保活启动失败只会记一行日志，App 照常运行。
        if !TvBoxTryCatch({ self.queue.sync { self.startLocked() } }) {
            NSLog("[BackgroundAudio] ⚠️ start 抛 Objective-C 异常，保活跳过（App 继续运行）")
        }
    }

    /// 真正的启动实现。
    ///
    /// ⚠️ 必须**在 queue 上调用**（内部不再自己 sync）。
    /// 拆出来是为了让中断恢复路径能直接复用：原来 resume 里若调 start()，
    /// 而 start() 内部又 queue.sync，就会在串行队列上自我等待 → 死锁。
    private func startLocked() {
        if isStarted {
            NSLog("[BackgroundAudio] already started, skip")
            return
        }

        do {
            // 1. 配置 audio session - playback category
            let session = AVAudioSession.sharedInstance()
            // ⚠️ 必须带 `.mixWithOthers`（2026-10-14 修）：
            //   原来这里是 `options: []`，注释写"我们是唯一 audio source" ——
            //   **这个前提是错的**：用户很可能正戴着耳机听 Apple Music / 播客。
            //   非混音的 `.playback` 一旦 setActive，系统会把**其它 App 的音频
            //   中断掉**，而我们这边循环播放的是**静音** buffer ⇒ 用户看到的是
            //   "外部音乐莫名停了，本 App 却一点声音都没有" ✗✗。
            //   加上 `.mixWithOthers` 后：本 App 依然被系统视为"正在播放音频"
            //   （后台保活效果不变），但**不抢占音频焦点**，外部音乐照常播 ✓。
            //
            // ⚠️ 但混音模式下**控制中心/锁屏永远看不到本 App 的正在播放**
            //   （见 `exclusiveMode` 的说明）⇒ 音乐在播时必须切到独占模式。
            try Self.applyCategoryLocked(exclusive: self.exclusiveMode)
            try session.setActive(true, options: [])
            NSLog("[BackgroundAudio] AVAudioSession activated (.playback, exclusive=\(self.exclusiveMode))")

            // 2. 创建静音 buffer
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 22050,
                channels: 1
            ) else {
                NSLog("[BackgroundAudio] ❌ failed to create AVAudioFormat")
                return
            }

            let frameCapacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                NSLog("[BackgroundAudio] ❌ failed to create PCM buffer")
                return
            }
            buffer.frameLength = frameCapacity
            // buffer 默认全是 0 (静音), 不需要 fill

            // 3. Attach + connect + start engine
            audioEngine.attach(player)
            audioEngine.connect(
                player,
                to: audioEngine.mainMixerNode,
                format: format
            )
            try audioEngine.start()
            NSLog("[BackgroundAudio] AVAudioEngine started")

            // 4. Schedule buffer 循环播放
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: .loops,
                completionHandler: nil
            )
            // 启动播放：这是保活的起点（静音 buffer 循环）
            //
            // ⚠️ 必须包 TvBoxTryCatch：AVAudioPlayerNode.play() 在会话状态
            // 不合法时会抛 Objective-C 异常，Swift catch 不到 → SIGABRT。
            if TvBoxTryCatch({ self.player.play() }) {
                NSLog("[BackgroundAudio] player.play() called, looping silent buffer")
            } else {
                NSLog("[BackgroundAudio] ⚠️ player.play() 抛异常，本次保活跳过（不影响 App）")
            }

            // 5. 监听 interruption (e.g., 来电 / 其它 App 抢音频会话)
            //
            // ⚠️ 先移除再添加：start() 在 stop() 之后可能被再次调用，
            // 重复注册会让同一个通知触发多次 handler。
            NotificationCenter.default.removeObserver(
                self,
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption(_:)),
                name: AVAudioSession.interruptionNotification,
                object: nil
            )

            // 6. 监听 route change (耳机拔掉) - 不需要 stop
            NotificationCenter.default.removeObserver(
                self,
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange(_:)),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )

            isStarted = true
            NSLog("[BackgroundAudio] ✅ silent audio started, app can run in background")
        } catch {
            NSLog("[BackgroundAudio] ❌ start failed: \(error.localizedDescription)")
        }
    }

    /// 配置音频会话类别。
    ///
    /// · `exclusive == true`  → `.playback` **不带** `.mixWithOthers`：
    ///   本 App 成为 Now Playing 所有者，控制中心/锁屏才会显示封面与控件
    /// · `exclusive == false` → 带 `.mixWithOthers`：不抢音频焦点，
    ///   静音保活可以和用户正在听的其它 App 共存
    ///
    /// 静态方法是因为它要在 `startLocked()` 与 [setExclusive] 两处复用。
    private static func applyCategoryLocked(exclusive: Bool) throws {
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: exclusive ? [] : [.mixWithOthers]
        )
    }

    /// 音乐/听书开始或结束播放时调用：切换「独占 / 混音」两种会话模式。
    ///
    /// 由 `MusicNowPlaying` / `TtsNowPlaying` 在收到 Dart 的 `update` 时调用
    /// （见那边 `syncSessionMode` 的注释）。
    ///
    /// ⚠️ 切换类别会打断正在跑的 `AVAudioEngine`（player node 停止），
    /// 所以切完之后必须把静音循环重新播起来，否则 Node 保活会断。
    /// 整个过程包 `TvBoxTryCatch`：`play()` 在会话状态不合法时抛 ObjC 异常，
    /// Swift 的 `catch` 接不住 → SIGABRT 闪退。
    func setExclusive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.exclusiveMode != on else { return }
            self.exclusiveMode = on
            NSLog("[BackgroundAudio] session mode → \(on ? "exclusive" : "mix")")

            let ok = TvBoxTryCatch({
                try Self.applyCategoryLocked(exclusive: on)
                try AVAudioSession.sharedInstance().setActive(true, options: [])

                // 类别切换后引擎可能已经停了：重启再播，别盲目 play()
                if self.isStarted {
                    if !self.audioEngine.isRunning {
                        self.restartEngine()
                    } else if !self.player.isPlaying {
                        self.player.play()
                    }
                }
            })
            if !ok {
                NSLog("[BackgroundAudio] ⚠️ setExclusive 抛异常，已忽略（App 继续运行）")
            }
        }
    }

    /// 停止 (e.g., app 真正退出时)
    func stop() {
        queue.sync {
            guard isStarted else { return }
            // 整段兜住：stop/引擎停止/setActive 在状态不干净时都可能抛 ObjC 异常
            _ = TvBoxTryCatch({
                self.player.stop()
                self.audioEngine.stop()
                // ⚠️ 2026-10-14：这里**不再** `setActive(false, ...)`。
                //   `AVAudioSession` 是**进程级单例** —— 影视/音乐播放器用的是
                //   同一个 session。保活音频停止时把整个 session deactivate，
                //   会连带把用户正在听的**本 App 播放器一起静音/暂停** ✗。
                //   而且 `.notifyOthersOnDeactivation` 的语义是"我是唯一
                //   audio source、我要让位"，与事实不符（通常还有外部音乐 App）。
                //   停掉我们自己的 engine 就够了：没有音频输出时 iOS 会自行把
                //   App 挂起，不需要、也不该由这里关掉全局音频会话 ✓。
            })
            isStarted = false
            NSLog("[BackgroundAudio] stopped")
        }
    }

    /// app 进入后台前再次激活 session (保险)
    /// iOS 在某些情况下会 deactivate audio session, 重新激活以确保保持
    @objc func appWillResignActive() {
        NSLog("[BackgroundAudio] app will resign active, re-activate session")
        _ = TvBoxTryCatch({
            try? AVAudioSession.sharedInstance().setActive(true)
        })
    }

    @objc func appDidEnterBackground() {
        NSLog("[BackgroundAudio] app did enter background, ensure audio playing")
        // ⚠️ 不能只判断 isPlaying 就 play()：
        // 引擎被系统停掉时 player.isPlaying 也是 false，此时 play() 会抛
        // ObjC 异常（Swift catch 不到）→ SIGABRT 闪退，与中断路径是同一个坑。
        // 统一走 resumeSilently()：它会先校验会话与引擎状态，必要时重启引擎。
        if isStarted {
            resumeSilently()
        } else {
            _ = TvBoxTryCatch({
                try? AVAudioSession.sharedInstance().setActive(true)
            })
        }
    }

    @objc func appWillEnterForeground() {
        NSLog("[BackgroundAudio] app will enter foreground, re-activate session")
        _ = TvBoxTryCatch({
            try? AVAudioSession.sharedInstance().setActive(true)
        })
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            NSLog("[BackgroundAudio] interruption began, pause")
            _ = TvBoxTryCatch({ self.player.pause() })
        case .ended:
            // ⚠️⚠️ 这里是**闪退根因**，改动必须谨慎：
            //
            // 旧写法：
            //     try? session.setActive(true)   // try? 把失败静默吞掉
            //     player.play()                  // 会话没激活成功时直接崩
            //
            // `-[AVAudioPlayerNode play]` 在音频会话未激活时会抛
            // **Objective-C 异常**（AVAE_RaiseException），而 Swift 无法 catch
            // ObjC 异常 → 进程直接 SIGABRT（崩溃日志：Abort trap: 6，
            // 栈顶就是 BackgroundAudio.handleInterruption → player.play）。
            //
            // 触发条件很常见：来电结束、其它 App 抢走音频会话、
            // 新加的 TTS 朗读会重设 session 类别/模式 —— 都会发这个通知。
            //
            // 正确做法：**恢复播放前逐项验证状态**，任何一项不满足就重新
            // 走一遍完整的启动流程，绝不盲目 play()。
            NSLog("[BackgroundAudio] interruption ended, resume carefully")
            resumeSilently()
        @unknown default:
            break
        }
    }

    /// 中断结束后恢复静音保活。
    ///
    /// 宁可"这次不恢复"，也不能因为 play() 抛异常把 App 带崩 ——
    /// 后台保活失败只是 Node 可能被挂起，崩了则整个 App 直接退出。
    private func resumeSilently() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isStarted else {
                NSLog("[BackgroundAudio] resume skipped: not started")
                return
            }

            // ⚠️ 整个恢复过程都包在 ObjC 异常保护里，理由：
            //   · setActive / play / audioEngine 这一串都可能抛 ObjC 异常
            //   · restartEngine() → startLocked() 内部同样可能抛
            //     （attach/connect/start 全在引擎状态不干净时执行）
            //   · 这个 block 跑在 GCD 队列上，抛出去同样是 SIGABRT
            // 任何一步失败都只是"这次没恢复保活"，绝不影响 App 存活。
            let ok = TvBoxTryCatch({
                let session = AVAudioSession.sharedInstance()
                // 先确保会话可用；失败就重启引擎
                do {
                    try session.setActive(true, options: [])
                } catch {
                    NSLog("[BackgroundAudio] resume: setActive failed, restart engine — \(error.localizedDescription)")
                    self.restartEngine()
                    return
                }

                // 引擎被系统停掉时必须重启，否则 play() 同样会抛异常
                if !self.audioEngine.isRunning {
                    NSLog("[BackgroundAudio] resume: engine not running, restart")
                    self.restartEngine()
                    return
                }

                self.player.play()
                NSLog("[BackgroundAudio] resume: silent audio resumed")
            })

            if !ok {
                NSLog("[BackgroundAudio] ⚠️ resume 抛异常，已忽略（App 继续运行）")
            }
        }
    }

    /// 兜底：按 start() 的完整流程重建（不依赖旧的 engine/player 状态）
    ///
    /// 注意：调用方需自行保证异常被兜住（见 resumeSilently）。
    private func restartEngine() {
        // 复位状态后复用 startLocked()：已在 queue 上，不能调 start()（会死锁）
        isStarted = false
        startLocked()
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // route change（拔耳机/切蓝牙）不需要 stop，但要重新激活 session。
        // 同样不能裸调 play()：会话/引擎状态可能已被系统改变，
        // 走 resumeSilently() 里的逐项校验 + 必要时重启引擎。
        NSLog("[BackgroundAudio] route changed, re-check playback")
        resumeSilently()
    }
}
