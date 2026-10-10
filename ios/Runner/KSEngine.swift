import AVFoundation
import AVKit
import Combine
import Flutter
import KSPlayer
import UIKit

/// 全局唯一 KSPlayer（第四播放核心「FF」：FFmpeg + Metal）。
///
/// - MKV/AC3/DTS/ASS 等 AVPlayer 吃不下的格式全兼容，并自带系统小窗（PiP）；
/// - 应用内画面：KSPlayerLayer 本身就是 UIView，由 UiKitView 平台视图直接 addSubview；
/// - 控制通道 'ks_player'（open/play/pause/seek/setRate/setVolume/getState/enterPip/exitPip）；
/// - PiP 事件复用 "pip_manager" 通道名回调 Dart（onPipStarted/onPipStopped），
///   与 AVPlayer 路径共用 VideoPlayerPip 的同一套状态机；
/// - 首选 KSMEPlayer（FFmpeg 全格式），失败自动回退 KSAVPlayer。
///
/// ⚠️ PiP 状态同步要点（KSPlayerLayer 快照 95e6e61 的已知缺口）：
/// 用户点小窗「×」关闭时，KSPlayerLayer 只走
/// `pictureInPictureControllerDidStopPictureInPicture`，**不会**把 isPipActive
/// 置回 false；只有「返回 App」按钮才会（restoreUserInterface delegate）。
/// 因此这里用 KVO 观察 pipController.isPictureInPictureActive 作为小窗结束的
/// 唯一真相源，× 关闭 / 返回 App / 系统终止三条路都能触发 onPipStopped。
final class KSEngine: NSObject {
  static let shared = KSEngine()

  private var channel: FlutterMethodChannel?
  /// 仅用于向 Dart 发 PiP 事件（不设 handler，不影响 PipManager 在该通道上的 handler）
  private var pipChannel: FlutterMethodChannel?

  /// 全局唯一播放层；每次 open 重建（旧层 deinit 自清理 PiP/远程控制/通知）
  private var playerLayer: KSPlayerLayer?
  private var pipSink: Any?
  private var pipKvo: NSKeyValueObservation?
  /// 已向 Dart 发过 onPipStarted（KVO 判定，去重）
  private var pipEventActive = false
  /// 重建播放层后等 readyToPlay 再置 isPipActive（换地址进小窗的路径）
  private var pendingPip = false

  private(set) var isPlaying = false
  private(set) var duration: Double = 0
  private(set) var position: Double = 0

  /// 画面分辨率（来自 player.naturalSize）。0 表示尚未就绪或纯音频流。
  private(set) var videoWidth: Double = 0
  private(set) var videoHeight: Double = 0
  private var lastReportedPos: Double = -1

  /// 应用内预览宿主（平台视图注册；弱引用，同 AvEngine.displayContainer 模式）
  private weak var displayHost: UIView?

  private override init() {
    super.init()
  }

  // MARK: - 注册

  func register(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ks_player", binaryMessenger: messenger)
    pipChannel = FlutterMethodChannel(name: "pip_manager", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "KSEngine gone", details: nil))
        return
      }
      switch call.method {
      case "open":
        let args = call.arguments as? [String: Any] ?? [:]
        let url = args["url"] as? String ?? ""
        let headers = args["headers"] as? [String: String] ?? [:]
        let posMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
        self.open(url: url, headers: headers, positionMs: posMs)
        result(nil)
      case "play":
        self.playerLayer?.play()
        self.isPlaying = true
        self.emit("onPlaying", arguments: true)
        result(nil)
      case "pause":
        self.playerLayer?.pause()
        self.isPlaying = false
        self.emit("onPlaying", arguments: false)
        result(nil)
      case "seek":
        let ms = (call.arguments as? NSNumber)?.doubleValue ?? 0
        if let l = self.playerLayer {
          // layer.seek 的 completion 在 NaN/未就绪等分支可能多次回调，防重复 reply
          var replied = false
          let reply: (Bool) -> Void = { [weak self] finished in
            guard !replied else { return }
            replied = true
            if finished, let self = self {
              self.position = ms / 1000.0
              self.emit("onPosition", arguments: ms / 1000.0)
            }
            result(nil)
          }
          l.seek(time: ms / 1000.0, autoPlay: self.isPlaying, completion: reply)
        } else {
          result(nil)
        }
        return
      case "setRate":
        let r = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.playerLayer?.player.playbackRate = Float(r)
        result(nil)
      case "setVolume":
        let v = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.playerLayer?.player.playbackVolume = Float(v)
        result(nil)
      case "getState":
        result(self.currentState())
      case "enterPip":
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          let url = args["url"] as? String ?? ""
          let headers = args["headers"] as? [String: String] ?? [:]
          let posMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
          try self.enterPip(url: url, headers: headers, positionMs: posMs)
          result(nil)
        } catch {
          result(FlutterError(code: "pip", message: error.localizedDescription, details: nil))
        }
      case "exitPip":
        self.exitPip()
        result(nil)
      case "close":
        // 销毁播放层（Dart KSPlayer.dispose 时调用），避免层常驻占内存
        self.closeLayer()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[KSEngine] channel registered")
  }

  // MARK: - 播放

  private func open(url: String, headers: [String: String], positionMs: Double) {
    guard !url.isEmpty, let u = URL(string: url) else {
      emit("onError", arguments: "invalid url")
      return
    }
    closeLayer()

    isPlaying = false
    duration = 0
    position = positionMs / 1000.0
    videoWidth = 0
    videoHeight = 0
    lastReportedPos = -1
    pendingPip = false

    let options = KSOptions()
    options.isAutoPlay = true
    options.hardwareDecode = true
    options.registerRemoteControll = false
    if positionMs > 0 {
      options.startPlayTime = positionMs / 1000.0
    }
    if !headers.isEmpty {
      options.appendHeader(headers)
    }
    // FFmpeg 内核优先（全格式兼容），失败自动回退 KSAVPlayer
    KSOptions.firstPlayerType = KSMEPlayer.self
    KSOptions.secondPlayerType = KSAVPlayer.self

    let l = KSPlayerLayer(url: u, options: options, delegate: self)
    playerLayer = l
    isPlaying = true
    attachLayerToHost(l)
    observePip(l)
    emit("onPlaying", arguments: true)
  }

  /// 销毁播放层。PiP 活跃时先停小窗（静态 pipController 强引用会导致层无法释放）。
  private func closeLayer() {
    pipKvo = nil
    pipSink = nil
    if pipEventActive, let l = playerLayer {
      // KS 的 pipController.stop(restoreUserInterface:) 是 internal，跨模块不可调；
      // 它内部就是设恢复标志 + 调 AVKit 公开 API，传 false 语义下直接调公开 API 等价
      l.player.pipController?.stopPictureInPicture()
      pipEventActive = false
    }
    playerLayer?.removeFromSuperview()
    playerLayer = nil
  }

  // MARK: - 应用内画面（平台视图挂载）

  private func attachLayerToHost(_ l: KSPlayerLayer) {
    guard let host = displayHost else { return }
    l.frame = host.bounds
    l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.addSubview(l)
  }

  /// 平台视图创建时挂载现有播放层（晚于 open 的场景）
  func attach(to host: UIView) {
    displayHost = host
    if let l = playerLayer {
      l.removeFromSuperview()
      attachLayerToHost(l)
    }
  }

  func detachDisplay(_ host: UIView) {
    if displayHost === host {
      displayHost = nil
    }
  }

  // MARK: - 状态

  private func currentState() -> [String: Any] {
    if let l = playerLayer {
      position = l.player.currentPlaybackTime
      let d = l.player.duration
      if d.isFinite && d > 0 {
        duration = d
      }
      let size = l.player.naturalSize
      if size.width > 0, size.height > 0 {
        videoWidth = Double(size.width)
        videoHeight = Double(size.height)
      }
      return [
        "playing": isPlaying,
        "position": position,
        "duration": duration,
        "buffering": !l.player.isReadyToPlay,
        "videoWidth": videoWidth,
        "videoHeight": videoHeight,
      ]
    }
    return [
      "playing": false,
      "position": 0.0,
      "duration": 0.0,
      "buffering": false,
      "videoWidth": 0.0,
      "videoHeight": 0.0,
    ]
  }

  // MARK: - 事件发送（通道回调要求主线程，delegate 可能来自解码线程）

  private func emit(_ method: String, arguments: Any?) {
    if Thread.isMainThread {
      channel?.invokeMethod(method, arguments: arguments)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel?.invokeMethod(method, arguments: arguments)
      }
    }
  }

  private func emitPip(_ method: String, arguments: Any?) {
    if Thread.isMainThread {
      pipChannel?.invokeMethod(method, arguments: arguments)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.pipChannel?.invokeMethod(method, arguments: arguments)
      }
    }
  }

  // MARK: - 画中画（KSPlayer 自带 sample-buffer PiP，iOS 15+ 真机）

  private var isSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  private func observePip(_ l: KSPlayerLayer) {
    // isPipActive 置 true → 尝试挂 KVO（系统自动小窗不经过这个开关，见
    // readyToPlay / getState 处的 watchPipController 兜底）
    pipSink = l.$isPipActive.receive(on: DispatchQueue.main).sink { [weak self] active in
      guard let self = self, active else { return }
      self.watchPipController()
    }
  }

  /// 挂 KVO 观察 PiP 真实启停（去重：已挂则跳过）
  private func watchPipController() {
    guard pipKvo == nil, let l = playerLayer else { return }
    guard let pip = l.player.pipController else { return }
    pipKvo = pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, change in
      guard let self = self else { return }
      let active = change.newValue ?? false
      DispatchQueue.main.async { [weak self] in
        self?.handlePipActive(active)
      }
    }
  }

  private func handlePipActive(_ active: Bool) {
    if active {
      if !pipEventActive {
        pipEventActive = true
        emitPip("onPipStarted", arguments: ["position": 0.0])
      }
      return
    }
    guard pipEventActive else { return }
    pipEventActive = false
    pipKvo = nil
    let pos = playerLayer?.player.currentPlaybackTime ?? position
    emitPip("onPipStopped", arguments: ["position": pos])
    // × 关闭路径：layer.isPipActive 不会自己复位，这里同步。
    // didSet 会再调一次 stop(restoreUserInterface:true)，此时 PiP 已停，无害。
    if playerLayer?.isPipActive == true {
      playerLayer?.isPipActive = false
    }
  }

  private func enterPip(url: String, headers: [String: String], positionMs: Double) throws {
    guard !url.isEmpty, let u = URL(string: url) else {
      throw NSError(
        domain: "KSEngine", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "invalid url"]
      )
    }
    if let l = playerLayer, l.url == u {
      // 同一地址（常规路径）：画面直接交给系统小窗，播放不中断
      guard l.player.pipController != nil else {
        throw NSError(
          domain: "KSEngine", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "pip not ready"]
        )
      }
      pendingPip = false
      watchPipController()
      l.isPipActive = true
      return
    }
    // 没有播放层或换了地址：重建播放层，等 readyToPlay 后再进小窗
    guard #available(iOS 15.0, *), !isSimulator else {
      throw NSError(
        domain: "KSEngine", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "pip unsupported"]
      )
    }
    open(url: url, headers: headers, positionMs: positionMs)
    pendingPip = true
  }

  private func exitPip() {
    guard let l = playerLayer else { return }
    pendingPip = false
    if l.isPipActive {
      l.isPipActive = false
    } else if pipEventActive {
      // 系统自动小窗（isPipActive 未被置 true 的路径）：直接停
      // 同上：KS 的 stop(restoreUserInterface:) internal，用 AVKit 公开 API 替代
      l.player.pipController?.stopPictureInPicture()
    }
  }
}

// MARK: - KSPlayerLayerDelegate

extension KSEngine: KSPlayerLayerDelegate {
  func player(layer: KSPlayerLayer, state: KSPlayerState) {
    switch state {
    case .readyToPlay:
      let d = layer.player.duration
      if d.isFinite && d > 0 {
        duration = d
        emit("onDuration", arguments: d)
      }
      emit("onReady", arguments: nil)
      // 换地址进小窗：等 ready 后再置 isPipActive
      if pendingPip {
        pendingPip = false
        if layer.player.pipController != nil {
          watchPipController()
          layer.isPipActive = true
        } else {
          emit("onError", arguments: "pip not supported on this device")
        }
      }
    case .buffering:
      emit("onBuffering", arguments: true)
    case .bufferFinished:
      emit("onBuffering", arguments: false)
      isPlaying = true
      emit("onPlaying", arguments: true)
    case .paused:
      isPlaying = false
      emit("onPlaying", arguments: false)
    case .playedToTheEnd:
      isPlaying = false
      emit("onCompleted", arguments: true)
      emit("onPlaying", arguments: false)
    case .error:
      isPlaying = false
      emit("onError", arguments: "player error")
    case .prepareToPlay:
      break
    }
  }

  func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
    if totalTime.isFinite && totalTime > 0 && abs(totalTime - duration) > 0.01 {
      duration = totalTime
      emit("onDuration", arguments: totalTime)
    }
    // KS 内部 timer 每 0.1s 回调一次，节流到 0.25s 再发给 Dart
    if abs(currentTime - lastReportedPos) >= 0.25 {
      lastReportedPos = currentTime
      position = currentTime
      emit("onPosition", arguments: currentTime)
    }
    let size = layer.player.naturalSize
    if size.width > 0, size.height > 0, Double(size.width) != videoWidth {
      videoWidth = Double(size.width)
      videoHeight = Double(size.height)
    }
  }

  func player(layer: KSPlayerLayer, finish error: Error?) {
    if let error = error {
      isPlaying = false
      emit("onError", arguments: error.localizedDescription)
    } else {
      isPlaying = false
      emit("onCompleted", arguments: true)
      emit("onPlaying", arguments: false)
    }
  }

  func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime _: TimeInterval) {
    // 首帧统计，暂不使用
  }
}

// MARK: - 平台视图（应用内画面，触摸穿透到 Flutter）

final class KSPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return KSPlayerPlatformView(frame: frame)
  }
}

/// 触摸穿透 host：所有手势交给 Flutter 层处理
private final class KSPlayerHostView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }
}

final class KSPlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: KSPlayerHostView

  init(frame: CGRect) {
    host = KSPlayerHostView(frame: frame)
    host.isUserInteractionEnabled = false
    super.init()
    // 晚于 open 创建时挂载现有播放层；早于 open 时由 open 回来挂载
    KSEngine.shared.attach(to: host)
    NSLog("[KSPlayerView] host frame=\(frame)")
  }

  func view() -> UIView {
    return host
  }

  deinit {
    KSEngine.shared.detachDisplay(host)
  }
}
