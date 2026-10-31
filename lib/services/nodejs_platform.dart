// lib/services/nodejs_platform.dart
//
// Node.js 跨平台抽象层
// -----------------------------------------------------------------------------
// 目前只有 **iOS** 有实现（platform channel → Swift → NodeMobile.xcframework）。
// Windows / Android 的实现从未落地；原先为 Windows 预留的"运行时 zip 下载"
// 接口（`NodeDownloadConfig` / `isNodeRuntimeInstalled` /
// `downloadAndExtractNodeRuntime`）已于 2026-10-26 删除 —— 全仓无调用方，
// 留着只会让人误以为支持 Windows。
//
// 跨端统一接口在 [NodeJSPlatform] 抽象类里。
// NodeJSManager 用 `Platform.isXxx` 选具体实现。

import 'dart:async';

/// Node.js 平台抽象接口
///
/// **各端必须实现**的核心方法（启动/停止/加载源/路径）。
abstract class NodeJSPlatform {
  // ============================================================
  // 运行时状态
  // ============================================================
  bool get isRunning;
  bool get isNodeReady;
  int get nativeServerPort;
  int get managementPort;
  int get spiderPort;

  /// 引擎槽位里**当前驻留的源标识** —— 与调用方传给 [loadSource] 的字符串
  /// **完全一致**（不做规范化，方便上层直接做字符串比较）。
  ///
  /// ── 为什么需要（2026-10-31，用户：「本地JS 和订阅还是引擎冲突吗」「不要再串了」）──
  /// Node 引擎是**单槽位**（`main.js` 里 `sourceModule` 一个变量 + `spiderPort`
  /// 一个端口），但上层 `SpiderService` 自己另存了一份"上次载入了谁"
  /// （`_loadedScriptUrl`）。两份记录一旦不一致，请求就会带着 A 的 key
  /// 打到 B 的服务上 —— 表现为 404 或「切了源内容没变 / 全是另一个源的内容」。
  ///
  /// 造成不一致的路径：绕开 `SpiderService._ensureNodeScript` 直接调
  /// `NodeJSManager.loadSource()` 的地方（手动加载引擎、未来的新入口），
  /// 它们换了槽位却没人更新 Dart 那份记录。
  ///
  /// 所以这里把「槽位里是谁」收敛成**引擎侧唯一真源**：只有真正载入成功的
  /// 那一刻才写，上层每次判定前对齐一次即可。
  ///
  /// 未载入 / 已清空时返回空串。
  String get loadedScriptId => '';

  // ============================================================
  // 启动 / 停止 Node.js
  // ============================================================

  /// 启动 Node.js 进程
  ///
  /// - Windows: 调 `Process.start(node.exe, [main.js, --native-port ...])`
  /// - iOS:     调 platform channel → Swift → `node_start(argc, argv)`
  /// - Android: 调 platform channel → Kotlin → JNI 调 libnode
  ///
  /// 三端都需要：
  /// 1. 把 `main.js` 准备好（Windows: rootBundle→本地；iOS: bundle resource；Android: assets）
  /// 2. 起本地 HTTP server 收 Node.js 通知（用 dart:io，三端统一）
  /// 3. 通过 `--native-port` 把 HTTP server 端口传给 Node.js
  ///
  /// 返回 `isNodeReady`（Node.js 已发出 ready 消息）
  Future<bool> startNodeJS();

  void stopNodeJS();

  void forceResetRunningState();

  /// 等待 Node.js 发出 `ready` 消息
  Future<bool> waitForNodeReady();

  /// 等待 Spider HTTP server 端口打开
  Future<bool> waitForSpiderPort();

  // ============================================================
  // 源管理
  // ============================================================

  /// 从 URL 加载源（MD5 校验 + 下载 + 通过 management 端口通知 Node.js）
  ///
  /// 返回 `(success, message?)`
  Future<(bool success, String? message)> loadSource(String urlString);

  /// 删除已下载的源文件
  Future<bool> deleteSource();

  /// 文档目录下 nodejs source 目录的绝对路径
  /// - Windows / Android: `getApplicationDocumentsDirectory()/nodejs/source`
  /// - iOS:               `<Documents>/nodejs-project/src/source`
  Future<String> getDocumentsSourcePath();

  /// 最近一次实际载入的源缓存目录（按源 URL 分目录缓存）。
  /// 恢复流程（scene_recovery）要重新 `/source/loadPath` 时必须用这个，
  /// 不能再用根目录 —— 根目录下已没有 `index.js`。
  Future<String?> getLastSourceCachePath() async => null;

  // ============================================================
  // 端口注入
  // ============================================================

  /// 由 [NodeJSManager] 在启动 HTTP server 后注入端口
  /// Node.js 通过 `--native-port $port` 拿到这个端口，回调通知 Dart
  void setNativeServerPort(int port);

  // ============================================================
  // 小程序 Node 后端（manifest.json 的 `node` 字段）
  // ============================================================

  /// 启动某个小程序自带的 Node 服务，返回它的 base URL（`http://127.0.0.1:<port>`）。
  ///
  /// 默认实现返回 null（该平台不支持 / 还没有实现）。iOS 走 management 端口
  /// 的 `/miniapp/start`，让 Node 侧 require 小程序的 `server/index.js` 并 listen。
  Future<String?> startMiniAppService({
    required String appId,
    required String dir,
    String entry = 'server/index.js',
    String config = 'server/index.config.js',
  }) async =>
      null;

  /// 停止某个小程序的 Node 服务（不存在时静默返回）。
  Future<void> stopMiniAppService(String appId) async {}

  /// HTTP server 收到 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type);

  /// HTTP server 收到 `/onMessage` 时调用
  void onMessage(String message);
}
