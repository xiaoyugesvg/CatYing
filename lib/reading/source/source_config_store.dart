// 漫画源配置存储（独立通道，单例）。
//
// 负责 SourceDefinition 的本地加载与持久化、远端拉取。
//
// 内置漫画源已移除（用户 2026-10-13）：软件**不再自带**任何漫画源。
//   · `loadLocal()` 只读文档目录 `sources.json`（用户导入 / 云端更新覆盖层）；
//     没有就是**空列表**（首装无源是预期行为）。
//   · 装源的两条路：漫画源仓库填「云端地址」（fetchRemote 拉 `{"version":1,"sources":[…]}`），
//     或在仓库页直接导入 JSON。
//
// fetchRemote 读用户配置的云端 URL（SettingsService.sourceRepoUrl）：为空返回 null（不拉取，
// 沿用本地）；非空则 Dio 拉取 sources.json -> 校验 -> saveLocal -> 返回新 defs。
// 风格参考 RemoteConfigService（Dio + 本地缓存）但与之解耦，独立演进。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/settings_service.dart';
import 'source_definition.dart';
import 'global_proxy.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceConfigStore] $message');
  }
}

const _kDocFileName = 'sources.json';
// 云端源迁移标记：升级到本版本时一次性清除本地源覆盖层（旧版本缓存/自定义）。
const _kCloudOnlyMigrationDone = 'source_cloud_only_migration_done';
// 用户主动「清空」标记（保留：saveLocal 会清除它，兼容老装机遗留值）。
const _kSourcesCleared = 'sources_cleared';

class SourceConfigStore {
  SourceConfigStore._();
  static final SourceConfigStore _instance = SourceConfigStore._();
  factory SourceConfigStore() => _instance;

  /// 升级到本版本的一次性迁移：清除文档目录 sources.json 覆盖层。
  ///
  /// 旧版本可能在本地下沉了过时/自定义的源配置；升级首跑清掉本地覆盖层。
  ///
  /// ⚠️ 内置漫画源已移除（用户 2026-10-13）⇒ 清掉覆盖层之后是「**无源**」，
  /// 由用户在漫画源仓库填云端地址或导入 JSON 重新装源。
  /// 迁移本身仍然是对的：旧版本下沉的过时/自定义配置确实该清
  /// （它已备份为 `sources.json.bak`，可人工找回，不会不可恢复地丢）。
  /// 用 SharedPreferences 标记保证仅执行一次（失败不置位，下次重试）。
  Future<void> _migrateOnceIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kCloudOnlyMigrationDone) ?? false) return;
      await resetToLocal();
      await prefs.setBool(_kCloudOnlyMigrationDone, true);
      _log('已执行云端源迁移：清除本地源覆盖层');
    } catch (e) {
      _log('云端源迁移失败（下次重试）: $e');
    }
  }

  /// 加载源配置定义：只读文档目录 sources.json（用户导入 / 云端更新覆盖层）。
  ///
  /// 内置漫画源已移除（用户 2026-10-13）：文档目录没有配置就是**无源**，
  /// 由用户在「漫画源仓库」填云端地址（fetchRemote）或导入 JSON，不再回退随包内置源。
  Future<List<SourceDefinition>> loadLocal() async {
    // 升级一次性迁移：先清掉旧版本本地源覆盖层（仅一次）。
    await _migrateOnceIfNeeded();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final parsed = SourceConfigFile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (parsed.sources.isNotEmpty) {
          _log('加载文档目录配置: ${parsed.sources.length} 源');
          return parsed.sources;
        }
      }
    } catch (e) {
      _log('文档目录配置读取失败: $e');
    }

    _log('无本地源配置（未从云端更新过，也未导入）');
    return [];
  }

  /// 写入文档目录（远端更新或自定义后调用）。
  Future<void> saveLocal(List<SourceDefinition> defs) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_kDocFileName');
    final fileObj = SourceConfigFile(version: 1, sources: defs);
    await file.writeAsString(jsonEncode(fileObj.toJson()));
    // 有写入即视为用户重新拥有源配置：清除「已清空」标记，恢复内置兜底语义。
    await clearClearedFlag();
    _log('已写入文档目录配置: ${defs.length} 源');
  }

  /// 标记「用户已清空漫画源」：此后 loadLocal 不回退内置源。
  Future<void> markCleared() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSourcesCleared, true);
    _log('已标记清空漫画源（不回退内置源）');
  }

  /// 清除「已清空」标记（写入新配置 / 云端更新后调用）。
  Future<void> clearClearedFlag() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kSourcesCleared) ?? false) {
      await prefs.setBool(_kSourcesCleared, false);
      _log('已清除清空标记');
    }
  }

  /// 删除文档目录覆盖层（清空**云端缓存/用户导入的覆盖层**）。
  ///
  /// ⚠️ 内置漫画源已移除（用户 2026-10-13）：删掉覆盖层后就是**无源**
  /// （不再有随包内置源兜底），需要用户重新导入。
  /// ⚠️ 本函数会清掉**用户导入/编辑过的源**，请务必先确认；
  ///   它的唯一调用方是升级一次性迁移 [_migrateOnceIfNeeded]（清前会先备份为 .bak）。
  Future<void> resetToLocal() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) {
        // 🔴 原来是**直接 delete** ✗ —— 而这份文件正是"用户导入/编辑过的源覆盖层"
        // （:52 注释也自认"可能下沉了过时/**自定义**的源配置"），删掉后**无从恢复** ✗。
        // 更糟的是升级迁移会在首跑自动调用它（:55-65），且失败还会下次重试 ✗。
        // → 先**改名成 .bak 备份**再清空（可人工恢复）✓；
        //   备份失败就**不删**——宁可留旧覆盖层，也不能不可恢复地删用户数据 ✓
        try {
          final bak = File('${dir.path}/$_kDocFileName.bak');
          if (await bak.exists()) await bak.delete();
          await file.rename(bak.path);
          _log('覆盖层已备份为 $_kDocFileName.bak，随后才清除');
        } catch (e) {
          _log('备份覆盖层失败 → 跳过本次清除（不删用户数据）: $e');
          return;
        }
      }
      _log('已清除文档目录覆盖层（无源直至云端更新）');
    } catch (e) {
      _log('清除文档目录覆盖层失败: $e');
    }
  }

  /// 远端拉取 sources.json。
  ///
  /// 读用户配置的云端 URL（[SettingsService.sourceRepoUrl]）：为空返回 null（不拉取，沿用本地）。
  /// 非空则 Dio GET -> 容错解析为 SourceConfigFile -> 空则返回 null -> 否则 saveLocal 并返回 defs。
  /// 失败返回 null（保留本地），不抛错给上层（启动后台调用）。
  Future<List<SourceDefinition>?> fetchRemote() async {
    final url = SettingsService().sourceRepoUrl.trim();
    if (url.isEmpty) {
      _log('未配置云端仓库地址，跳过远端拉取');
      return null;
    }
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
        ),
      );
      // ✅ **云端源拉取也走「网络代理」**（本轮接上 ✓）—— 这处很关键 ✓：
      //   `fetchRemote` 就是**从云端仓库拉 sources.json** ✓（决定"漫画源能不能更新"✓）。
      //   以前它**直连** ✗ → 用户开了代理、源却依然更新不了 ✓（"代理没用"的又一来源 ✓）。
      //   ℹ️ 安全依据 ✓：本处**无自定义适配器** ✗✓（只有三个基参 ✓）→ 直接挂**安全** ✓✓
      //   · 代理**关闭** ✓ → 返回 false ✓ **一行不改** ✓（与从前完全一致 ✓✓）
      applyGlobalProxy(dio);
      final res = await dio.get<dynamic>(url);
      final cfg = _asMap(res.data);
      if (cfg == null) {
        _log('云端 sources.json 解析失败（非 JSON Map）: $url');
        return null;
      }
      final parsed = SourceConfigFile.fromJson(cfg);
      if (parsed.sources.isEmpty) {
        _log('云端 sources.json 为空，忽略');
        return null;
      }
      await saveLocal(parsed.sources);
      _log('已从云端拉取并保存: ${parsed.sources.length} 源');
      return parsed.sources;
    } catch (e) {
      _log('云端 sources.json 拉取失败（保留本地）: $e');
      return null;
    }
  }

  /// 容错解析为 Map：Dio 默认按 application/json 自动解析为 Map，
  /// 个别情况下返回 String，则再 jsonDecode。
  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }
}
