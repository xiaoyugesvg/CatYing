// 漫画源配置存储（独立通道，单例）。
//
// 负责 SourceDefinition 的本地加载与持久化、远端拉取。
//
// ⚠️ **本段原来写的是**「软件**不自带**任何漫画源，源定义**完全云端驱动**，**仅**从文档目录
//    sources.json 加载，**无缓存时返回空列表**」✗✗ —— **与代码不符，已改正** ✓：
//    · 本文件**确有内置兜底** ✓：`_kBundledSourcesPath = 'assets/config/sources.json'` ✓
//      （`pubspec.yaml:89-90` 已声明 `assets/config/` ✓，那里写着"**出厂内置漫画源（15 个官方源
//       明文，装上即有源）**"✓）；`loadLocal()` 在文档目录无配置时会**读资产兜底** ✓✓
//    · 正确优先级 ✓：**文档目录 sources.json（云端更新覆盖层）优先 → 出厂内置源兜底** ✓
//    · ⚠️ 唯一会"没源"的情形 ✗：用户**主动点过「清空」**✓ 且内置包指纹未变 ✓
//      （`_kSourcesCleared` + `_kBundledFp` ✓，见 `loadLocal` 里那条 `return []` ✓）
//      ⇒ 该状态**界面上看不出来** ✗✓ → 需要一个「**恢复内置源**」入口 ✓
//        （`clearClearedFlag()` 里 `setBool(_kSourcesCleared,false)` ✓ 能力已存在 ✓，只差接 UI ✓）
//
// fetchRemote 读用户配置的云端 URL（SettingsService.sourceRepoUrl）：为空返回 null（不拉取，
// 沿用本地）；非空则 Dio 拉取 sources.json -> 校验 -> saveLocal -> 返回新 defs。
// 风格参考 RemoteConfigService（Dio + 本地缓存）但与之解耦，独立演进。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
// 出厂内置源（装上即有源，文档目录无配置时兜底加载）。
const _kBundledSourcesPath = 'assets/config/sources.json';
// 云端源迁移标记：升级到本版本时一次性清除本地源覆盖层（旧版本缓存/自定义）。
const _kCloudOnlyMigrationDone = 'source_cloud_only_migration_done';
// 用户主动「清空」标记：置位后 loadLocal 不再回退内置源（清空=彻底无源，
// 直到云端更新 / 导入新源）。避免清空后内置源兜底回来，让"清空"看起来失效。
const _kSourcesCleared = 'sources_cleared';
// 出厂内置源指纹：assets/config/sources.json 内容变化时（内置包更新），
// 即使之前已清空过 / 已初始化过，也会重新把内置源补入文档目录（同 id 跳过，
// 不覆盖用户编辑）。指纹不变则永不重复补入，清空语义保持有效。
const _kBundledFp = 'sources_bundled_fp';
// 旧内置残留清理标记：一次性。删除文档目录里不在「当前内置」源中的旧源
// （旧版 15 源内置 / 更早云端包残留），仓库回到仅当前内置（16 源）。
const _kLegacyPruneDone = 'sources_legacy_prune_done';

class SourceConfigStore {
  SourceConfigStore._();
  static final SourceConfigStore _instance = SourceConfigStore._();
  factory SourceConfigStore() => _instance;

  /// 升级到本版本的一次性迁移：清除文档目录 sources.json 覆盖层。
  ///
  /// 旧版本可能在本地下沉了过时/自定义的源配置；升级首跑清掉本地覆盖层。
  ///
  /// ⚠️ 本段原来写「本版本起源定义**完全云端驱动**…（**无自带源兜底**）」✗✗ —— **与代码不符，已改正** ✓：
  ///   本版本**有出厂内置源兜底** ✓（`_kBundledSourcesPath = 'assets/config/sources.json'` ✓，
  ///   `pubspec.yaml:89-90` 已声明「出厂内置漫画源（15 个官方源明文，装上即有源）」✓）
  ///   ⇒ 所以清掉覆盖层之后是「**回到内置源**」✓，**不是**"从此无源"✗（除非用户点过「清空」✓，
  ///     那种情况用漫画源仓库的「**恢复内置源**」按钮一键回来 ✓✓）。
  ///   迁移本身仍然**是对的** ✓：旧版本下沉的过时/自定义配置确实该清 ✓
  ///   （它已备份为 `sources.json.bak` ✓，可人工找回 ✓ 不会不可恢复地丢 ✓）。
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

  /// 加载源配置定义：文档目录 sources.json（云端更新覆盖层）优先，
  /// 无配置时回落出厂内置源（assets/config/sources.json）。
  /// 软件出厂自带 15 个官方源，保证装上即有可用源；
  /// 用户云端更新后以文档目录为准（覆盖层设计，内置源不重复注册）。
  Future<List<SourceDefinition>> loadLocal() async {
    // 升级一次性迁移：先清掉旧版本本地源覆盖层（仅一次）。
    await _migrateOnceIfNeeded();
    // 旧内置残留清理：删除文档目录里不在当前内置中的旧源（仅一次）。
    await _pruneLegacySourcesOnce();
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

    // 出厂内置源兜底：文档目录无配置（首次安装/清缓存后）时读 assets，
    // 保证装上即有源，无需用户手动导入。
    try {
      final bundled = await rootBundle.loadString(_kBundledSourcesPath);
      final parsed = SourceConfigFile.fromJson(
        jsonDecode(bundled) as Map<String, dynamic>,
      );
      if (parsed.sources.isNotEmpty) {
        final fp = '${bundled.length}:${bundled.hashCode}';
        // 用户主动「清空」过：仅当**同一批**内置源（指纹相同）时保持无源；
        // 内置包更新过（指纹变化）视为新出厂内容，允许重新补入。
        try {
          final prefs = await SharedPreferences.getInstance();
          final cleared = prefs.getBool(_kSourcesCleared) ?? false;
          if (cleared && (prefs.getString(_kBundledFp) ?? '') == fp) {
            _log('用户已清空漫画源且内置源未更新，保持无源');
            return [];
          }
        } catch (e) {
          _log('读取清空标记失败: $e');
        }

        // 资产指纹变化（内置源更新/首次安装）时把内置源写入文档目录，
        // 之后用户可像自己导入的源一样编辑/删除；指纹不变则不重复补入，
        // 用户对文档目录源的增删改不会被内置包重置。
        await _ensureBundledSynced(bundled, parsed.sources);
        _log('加载出厂内置源: ${parsed.sources.length} 源');
        return parsed.sources;
      }
    } catch (e) {
      _log('出厂内置源读取失败: $e');
    }

    _log('无本地源配置（未从云端更新过，也无内置源）');
    return [];
  }

  /// 内置源同步：指纹变化才写文档目录（saveLocal 顺带清除「已清空」标记）。
  ///
  /// 为什么把内置源落盘到文档目录而不是每次只读 assets：
  /// 「清空」「删除单个源」「导入合并」都操作文档目录，若内置源只存在
  /// assets 里，用户删掉某内置源后 loadLocal 又从 assets 兜底回来，
  /// 删除会"看起来失效"。落盘一次后，文档目录成为唯一权威，内置包
  /// 只承担"首次/升级补入"职责。
  Future<void> _ensureBundledSynced(
    String bundled,
    List<SourceDefinition> bundledSources,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fp = '${bundled.length}:${bundled.hashCode}';
      if ((prefs.getString(_kBundledFp) ?? '') == fp) return;
      await saveLocal(bundledSources);
      await prefs.setString(_kBundledFp, fp);
      _log('内置源指纹变化，已补入文档目录: ${bundledSources.length} 源');
    } catch (e) {
      _log('内置源同步失败: $e');
    }
  }

  /// 旧内置残留清理：删除文档目录里不在「当前内置」id 集合中的旧源
  /// （旧版 15 源内置 / 更早云端包残留），仓库回到仅当前内置（16 源）。
  /// 用 SharedPreferences 标记保证仅执行一次（失败不置位，下次重试）；
  /// 之后用户手动导入的新源不受影响。
  Future<void> _pruneLegacySourcesOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kLegacyPruneDone) ?? false) return;
      // 当前内置 id 集合
      final bundled = await rootBundle.loadString(_kBundledSourcesPath);
      final parsed = SourceConfigFile.fromJson(
        jsonDecode(bundled) as Map<String, dynamic>,
      );
      final builtinIds = parsed.sources.map((s) => s.id).toSet();
      if (builtinIds.isEmpty) {
        await prefs.setBool(_kLegacyPruneDone, true);
        return;
      }
      // 文档目录源：删除不在内置里的旧源
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final local = SourceConfigFile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final before = local.sources.length;
        local.sources.removeWhere((s) => !builtinIds.contains(s.id));
        if (local.sources.length != before) {
          await saveLocal(local.sources);
          _log('清理旧内置漫画源: $before -> ${local.sources.length}');
        }
      }
      await prefs.setBool(_kLegacyPruneDone, true);
      _log('旧内置漫画源清理完成');
    } catch (e) {
      _log('旧内置漫画源清理失败（下次重试）: $e');
    }
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

  /// 删除文档目录覆盖层（清空**云端缓存/用户导入的覆盖层**，回到"只有内置源"的状态）。
  ///
  /// ⚠️ 本段原来写「**软件不自带源**，清空后无源直至下次云端更新」✗✗ —— **与代码不符，已改正** ✓：
  ///   本文件在文档目录无配置时**会回退出厂内置源** ✓（`_kBundledSourcesPath` ✓ 见 `loadLocal` ✓）。
  /// ⇒ 所以清掉覆盖层之后是「**回到内置源**」✓，而不是"无源"✗ —— 除非用户**点过「清空」**✓
  ///   （那时 `_kSourcesCleared=true` ✓ 才会真的无源 ✓；用 `clearClearedFlag()` ✓ 即可恢复 ✓✓）。
  ///   ⚠️ 本函数**不是**"恢复内置源"该调用的方法 ✗ —— 它会清掉**用户导入/编辑过的源** ✗✓；
  ///     要恢复内置源请用 [clearClearedFlag] ✓（只清标记 ✓，不动任何文件 ✓）。
  /// 供 [_migrateOnceIfNeeded] 升级迁移调用。
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
