// lib/reading/services/bsr_independent_layout.dart
//
// ✅ **在线书源阅读器（`book_source_reader_page`）的「独立排版 / 独立设置」存储** ✓
//    （本会话新增 ✓ —— 对应阅读器里那 3 个此前是"装饰开关"的入口 ✗ → 正在接线 ✓）
//
// 为什么**不复用** `ReaderOverrideService` ✗（重要 ✓，别以后又想去"统一" ✗）：
//   · 那个服务 key 是 `bookId` ✓，存的是 fontSize / lineHeight / 边距 / 字体 / 模式 等 ✓，
//     且 `setIndependentBook()` 是"**用全局设置服务的当前快照**建条目"✓；
//   · 而书源阅读器的排版存在**本页自己的 prefs** 里 ✓，还多出
//     **标题对齐 / 标题样式 / 底线样式 / 背景** 等那个服务**根本没有的字段** ✗；
//   ⇒ 硬接会把"基线来源"与"字段集合"两处都对不上 ✗（开关能拨、值却不一致 ✓ 更难查 ✗）。
//
// 所以这里**自包含**地实现 ✓（**不碰**本地图书 / 漫画那两条已有链路 ⛔ 零风险 ✓）：
//   · 一本书 = 一个键 ✓，身份与**进度 / 笔记 / 书签**完全一致 ✓：
//       `'${source.id}.${bookName}'`（调用方传入 ✓，见页面里的 `_progressKey` ✓）
//   · 存储约定与 `ReaderOverrideService` **保持同一种语义** ✓（便于理解 ✓）：
//       **键存在 = 独立排版 ON** ✓（值为该书的排版快照 JSON ✓）；**删键 = OFF** ✓（回退全局 ✓）
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[BsrIndependentLayout] $message');
}

/// 在线书源阅读器的「独立排版」覆盖存储（单例 ✓）。
class BsrIndependentLayout {
  BsrIndependentLayout._();
  static final BsrIndependentLayout instance = BsrIndependentLayout._();

  /// 键前缀 ✓。整键 = `bsr.indep.<bookKey>` ✓（与页面里 `bsr.bookmarks.<key>` 同风格 ✓）
  static const String keyPrefix = 'bsr.indep.';

  String _fullKey(String bookKey) => '$keyPrefix$bookKey';

  /// 该书是否已开启「独立排版」✓（= 覆盖键存在 ✓）
  Future<bool> isIndependent(String bookKey) async {
    if (bookKey.trim().isEmpty) return false;
    try {
      final p = await SharedPreferences.getInstance();
      return p.containsKey(_fullKey(bookKey));
    } catch (e) {
      _log('读取独立排版开关失败: $e');
      return false;
    }
  }

  /// 读取该书的排版快照 ✓；**未独立 / 解析失败 → null** ✓（调用方据此回退全局 ✓）
  Future<Map<String, dynamic>?> read(String bookKey) async {
    if (bookKey.trim().isEmpty) return null;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_fullKey(bookKey));
      if (raw == null || raw.isEmpty) return null;
      final v = jsonDecode(raw);
      if (v is Map) return v.cast<String, dynamic>();
      _log('独立排版内容不是 Map，按未独立处理');
      return null;
    } catch (e) {
      // 解析失败**不崩** ✓：当成未独立 ✓（用户仍能正常阅读 ✓ 只是用全局设置 ✓）
      _log('读取独立排版失败（按未独立处理）: $e');
      return null;
    }
  }

  /// 开启独立并写入快照 ✓（`snapshot` 由页面给出 ✓ = 本页**全部**排版项 ✓）。
  /// ⚠️ `snapshot` 为空也**照样建键** ✓ —— "开了独立、暂时与全局同值"是**合法状态** ✓，
  ///   之后用户在独立模式下改任何一项都会写进来 ✓（不会出现"开了但存不下"✗）。
  Future<bool> enable(String bookKey, Map<String, Object?> snapshot) async {
    if (bookKey.trim().isEmpty) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_fullKey(bookKey), jsonEncode(snapshot));
      _log('已开启独立排版: $bookKey（${snapshot.length} 项）');
      return true;
    } catch (e) {
      _log('开启独立排版失败: $e');
      return false;
    }
  }

  /// 更新快照 ✓（已开启时用 ✓；**未开启则什么都不做** ✓ —— 不偷偷建键 ✗）
  Future<void> update(String bookKey, Map<String, Object?> snapshot) async {
    if (bookKey.trim().isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (!p.containsKey(_fullKey(bookKey))) return;
      await p.setString(_fullKey(bookKey), jsonEncode(snapshot));
    } catch (e) {
      _log('更新独立排版失败: $e');
    }
  }

  /// 关闭独立 ✓（**删键** ✓ → 回退全局 ✓，与 `ReaderOverrideService` 的语义一致 ✓）
  Future<void> disable(String bookKey) async {
    if (bookKey.trim().isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_fullKey(bookKey));
      _log('已关闭独立排版: $bookKey');
    } catch (e) {
      _log('关闭独立排版失败: $e');
    }
  }
}
