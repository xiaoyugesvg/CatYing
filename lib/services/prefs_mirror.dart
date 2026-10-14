import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 设置项的整体「文件镜像」兜底。
///
/// ── 为什么需要 ──────────────────────────────────────────────
/// iOS 上**所有**设置都躺在同一个 NSUserDefaults plist 里。App 一旦被信号
/// （SIGSEGV / SIGABRT）**直接杀死**——例如 CPython watchdog 崩溃
/// （`Runner-2026-10-13-230423.ips`：`PyThreadState_SetAsyncExc` 在无线程状态的
/// GCD 队列上解引用空指针）——plist 往往来不及落盘 ⇒ **整域设置全丢**
/// （音乐 / 阅读 / 弹幕 / 直播 / 小程序 一起没，用户 2026-10-13 反馈）。
///
/// 这里把 prefs 全量快照写到一个**独立文件**（`<Documents>/prefs_mirror.json`）。
/// 文件写是一次独立的 write(flush)，不受 plist 影响；启动时若发现 prefs 空了、
/// 而镜像有数据，就整份恢复。
class PrefsMirror {
  PrefsMirror._();

  static const String _fileName = 'prefs_mirror.json';

  static Timer? _timer;

  static Future<File?> _mirrorFile() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/$_fileName');
    } catch (_) {
      return null;
    }
  }

  /// 启动**最早期**调用（必须早于任何服务读 prefs）。
  ///
  /// 只在 prefs 一个键都没有、而镜像里有数据时才恢复 —— 避免把用户
  /// 已经删掉的设置又"复活"回来。
  static Future<void> restoreIfLost() async {
    try {
      final f = await _mirrorFile();
      if (f == null || !await f.exists()) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getKeys().isNotEmpty) return; // prefs 正常 → 不动
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      for (final e in map.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (v is bool) {
          await prefs.setBool(k, v);
        } else if (v is int) {
          await prefs.setInt(k, v);
        } else if (v is double) {
          await prefs.setDouble(k, v);
        } else if (v is String) {
          await prefs.setString(k, v);
        } else if (v is List) {
          await prefs.setStringList(k, v.map((x) => x.toString()).toList());
        }
      }
      AppLog.instance
          .log('[PrefsMirror] prefs 为空，已从文件镜像恢复 ${map.length} 项设置');
    } catch (e) {
      AppLog.instance.log('[PrefsMirror] 镜像恢复失败: $e');
    }
  }

  /// 把当前 prefs 全量快照写进镜像文件。
  static Future<void> snapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      if (keys.isEmpty) return;
      final map = <String, dynamic>{};
      for (final k in keys) {
        final v = prefs.get(k);
        if (v == null) continue;
        if (v is List) {
          map[k] = v.map((x) => x.toString()).toList();
        } else if (v is bool || v is int || v is double || v is String) {
          map[k] = v;
        }
      }
      final f = await _mirrorFile();
      await f?.writeAsString(jsonEncode(map), flush: true);
    } catch (e) {
      AppLog.instance.log('[PrefsMirror] 镜像写入失败: $e');
    }
  }

  /// 起一个低频周期快照（默认 15s）。
  ///
  /// 为什么用轮询而不是 hook 每一次 prefs 写入：写入点散落几十处，逐一挂钩
  /// 侵入性太大且容易漏；15s 写一个几 KB 的 JSON 开销可忽略，且能保证
  /// "崩溃前最多丢 15s 内的改动"。
  static void startAutoSnapshot({Duration interval = const Duration(seconds: 15)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(snapshot()));
    AppLog.instance.log('[PrefsMirror] 自动快照已启动（每 ${interval.inSeconds}s）');
  }

  static void stopAutoSnapshot() {
    _timer?.cancel();
    _timer = null;
  }
}
