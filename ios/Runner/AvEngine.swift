import AVFoundation
import AVKit
import Flutter
import UIKit

/// 全局唯一 AVPlayer：应用内画面与系统小窗共用。
/// 进/出 PiP 不再 pause/换播放器，视频连续、音画同步。
final class AvEngine: NSObject {
  static let shared = AvEngine()

  let player = AVPlayer()
  /// 全局唯一画面层：应用内预览与 PiP 共用（系统 PiP 会接管该 layer）
  let playerLayer = AVPlayerLayer()
  private var channel: FlutterMethodChannel?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var statusObserver: NSKeyValueObservation?

  private(set) var isPlaying = false
  private(set) var duration: Double = 0
  private(set) var position: Double = 0

  /// 画面分辨率（来自 AVPlayerItem.presentationSize）。
  /// 0 表示尚未就绪或纯音频流；Dart 侧用 0 判定「不显示分辨率」。
  private(set) var videoWidth: Double = 0
  private(set) var videoHeight: Double = 0

  /// presentationSize 在 item ready 前后都可能有效，统一在轮询/事件里同步
  private func syncPresentationSize(_ item: AVPlayerItem?) {
    guard let size = item?.presentationSize, size.width > 0, size.height > 0 else {
      return
    }
    videoWidth = Double(size.width)
    videoHeight = Double(size.height)
  }

  private override init() {
    super.init()
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] t in
      guard let self = self else { return }
      self.position = t.seconds
      // 顺带同步分辨率：presentationSize 在 readyToPlay 之后才可靠，
      // Dart 侧每秒轮询 getState，这里持续刷新即可拿到真实画面尺寸。
      self.syncPresentationSize(self.player.currentItem)
      self.channel?.invokeMethod("onPosition", arguments: t.seconds)
    }
  }

  func register(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "av_engine", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "AvEngine gone", details: nil))
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
        self.player.play()
        self.isPlaying = true
        self.channel?.invokeMethod("onPlaying", arguments: true)
        result(nil)
      case "pause":
        self.player.pause()
        self.isPlaying = false
        self.channel?.invokeMethod("onPlaying", arguments: false)
        result(nil)
      case "seek":
        let ms = (call.arguments as? NSNumber)?.doubleValue ?? 0
        self.player.seek(
          to: CMTime(seconds: ms / 1000.0, preferredTimescale: 600),
          toleranceBefore: .zero,
          toleranceAfter: .zero
        ) { _ in
          self.position = ms / 1000.0
          self.channel?.invokeMethod("onPosition", arguments: ms / 1000.0)
          result(nil)
        }
        return
      case "setRate":
        let r = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.player.rate = Float(r)
        result(nil)
      case "setVolume":
        let v = (call.arguments as? NSNumber)?.doubleValue ?? 1
        self.player.volume = Float(v)
        result(nil)
      case "getState":
        result([
          "playing": self.isPlaying,
          "position": self.position,
          "duration": self.duration,
          "buffering": false,
          // Dart 侧 AppPlayerStateView.width/height → 播放信息面板的分辨率
          "videoWidth": self.videoWidth,
          "videoHeight": self.videoHeight,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[AvEngine] channel registered")
  }

  func open(url: String, headers: [String: String], positionMs: Double) {
    guard !url.isEmpty, let u = URL(string: url) else { return }
    var options: [String: Any] = [:]
    if !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: u, options: options)
    let item = AVPlayerItem(asset: asset)

    if let oldEnd = endObserver {
      NotificationCenter.default.removeObserver(oldEnd)
    }
    statusObserver?.invalidate()
    statusObserver = nil

    duration = 0
    // 换源先清零分辨率，避免新源就绪前 Dart 侧仍显示上一个源的尺寸
    videoWidth = 0
    videoHeight = 0
    position = positionMs / 1000.0
    player.replaceCurrentItem(with: item)
    if positionMs > 0 {
      player.seek(
        to: CMTime(seconds: positionMs / 1000.0, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }

    statusObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
      guard let self = self else { return }
      if it.status == .readyToPlay {
        let d = it.duration.seconds
        if d.isFinite && d > 0 {
          self.duration = d
          self.channel?.invokeMethod("onDuration", arguments: d)
        }
        // ready 时 presentationSize 已可靠，立刻同步一次（不必等下一次轮询）
        self.syncPresentationSize(it)
        self.channel?.invokeMethod("onReady", arguments: nil)
      } else if it.status == .failed {
        self.channel?.invokeMethod(
          "onError",
          arguments: it.error?.localizedDescription ?? "play failed"
        )
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.isPlaying = false
      self.channel?.invokeMethod("onCompleted", arguments: true)
      self.channel?.invokeMethod("onPlaying", arguments: false)
    }
    player.play()
    isPlaying = true
    channel?.invokeMethod("onPlaying", arguments: true)
  }

  /// 应用内预览（UiKitView 的 AVPlayerLayer，layerClass 方式）
  weak var displayContainer: UIView?
  weak var displayLayer: AVPlayerLayer?

  /// PiP / 预览共用的画面层
  func currentDisplayLayer() -> AVPlayerLayer {
    return displayLayer ?? playerLayer
  }

  /// 关小窗后确保 player 仍挂在预览 layer 上
  func restoreLayerToDisplay() {
    guard let pl = displayLayer else {
      playerLayer.player = player
      return
    }
    pl.player = player
    pl.videoGravity = .resizeAspect
    if let host = displayContainer {
      pl.frame = host.bounds
    }
  }

  /// 当前播放用的 AVPlayer（PiP 与预览共用）
  var avPlayer: AVPlayer { return player }
}