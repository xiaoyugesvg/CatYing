import 'dart:io';

import 'package:flutter/foundation.dart';

/// 磁盘缓存**容量守卫** ✓ —— 统计目录体积 + 按"最久未用"淘汰到上限 ✓。
///
/// ── 为什么需要它（今天核实的缺口 ✗）───────────────────────────
/// 设置页里有两个**看起来很正规、实际没人读**的滑杆 ✗✗：
///   · `onlineBookCacheGb`（在线书临时缓存上限 ✓）
///   · `onlineComicCacheGb`（在线漫画图片缓存上限 ✓）
/// 它们只有 getter/setter/落盘 ✓，**全模块 0 个读取点** ✗ → 拨了没有任何效果 ✓。
/// 而三个真实的磁盘缓存（`BookContentCacheService` ✓ `BookPageCacheService` ✓
/// `SourceCoverCache` ✓）**没有总量上限** ✗ —— 读得越多攒得越多 ✓。
/// 本文件提供"**量体积 + 淘汰**"这两件最基础的能力 ✓，供上面两处接线复用 ✓✓。
///
/// ── 设计取舍 ──────────────────────────────────────────────────
///   · **不做后台定时清理** ✗：只提供**可被调用**的纯函数 ✓，何时调用由各缓存自己决定 ✓
///     （各缓存知道自己什么时候写入 ✓，也知道自己的目录在哪 ✓）。
///   · **只删文件，不删目录** ✓；且**只在传入的目录内**删除 ✓（不递归到父级 ✗）。
///   · 淘汰顺序 = **最后修改时间最旧优先** ✓（= 最久没被写入 = 最可能"用不到"✓，
///     与磁盘缓存的常规 LRU 近似 ✓；比"随机删"和"按大小删"都稳妥 ✓）。
///   · 删除失败**不抛** ✗：记一条日志继续 ✓（缓存目录里偶发占用/权限问题不该让阅读崩 ✗）。
class CacheCapacity {
  CacheCapacity._();

  /// 统计目录（含子目录）内所有文件的**总字节数** ✓；目录不存在返回 0 ✓。
  static Future<int> dirBytes(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } catch (_) {
          // 单个文件读不到长度 → 跳过 ✓（不影响整体估算 ✓）
        }
      }
      return total;
    } catch (e) {
      _log('统计缓存体积失败（按 0 处理）: ${dir.path} - $e');
      return 0;
    }
  }

  /// 把 [dir] 内的文件体积压到 [maxBytes] 以内 ✓，返回**实际删除的字节数** ✓。
  ///
  /// · `maxBytes <= 0` → **不做任何事** ✓（0/负值视为"未设置上限"✗，
  ///   绝不能理解成"上限为 0 → 全删光" ✗✗）。
  /// · 已在上限内 → 直接返回 0 ✓（最常见的快路径 ✓，不 list 目录 ✓）。
  /// · 删除按 **mtime 升序**（最旧先删 ✓），删够即停 ✓。
  /// · [keepFiles] 里的文件名**永不删除** ✓（供"正在读的那本书"这类白名单 ✓）。
  /// · [dryRun] 只计算不删除 ✓（供设置页预览"将释放多少" ✓）。
  static Future<int> evictToLimit(
    Directory dir,
    int maxBytes, {
    Set<String> keepFiles = const {},
    bool dryRun = false,
  }) async {
    if (maxBytes <= 0) return 0;
    try {
      if (!await dir.exists()) return 0;

      final files = <({File file, int size, DateTime mtime})>[];
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          total += st.size;
          files.add((file: e, size: st.size, mtime: st.modified));
        } catch (_) {
          // 读不到状态 → 跳过 ✓（保守：不删拿不准的东西 ✓）
        }
      }
      if (total <= maxBytes) return 0;

      // 最旧的先淘汰 ✓
      files.sort((a, b) => a.mtime.compareTo(b.mtime));

      var freed = 0;
      for (final f in files) {
        if (total - freed <= maxBytes) break;
        final name = f.file.uri.pathSegments.isNotEmpty
            ? f.file.uri.pathSegments.last
            : '';
        if (name.isNotEmpty && keepFiles.contains(name)) continue;
        if (dryRun) {
          freed += f.size;
          continue;
        }
        try {
          await f.file.delete();
          freed += f.size;
        } catch (e) {
          _log('删除缓存文件失败（跳过）: ${f.file.path} - $e');
        }
      }
      _log('缓存淘汰: ${dir.path} 释放 ${_mb(freed)}（上限 ${_mb(maxBytes)}${dryRun ? ' · 试算' : ''}）');
      return freed;
    } catch (e) {
      _log('缓存淘汰失败（忽略）: ${dir.path} - $e');
      return 0;
    }
  }

  /// GB（设置页里的单位 ✓）→ 字节 ✓；非法值返回 0（= 未设置上限 ✓，不删任何东西 ✓）。
  static int gbToBytes(int gb) => gb <= 0 ? 0 : gb * 1024 * 1024 * 1024;

  /// 供日志/界面显示 ✓（保留 1 位小数 ✓）
  static String humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _mb(int bytes) => humanBytes(bytes);

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[CacheCapacity] $msg');
  }
}
