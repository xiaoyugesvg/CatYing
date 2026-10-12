import AVFoundation
import Combine
import Flutter
import UIKit
import AetherEngine

/// 第五播放核心「Aether」：AetherEngine（FFmpeg 解复用 + VideoToolbox/dav1d 解码 + Metal）。
/// vendored 本地包 ios/AetherEngine（源自 superuser404notfound/AetherEngine，平台下限降 16）。
///
/// 与 KSEngine（FF 核心）同构的桥接模式：
/// - 控制通道 'aether_player'（open/play/pause/seek/setRate/setVolume/getState/close）；
/// - 事件回调 onReady/onPlaying/onPosition/onDuration/onBuffering/onCompleted/onError，
///   与 ks_player.dart 的 KSPlayer 封装共用同一套事件协议，Dart 侧封装可对称复用；
/// - 应用内画面：AetherPlayerView(engine:) 由 open 成功后挂进平台视图宿主；
/// - 事件源：AetherEngine 的 @Published（Combine）状态流 + position 用 0.25s Timer 拉取。
///
/// 限制（第一版）：
/// - 不支持画中画（Aether 的 PiP 走 SoftwarePiPSource 独立链路，后续按需接入）；
/// - native HLS 路径暂无公开分辨率属性，getState 的 videoWidth/Height 仅软件路径有效。
final class AetherBridge: NSObject {
  static let shared = AetherBridge()

  private var channel: FlutterMethodChannel?
  private var engine: AetherEngine?
  private var cancellables = Set<AnyCancellable>()
  private var positionTimer: Timer?

  private(set) var isPlaying = false
  private(set) var duration: Double = 0
  private(set) var position: Double = 0
  private var lastReportedPos: Double = -1
  /// open 后 load 尚未返回的状态：区分「加载中」与「已报错」
  private var loadTask: Task<Void, Never>?

  /// 应用内预览宿主（平台视图；弱引用，同 KSEngine.displayHost 模式）
  private weak var displayHost: UIView?
  /// 当前挂载的引擎画面视图（open 重建时随旧引擎一起移除）
  private var playerView: UIView?

  private override init() {
    super.init()
  }

  // MARK: - 注册

  func register(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "aether_player", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "AetherBridge gone", details: nil))
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
        self.engine?.play()
        self.isPlaying = true
        self.emit("onPlaying", arguments: true)
        result(nil)
      case "pause":
        self.engine?.pause()
        self.isPlaying = false
        self.emit("onPlaying", arguments: false)
        result(nil)
      case "seek":
        let ms = (call.arguments as? NSNumber)?.doubleValue ?? 0
        if let e = self.engine {
          self.position = ms / 1000.0
          Task { [weak e] in
            await e?.seek(to: ms / 1000.0)
          }
        }
        result(nil)
      case "setRate":
        let r = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.engine?.setRate(Float(r))
        result(nil)
      case "setVolume":
        let v = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.engine?.volume = Float(v)
        result(nil)
      case "getState":
        result(self.currentState())
      case "close":
        self.closeEngine()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[AetherBridge] channel registered")
  }

  // MARK: - 播放

  private func open(url: String, headers: [String: String], positionMs: Double) {
    guard !url.isEmpty, let u = URL(string: url) else {
      emit("onError", arguments: "invalid url")
      return
    }
    closeEngine()

    isPlaying = false
    duration = 0
    position = positionMs / 1000.0
    lastReportedPos = -1

    let e: AetherEngine
    do {
      e = try AetherEngine()
    } catch {
      emit("onError", arguments: "engine init failed: \(error.localizedDescription)")
      return
    }
    engine = e
    isPlaying = true

    var options = LoadOptions()
    if !headers.isEmpty {
      // #119：IPTV 的 Referer / User-Agent / Authorization 头在 nativeRemoteHLS
      // 路径会带进 AVURLAsset，header 校验源可用
      options.httpHeaders = headers
    }

    observe(e)

    loadTask = Task { [weak self] in
      do {
        try await e.load(
          url: u,
          startPosition: positionMs > 0 ? positionMs / 1000.0 : nil,
          options: options
        )
        await MainActor.run {
          guard let self = self, self.engine === e else { return }
          self.attachView(e)
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self = self, self.engine === e else { return }
          self.isPlaying = false
          self.emit("onError", arguments: error.localizedDescription)
        }
      }
    }

    // position 拉取：Aether 的 clock 无逐帧回调，用 0.25s Timer
    // （与 KSEngine 的 0.25s 节流同频，Dart 侧无感知差异）
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.pollPosition()
    }
    RunLoop.main.add(timer, forMode: .common)
    positionTimer = timer
    emit("onPlaying", arguments: true)
  }

  private func closeEngine() {
    loadTask?.cancel()
    loadTask = nil
    positionTimer?.invalidate()
    positionTimer = nil
    cancellables.removeAll()
    playerView?.removeFromSuperview()
    playerView = nil
    // stop(resetDisplayCriteria:) 默认完全拆除会话；finalTeardown nil = 引擎自行判断
    engine?.stop()
    engine = nil
    isPlaying = false
  }

  // MARK: - 状态订阅（@Published → Dart 事件）

  private func observe(_ e: AetherEngine) {
    e.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
      guard let self = self, self.engine === e else { return }
      switch state {
      case .idle, .loading, .seeking:
        break
      case .playing:
        self.isPlaying = true
        self.emit("onBuffering", arguments: false)
        self.emit("onPlaying", arguments: true)
      case .paused:
        self.isPlaying = false
        self.emit("onPlaying", arguments: false)
      case .ended:
        self.isPlaying = false
        self.emit("onCompleted", arguments: true)
        self.emit("onPlaying", arguments: false)
      case .error(let msg):
        self.isPlaying = false
        self.emit("onError", arguments: msg)
      }
    }.store(in: &cancellables)

    e.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] b in
      guard let self = self, self.engine === e else { return }
      self.emit("onBuffering", arguments: b)
    }.store(in: &cancellables)

    e.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
      guard let self = self, self.engine === e else { return }
      guard d.isFinite && d > 0 else { return }
      self.duration = d
      self.emit("onDuration", arguments: d)
    }.store(in: &cancellables)

    e.$errorInfo.receive(on: DispatchQueue.main).sink { [weak self] info in
      guard let self = self, self.engine === e, let info = info else { return }
      self.isPlaying = false
      self.emit("onError", arguments: info.message)
    }.store(in: &cancellables)
  }

  private func pollPosition() {
    guard let e = engine else { return }
    let t = e.currentTime
    guard t.isFinite, t >= 0 else { return }
    if abs(t - lastReportedPos) >= 0.25 {
      lastReportedPos = t
      position = t
      emit("onPosition", arguments: t)
    }
  }

  // MARK: - 应用内画面（平台视图挂载）

  /// load 成功后创建 AetherPlayerView 并挂进宿主。
  /// 每次 open 重建引擎 → 旧视图随 closeEngine 移除，新视图绑定新引擎实例。
  private func attachView(_ e: AetherEngine) {
    guard let host = displayHost else { return }
    playerView?.removeFromSuperview()
    let v = AetherPlayerView(engine: e)
    v.frame = host.bounds
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.addSubview(v)
    playerView = v
  }

  /// 平台视图创建时绑定宿主（晚于 open 的场景：直接挂现有引擎视图）
  func attach(to host: UIView) {
    displayHost = host
    if let e = engine, playerView == nil {
      attachView(e)
    }
  }

  func detachDisplay(_ host: UIView) {
    if displayHost === host {
      displayHost = nil
    }
  }

  // MARK: - 状态

  private func currentState() -> [String: Any] {
    if let e = engine {
      let t = e.currentTime
      if t.isFinite && t >= 0 {
        position = t
      }
      let d = e.duration
      if d.isFinite && d > 0 {
        duration = d
      }
      let size = e.softwareDisplaySize ?? .zero
      return [
        "playing": isPlaying,
        "position": position,
        "duration": duration,
        "buffering": e.isBuffering,
        "videoWidth": Double(size.width),
        "videoHeight": Double(size.height),
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
}

// MARK: - 平台视图（应用内画面，触摸穿透到 Flutter）

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
    return AetherPlatformView(frame: frame)
  }
}

/// 触摸穿透 host：所有手势交给 Flutter 层处理（与 KSPlayerHostView 同款）
private final class AetherHostView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }
}

final class AetherPlatformView: NSObject, FlutterPlatformView {
  private let host: AetherHostView

  init(frame: CGRect) {
    host = AetherHostView(frame: frame)
    // 视频区永远黑底（与 KSPlayerPlatformView 一致，避免首帧前透灰白）
    host.backgroundColor = .black
    host.isUserInteractionEnabled = false
    super.init()
    AetherBridge.shared.attach(to: host)
    NSLog("[AetherPlatformView] host frame=\(frame)")
  }

  func view() -> UIView {
    return host
  }

  deinit {
    AetherBridge.shared.detachDisplay(host)
  }
}
