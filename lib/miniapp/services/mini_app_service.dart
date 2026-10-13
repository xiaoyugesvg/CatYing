import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_config.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/live_service.dart';
import '../../services/network_manager.dart';
import '../models/mini_app.dart';

/// 「程序」模块服务：管理导入的 TVBox 生态小程序配置。
///
/// - 持久化：SharedPreferences（`miniapp_list_v1`）
/// - 导入：网络 URL / 本地文件 / 手动粘贴 JSON
/// - 影视源：解析出的站点即时注册进 `ApiConfig.sourceBeanList`
///   - CMS 站点（type 0/1）key `app_<appId>[_<i>]` → 详情/播放走现有影视链路；
///   - Spider 站点（spider 为 JS URL）key `app_<appId>_s<i>`、type 3 →
///     由 Node 引擎加载，SpiderService 五接口承载；
/// - 频道：lives 数组保留在 rawJson，播放时交给 `LiveService`。
class MiniAppService extends GetxService {
  static MiniAppService get instance {
    if (!Get.isRegistered<MiniAppService>()) {
      Get.put<MiniAppService>(MiniAppService(), permanent: true);
    }
    return Get.find<MiniAppService>();
  }

  static const String _key = 'miniapp_list_v1';

  /// 已安装程序列表
  final apps = <MiniApp>[].obs;

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        apps.assignAll(list
            .whereType<Map>()
            .map((e) => MiniApp.fromJson(Map<String, dynamic>.from(e)))
            .toList());
        // 重启后把已装程序的影视源重新注册进视频源列表
        for (final app in apps) {
          _registerVideoSources(app);
        }
      }
    } catch (e) {
      AppLog.instance.w('[MiniApp] 读取列表失败: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(apps.map((a) => a.toJson()).toList()));
  }

  // ── 导入 ──────────────────────────────────────────────────────

  /// 从网络 URL 导入（下载 JSON 后走 [importRaw]）
  Future<({bool ok, String? error})> importFromUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '地址不能为空');
    try {
      final body = await NetworkManager.instance.getString(trimmed);
      if (body.trim().isEmpty) return (ok: false, error: '下载内容为空');
      return await importRaw(body, source: trimmed);
    } catch (e) {
      return (ok: false, error: '下载失败: $e');
    }
  }

  /// 从本地文件导入
  Future<({bool ok, String? error})> importFromFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return (ok: false, error: '文件不存在');
      final body = await file.readAsString();
      return await importRaw(body, source: path);
    } catch (e) {
      return (ok: false, error: '读取失败: $e');
    }
  }

  /// 从粘贴的 JSON 文本导入
  Future<({bool ok, String? error})> importFromText(String text) =>
      importRaw(text, source: '手动粘贴');

  /// 导入麦优直播订阅（单独的应用类型，不走 TVBox 配置解析）。
  ///
  /// [url] 为麦优分类接口地址（如 http://api.maiyoux.com:81/mf/json.txt），
  /// 保存为 `type=maiyou` 应用：rawJson 存 `{"type":"maiyou","url":...}`，
  /// 打开时按麦优协议拉取分类与频道。
  Future<({bool ok, String? error})> importMaiyou(
    String url, {
    String? nameOverride,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '订阅地址不能为空');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return (ok: false, error: '订阅地址格式不正确（需 http/https 链接）');
    }
    final name = (nameOverride?.trim().isNotEmpty ?? false)
        ? nameOverride!.trim()
        : '麦优直播';
    final app = MiniApp(
      id: 'app_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      type: 'maiyou',
      source: trimmed,
      rawJson: jsonEncode({'type': 'maiyou', 'url': trimmed}),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    apps.add(app);
    await _persist();
    return (ok: true, error: null);
  }

  /// 更新麦优订阅地址（独立管理页用）
  Future<({bool ok, String? error})> updateMaiyouUrl(
    MiniApp app,
    String url,
  ) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '订阅地址不能为空');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return (ok: false, error: '订阅地址格式不正确（需 http/https 链接）');
    }
    final idx = apps.indexWhere((a) => a.id == app.id);
    if (idx < 0) return (ok: false, error: '应用不存在');
    apps[idx] = MiniApp(
      id: app.id,
      name: app.name,
      type: 'maiyou',
      source: trimmed,
      rawJson: jsonEncode({'type': 'maiyou', 'url': trimmed}),
      createdAt: app.createdAt,
    );
    await _persist();
    return (ok: true, error: null);
  }

  /// 校验并保存一份配置
  Future<({bool ok, String? error})> importRaw(
    String raw, {
    String source = '',
    String? nameOverride,
  }) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return (ok: false, error: '内容为空');

    // 预解析校验：必须是 JSON 且能提取名称
    final parsed = MiniAppParsed.parse(trimmed);
    if (parsed.cmsSites.isEmpty &&
        parsed.spiderSites.isEmpty &&
        parsed.liveGroups.isEmpty) {
      return (ok: false, error: '无法识别影视源或直播频道（需 TVBox 格式配置）');
    }

    final name = (nameOverride?.trim().isNotEmpty ?? false)
        ? nameOverride!.trim()
        : parsed.name;
    if (name.isEmpty) return (ok: false, error: '配置缺少名称');

    final app = MiniApp(
      id: 'app_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      type: 'tvbox',
      source: source,
      rawJson: trimmed,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    apps.add(app);
    _registerVideoSources(app);
    _registerParses(app);
    await _persist();
    return (ok: true, error: null);
  }

  /// 把程序的 parses 解析接口合并进全局解析列表（同名 URL 覆盖更新）。
  /// 这样影视播放 / 嗅探页 / 小程序 parse/jx 线路都能直接用上解析接口。
  void _registerParses(MiniApp app) {
    try {
      final decoded = jsonDecode(app.rawJson);
      final parses = decoded is Map ? decoded['parses'] : null;
      if (parses is! List) return;
      final list = ApiConfig.instance.parseBeanList;
      for (final p in parses) {
        if (p is! Map) continue;
        final url = (p['url'] ?? '').toString().trim();
        if (url.isEmpty) continue;
        final name = (p['name'] ?? '').toString();
        final type = int.tryParse('${p['type'] ?? 0}') ?? 0;
        final extRaw = p['ext'];
        final bean = ParseBean(
          name: name,
          url: url,
          type: type,
          ext: extRaw is Map
              ? extRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
              : null,
        );
        final existing = list.indexWhere((e) => e.url == url);
        if (existing >= 0) {
          list[existing] = bean;
        } else {
          list.add(bean);
        }
      }
      if (parses.isNotEmpty) {
        AppLog.instance.log('[MiniApp] 已注册 ${parses.length} 条解析接口');
      }
    } catch (e) {
      AppLog.instance.log('[MiniApp] parses 注册失败: $e');
    }
  }

  /// 把程序的影视源注册进视频源列表（可重复调用，先清理旧的）
  void _registerVideoSources(MiniApp app) {
    final parsed = app.parsed;

    // 麦优订阅应用不注册影视源（独立直播订阅形态）
    if (parsed.maiyouUrl.isNotEmpty) return;

    // 清理该程序旧的注册（避免重复导入叠加）
    ApiConfig.instance.sourceBeanList.removeWhere(
        (s) => s.key.startsWith('${app.id}_'));

    // ── CMS 站点（type 0/1，key `app_<id>_<i>`）────────────
    if (parsed.cmsSites.isNotEmpty) {
      for (var i = 0; i < parsed.cmsSites.length; i++) {
        final site = parsed.cmsSites[i];
        final key = parsed.cmsSites.length == 1
            ? '${app.id}_0'
            : '${app.id}_$i';
        ApiConfig.instance.sourceBeanList.removeWhere((s) => s.key == key);
        ApiConfig.instance.sourceBeanList.add(SourceBean(
              key: key,
              name: site.name,
              api: site.api,
              searchable: 1,
              filterable: 1,
              type: 1, // JSON CMS
            ));
      }
    }

    // ── Spider 站点（type 3，key `app_<id>_s<i>`）───────────
    // 脚本源：api 为 .js/.py 脚本 URL 或 drpy2 运行时 URL；
    // ext 为 drpy2 模式下的站点脚本（普通脚本源为空）。
    // 由 Node/Python 引擎加载（引擎单源架构：同一时间只会加载第一个 type 3 源，
    // 程序 spider 源只有在主影视源不是 spider 时才会被加载）。
    if (parsed.spiderSites.isNotEmpty) {
      for (var i = 0; i < parsed.spiderSites.length; i++) {
        final site = parsed.spiderSites[i];
        final key = '${app.id}_s$i';
        ApiConfig.instance.sourceBeanList.removeWhere((s) => s.key == key);
        ApiConfig.instance.sourceBeanList.add(SourceBean(
              key: key,
              name: site.name,
              api: site.api.isNotEmpty ? site.api : site.ext,
              ext: site.ext,
              searchable: 1,
              filterable: 1,
              type: 3, // Spider（JS/Python 脚本）
            ));
      }
    }
  }

  /// 删除程序（同时从视频源列表移除其注册的源）
  Future<void> remove(MiniApp app) async {
    apps.removeWhere((a) => a.id == app.id);
    ApiConfig.instance.sourceBeanList
        .removeWhere((s) => s.key.startsWith('${app.id}_'));
    // 一并移除该程序注册的解析接口（按 url 精确匹配，避免误删用户自建的）
    _removeRegisteredParses(app);
    await _persist();
  }

  void _removeRegisteredParses(MiniApp app) {
    try {
      final decoded = jsonDecode(app.rawJson);
      final parses = decoded is Map ? decoded['parses'] : null;
      if (parses is! List) return;
      final urls = parses
          .whereType<Map>()
          .map((p) => (p['url'] ?? '').toString().trim())
          .where((u) => u.isNotEmpty)
          .toSet();
      if (urls.isEmpty) return;
      ApiConfig.instance.parseBeanList.removeWhere((b) => urls.contains(b.url));
    } catch (e) {
      AppLog.instance.log('[MiniApp] 移除解析接口失败: $e');
    }
  }

  /// 把程序 lives 交给直播服务（直播页展示/播放）
  Future<void> playLives(MiniApp app) async {
    if (app.parsed.liveGroups.isEmpty) return;
    try {
      final decoded = jsonDecode(app.rawJson);
      if (decoded is Map) {
        final lives = decoded['lives'];
        if (lives is List) {
          await LiveService.instance.loadFromLivesJson(lives);
        }
      }
    } catch (e) {
      AppLog.instance.w('[MiniApp] 频道加载失败: $e');
    }
  }
}
