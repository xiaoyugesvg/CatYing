import AVKit
import AVFoundation
import Flutter
import UIKit

/// iOS 系统画中画（PiP）管理器
///
/// **单播放器方案（当前）**：
///   AvEngine.shared.player 为全局唯一 AVPlayer。
///   - 应用内 UiKitView 挂同一 AVPlayerLayer 显示画面
///   - PiP 把**同一 layer** 交给系统悬浮窗
///   - 进/出小窗不暂停、不换播放器，视频连续、音画同步
///
/// 前置条件：
///   - Info.plist UIBackgroundModes 含 audio
///   - AVAudioSession .playback
///
/// 稳定性修复 v4（2026-09-26）：
///   旧版根因导致"画中画时灵时不灵"：
///   a) 后台才调 startPip：App 已进后台才创建 AVPlayer 等 readyToPlay，
///      后台缓冲慢/受限，15s 超时或系统拒绝启动 → 无小窗但主播放器还在播。
///   b) http 明文源：原生 AVPlayer 受 ATS 限制，http:// m3u8 直接加载失败
///      （Info.plist 已放行 NSAllowsArbitraryLoads）；media_kit 自己的网络栈
///      不受 ATS 影响 → "主播放器能播、PiP 失败"。
///   c) v2/v3 的 appDidEnterBackground 只要求 preparedReady / 只要求实例存在
///      才启动，但存在竞态：原生已 startPictureInPicture（didStart 尚未回调，
///      isActive 仍为 false）时，Dart 侧 paused 回调又调 enterIos → startPip
///      开头 `if pipController != nil { cleanup() }` 会把刚启动的实例销毁 →
///      自动 PiP 时灵时不灵。
///
///   修复（v4）：
///   - preparePip(url, headers)：**前台播放时预热**创建 AVPlayer，静音预缓冲
///     并常驻待命（readyToPlay 后保持），退后台/点 PiP 时立即启动。
///   - startPip 复用路径：**存在常驻实例（同 URL，无论是否就绪）即 seek + 启动**，
///     不再 cleanup 销毁；实例正处启动中（startingPip，didStart 未回调）时
///     直接回传成功，消除双路径竞态。
///   - appDidEnterBackground：只要存在常驻实例且未在 PiP，即启动系统悬浮窗；
///     预热中（源慢）时窗口先出现，AVPlayer 缓冲完成后面面自然呈现。
///   - 真实激活由 pictureInPictureControllerDidStartPictureInPicture 确认，
///     并通过通道事件 onPipStarted 通知 Dart 暂停主播放器。
///
/// 无声修复 v5（2026-09-26）：
///   "自动小窗能播但没有声音、手动有声" 的根因：主播放器(mpv)仍占用
///   AVAudioSession 时启动 AVPlayer PiP，audio session 未激活/被抢占 →
///   小窗有画面无声音。修复：
///   - Dart 侧进 PiP 前先暂停主播放器释放 session（见 video_player.dart）
///   - 原生侧所有启动路径（复用/慢路径/退后台/didStart）统一先
///     activateAudioSession() 激活 .playback session，再 play
class PipManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = PipManager()

  private var channel: FlutterMethodChannel?
  private var pipController: AVPictureInPictureController?
  private var pipPlayer: AVPlayer?
  private var pipLayer: AVPlayerLayer?
  private var containerView: UIView?

  // -- 启动门闩（懒加载路径：等 readyToPlay 再进 PiP）--
  private var itemStatusObserver: NSKeyValueObservation?
  private var startTimeoutWork: DispatchWorkItem?
  // MARK: - 状态机（单入口 phase，避免多 bool 竞态）
  enum PipPhase {
    case idle          // 无实例/已清理
    case prepared      // 预热完成，可快速启动
    case preparing     // 预热中（等 readyToPlay）
    case pendingStart  // 已请求启动，等 ready 后 startPictureInPicture
    case starting      // startPictureInPicture 已调，等 didStart
    case active        // 系统 PiP 显示中
    case stopping      // 停止中
  }

  private(set) var phase: PipPhase = .idle

  /// 兼容旧字段：由 phase 推导，写操作统一走 setPhase
  private var pendingStart: Bool {
    get { phase == .pendingStart }
    set { if newValue { setPhase(.pendingStart) } else if phase == .pendingStart { setPhase(.prepared) } }
  }
  private var startingPip: Bool {
    get { phase == .starting }
    set { if newValue { setPhase(.starting) } else if phase == .starting { setPhase(isActive ? .active : .idle) } }
  }
  /// 当前是否处于系统 PiP
  var isActive: Bool { phase == .active }

  private func setPhase(_ p: PipPhase) {
    NSLog("[PipManager] phase \(phase) -> \(p)")
    phase = p
  }

  /// 是否处于启动/进行中（重复 start 时短路）
  private var isBusy: Bool {
    phase == .starting || phase == .pendingStart || phase == .active || phase == .stopping
  }

  /// 挂起的 startPip result（就绪/失败后才回传）
  private var startResult: FlutterResult?

  // -- 预热常驻状态 --
  /// 常驻实例已 readyToPlay，可直接启动 PiP
  private var preparedReady = false
  /// 预热时的源 URL（换源时重建实例）
  private var preparedURL = ""
  /// PiP 最后播放位置（秒，供 Dart 恢复主播放器进度）
  private(set) var lastPositionSeconds: Double = 0

  private override init() {
    super.init()
    // 退后台自动启动 PiP：前台已预热（含预热中）时，进后台瞬间直接启动系统悬浮窗
    // （比 Dart 侧 AppLifecycleState 回调更早、更稳，且此时 AVPlayer 已开始缓冲）
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - 注册（AppDelegate.didInitializeImplicitFlutterEngine 调）

  func register(with messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "pip_manager", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "PipManager 已释放", details: nil))
        return
      }
      switch call.method {
      case "isPipSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "startPip":
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
          result(FlutterError(code: "bad_args", message: "缺少播放地址", details: nil))
          return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        let positionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
        self.startPip(url: url, headers: headers, positionMs: positionMs, result: result)
      case "stopPip":
        self.stopPip()
        result(nil)
      case "preparePip":
        // 前台预热：静音预缓冲 AVPlayer 并常驻待命（不启动 PiP）
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
          result(FlutterError(code: "bad_args", message: "缺少播放地址", details: nil))
          return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        self.preparePip(url: url, headers: headers)
        result(nil)
      case "releasePip":
        // 离开播放页：释放常驻实例
        self.releasePip()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[PipManager] channel registered")
  }

  // MARK: - 与主播放器共用 AvEngine.shared.player（单实例，进出小窗不中断）

  /// 确保 PiP 控制器挂在全局唯一 AVPlayerLayer 上
  private func ensurePipController() {
    if pipController != nil {
      pipPlayer = AvEngine.shared.player
      pipLayer = AvEngine.shared.playerLayer
      return
    }
    let layer = AvEngine.shared.playerLayer
    let player = AvEngine.shared.player
    // layer 必须在 window 层级；应用内 UiKitView 已挂则复用
    if layer.superlayer == nil {
      guard let window = Self.keyWindow() else { return }
      let container = UIView(frame: window.bounds)
      container.backgroundColor = .clear
      container.isUserInteractionEnabled = false
      window.insertSubview(container, at: 0)
      layer.frame = container.bounds
      layer.videoGravity = .resizeAspect
      container.layer.addSublayer(layer)
      containerView = container
    }
    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      NSLog("[PipManager] PiP controller init failed")
      return
    }
    controller.delegate = self
    pipController = controller
    pipPlayer = player
    pipLayer = layer
    preparedReady = true
    NSLog("[PipManager] PiP bound to shared AVPlayer")
  }

  /// 前台调用：只绑定共用播放器，不再另建静音 AVPlayer
  private func preparePip(url: String, headers: [String: String]) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    preparedURL = url
    ensurePipController()
  }

  /// 离开播放页：释放 PiP 控制器（**不**销毁 AvEngine 播放器）
  func releasePip() {
    NSLog("[PipManager] releasePip (keep shared player)")
    if let c = pipController, c.isPictureInPictureActive {
      c.stopPictureInPicture()
    }
    pipController?.delegate = nil
    pipController = nil
    // 不要 pause AvEngine.player —— 避免误杀主画面
    if let c = containerView {
      c.removeFromSuperview()
      containerView = nil
    }
    pipLayer = nil
    pipPlayer = nil
    preparedURL = ""
    setPhase(.idle)
  }

  // MARK: - 启动 PiP（同一播放器接管到系统小窗）

  private func startPip(url: String, headers: [String: String], positionMs: Double, result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "unsupported", message: "当前设备不支持画中画", details: nil))
      return
    }
    ensurePipController()
    guard let controller = pipController else {
      result(FlutterError(code: "pip_init_failed", message: "画中画控制器创建失败", details: nil))
      return
    }
    if isBusy {
      result(nil)
      return
    }

    preparedURL = url
    activateAudioSession()
    // 同一播放器已在播则不要 seek（避免跳动）；换源由 AvEngine.open 处理
    let player = AvEngine.shared.player
    player.volume = 1.0
    if player.timeControlStatus != .playing {
      player.play()
    }
    setPhase(.starting)
    waitForPipPossible(controller, timeoutSeconds: 4, result: result) { [weak self] in
      guard let self = self else { return }
      if self.isBusy {
        result(nil)
        return
      }
      self.setPhase(.starting)
      controller.startPictureInPicture()
      NSLog("[PipManager] startPictureInPicture() on shared player")
      result(nil)
    }
  }

  /// item 状态变化处理（懒加载路径）
  private func handleItemStatus(_ status: AVPlayerItem.Status) {
    switch status {
    case .readyToPlay:
      NSLog("[PipManager] item readyToPlay → start PiP")
      doStartPiP()
    case .failed:
      let reason = pipPlayer?.currentItem?.error?.localizedDescription ?? "未知"
      NSLog("[PipManager] item failed: \(reason)")
      failStart("画中画启动失败：源加载失败（\(reason)）")
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  /// 就绪后真正启动系统 PiP（懒加载路径）
  private func doStartPiP() {
    guard pendingStart, let controller = pipController else { return }
    if phase == .pendingStart { setPhase(.prepared) }
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    // 回传"已发起"：Dart 侧等 onPipStarted 真实激活后再暂停主播放器
    startResult?(nil)
    startResult = nil
    preparedReady = true
    pipPlayer?.volume = 1.0
    setPhase(.starting)
    // **v6**：同样等待 isPictureInPicturePossible 再启动，避免静默失败
    waitForPipPossible(controller, timeoutSeconds: 4) { [weak self] in
      guard let self = self else { return }
      if self.isBusy {
        return
      }
      self.setPhase(.starting)
      controller.startPictureInPicture()
      NSLog("[PipManager] startPictureInPicture() (slow path, after possible)")
    }
    NSLog("[PipManager] startPictureInPicture() called (slow path)")
  }

  /// **v6 手动 PiP 修复**：轮询等待 AVPictureInPictureController 的
  /// isPictureInPicturePossible 变为 true，再执行 startPictureInPicture()。
  /// iOS 前台手动启动时，若 audio session / playerLayer 未就绪，
  /// startPictureInPicture() 会被系统静默忽略（不回调、不报错），
  /// 表现为"点了没反应"。轮询到超时则明确报错返回给 Dart。
  /// - Parameters:
  ///   - controller: PiP 控制器
  ///   - timeoutSeconds: 超时（秒），默认 4
  ///   - result: 手动路径的 FlutterResult（超时时回传错误）
  ///   - onReady: possible 就绪后的回调（在 main queue 执行）
  private func waitForPipPossible(
    _ controller: AVPictureInPictureController,
    timeoutSeconds: Double = 4,
    result: FlutterResult? = nil,
    onReady: @escaping () -> Void
  ) {
    let startTime = Date()
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
      guard t.isValid else { return }
      if controller.isPictureInPicturePossible {
        t.invalidate()
        DispatchQueue.main.async { onReady() }
        return
      }
      if Date().timeIntervalSince(startTime) >= timeoutSeconds {
        t.invalidate()
        NSLog("[PipManager] waitForPipPossible TIMEOUT (possible=\(controller.isPictureInPicturePossible))")
        if let r = result {
          r(FlutterError(
            code: "pip_not_possible",
            message: "画中画当前不可用（请稍后重试）",
            details: nil
          ))
        }
      }
    }
    // 保底：定时器强引用置空防泄漏（Timer 自身持有 closure，closure 持有 timer，
    // 但 repeats 定时器在 invalidate 后自然释放）
    _ = timer
  }

  /// 启动失败统一出口（超时 / 加载失败 / 其它）
  private func failStart(_ message: String) {
    guard pendingStart else { return }
    if phase == .pendingStart { setPhase(.prepared) }
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    startResult?(FlutterError(code: "pip_start_failed", message: message, details: nil))
    startResult = nil
    NSLog("[PipManager] failStart: \(message)")
    cleanup()
  }

  // MARK: - 停止 PiP

  func stopPip() {
    NSLog("[PipManager] stopPip (isActive=\(isActive), pendingStart=\(pendingStart), startingPip=\(startingPip))")
    if isActive {
      lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
      pipController?.stopPictureInPicture()
      // didStop 里只解绑 PiP 控制器，**不**暂停共享播放器
      return
    }
    if pendingStart {
      startResult?(nil)
      startResult = nil
    }
    // 未在 PiP：绝不能 pause 共享播放器（AvEngine），否则主画面跟着停
  }

  /// 只解绑 PiP 控制器。
  /// **禁止** pause AvEngine.shared.player，**禁止** removeFromSuperlayer
  /// 共享 playerLayer（否则 UiKitView 黑屏、主播放器停住）。
  private func cleanup() {
    itemStatusObserver?.invalidate()
    itemStatusObserver = nil
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    if phase == .pendingStart { setPhase(.prepared) }
    startingPip = false
    if startResult != nil {
      startResult?(nil)
      startResult = nil
    }
    // 不碰 pipPlayer（= AvEngine.shared.player）播放状态
    pipController?.delegate = nil
    pipController = nil
    pipPlayer = nil
    pipLayer = nil
    // 仅移除临时 container；**必须把共享 layer 归还预览**，否则 App 内黑屏
    if let c = containerView {
      c.removeFromSuperview()
      containerView = nil
    }
    AvEngine.shared.restoreLayerToDisplay()
    setPhase(.idle)
    preparedReady = false
    preparedURL = ""
    NSLog("[PipManager] cleanup (shared player untouched, layer restored)")
  }

  // MARK: - 退后台自动启动 PiP

  /// 激活音频会话：AVPlayer 出声的前提。App 退后台 / 启动 PiP 前调用，
  /// 修复"自动小窗无声"：主播放器(mpv)暂停后 audio session 可能被释放/
  /// 停用，AVPlayer 启动时如果没有 active 的 playback session 会无声。
  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      NSLog("[PipManager] audio session activated (playback)")
    } catch {
      NSLog("[PipManager] activateAudioSession failed: \(error.localizedDescription)")
    }
  }

  /// App 进入后台：**只要存在常驻实例、未在 PiP 且未在启动中**，立即启动系统悬浮窗。
  /// 不再要求 preparedReady——预热中（源加载慢）退后台时，PiP 窗口先出现
  /// （黑屏/loading），AVPlayer 缓冲完成后画面自然呈现，避免"退后台只有声音没有小窗"。
  @objc private func appDidEnterBackground() {
    NSLog("[PipManager] appDidEnterBackground (preparedReady=\(preparedReady), isActive=\(isActive), startingPip=\(startingPip))")
    guard !isActive, !startingPip, let controller = pipController else { return }
    activateAudioSession()
    pipPlayer?.volume = 1.0
    pipPlayer?.play()
    setPhase(.starting)
    controller.startPictureInPicture()
    // 真实激活由 didStart 回调确认并通知 Dart
    NSLog("[PipManager] auto startPictureInPicture on background (preparedReady=\(preparedReady))")
  }

  // MARK: - AVPictureInPictureControllerDelegate

  /// 系统 PiP 悬浮窗真正出现
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStartPictureInPicture")
    setPhase(.active)
    startingPip = false
    // **修复自动小窗无声**: PiP 激活瞬间再确保 audio session 激活 +
    // 音量恢复 + 继续播放。主播放器刚暂停, audio session 归 AVPlayer,
    // 这里显式激活保证小窗一定有声音。
    activateAudioSession()
    pipPlayer?.volume = 1.0
    pipPlayer?.play()
    // 通知 Dart：PiP 真实激活（单实例：**不要**暂停主播放器）
    notifyFlutter("onPipStarted", position: 0)
  }

  /// 用户点了 PiP 悬浮窗的关闭（×）或 PiP 被系统终止
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStopPictureInPicture")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter("onPipStopped", position: lastPositionSeconds)
    cleanup()
  }

  /// 用户点了 PiP 悬浮窗的"返回 App"按钮
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    NSLog("[PipManager] restoreUserInterface")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter("onPipStopped", position: lastPositionSeconds)
    completionHandler(true)
    // 延迟清理，避免切回 App 时画面闪烁
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.cleanup()
    }
  }

  private func notifyFlutter(_ method: String, position: Double) {
    let args: [String: Any] = ["position": position]
    channel?.invokeMethod(method, arguments: args)
  }

  // MARK: - 工具

  static func keyWindow() -> UIWindow? {
    if #available(iOS 15.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first
    }
    return UIApplication.shared.windows.first { $0.isKeyWindow }
  }
}
