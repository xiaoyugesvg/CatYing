import AVFoundation
import Flutter
import Photos
import UIKit

/// 语音朗读（TTS）原生实现
///
/// ── 为什么不用 flutter_tts 这类插件 ──────────────────────────────
/// 本 App 是 TrollStore 侧载，iOS 侧只维护 `Podfile.lock` 里已有的那几个
/// 原生库。**新增 pub 依赖若没重新 `pod install`，插件原生库不会被链接**，
/// Flutter 在启动时找不到注册的插件就会直接崩 —— 这正是加 flutter_tts 后
/// "装完就闪退"的原因。
///
/// 而这个功能根本不需要引入新库：iOS 自带 `AVSpeechSynthesizer`，
/// 通过项目已有的原生频道模式暴露给 Flutter 即可（与 AvEngine / PipManager
/// 完全一致的注册方式）。
///
/// ── 职责边界 ──────────────────────────────────────────────────
/// Dart 侧负责"把章节切成段落、逐段驱动、自动连播"；这里只做
/// "念一段 / 停 / 暂停 / 继续"，念完通过 channel 回调通知 Dart。
class TtsEngine: NSObject, AVSpeechSynthesizerDelegate {

  static let shared = TtsEngine()

  private var synth: AVSpeechSynthesizer?
  private var channel: FlutterMethodChannel?

  /// 当前这段话念完/出错的回调（Dart 侧据此念下一段）
  private var onDone: (() -> Void)?

  func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "tts_engine", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "speak":
      let text = args["text"] as? String ?? ""
      let rate = args["rate"] as? Double ?? 0.5
      let pitch = args["pitch"] as? Double ?? 1.0
      speak(text: text, rate: rate, pitch: pitch)
      result(nil)

    case "stop":
      stop()
      result(nil)

    case "pause":
      // pauseSpeaking 返回 Bool：正在念才为 true
      result(synth?.pauseSpeaking(at: .immediate) ?? false)

    case "resume":
      result(synth?.continueSpeaking() ?? false)

    case "isSpeaking":
      result(synth?.isSpeaking ?? false)

    case "available":
      // AVSpeechSynthesizer 是系统能力，恒可用；
      // 但没有中文语音包时会用默认语音念，这里不视为不可用。
      result(true)

    // MARK: 屏幕休眠（阅读设置里的 默认 / 10分钟 / 永不息屏）
    //
    // 「永不息屏」= UIApplication.isIdleTimerDisabled = true。
    // 这里**不需要 wakelock_plus 之类的插件** —— 它是 UIKit 的一个布尔量。
    //
    // ⚠️ 必须提供 allowSleep 让调用方在退出阅读器时**关掉它**，
    // 否则用户离开阅读器后屏幕永远不灭（那是很严重的耗电问题）。
    case "keepAwake":
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = true
      }
      result(true)

    case "allowSleep":
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = false
      }
      result(true)

    // MARK: 电量（阅读器信息栏的「电量」项）
    //
    // UIDevice.batteryLevel 需要先开 isBatteryMonitoringEnabled，
    // 否则恒返回 -1。
    case "battery":
      UIDevice.current.isBatteryMonitoringEnabled = true
      let lvl = UIDevice.current.batteryLevel
      // -1 = 取不到（模拟器/权限），返回 null 让 Dart 显示 "--%"
      result(lvl < 0 ? nil : Int((lvl * 100).rounded()))

    // MARK: 保存图片到相册（图片模式的「保存」）
    //
    // 走系统 Photos 框架，同样不需要插件。
    // Dart 侧已经把图片下载好并以 base64 传进来（避免原生再做一次网络请求，
    // 那样就要处理重定向 / 请求头 / 超时一堆事）。
    //
    // Info.plist 里已有 NSPhotoLibraryUsageDescription
    //（"请允许APP保存图片到相册"），所以首次会正常弹权限框。
    case "saveImage":
      let b64 = args["bytes"] as? String ?? ""
      guard let data = Data(base64Encoded: b64), !data.isEmpty else {
        result(FlutterError(code: "bad_data", message: "图片数据为空", details: nil))
        return
      }
      guard let image = UIImage(data: data) else {
        result(FlutterError(code: "decode_failed", message: "图片解码失败", details: nil))
        return
      }
      saveToAlbum(image: image, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 存一张图到相册（先申请权限，再写入）
  private func saveToAlbum(image: UIImage, result: @escaping FlutterResult) {
    // 只请求「添加」权限就够 —— 不需要读用户整个相册（权限最小化）
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "denied",
                              message: "没有相册权限，请在系统设置里允许",
                              details: nil))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }) { ok, err in
        DispatchQueue.main.async {
          if ok {
            result(true)
          } else {
            result(FlutterError(code: "save_failed",
                                message: err?.localizedDescription ?? "保存失败",
                                details: nil))
          }
        }
      }
    }
  }

  // MARK: - 朗读

  private func speak(text: String, rate: Double, pitch: Double) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      onDone?()
      return
    }

    // 懒建：AVSpeechSynthesizer 会占用音频会话，不用时不建
    let s = synth ?? {
      let made = AVSpeechSynthesizer()
      made.delegate = self
      synth = made
      return made
    }()

    // 打断上一段（正常流程里 Dart 会逐段调用，这里兜住重复调用）
    if s.isSpeaking {
      s.stopSpeaking(at: .immediate)
    }

    // 语音会话：TTS 属于播放类，用 playback 才能在静音键打开时也出声。
    //
    // ⚠️ options 保持为空、mode 用 .default，**故意与 BackgroundAudio
    // 的配置一致**（它用 .playback + .default + []）。
    // 两者配置若不同，每次朗读都会让系统重配 session 并发出
    // interruption 通知；而 BackgroundAudio 在中断结束时会尝试恢复播放，
    // 那条路径曾经直接 play() 导致 App 闪退。配置对齐后就不会来回抢。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true, options: [])
    } catch {
      print("[TtsEngine] audio session 设置失败: \(error)")
    }

    let u = AVSpeechUtterance(string: trimmed)
    // 中文优先，取不到就交给系统挑（不会崩）
    u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
      ?? AVSpeechSynthesisVoice(language: "zh")
    // Flutter 侧传 0.1~1.0；AVSpeechUtterance 常规区间约 0.0~1.0，
    // 直接用会让听感偏快，这里压到 0.5 倍更接近"朗读"而不是"念稿"
    u.rate = Float(max(0.1, min(1.0, rate)) * 0.5)
    u.pitchMultiplier = Float(max(0.5, min(2.0, pitch)))
    u.volume = 1.0
    // 念完一小段后停一下，段落感更自然
    u.postUtteranceDelay = 0.08

    onDone = { [weak self] in
      self?.channel?.invokeMethod("onDone", arguments: nil)
    }

    s.speak(u)
  }

  private func stop() {
    onDone = nil
    synth?.stopSpeaking(at: .immediate)
  }

  // MARK: - AVSpeechSynthesizerDelegate

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didFinish utterance: AVSpeechUtterance) {
    notifyDone()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didCancel utterance: AVSpeechUtterance) {
    // 主动 stop 时不通知（Dart 侧已经知道停了）
  }

  private func notifyDone() {
    let cb = onDone
    onDone = nil
    cb?()
  }
}
