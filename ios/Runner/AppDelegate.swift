import Flutter
import UIKit
import AVFoundation
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // NodeJSBridge 持有 platform channel
  private var nodeJSBridge: NodeJSBridge?
  // PythonBridge（CPython 嵌入，对齐 NodeJSBridge 模式）
  private var pythonBridge: PythonBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo

    // ── 把「可再生的大目录」排除出 iCloud 备份（2026-10-14）────────────
    //   iOS 默认把 Documents/ **全量**备份进 iCloud。而本 App 在 Documents 下
    //   放了 Node 运行时（nodejs-project/）与插件脚本缓存（musicfree_plugins/）——
    //   它们都能从包内/网络重新生成，却会实打实吃掉用户的 iCloud 备份配额。
    //   排除它们**不影响数据安全**：书架 / 收藏 / 设置 / 传书等用户数据一律不动。
    excludeReproducibleDirsFromBackup()

    // **2026-07-08 方案 A (Background Audio)**:
    // 启动 silent audio playback, 让 iOS 把 app 当作 "audio app",
    // 维持 app 在后台 / 锁屏时不挂起 embed library (Node.js 进程).
    // 见 BackgroundAudio.swift 详细说明.
    // 必须在 Flutter 引擎启动**之前**调, 否则 iOS 在 Flutter 启动过程中
    // 可能已经判定 app 进入 inactive.
    // 按需保活：不再启动就常驻静音音频；Node 启动后再开，见 NodeJSBridge

    // 监听 lifecycle 事件, 在进入后台前重新激活 audio session
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 把 Documents 下**可再生**的大目录标记为「不参与 iCloud 备份」。
  ///
  /// · `nodejs-project/`    —— Node 运行时 + app.log（可从包内重新解压）
  /// · `musicfree_plugins/` —— MusicFree 插件脚本文件缓存（可重新下载）
  ///
  /// ⚠️ 目录不存在时**安全跳过**（首次启动时它们尚未创建 ⇒ 下次启动会被标记）。
  /// ⚠️ 这里**只加标记、绝不删除任何文件**。
  /// ⚠️ 只排除这两项：Hive（书架/收藏/记录）、`prefs_mirror.json`、
  ///    `reading_state.bak`、`music/`（用户下载的歌）都是用户数据，**必须保留备份**。
  private func excludeReproducibleDirsFromBackup() {
    guard let docs = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask
    ).first else { return }
    for name in ["nodejs-project", "musicfree_plugins"] {
      var url = docs.appendingPathComponent(name, isDirectory: true)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        NSLog("[AppDelegate] 已排除 iCloud 备份: \(name)")
      } catch {
        NSLog("[AppDelegate] 排除 iCloud 备份失败 \(name): \(error)")
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // 注册 Flutter 生态的所有插件
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 注册 NodeJSBridge（iOS 端 Node.js 集成的 platform channel）
    //
    // FlutterImplicitEngineBridge 协议不直接暴露 binaryMessenger 属性，
    // 但暴露 pluginRegistry；通过 registrar(forPlugin:).messenger() 可以拿到
    // FlutterBinaryMessenger，这是 Flutter 标准的插件注册方式。
    //
    // 参考：
    //   - D:\lj\11\tvbox_project\ios\Runner\AppDelegate.swift（旧的 FlutterViewController 模式）
    //   - Flutter 官方插件开发：registrar.messenger() 是 binaryMessenger 的标准来源
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NodeJSBridge") {
      self.nodeJSBridge = NodeJSBridge(messenger: registrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 NodeJSBridge 的 registrar")
    }

    // 注册 PythonBridge（iOS 端 CPython 集成的 platform channel）
    // 与 NodeJSBridge 同一注册模式。Python.xcframework 由 T0-5 集成进工程；
    // 在未集成前，PythonBridge.swift 内的 `import Python` 会编译失败——
    // 因此本注册块与 xcframework 集成**必须同时**进入 CI。
    if let pythonRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PythonBridge") {
      self.pythonBridge = PythonBridge(messenger: pythonRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 PythonBridge 的 registrar")
    }

    // 注册 PipManager（iOS 系统画中画）
    // 与 NodeJSBridge 同一注册模式：registrar(forPlugin:).messenger() 拿
    // FlutterBinaryMessenger，PipManager 内部建 "pip_manager" MethodChannel。
    if let pipRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PipManager") {
      PipManager.shared.register(with: pipRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 PipManager 的 registrar")
    }

    // 注册全局唯一 AVPlayer（应用内画面 + PiP 共用）
    if let avRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AvEngine") {
      AvEngine.shared.register(messenger: avRegistrar.messenger())
      avRegistrar.register(
        AvPlayerViewFactory(messenger: avRegistrar.messenger()),
        withId: "av_player_view"
      )
    } else {
      print("[AppDelegate] ❌ 无法获取 AvEngine 的 registrar")
    }

    // 注册全局唯一 KSPlayer（第四播放核心「FF」：FFmpeg + Metal，MKV 等全格式）
    if let ksRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "KSEngine") {
      KSEngine.shared.register(messenger: ksRegistrar.messenger())
      ksRegistrar.register(
        KSPlayerViewFactory(messenger: ksRegistrar.messenger()),
        withId: "ks_player_view"
      )
    } else {
      print("[AppDelegate] ❌ 无法获取 KSEngine 的 registrar")
    }

    // 注册 TTS（听书朗读）
    //
    // 用系统自带的 AVSpeechSynthesizer，**不引第三方插件**：
    // 新增 pub 依赖若没重新 pod install，插件原生库不会被链接，
    // Flutter 启动时找不到插件会直接崩（flutter_tts 就是这么导致闪退的）。
    if let ttsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "TtsEngine") {
      TtsEngine.shared.register(messenger: ttsRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 TtsEngine 的 registrar")
    }

    // 注册**锁屏 / 控制中心 媒体控制**（音乐）
    //
    // 用户 2026 要求：「苹果系统层次不能控制呢？…不能在控制中心控制？」
    // 原状是全项目 0 处 MPNowPlayingInfoCenter / MPRemoteCommandCenter →
    // 锁屏和控制中心完全看不到音乐、也没法控制。
    //
    // 与上面几个同款模式：registrar(forPlugin:).messenger() 拿
    // FlutterBinaryMessenger，MusicNowPlaying 内部建
    // "tvbox/music_now_playing" MethodChannel。
    //
    // ⚠️ 它只写 nowPlayingInfo（元数据）并接收远程按键，
    //    **不碰** BackgroundAudio 那个保活用的静音 buffer（见该文件注释）。
    if let nowPlayingRegistrar =
      engineBridge.pluginRegistry.registrar(forPlugin: "MusicNowPlaying") {
      MusicNowPlaying.shared.register(messenger: nowPlayingRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 MusicNowPlaying 的 registrar")
    }

    // 注册**听书（TTS）的锁屏 / 控制中心**控制
    // 与 MusicNowPlaying 同文件、同款注册方式；只在 TTS 播放时 activate。
    if let ttsNowPlayingRegistrar =
      engineBridge.pluginRegistry.registrar(forPlugin: "TtsNowPlaying") {
      TtsNowPlaying.shared.register(messenger: ttsNowPlayingRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 TtsNowPlaying 的 registrar")
    }

    // 注册**文件导出**（系统分享面板）：阅读/音乐下载完成后"导出到文件"用
    if let fileExportRegistrar =
      engineBridge.pluginRegistry.registrar(forPlugin: "FileExport") {
      FileExport.shared.register(messenger: fileExportRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 FileExport 的 registrar")
    }

    // 注册 PrefsFlush（让 NSUserDefaults 立刻落盘）
    //
    // 用户 2026-10-14：「为啥非要恢复备份呢？就不能改了就是改了？」
    // iOS 的 defaults 只在系统愿意的时候写盘，App 被硬杀时**本次会话改过的
    // 键**会跟着内存一起丢（表现：刚改的设置没了、别的还在）。
    // 设置改完后由 Dart 侧调这个通道强制 synchronize()，从根上做到"改了就是改了"。
    if let prefsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PrefsFlush") {
      PrefsFlush.shared.register(messenger: prefsRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 PrefsFlush 的 registrar")
    }

    // 注册 OcrEngine（漫画/影视翻译用的本机 OCR，走 Apple Vision）
    if let ocrRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "OcrEngine") {
      OcrEngine.shared.register(messenger: ocrRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 OcrEngine 的 registrar")
    }
  }
}

// MARK: - PrefsFlush

/// 让 `NSUserDefaults` **立刻落盘** 的极小通道。
///
/// ── 为什么需要（用户 2026-10-14）──────────────────────────────
/// 用户的原话："为啥非要恢复备份呢？就不能改了就是改了？"
/// 问得对 —— 备份是补丁，根因是**那次写没有落到磁盘**：
///
/// iOS 的 `NSUserDefaults` 不是每次 set 就写盘，系统只在"它愿意的时候"
/// （周期刷新 / 进后台 / 正常退出）把**整个域**写进 Library/Preferences 的 plist。
/// 于是磁盘上那份永远是"**上一次落盘时的快照**"：
///   · 上次落盘时就存在的键 → 一直在；
///   · 本次会话新写 / 改过的键 → 还没进 plist 就随进程一起没了（被硬杀时）。
/// 表现正是用户看到的：**「我刚改的那个设置没了，别的都还在」**。
///
/// ⇒ 正确做法不是"事后恢复"，而是**写完就落盘**：设置改完立刻 synchronize()，
///   内存与 plist 一致，"改了就是真的改了"。
///
/// ── 关于 synchronize() ──────────────────────────────────────
/// Apple 从 iOS 12 起把它标记为"通常不需要"（自动落盘时机已足够激进），
/// 但**它并没有失效**，仍是"强制立刻写盘"的唯一公开手段，代价只是一次
/// 几 KB 的写盘。调用时机很克制：设置被改动后（见 Dart 侧
/// `PrefsMirror.snapshotSoon` / `snapshot`）。
///
/// ⚠️ 刻意**不新建 .swift 文件**：本工程 project.pbxproj 是逐文件登记的
/// （PBXBuildFile + PBXFileReference + group + Sources 四处都要加），
/// 新文件漏登记就是"编译不过或根本没编进去"。放在 AppDelegate 这个
/// 已在编译列表里的文件内，零工程文件改动。
final class PrefsFlush {
  static let shared = PrefsFlush()
  private static let channelName = "tvbox/prefs_flush"

  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "flush":
        // 强制把内存里的所有 defaults 写进 plist。
        // `_ =` 是必须的：synchronize() 有 Bool 返回值，忽略它 Swift 会给
        // "result of call is unused" 警告（CI 里是噪音）。
        _ = UserDefaults.standard.synchronize()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}

// MARK: - OcrEngine

/// 本机 OCR（Apple Vision）—— 漫画 / 影视翻译管线的第一环。
///
/// ── 为什么用 Vision 而不是 ML Kit / PaddleOCR ───────────────────
/// · 系统自带、**离线**、免下载模型，包体不增加；
/// · 支持 `zh-Hans / zh-Hant / en-US / ja-JP / ko-KR`（正是漫画最常见语种）；
/// · 返回每个文本块的**归一化坐标**（左上原点），Flutter 侧才能把译文
///   精确盖回原位置。
///
/// 通道：`tvbox/ocr`，方法 `recognize`，参数 `{bytes, languages}`。
/// 返回 `[{text, x, y, w, h, confidence}]`（坐标 0~1）。
final class OcrEngine {
  static let shared = OcrEngine()
  private static let channelName = "tvbox/ocr"
  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      guard call.method == "recognize" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let typed = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 bytes", details: nil))
        return
      }
      let langs = (args["languages"] as? [String]) ?? ["zh-Hans", "en-US"]
      // Vision 是同步阻塞的，必须离开主线程，否则大图会卡住 UI
      DispatchQueue.global(qos: .userInitiated).async {
        let blocks = Self.recognize(typed.data, languages: langs)
        DispatchQueue.main.async { result(blocks) }
      }
    }
    channel = ch
  }

  private static func recognize(_ data: Data, languages: [String]) -> [[String: Any]] {
    guard let image = UIImage(data: data), let cg = image.cgImage else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(iOS 16.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
    }
    // 传了 Vision 不认的语言会抛异常 ⇒ 先按系统支持清单过滤
    let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
      for: .accurate, revision: request.revision)) ?? languages
    let picked = languages.filter { supported.contains($0) }
    request.recognitionLanguages = picked.isEmpty ? supported : picked

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
      try handler.perform([request])
      let obs = request.results ?? []
      var out: [[String: Any]] = []
      out.reserveCapacity(obs.count)
      for o in obs {
        guard let top = o.topCandidates(1).first else { continue }
        let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let bb = o.boundingBox // 归一化，原点在左下
        out.append([
          "text": text,
          "x": Double(bb.minX),
          // Vision 用左下原点，Flutter 用左上 ⇒ 翻一下
          "y": Double(1.0 - bb.maxY),
          "w": Double(bb.width),
          "h": Double(bb.height),
          "confidence": Double(top.confidence),
        ])
      }
      return out
    } catch {
      NSLog("[OcrEngine] Vision 识别失败: \(error)")
      return []
    }
  }
}
