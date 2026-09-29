import AVFoundation
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

  private override init() {
    super.init()
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] t in
      guard let self else { return }
      self.position = t.seconds
      self.channel?.invokeMethod("onPosition", arguments: t.seconds)
    }
  }

  func register(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "av_engine", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
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
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[AvEngine] channel registered")
  }

  func open(url: String, headers: [String: String], positionMs: Double) {
    guard let u = URL(string: url), !url.isEmpty else { return }
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

    duration = 0
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
      guard let self else { return }
      if it.status == .readyToPlay {
        let d = it.duration.seconds
        if d.isFinite && d > 0 {
          self.duration = d
          self.channel?.invokeMethod("onDuration", arguments: d)
        }
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
      self?.isPlaying = false
      self?.channel?.invokeMethod("onCompleted", arguments: true)
      self?.channel?.invokeMethod("onPlaying", arguments: false)
    }
    player.play()
    isPlaying = true
    channel?.invokeMethod("onPlaying", arguments: true)
  }

  /// 当前播放用的 AVPlayer（PiP 与预览共用）
  var avPlayer: AVPlayer { player }
}
