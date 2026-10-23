// lib/services/generic_source_service.dart
//
// 「通用源」管理（2026-10-22）：
// 把任意标准苹果 CMS（MacCMS）/ TVBox JSON 接口加成一条用户线路。
//
// 为什么只需要这一种：韩小圈、鬼片这类短剧/影视站绝大多数都是 MacCMS，
// 它们的 `api.php/provide/vod/` 就是 TVBox 的 type=1 JSON 协议
// （`?ac=list` 出分类、`?ac=videolist&t=&pg=` 出列表、`?ac=detail&ids=` 出详情）。
// 加进来之后就和订阅线路完全同权：首页分类、搜索、短剧聚合都能用。
//
// 不做的事：不解析私有签名接口（红果/剧果等），不绕过 VIP。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/source_bean.dart';
import '../reading/source/global_proxy.dart';
import 'api_config.dart';

class GenericSourceService {
  GenericSourceService._();
  static final GenericSourceService instance = GenericSourceService._();

  static const _keyPrefix = 'user_generic_';

  /// 把用户输入（域名 或 完整接口地址）规范成可用的 JSON 接口。
  /// 返回 (ok, message, api)
  Future<({bool ok, String message, String api})> probe(String input) async {
    var raw = input.trim();
    if (raw.isEmpty) return (ok: false, message: '请输入站点域名或接口地址', api: '');
    raw = raw.replaceAll(RegExp(r'^["\s]+|["\s]+$'), '');
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }

    final candidates = <String>[];
    if (raw.contains('api.php/provide/vod')) {
      var u = raw.split('?').first;
      if (!u.endsWith('/')) u = '$u/';
      candidates.add(u);
    } else {
      final base = raw.replaceAll(RegExp(r'/+$'), '');
      candidates
        ..add('$base/api.php/provide/vod/')
        ..add('$base/api.php/provide/vod/at/json/');
    }

    final errors = <String>[];
    for (final api in candidates) {
      final r = await _validate(api);
      if (r == null) return (ok: true, message: '可用', api: api);
      errors.add('$api → $r');
    }
    return (
      ok: false,
      message: '接口不可用：\n${errors.join('\n')}\n'
          '需要标准 MacCMS 的 api.php/provide/vod/ 接口',
      api: '',
    );
  }

  /// 拉一次 `?ac=list` 校验：能拿到 JSON 且含 class/list 才算可用。
  Future<String?> _validate(String api) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
        responseType: ResponseType.plain,
        validateStatus: (c) => c != null && c < 500,
      ),
    );
    applyGlobalProxy(dio);
    try {
      final sep = api.contains('?') ? '&' : '?';
      final res = await dio.get<String>('$api${sep}ac=list');
      final body = (res.data ?? '').trim();
      if (res.statusCode != 200) return 'HTTP ${res.statusCode}';
      if (body.isEmpty) return '返回为空';
      final j = jsonDecode(body);
      if (j is! Map) return '不是 JSON 对象';
      final cls = j['class'];
      if (cls is List && cls.isNotEmpty) return null;
      final list = j['list'];
      if (list is List) return null;
      return 'JSON 里没有 class/list 字段';
    } catch (e) {
      final s = e.toString();
      return s.length > 80 ? s.substring(0, 80) : s;
    } finally {
      dio.close(force: true);
    }
  }

  /// 保存为一条用户线路（已存在同 api 会覆盖）
  Future<({bool ok, String message})> add({
    required String name,
    required String input,
  }) async {
    final p = await probe(input);
    if (!p.ok) return (ok: false, message: p.message);
    final key =
        '$_keyPrefix${md5.convert(utf8.encode(p.api)).toString().substring(0, 10)}';
    final bean = SourceBean(
      key: key,
      name: name.trim().isEmpty ? Uri.parse(p.api).host : name.trim(),
      api: p.api,
      type: 1,
      searchable: 1,
      filterable: 1,
      quickSearch: 1,
      playerType: 0,
    );
    await ApiConfig.instance.addUserVideoSource(bean, enabled: true);
    return (ok: true, message: '已添加：${bean.name}');
  }

  /// 从一份 MacCMS 格式的 JSON 添加「本地源」（**离线可用**）。
  ///
  /// JSON 需要含 `class`（分类）或 `list`（条目），与 `?ac=list` 的响应一致。
  /// 内容复制到 App 私有目录，`api` 记成 `file://…`；
  /// [SourceService] 会识别这个前缀并直接读文件，不再发网络请求。
  Future<({bool ok, String message})> addLocalJson({
    required String name,
    required String jsonText,
  }) async {
    final text = jsonText.trim();
    if (text.isEmpty) return (ok: false, message: '内容为空');

    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(text);
      if (d is Map) j = d.cast<String, dynamic>();
    } catch (_) {
      j = null;
    }
    if (j == null) return (ok: false, message: '不是合法的 JSON');

    final cls = j['class'] ?? j['classes'];
    final list = j['list'];
    final hasClass = cls is List && cls.isNotEmpty;
    final hasList = list is List && list.isNotEmpty;
    if (!hasClass && !hasList) {
      return (ok: false, message: 'JSON 里没有 class / list 字段（需要 MacCMS 格式）');
    }

    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/local_sources');
      if (!await dir.exists()) await dir.create(recursive: true);

      final key =
          '$_keyPrefix${md5.convert(utf8.encode(text)).toString().substring(0, 10)}';
      final file = File('${dir.path}/$key.json');
      await file.writeAsString(text);

      final bean = SourceBean(
        key: key,
        name: name.trim().isEmpty ? '本地源' : name.trim(),
        api: Uri.file(file.path).toString(),
        type: 1,
        searchable: 1,
        filterable: 0,
        quickSearch: 1,
        playerType: 0,
      );
      await ApiConfig.instance.addUserVideoSource(bean, enabled: true);
      return (ok: true, message: '已添加本地源：${bean.name}');
    } catch (e) {
      return (ok: false, message: '保存失败：$e');
    }
  }

  /// 已添加的通用源（从用户线路里筛出来）
  Future<List<Map<String, dynamic>>> list() async {
    final all = await ApiConfig.instance.userInjectedSites();
    return all
        .where((e) => (e['key'] ?? '').toString().startsWith(_keyPrefix))
        .toList();
  }

  Future<void> remove(String key) =>
      ApiConfig.instance.removeUserVideoSource(key);
}
