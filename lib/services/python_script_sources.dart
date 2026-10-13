// lib/services/python_script_sources.dart
//
// 远端 Python 脚本源（TVBox 聚合配置里 type=3、api/ext 指向远端 .py）的下载与注册。
// -----------------------------------------------------------------------------
// 与「用户手动导入 .py 文件」共用同一个 CPython 引擎、同一套目录约定
// （<Documents>/python-project/src/spider/video/<key>.py）：
//   · 首次使用时把 .py 下载到该目录并注册进引擎（reload 语义，立即生效）；
//   · 之后重启由 PythonSourcesService.syncToEngine() 自动重新注册，无需再下载。
//
// key 为什么用 URL 哈希：
//   huahua.json 这类聚合配置的脚本名是 `🐱优酷.py` / `腾讯视频.py`，而引擎侧
//   （spider_runner._load_module）只接受 [A-Za-z0-9_-]，中文/emoji 作模块名也不稳定
//   ⇒ 统一映射成 `psrc_<md5(url) 前 12 位>`（确定性：同一 URL 永远同一 key）。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_log.dart';
import 'network_manager.dart';
import 'python_manager.dart';
import 'python_sources_service.dart';

class PythonScriptSources {
  static final PythonScriptSources _instance = PythonScriptSources._internal();
  static PythonScriptSources get instance => _instance;
  PythonScriptSources._internal();

  /// 本会话内已确认注册进引擎的 key（避免每次调用都重跑 install_source）
  final Set<String> _registeredThisSession = {};

  /// 最近一次失败的**可读原因**（供上层显示，别让用户只看到"啥都没有"）
  String? lastError;

  /// URL → 引擎 key（确定性哈希，纯 ASCII，满足引擎的 key 校验）
  static String keyFor(String url) {
    final h = md5.convert(utf8.encode(url.trim())).toString();
    return 'psrc_${h.substring(0, 12)}';
  }

  /// 确保 [url] 的 .py 已落盘并注册进引擎，返回引擎 key；失败返回 null。
  ///
  /// 本会话已注册过 → 直接返回 key（零开销）。失败时把原因写进 [lastError]。
  Future<String?> ensureInstalled(String url) async {
    final u = url.trim();
    lastError = null; // 每轮清一次，避免把上次源的原因报给这次
    if (u.isEmpty) {
      lastError = '脚本地址为空';
      return null;
    }
    final key = keyFor(u);
    if (_registeredThisSession.contains(key)) return key;

    // 启动时的 syncToEngine() 已经把 <Documents> 下所有 .py 全量注册过一遍
    // （我们的 psrc_*.py 就写在那里）⇒ 这时不必再写一次文件 + 重新编译模块，
    // 直接返回 key 即可。免掉每次冷启动每个 py 源的一次重复注册。
    if (PythonSourcesService.instance.isRegisteredInSession('video', key)) {
      _registeredThisSession.add(key);
      return key;
    }

    if (!PythonManager.instance.isIOS) {
      lastError = 'Python 引擎仅支持 iOS';
      AppLog.instance.w('[PyScript] 远端 .py 源仅 iOS 支持：$u');
      return null;
    }
    if (!await PythonManager.instance.ensureStarted()) {
      lastError = 'Python 引擎启动失败（${PythonManager.instance.lastError.value ?? "详见日志"}）';
      AppLog.instance.w('[PyScript] Python 引擎未就绪，无法注册 $u');
      return null;
    }

    // 已有本地缓存就直接用；没有才下载（避免每次启动都拉网络）
    String? code = await PythonSourcesService.instance.readSource('video', key);
    if (code == null || code.trim().isEmpty) {
      try {
        code = await NetworkManager.instance.getString(u);
      } catch (e) {
        lastError = '脚本下载失败: $e';
        AppLog.instance.w('[PyScript] 下载 .py 失败 $u: $e');
        return null;
      }
      if (code.trim().isEmpty) {
        lastError = '脚本下载内容为空（$u）';
        AppLog.instance.w('[PyScript] 下载 .py 内容为空 $u');
        return null;
      }
    }

    final r =
        await PythonSourcesService.instance.installSource('video', key, code);
    if (!r.ok) {
      lastError = '脚本注册失败: ${r.message}';
      AppLog.instance.w('[PyScript] 注册 .py 源失败 $u: ${r.message}');
      return null;
    }
    _registeredThisSession.add(key);
    AppLog.instance.log('[PyScript] 远端 .py 源已就绪 $key ← $u');
    return key;
  }
}
