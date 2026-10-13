import 'dart:convert';

import '../../models/live_models.dart';

/// 「程序」= 导入的 TVBox 生态小程序配置（独立功能模块）。
///
/// 一个程序包对应一份 TVBox JSON 配置：
/// - 影视：`sites` 里的站点 → 注册进 `ApiConfig.sourceBeanList`
///   - CMS 站点（spider 为空、type 0/1 的 api.php 站点）→ 搜索/分类/详情/播放复用现有影视链路；
///   - Spider 站点（`spider` 字段指向 JS 脚本 URL）→ 注册 type 3 源，由 Node 引擎加载并走
///     `SpiderService` 五接口；脚本是内嵌内容（非 URL）的标记为 inline，暂不执行；
/// - 频道：`lives` 直播频道数组 → 点击后交给 `LiveService` 播放。
class MiniApp {
  /// 唯一 ID（随机生成，持久化用）
  final String id;

  /// 程序名（取自配置 `name`，导入时可覆盖）
  final String name;

  /// 应用类型：`tvbox` = TVBox JSON 配置（影视+直播）；
  /// `maiyou` = 麦优直播订阅（分类式直播接口）
  final String type;

  /// 来源（网络 URL / 本地文件路径 / 手动粘贴）
  final String source;

  /// 原始配置 JSON 文本
  final String rawJson;

  /// 创建时间（epoch ms）
  final int createdAt;

  const MiniApp({
    required this.id,
    required this.name,
    required this.type,
    required this.source,
    required this.rawJson,
    required this.createdAt,
  });

  /// 是否为麦优直播订阅应用
  bool get isMaiyou => type == 'maiyou';

  /// 解析后的内容（每次从 rawJson 现算，不缓存——避免过期脏数据）
  MiniAppParsed get parsed => MiniAppParsed.parse(rawJson);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'source': source,
        'rawJson': rawJson,
        'createdAt': createdAt,
      };

  factory MiniApp.fromJson(Map<String, dynamic> json) => MiniApp(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '程序',
        type: json['type'] as String? ?? 'tvbox',
        source: json['source'] as String? ?? '',
        rawJson: json['rawJson'] as String? ?? '{}',
        createdAt: json['createdAt'] as int? ?? 0,
      );
}

/// TVBox JSON 配置的解析结果
class MiniAppParsed {
  final String name;
  final List<MiniAppCmsSite> cmsSites;

  /// 可执行的 spider 源（`spider` 字段是 http(s) 脚本 URL）
  final List<MiniAppSpiderSite> spiderSites;

  /// 内嵌脚本型 spider（`spider` 字段是 JS 内容而非 URL）——引擎无法直接加载，仅标记
  final bool hasInlineSpider;
  final List<LiveGroup> liveGroups;

  /// 麦优直播订阅地址（type=maiyou 的配置：`{"type":"maiyou","url":...}`）
  final String maiyouUrl;

  const MiniAppParsed({
    required this.name,
    required this.cmsSites,
    required this.spiderSites,
    required this.hasInlineSpider,
    required this.liveGroups,
    required this.maiyouUrl,
  });

  factory MiniAppParsed.parse(String raw) {
    var name = '程序';
    final cmsSites = <MiniAppCmsSite>[];
    final spiderSites = <MiniAppSpiderSite>[];
    final liveGroups = <LiveGroup>[];
    var hasInlineSpider = false;
    var maiyouUrl = '';

    try {
      final decoded = jsonDecodeSafe(raw);
      if (decoded is Map<String, dynamic>) {
        name = (decoded['name'] as String?)?.trim() ?? '程序';
        if (name.isEmpty) name = '程序';

        // ── 麦优直播订阅（type=maiyou）──────────────────────
        if (decoded['type'] == 'maiyou') {
          maiyouUrl = (decoded['url'] as String?)?.trim() ?? '';
        }

        // ── 影视源（sites 数组 / 顶层 api）──────────────────────
        final sites = decoded['sites'];
        if (sites is List) {
          for (final s in sites) {
            if (s is! Map) continue;
            final siteName = (s['name'] as String?)?.trim() ?? '';
            final api = (s['api'] as String?)?.trim() ?? '';
            if (api.isEmpty) continue;
            // spider 非空 → JS 脚本源
            final spider = s['spider'];
            if (spider is String && spider.trim().isNotEmpty) {
              final ext = spider.trim();
              final uri = Uri.tryParse(ext);
              final isUrl = uri != null &&
                  (uri.scheme == 'http' || uri.scheme == 'https');
              if (isUrl) {
                spiderSites.add(MiniAppSpiderSite(
                    name: siteName.isEmpty ? name : siteName,
                    api: api,
                    ext: ext));
              } else {
                hasInlineSpider = true;
              }
              continue;
            }
            final type = _toInt(s['type'], 1);
            // CMS：type 0(XML)/1(JSON)；api 指向 api.php/provide/vod
            if (type == 0 || type == 1) {
              cmsSites.add(MiniAppCmsSite(
                  name: siteName.isEmpty ? name : siteName, api: api));
              continue;
            }
            // type 3 脚本源（TVBox spider）：api 可能是
            //  - 远程 .js / .py 脚本 URL（如 `https://…/腾讯视频.py`）
            //  - drpy2 运行时 URL + ext 站点脚本（`api=drpy2.min.js` + `ext=站点.js`）
            //  - csp_ 开头的 jar 源（Java 爬虫，宿主不加载，仅保留标记）
            if (type == 3) {
              final extRaw = s['ext'];
              final extStr = extRaw is String ? extRaw.trim() : '';
              final lowerApi = api.toLowerCase();
              final isJarSource = api.startsWith('csp_');
              if (!isJarSource &&
                  (lowerApi.endsWith('.py') ||
                      lowerApi.endsWith('.js') ||
                      extStr.isNotEmpty)) {
                spiderSites.add(MiniAppSpiderSite(
                    name: siteName.isEmpty ? name : siteName,
                    api: api,
                    ext: extStr));
              }
              continue;
            }
          }
        }
        // 顶层 api 字段（无 sites 的简化配置）
        if (cmsSites.isEmpty && spiderSites.isEmpty) {
          final topApi = (decoded['api'] as String?)?.trim() ?? '';
          if (topApi.isNotEmpty) {
            cmsSites.add(MiniAppCmsSite(name: name, api: topApi));
          }
        }

        // ── 直播频道（lives 数组）────────────────────────────────
        final lives = decoded['lives'];
        if (lives is List) {
          final groupMap = <String, List<LiveChannel>>{};
          for (final l in lives) {
            if (l is! Map) continue;
            final chName = (l['name'] as String?)?.trim() ?? '';
            final group = (l['group'] as String?)?.trim() ?? '未分组';
            final logo = (l['logo'] as String?)?.trim();
            final urls = <String>[];
            final rawUrls = l['urls'];
            if (rawUrls is List) {
              urls.addAll(rawUrls
                  .map((e) => e?.toString() ?? '')
                  .where((u) => u.trim().isNotEmpty));
            } else if (rawUrls is String && rawUrls.trim().isNotEmpty) {
              urls.add(rawUrls.trim());
            }
            if (chName.isEmpty || urls.isEmpty) continue;
            groupMap.putIfAbsent(group, () => []).add(LiveChannel(
                  name: chName,
                  urls: urls,
                  group: group,
                  logo: logo,
                ));
          }
          groupMap.forEach((g, channels) {
            liveGroups.add(LiveGroup(name: g, channels: channels));
          });
        }
      }
    } catch (_) {
      // 解析失败保持空结果，由调用方提示
    }

    return MiniAppParsed(
      name: name,
      cmsSites: cmsSites,
      spiderSites: spiderSites,
      hasInlineSpider: hasInlineSpider,
      liveGroups: liveGroups,
      maiyouUrl: maiyouUrl,
    );
  }

  static int _toInt(dynamic v, int def) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }

  static dynamic jsonDecodeSafe(String raw) {
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
    if (m == null) return null;
    return jsonDecode(m.group(0)!);
  }
}

/// CMS 影视源（spider 为空的 api.php 站点）
class MiniAppCmsSite {
  final String name;
  final String api;

  const MiniAppCmsSite({required this.name, required this.api});
}

/// Spider 影视源（`spider` / `api` 为 http(s) 脚本 URL，type 3）
class MiniAppSpiderSite {
  final String name;
  /// 原始 api：脚本 URL（.js / .py / drpy2 运行时）
  final String api;
  /// 站点脚本（drpy2 模式的 `ext`；普通脚本源为空）
  final String ext;

  const MiniAppSpiderSite({required this.name, required this.api, this.ext = ''});
}
