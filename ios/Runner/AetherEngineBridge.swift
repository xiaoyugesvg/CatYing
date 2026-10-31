import AVFoundation
import AetherEngine
import Combine
import Flutter
import UIKit

/// 全局唯一 AetherEngine（第五播放核心「AE」：FFmpeg demux + VideoToolbox 解码）。
///
/// ── 与 KSPlayer 并存（用户 2026-11-01 明确要求）──────────────────
/// 第五播放核心，和 KSPlayer（FF 核心）**同时**编进 App，用户在设置里二选一。
///
/// ⚠️ 两套 FFmpeg 的已知风险（上 mac 编译时先看这里）：
///   · KSPlayer      → kingslay/FFmpegKit  （FFmpeg 6.x，符号 `avcodec_*` 无前缀）
///   · AetherEngine  → FFmpegBuild         （FFmpeg 8.1，符号同样 `avcodec_*` 无前缀）
///   · 静态库按需拉取：KSPlayer 先拉走某个 `.o` 后，AetherEngine 再需要同一 `.o` 里
///     的符号就会 duplicate symbol；反过来若全部符号都被 KSPlayer 满足，
///     AetherEngine 实际调到的是 **6.x 的实现**，ABI 不匹配 ⇒ 运行时崩。
///   · 排查顺序：① 编译报 duplicate symbol → 说明两套都被拉取，需要把其中一个改成
///     dynamic framework；② 编译过但一播就崩 → 说明 AetherEngine 用了 8.1 独有 API，
///     同样是符号被抢答，只能二选一。
///   在这两条被真机验证之前，别删掉这条注释。
/// ── 通道协议 ────────────────────────────────────────────────
/// 与原来 `ks_player` 通道**逐方法对齐**，这样 Dart 侧只换实现、不动协议：
///   方法：open / play / pause / seek / setRate / setVolume / setMuted /
///         getState / getSubtitleTracks / selectSubtitleTrack /
///         enterPip / exitPip / close
///   事件：onPlaying / onPosition / onDuration / onReady / onBuffering /
///         onCompleted / onError
///   小窗：复用 "pip_manager" 通道的 onPipStarted / onPipStopped
///         （与 AVPlayer 路径共用 VideoPlayerPip 的同一套状态机）
///
/// ── 与 KSPlayer 实现的差异 ────────────────────────────────────
///   · 画面：AetherPlayerView 自己持有并替换内部 CALayer（AVPlayerLayer /
///     AVSampleBufferDisplayLayer 按会话切换），所以这里**不用**再手动
///     addSubview 内核的 player.view，只需要 engine.bind(view:) 一次。
///   · 进度：AetherEngine 的 currentTime 是计算属性（不在 @Published 里），
///     所以用 250ms 定时器主动上报 —— 与 KSEngine 的 lastReportedPos 同一思路。
///   · 字幕轨：TrackInfo 的字段名需要上 mac 核对，这里先只按序号列出，
///     选轨走 `selectTitle(id:)`。名字暂时显示「字幕 N」。
final class AetherEngineBridge: NSObject {
  static let shared = AetherEngineBridge()

  private var channel: FlutterMethodChannel?
  /// 仅用于向 Dart 发 PiP 事件（不设 handler，不影响 PipManager 在该通道上的 handler）
  private var pipChannel: FlutterMethodChannel?

  private var engine: AetherEngine?
  private var playerView: AetherPlayerView?
  /// 平台视图的宿主容器（Flutter 给的 frame 落在它上面，AetherPlayerView 铺满）
  private weak var displayHost: UIView?

  private var cancellables = Set<AnyCancellable>()

  /// 进度上报定时器
  private var ticker: Timer?
  private static let tickInterval: TimeInterval = 0.25

  private var isPlaying = false
  private var position: Double = 0
  private var duration: Double = 0
  private var videoWidth: Double = 0
  private var videoHeight: Double = 0
  private var currentVolume: Float = 1
  private var currentMuted = false

  /// 已向 Dart 发过 onPipStarted（去重）
  private var pipEventActive = false
  private var readyEmitted = false
  private var completedEmitted = false
  private var lastReportedPos: Double = -1

  private override init() {
    super.init()
  }

  // MARK: - 注册

  func register(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "aether_player", binaryMessenger: messenger)
    pipChannel = FlutterMethodChannel(name: "pip_manager", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "AetherEngineBridge gone", details: nil))
        return
      }
      switch call.method {
      case "open":
        let args = call.arguments as? [String: Any] ?? [:]
        let url = args["url"] as? String ?? ""
        let headers = args["headers"] as? [String: String] ?? [:]
        let posMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
        let live = (args["live"] as? NSNumber)?.boolValue ?? false
        Task { @MainActor in
          await self.open(url: url, headers: headers, positionMs: posMs, live: live)
          result(nil)
        }
      case "play":
        engine?.play()
        isPlaying = true
        emit("onPlaying", arguments: true)
        result(nil)
      case "pause":
        engine?.pause()
        isPlaying = false
        emit("onPlaying", arguments: false)
        result(nil)
      case "seek":
        let ms = (call.arguments as? NSNumber)?.doubleValue ?? 0
        Task { @MainActor in
          await self.engine?.seek(to: ms / 1000.0)
          self.position = ms / 1000.0
          self.lastReportedPos = self.position
          self.completedEmitted = false
          self.emit("onPosition", arguments: self.position)
          result(nil)
        }
      case "setRate":
        let r = (call.arguments as? NSNumber)?.floatValue ?? 1
        self.engine?.setRate(r)
        result(nil)
      case "setVolume":
        let v = (call.arguments as? NSNumber)?.floatValue ?? 1
        self.currentVolume = v
        // 音量为 0 即视为静音：同时置 muted，避免只靠 volume=0 仍出声
        self.currentMuted = v <= 0
        self.applyVolume()
        result(nil)
      case "setMuted":
        self.currentMuted = (call.arguments as? NSNumber)?.boolValue ?? false
        self.applyVolume()
        result(nil)
      case "getState":
        result(self.currentState())
      case "getSubtitleTracks":
        result(self.subtitleTracks())
      case "selectSubtitleTrack":
        let idx = (call.arguments as? NSNumber)?.intValue ?? -1
        self.selectSubtitleTrack(index: idx)
        result(nil)
      case "enterPip":
        Task { @MainActor in
          do {
            try await self.enterPip()
            result(nil)
          } catch {
            result(FlutterError(code: "pip", message: error.localizedDescription, details: nil))
          }
        }
      case "exitPip":
        self.exitPip()
        result(nil)
      case "close":
        Task { @MainActor in
          self.teardown()
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[AetherEngineBridge] channel registered")
  }

  // MARK: - 播放

  @MainActor
  private func open(url: String, headers: [String: String], positionMs: Double, live: Bool) async {
    guard !url.isEmpty, let u = URL(string: url) else {
      emit("onError", arguments: "invalid url")
      return
    }
    teardown()

    isPlaying = false
    position = positionMs / 1000.0
    duration = 0
    videoWidth = 0
    videoHeight = 0
    lastReportedPos = -1
    readyEmitted = false
    completedEmitted = false
    pipEventActive = false

    do {
      let eng = try makeEngine()
      var options = LoadOptions()
      if !headers.isEmpty { options.httpHeaders = headers }
      options.isLive = live

      // 先挂视图再 load：AetherPlayerView 由引擎在会话切换时自己换内部 CALayer，
      // 晚挂会丢首帧（黑屏到下一次 layout）。
      attachPlayerViewIfNeeded()
      if let v = playerView { eng.bind(view: v) }

      _ = try await eng.load(
        url: u,
        startPosition: positionMs > 0 ? positionMs / 1000.0 : nil,
        options: options
      )
      applyVolume()
      eng.play()
      isPlaying = true
      emit("onPlaying", arguments: true)
      startTicker()
    } catch {
      NSLog("[AetherEngineBridge] open failed: \(error)")
      emit("onError", arguments: "\(error)")
    }
  }

  @MainActor
  private func makeEngine() throws -> AetherEngine {
    if let e = engine { return e }
    let e = try AetherEngine()
    engine = e
    observe(e)
    return e
  }

  /// 订阅引擎状态 → 转成 Dart 侧熟悉的事件。
  private func observe(_ eng: AetherEngine) {
    cancellables.removeAll()

    eng.$isBuffering
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] buffering in
        self?.emit("onBuffering", arguments: buffering)
      }
      .store(in: &cancellables)

    eng.$isSessionReady
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] ready in
        guard let self = self, ready, !self.readyEmitted else { return }
        self.readyEmitted = true
        self.emit("onReady", arguments: nil)
      }
      .store(in: &cancellables)

    eng.$duration
      .receive(on: DispatchQueue.main)
      .sink { [weak self] d in
        guard let self = self, d.isFinite, d > 0 else { return }
        self.duration = d
        self.emit("onDuration", arguments: d)
      }
      .store(in: &cancellables)

    eng.$sourceVideoWidth
      .receive(on: DispatchQueue.main)
      .sink { [weak self] w in
        guard w > 0 else { return }
        self?.videoWidth = Double(w)
      }
      .store(in: &cancellables)

    eng.$sourceVideoHeight
      .receive(on: DispatchQueue.main)
      .sink { [weak self] h in
        guard h > 0 else { return }
        self?.videoHeight = Double(h)
      }
      .store(in: &cancellables)

    eng.$errorInfo
      .receive(on: DispatchQueue.main)
      .sink { [weak self] info in
        guard let info = info else { return }
        self?.emit("onError", arguments: "\(info)")
      }
      .store(in: &cancellables)

    // 小窗：AetherEngine 自己维护 pictureInPictureActive，用它作为唯一真相源
    eng.$pictureInPictureActive
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] active in
        self?.handlePipActive(active)
      }
      .store(in: &cancellables)
  }

  private func applyVolume() {
    engine?.volume = currentMuted ? 0 : currentVolume
  }

  // MARK: - 进度上报

  private func startTicker() {
    stopTicker()
    ticker = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  private func tick() {
    guard let eng = engine else { return }
    let t = eng.currentTime
    guard t.isFinite else { return }
    position = t
    if abs(t - lastReportedPos) >= 0.2 {
      lastReportedPos = t
      emit("onPosition", arguments: t)
    }
    // 播放结束：Aether 的 state 枚举不在这里 switch（避免绑死具体 case 名），
    // 用"时长已知 + 播到尾巴"判断，只报一次。
    if !completedEmitted, duration > 0, t >= duration - 0.3 {
      completedEmitted = true
      isPlaying = false
      emit("onPlaying", arguments: false)
      emit("onCompleted", arguments: true)
    }
  }

  // MARK: - 状态

  private func currentState() -> [String: Any] {
    if let eng = engine {
      let t = eng.currentTime
      if t.isFinite { position = t }
      let d = eng.duration
      if d.isFinite, d > 0 { duration = d }
      return [
        "playing": isPlaying,
        "position": position,
        "duration": duration,
        "buffering": eng.isBuffering,
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

  // MARK: - 字幕轨

  /// 枚举内嵌字幕轨。
  ///
  /// ⚠️ 这里刻意只按**序号**暴露：`TrackInfo` 的字段名（name / language /
  /// image）需要上 mac 编译核对，写错会直接编译失败。序号 + `selectTitle(id:)`
  /// 已经能完成「切轨 / 关字幕」两个动作，名字暂时显示「字幕 N」。
  /// 核对后把 name/language 填进来即可，Dart 侧不用改。
  private func subtitleTracks() -> [[String: Any]] {
    guard let eng = engine else { return [] }
    var out = [[String: Any]]()
    for i in 0 ..< eng.subtitleTracks.count {
      out.append([
        "id": "\(i)",
        "name": "字幕 \(i + 1)",
        "language": "",
        "image": false,
        "enabled": eng.activeSubtitleTrackIndex == i,
      ])
    }
    return out
  }

  private func selectSubtitleTrack(index: Int) {
    guard let eng = engine else { return }
    // <0 关闭全部字幕：Aether 用 selectTitle(id:) 选轨，关闭动作由引擎内部处理，
    // 这里保守地只在 >=0 时选轨。
    if index >= 0, index < eng.subtitleTracks.count {
      eng.selectTitle(id: index)
    }
  }

  // MARK: - 画中画

  private func handlePipActive(_ active: Bool) {
    if active {
      if !pipEventActive {
        pipEventActive = true
        emitPip("onPipStarted", arguments: ["position": position])
      }
      return
    }
    guard pipEventActive else { return }
    pipEventActive = false
    emitPip("onPipStopped", arguments: ["position": position])
  }

  @MainActor
  private func enterPip() async throws {
    guard let eng = engine else {
      throw NSError(
        domain: "AetherEngineBridge", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no active session"]
      )
    }
    attachPlayerViewIfNeeded()
    if let v = playerView { eng.bind(view: v) }
    eng.pictureInPictureActive = true
  }

  private func exitPip() {
    engine?.pictureInPictureActive = false
  }

  // MARK: - 画面挂载

  @MainActor
  private func attachPlayerViewIfNeeded() {
    if playerView == nil {
      playerView = AetherPlayerView(frame: .zero)
    }
    guard let host = displayHost, let v = playerView else { return }
    if v.superview === host { return }
    v.removeFromSuperview()
    v.frame = host.bounds
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    v.backgroundColor = .black
    host.addSubview(v)
  }

  /// 平台视图创建时挂载（晚于 open 的场景）
  @MainActor
  func attach(to host: UIView) {
    displayHost = host
    attachPlayerViewIfNeeded()
    if let v = playerView, let e = engine { e.bind(view: v) }
  }

  @MainActor
  func detachDisplay(_ host: UIView) {
    if displayHost === host {
      displayHost = nil
    }
  }

  // MARK: - 释放

  @MainActor
  private func teardown() {
    stopTicker()
    cancellables.removeAll()
    if pipEventActive {
      pipEventActive = false
      emitPip("onPipStopped", arguments: ["position": position])
    }
    if let e = engine, let v = playerView {
      e.unbind(view: v)
    }
    engine?.stop()
    engine = nil
    playerView?.removeFromSuperview()
    playerView = nil
    isPlaying = false
    readyEmitted = false
    completedEmitted = false
  }

  // MARK: - 事件发送（通道回调要求主线程）

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
}

// MARK: - 平台视图

final class AetherPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return AetherPlayerPlatformView(frame: frame)
  }
}

/// 应用内画面容器：AetherPlayerView 铺满它。
/// 触摸穿透到 Flutter（控制条在 Flutter 侧）。
final class AetherPlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: UIView

  init(frame: CGRect) {
    host = UIView(frame: frame)
    host.backgroundColor = .black
    host.clipsToBounds = true
    host.isUserInteractionEnabled = false
    super.init()
    Task { @MainActor in
      AetherEngineBridge.shared.attach(to: host)
    }
    NSLog("[AetherPlayerView] host frame=\(frame)")
  }

  func view() -> UIView {
    return host
  }

  func layout(_ frame: CGRect) {
    host.frame = frame
  }

  deinit {
    let h = host
    Task { @MainActor in
      AetherEngineBridge.shared.detachDisplay(h)
    }
  }
}
