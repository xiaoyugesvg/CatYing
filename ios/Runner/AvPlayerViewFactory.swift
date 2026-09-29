import AVFoundation
import Flutter
import UIKit

/// 应用内预览层：与 PiP 共用 AvEngine.shared.player
final class AvPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AvPlayerPlatformView(frame: frame)
  }
}

final class AvPlayerPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let layer: AVPlayerLayer

  init(frame: CGRect) {
    container = UIView(frame: frame)
    layer = AvEngine.shared.playerLayer
    if layer.superlayer == nil {
      container.layer.addSublayer(layer)
    }
    layer.frame = container.bounds
    super.init()
  }

  func view() -> UIView {
    container
  }

  func layout(_ frame: CGRect) {
    container.frame = frame
    layer.frame = container.bounds
  }
}
