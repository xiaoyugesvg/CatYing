// lib/reading/cores/reader_core_prefs.dart
//
// 阅读核心的**选择与配置**持久化。
//
// ── 为什么单独一个文件 ───────────────────────────────────────
//   · 与影视/直播/音乐的"播放器核心偏好各自独立持久化"同一个约定，**互不影响**；
//   · 也不把这两个键混进阅读模块那 ~40 个设置键里 —— 核心是自成一块的，
//     配置也该自成一块（用户 2026-10-14 明确要求别把三个模块搅在一起）。
//
// ── 两个键 ─────────────────────────────────────────────────
//   · `reader_core_id`        选了哪个核心（**空串 = 不启用核心，走现有链路**）
//   · `reader_core_source_url` 该核心要用的源脚本地址（Python 核心就是 .py 地址）
//
// 「不启用核心」是默认值，也是安全阀：只要没配，阅读器一律回落现有链路 ⇒
// 这个机制上线**不会影响任何现存功能**。

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_log.dart';
import '../../services/prefs_mirror.dart';
import 'python_core.dart';
import 'reader_core.dart';

class ReaderCorePrefs {
  ReaderCorePrefs._();
  static final ReaderCorePrefs instance = ReaderCorePrefs._();

  static const String _kCoreId = 'reader_core_id';
  static const String _kSourceUrl = 'reader_core_source_url';

  String _coreId = '';
  String _sourceUrl = '';

  /// 当前选中的核心 id（空串 = 不启用）
  String get coreId => _coreId;

  /// 源脚本地址（Python 核心用）
  String get sourceUrl => _sourceUrl;

  /// 当前生效的核心；**没配 / 核心不存在 / 核心能力不足 → null**，
  /// 调用方据此回落到现有链路（不要把它当错误）。
  ReaderCore? get activeCore {
    if (_coreId.isEmpty) return null;
    return ReaderCoreRegistry.byId(_coreId);
  }

  /// 启动时调用一次（在 `PrefsMirror.restoreIfLost()` **之后**，
  /// 保证读到的是被镜像修正过的值）。
  Future<void> init() async {
    // 注册可用核心（幂等）。以后加核心就在这后面再加一行。
    ReaderCoreRegistry.register(PythonCore.instance);
    try {
      final prefs = await SharedPreferences.getInstance();
      _coreId = (prefs.getString(_kCoreId) ?? '').trim();
      _sourceUrl = (prefs.getString(_kSourceUrl) ?? '').trim();
    } catch (e) {
      AppLog.instance.log('[ReaderCore] 配置读取失败: $e');
    }
    _applyToCore();
    AppLog.instance.log('[ReaderCore] 就绪：core=${_coreId.isEmpty ? "（未启用，走现有链路）" : _coreId}');
  }

  /// 把源地址同步给需要它的核心（Python 核心靠它知道用哪个脚本）
  void _applyToCore() {
    PythonCore.instance.sourceUrl = _sourceUrl;
  }

  /// 切换核心（空串 = 关闭核心，回落现有链路）
  Future<void> setCore(String id) async {
    _coreId = id.trim();
    _applyToCore();
    await _persist(_kCoreId, _coreId);
  }

  /// 设置源脚本地址
  Future<void> setSourceUrl(String url) async {
    _sourceUrl = url.trim();
    _applyToCore();
    await _persist(_kSourceUrl, _sourceUrl);
  }

  Future<void> _persist(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      // 与其它设置写入点一致：改完即落盘 + 刷镜像（这个 App 被硬杀是常态）
      PrefsMirror.snapshotSoon();
    } catch (e) {
      AppLog.instance.log('[ReaderCore] 保存失败 $key: $e');
    }
  }
}
