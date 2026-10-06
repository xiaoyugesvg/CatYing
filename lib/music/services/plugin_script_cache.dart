import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// MusicFree 插件脚本的**文件缓存**。
///
/// ── 为什么需要它（性能，不是洁癖）────────────────────────────────
/// 插件脚本原来直接存在 `ThirdPartySourceStore` 里，而那个 Store 是
/// **一整个 JSON 塞进 SharedPreferences**（键 `music.thirdPartySources.v1`）。
///
/// 内置插件从 10 个扩到 **50 个**（用户 2026 要求"这些源全部要加进去"）后：
///   · 实测 50 个插件**总计约 4.2 MB**
///   · 4.2 MB 的 JSON 要在**启动时**读出 + `jsonDecode` + 再 `jsonEncode` 写回
///   · 这会让冷启动**明显卡顿**（prefs 是同步读取，全在主线程）
///
/// 所以：**脚本体写文件**，prefs 里仍然保留完整源对象（用户要的"列表里
/// 有 50 个源"照旧满足）—— 但**下载来的**脚本在下次启动时优先从文件读，
/// 不强制把所有字节在启动路径上过一遍。
///
/// ── 目录 ────────────────────────────────────────────────────────
/// `<Documents>/musicfree_plugins/<插件文件名>`
///
/// 用文件名（不是 url）做键：`plugins.json` 里的 url 形如
/// `…/plugins/kugou-source.plugin.v1.9.18.js`，文件名自带版本号，
/// 所以"文件名变了"就等价于"有新版本"，天然避免了缓存过期问题。
class PluginScriptCache {
  PluginScriptCache._();
  static final PluginScriptCache instance = PluginScriptCache._();

  Directory? _dir;

  Future<Directory> _ensureDir() async {
    if (_dir != null && await _dir!.exists()) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/musicfree_plugins');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  /// 读缓存；没有（或读失败）返回 null。
  ///
  /// ⚠️ **不抛异常**：缓存只是加速手段，它坏了应该安静地回落到"重新下载"，
  ///    不该让整个内置源注册流程失败。
  Future<String?> read(String fileName) async {
    if (fileName.trim().isEmpty) return null;
    try {
      final d = await _ensureDir();
      final f = File('${d.path}/$fileName');
      if (!await f.exists()) return null;
      final s = await f.readAsString();
      return s.trim().isEmpty ? null : s;
    } catch (e) {
      debugPrint('[PluginCache] 读 $fileName 失败: $e');
      return null;
    }
  }

  /// 写缓存（失败静默 —— 下次再下就是了）。
  Future<void> write(String fileName, String script) async {
    if (fileName.trim().isEmpty || script.trim().isEmpty) return;
    try {
      final d = await _ensureDir();
      await File('${d.path}/$fileName').writeAsString(script);
    } catch (e) {
      debugPrint('[PluginCache] 写 $fileName 失败: $e');
    }
  }

  /// 缓存目录里已有的文件名（用于"哪些插件已经下过"的快速判断）。
  ///
  /// ⚠️ 返回空集合而不是抛异常：目录不存在 = 什么都没下过，完全正常。
  Future<Set<String>> cachedFileNames() async {
    try {
      final d = await _ensureDir();
      final out = <String>{};
      await for (final e in d.list()) {
        if (e is File) {
          out.add(e.uri.pathSegments.last);
        }
      }
      return out;
    } catch (e) {
      debugPrint('[PluginCache] 列目录失败: $e');
      return <String>{};
    }
  }

  /// 清除全部缓存（"恢复默认"/清理缓存时用）。
  Future<void> clear() async {
    try {
      final d = await _ensureDir();
      if (await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (e) {
      debugPrint('[PluginCache] 清空失败: $e');
    }
  }
}
