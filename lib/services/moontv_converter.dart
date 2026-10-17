/// MoonTV / LunaTV「影视仓」配置转换器。
///
/// 这类仓库（如 `video.json`）的结构是：
/// ```json
/// {
///   "cache_time": 7200,
///   "api_site": {
///     "lovedan.net": {
///       "name": "🎬艾旦影视",
///       "api": "https://lovedan.net/api.php/provide/vod",
///       "detail": "https://lovedan.net"
///     }
///   }
/// }
/// ```
/// 其中 `api` 绝大多数就是标准苹果 CMS（MacCMS）采集接口，
/// 因此可以 1:1 映射成 TVBox 的 `type: 1` 站点，交给现有 [SourceService] 加载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 转换后的一个点播站点。
class MoonTvSite {
  const MoonTvSite({
    required this.key,
    required this.name,
    required this.api,
    required this.detail,
  });

  final String key;
  final String name;

  /// MacCMS 采集接口（`.../api.php/provide/vod`）
  final String api;

  /// 站点主页（部分源用来做 Referer，这里仅保留展示/排查）
  final String detail;

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'type': 1,
        'api': api,
        'searchable': 1,
        'quickSearch': 1,
        'filterable': 1,
      };
}

class MoonTvConvertResult {
  const MoonTvConvertResult({required this.sites, required this.warnings});

  final List<MoonTvSite> sites;

  /// 被跳过的条目原因（缺 api / 重复 / 地址非法）
  final List<String> warnings;

  /// 标准 TVBox 配置（可直接作为订阅内容）。
  Map<String, dynamic> toConfig() => {
        'sites': sites.map((e) => e.toJson()).toList(),
        'parses': const [],
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toConfig());
}

class MoonTvConverter {
  MoonTvConverter._();

  /// 已经是 TVBox 配置（含非空 `sites`）→ 无需转换。
  static bool isTvBoxConfig(Object? json) {
    if (json is! Map) return false;
    final sites = json['sites'];
    return sites is List && sites.isNotEmpty;
  }

  /// 检测并转换；不是 MoonTV 格式返回 null。
  static MoonTvConvertResult? tryConvert(Object? json) {
    if (json is! Map) return null;
    final apiSite = json['api_site'];
    if (apiSite is! Map) return null;

    final sites = <MoonTvSite>[];
    final warnings = <String>[];
    final usedApis = <String>{};
    final usedKeys = <String>{};

    apiSite.forEach((hostRaw, raw) {
      final host = '$hostRaw'.trim();
      if (raw is! Map) {
        warnings.add('$host：条目不是对象，已跳过');
        return;
      }
      var api = '${raw['api'] ?? ''}'.trim();
      final detail = '${raw['detail'] ?? ''}'.trim();
      if (api.isEmpty) {
        warnings.add('$host：缺少 api 采集地址，已跳过');
        return;
      }
      if (!api.startsWith('http://') && !api.startsWith('https://')) {
        final base = detail.isNotEmpty ? detail : 'https://$host';
        final resolved = Uri.tryParse(base)?.resolve(api).toString();
        if (resolved != null &&
            (resolved.startsWith('http://') ||
                resolved.startsWith('https://'))) {
          api = resolved;
        } else {
          warnings.add('$host：api 地址无效（$api），已跳过');
          return;
        }
      }
      if (!usedApis.add(api)) {
        warnings.add('$host：采集地址与前面的源重复，已跳过');
        return;
      }

      var name = '${raw['name'] ?? ''}'.trim();
      if (name.isEmpty) name = host;

      var keyBase = host.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      if (keyBase.isEmpty) keyBase = 'site';
      var key = 'moontv_$keyBase';
      var n = 2;
      while (!usedKeys.add(key)) {
        key = 'moontv_${keyBase}_${n++}';
      }

      sites.add(MoonTvSite(
        key: key,
        name: name,
        api: api,
        detail: detail,
      ));
    });

    if (sites.isEmpty) return null;
    return MoonTvConvertResult(sites: sites, warnings: warnings);
  }
}

/// 转换结果的本地持久化（`local://<name>` 伪协议）。
///
/// 为什么要伪协议：订阅列表只存「地址」，而用户把 JSON 直接粘贴进来时
/// 没有远程地址可存。写到 Documents 后用 `local://` 引用，
/// `ApiConfig` 读到该前缀时直接读文件，不走网络。
class ConvertedConfigStore {
  ConvertedConfigStore._();

  static const String scheme = 'local://';
  static const String _dirName = 'converted_configs';

  static bool isLocal(String url) =>
      url.trim().toLowerCase().startsWith(scheme);

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');

  static String nameOf(String url) {
    final u = url.trim();
    if (!u.toLowerCase().startsWith(scheme)) return '';
    return _sanitize(u.substring(scheme.length));
  }

  /// 写入并返回 `local://<name>`。
  static Future<String> write(String name, String content) async {
    final safe = _sanitize(name);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    await File('${dir.path}/$safe.json').writeAsString(content, flush: true);
    return '$scheme$safe';
  }

  static Future<String?> read(String url) async {
    final name = nameOf(url);
    if (name.isEmpty) return null;
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/$_dirName/$name.json');
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  static Future<void> delete(String url) async {
    final name = nameOf(url);
    if (name.isEmpty) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/$_dirName/$name.json');
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉就留给下次覆盖，不影响使用
    }
  }
}
