import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/html_text.dart';

/// qread（轻阅读）服务端接入层。
///
/// 书源规则执行搬到自建 qread 服务端（Kotlin/Spring，Rhino 全量支持
/// `@js:` 规则），App 侧书源页 / 书源仓库变成对接 API 的"壳"。
///
/// 协议要点（对齐 qread 后端 `web/controller/api/*`）：
///   · 路径前缀 `/api/5`（apiversion=5），返回 `JsonResponse{isSuccess,errorMsg,data}`
///   · 鉴权：`accessToken` 一律走 query 参数（登录接口换取）
///   · 书源列表两段式：`getBookSourcesPage` 返回 `{page,md5}`，
///     再逐页 `getBookSourcesNew?md5=&page=` 拉每页（每页 50 条）
///   · 搜索/探索返回 Legado `SearchBook` 数组
class QreadException implements Exception {
  QreadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// qread 服务端连接配置（本地持久化，含登录 token）。
class QreadServerConfig {
  QreadServerConfig._();
  static final QreadServerConfig instance = QreadServerConfig._();

  static const _kBase = 'qread_server_base';
  static const _kUser = 'qread_server_user';
  static const _kPass = 'qread_server_pass';
  static const _kToken = 'qread_server_token';

  String baseUrl = '';
  String username = '';
  String password = '';
  String accessToken = '';

  bool get isConfigured => baseUrl.trim().isNotEmpty;
  bool get isLoggedIn => accessToken.trim().isNotEmpty;

  /// 规范化的服务端地址（去尾斜杠）。
  String get normalizedBase => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      baseUrl = p.getString(_kBase) ?? '';
      username = p.getString(_kUser) ?? '';
      password = p.getString(_kPass) ?? '';
      accessToken = p.getString(_kToken) ?? '';
      revision.value++;
    } catch (e) {
      debugPrint('[QreadConfig] load 失败: $e');
    }
  }

  Future<void> save({
    String? baseUrl,
    String? username,
    String? password,
    String? accessToken,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      this.baseUrl = baseUrl;
      await p.setString(_kBase, baseUrl);
    }
    if (username != null) {
      this.username = username;
      await p.setString(_kUser, username);
    }
    if (password != null) {
      this.password = password;
      await p.setString(_kPass, password);
    }
    if (accessToken != null) {
      this.accessToken = accessToken;
      await p.setString(_kToken, accessToken);
    }
    revision.value++;
  }

  Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    accessToken = '';
    await p.setString(_kToken, '');
    revision.value++;
  }
}

/// qread 搜索/探索返回的一本书（Legado SearchBook 的 Dart 映射）。
class QreadSearchResult {
  const QreadSearchResult({
    required this.bookUrl,
    this.origin = '',
    this.originName = '',
    this.type = 0,
    this.name = '',
    this.author = '',
    this.kind = '',
    this.coverUrl = '',
    this.intro = '',
    this.wordCount = '',
    this.latestChapterTitle = '',
    this.tocUrl = '',
    this.originOrder = 0,
  });

  final String bookUrl;
  final String origin;
  final String originName;
  final int type;
  final String name;
  final String author;
  final String kind;
  final String coverUrl;
  final String intro;
  final String wordCount;
  final String latestChapterTitle;
  final String tocUrl;
  final int originOrder;

  static QreadSearchResult? fromJson(Map<String, dynamic> j) {
    // 服务端返回的仍是源站原文 ⇒ 这里统一清掉站名 / 导航词 / 装饰符号。
    final name = cleanSourceTitle((j['name'] ?? '').toString().trim());
    final bookUrl = (j['bookUrl'] ?? '').toString().trim();
    if (name.isEmpty || bookUrl.isEmpty) return null;
    return QreadSearchResult(
      bookUrl: bookUrl,
      origin: (j['origin'] ?? '').toString(),
      originName: (j['originName'] ?? '').toString(),
      type: (j['type'] is num)
          ? (j['type'] as num).toInt()
          : int.tryParse(j['type']?.toString() ?? '') ?? 0,
      name: name,
      author: cleanSourceTitle((j['author'] ?? '').toString().trim()),
      kind: (j['kind'] ?? '').toString(),
      coverUrl: (j['coverUrl'] ?? '').toString(),
      intro: cleanIntroText((j['intro'] ?? '').toString()),
      wordCount: (j['wordCount'] ?? '').toString(),
      latestChapterTitle: cleanChapterTitle(
        (j['latestChapterTitle'] ?? '').toString(),
      ),
      tocUrl: (j['tocUrl'] ?? '').toString(),
      originOrder: (j['originOrder'] is num)
          ? (j['originOrder'] as num).toInt()
          : int.tryParse(j['originOrder']?.toString() ?? '') ?? 0,
    );
  }
}

/// qread 服务端书源条目（列表接口的精简元数据）。
class QreadSourceInfo {
  const QreadSourceInfo({
    required this.name,
    required this.url,
    this.group = '',
    this.enabled = true,
    this.enabledExplore = true,
    this.loginUrl = '',
    this.checkKeyWord = '',
  });

  final String name;
  final String url;
  final String group;
  final bool enabled;
  final bool enabledExplore;
  final String loginUrl;
  final String checkKeyWord;

  static QreadSourceInfo fromJson(Map<String, dynamic> j) => QreadSourceInfo(
    name: (j['bookSourceName'] ?? '').toString(),
    url: (j['bookSourceUrl'] ?? '').toString(),
    group: (j['bookSourceGroup'] ?? '').toString(),
    enabled: j['enabled'] != false,
    enabledExplore: j['enabledExplore'] != false,
    loginUrl: (j['loginUrl'] ?? '').toString(),
    checkKeyWord: (j['checkKeyWord'] ?? '').toString(),
  );
}

/// qread 服务端返回的一章（BookChapter 精简映射）。
class QreadChapter {
  const QreadChapter({required this.url, required this.title});

  final String url;
  final String title;
}

/// qread 服务端 API 客户端。
class QreadApi {
  QreadApi._();
  static final QreadApi instance = QreadApi._();

  static const int apiVersion = 5;

  Dio? _dio;
  Dio get _client {
    final cfg = QreadServerConfig.instance;
    if (_dio == null || _dio!.options.baseUrl != cfg.normalizedBase) {
      // 重建前先释放旧实例，避免 baseUrl 变更时旧 HttpClient 连接池泄漏
      _dio?.close(force: true);
      _dio = Dio(
        BaseOptions(
          baseUrl: cfg.normalizedBase,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
    }
    return _dio!;
  }

  String get _token => QreadServerConfig.instance.accessToken;

  // ── 底层请求 ──────────────────────────────────────────────

  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) async {
    final cfg = QreadServerConfig.instance;
    if (!cfg.isConfigured) throw QreadException('未配置 qread 服务端地址');
    try {
      final res = await _client.get(
        '/api/$apiVersion$path',
        queryParameters: query,
      );
      return _unwrap(res);
    } on QreadException {
      rethrow;
    } on DioException catch (e) {
      throw QreadException(_dioError(e));
    } catch (e) {
      throw QreadException('请求失败：$e');
    }
  }

  Future<dynamic> _post(
    String path, {
    Map<String, dynamic>? query,
    Object? body,
  }) async {
    final cfg = QreadServerConfig.instance;
    if (!cfg.isConfigured) throw QreadException('未配置 qread 服务端地址');
    try {
      final res = await _client.post(
        '/api/$apiVersion$path',
        queryParameters: query,
        data: body,
        options: Options(contentType: Headers.textPlainContentType),
      );
      return _unwrap(res);
    } on QreadException {
      rethrow;
    } on DioException catch (e) {
      throw QreadException(_dioError(e));
    } catch (e) {
      throw QreadException('请求失败：$e');
    }
  }

  String _dioError(DioException e) {
    final code = e.response?.statusCode;
    final msg = e.message ?? e.toString();
    if (code != null) return '服务端错误 HTTP $code';
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '连接超时，请检查服务端地址/网络';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '无法连接服务端（$msg）';
    }
    return '网络错误：$msg';
  }

  /// 解析 `JsonResponse{isSuccess,errorMsg,data}`，失败抛 [QreadException]。
  dynamic _unwrap(Response res) {
    if (res.statusCode != 200) {
      final hint = switch (res.statusCode) {
        404 => '（接口不存在：确认地址是 http://IP:端口，不要加 /api）',
        401 || 403 => '（服务端拒绝访问，请检查账号权限）',
        502 || 503 => '（服务端未就绪或网关错误）',
        _ => '',
      };
      throw QreadException('服务端错误 HTTP ${res.statusCode}$hint');
    }
    dynamic body;
    final text = res.data?.toString() ?? '';
    try {
      body = jsonDecode(text);
    } catch (_) {
      final preview = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      throw QreadException('服务端返回无法解析（可能地址连错服务）：$preview');
    }
    if (body is! Map) throw QreadException('服务端返回格式异常');
    final ok = body['isSuccess'] == true;
    if (!ok) {
      final msg = (body['errorMsg'] ?? '').toString();
      throw QreadException(msg.isNotEmpty ? msg : '服务端操作失败');
    }
    return body['data'];
  }

  // ── 登录 ──────────────────────────────────────────────────

  Future<void> login() async {
    final cfg = QreadServerConfig.instance;
    if (!cfg.isConfigured) throw QreadException('未配置 qread 服务端地址');
    if (cfg.username.trim().isEmpty || cfg.password.isEmpty) {
      throw QreadException('请输入服务端账号和密码');
    }
    final data = await _get(
      '/login',
      query: {
        'username': cfg.username.trim(),
        'password': cfg.password,
        // 账号来源（bank）：xs.muiu.site 等服务端不认 cmbok，会返回 NOT_BANK；
        // 实测 model=bank 进入密码校验，为通用可用来源。
        'model': 'bank',
        'v': apiVersion,
      },
    );
    final token = (data is Map) ? (data['accessToken'] ?? '').toString() : '';
    if (token.isEmpty) throw QreadException('登录失败：未返回 accessToken');
    await cfg.save(accessToken: token);
  }

  Future<void> ensureLogin() async {
    if (QreadServerConfig.instance.isLoggedIn) return;
    await login();
  }

  // ── 书源管理（仓库壳） ────────────────────────────────────

  /// 拉取全部书源（精简元数据）。自动登录后两段式拉取。
  Future<List<QreadSourceInfo>> getSources({String? st}) async {
    await ensureLogin();
    final pageRes = await _get(
      '/getBookSourcesPage',
      query: {
        'accessToken': _token,
        if (st != null && st.isNotEmpty) 'st': st,
      },
    );
    if (pageRes is! Map) return [];
    final totalPage = (pageRes['page'] is num)
        ? (pageRes['page'] as num).toInt()
        : int.tryParse(pageRes['page']?.toString() ?? '1') ?? 1;
    final md5 = (pageRes['md5'] ?? '').toString();
    final out = <QreadSourceInfo>[];
    for (var p = 1; p <= totalPage; p++) {
      final data = await _get(
        '/getBookSourcesNew',
        query: {
          'accessToken': _token,
          'md5': md5,
          'page': '$p',
        },
      );
      if (data is List) {
        for (final e in data) {
          if (e is Map)
            out.add(QreadSourceInfo.fromJson(e.cast<String, dynamic>()));
        }
      }
    }
    return out;
  }

  /// 批量导入书源（完整 JSON 数组或单个对象）。
  Future<int> saveSources(List<Map<String, dynamic>> sources) async {
    await ensureLogin();
    if (sources.isEmpty) return 0;
    final content = sources.length == 1
        ? jsonEncode(sources.first)
        : jsonEncode(sources);
    final data = await _post(
      '/saveBookSources',
      query: {'accessToken': _token},
      body: content,
    );
    final n = (data is num)
        ? data.toInt()
        : (int.tryParse(data?.toString() ?? '') ?? sources.length);
    return n;
  }

  /// 单条导入/覆盖（内容为完整书源 JSON 字符串）。
  Future<bool> saveSource(String json) async {
    await ensureLogin();
    final data = await _post(
      '/saveBookSource',
      query: {'accessToken': _token},
      body: json,
    );
    return data == true;
  }

  /// 编辑书源（id = bookSourceUrl，json = 完整书源 JSON 字符串）。
  Future<bool> editSource(String id, String json) async {
    await ensureLogin();
    final data = await _post(
      '/editbookSources',
      query: {'accessToken': _token},
      body: jsonEncode({'id': id, 'json': json}),
    );
    return data == true;
  }

  Future<bool> deleteSource(String id) async {
    await ensureLogin();
    final data = await _get(
      '/delbookSource',
      query: {'accessToken': _token, 'id': id},
    );
    return data == true;
  }

  Future<bool> deleteSources(List<String> ids) async {
    await ensureLogin();
    if (ids.isEmpty) return true;
    final data = await _post(
      '/delbookSources',
      query: {'accessToken': _token},
      body: jsonEncode(ids),
    );
    return data == true;
  }

  /// 批量启用/停用书源。
  Future<bool> setSourcesEnabled(
    List<String> ids, {
    required bool enabled,
  }) async {
    await ensureLogin();
    if (ids.isEmpty) return true;
    final path = enabled ? '/startbookSources' : '/stopbookSources';
    final data = await _post(
      path,
      query: {'accessToken': _token},
      body: jsonEncode(ids),
    );
    return data == true;
  }

  /// 单个书源停用/启用（st=0 停用 / 1 启用）。
  Future<bool> setSourceEnabled(String id, {required bool enabled}) async {
    await ensureLogin();
    final data = await _get(
      '/stopbookSource',
      query: {
        'accessToken': _token,
        'id': id,
        'st': enabled ? '1' : '0',
      },
    );
    return data == true;
  }

  /// 批量开关发现（explore）。
  Future<bool> setExploresEnabled(
    List<String> ids, {
    required bool enabled,
  }) async {
    await ensureLogin();
    if (ids.isEmpty) return true;
    final path = enabled
        ? '/startbookSourceExplores'
        : '/stopbookSourceExplores';
    final data = await _post(
      path,
      query: {'accessToken': _token},
      body: jsonEncode(ids),
    );
    return data == true;
  }

  /// 置顶/置底。
  Future<bool> topSources(List<String> ids, {bool bottom = false}) async {
    await ensureLogin();
    if (ids.isEmpty) return true;
    final path = bottom ? '/bottomallSource' : '/topallSource';
    final data = await _post(
      path,
      query: {'accessToken': _token},
      body: jsonEncode(ids),
    );
    return data == true;
  }

  Future<bool> topSource(String id, {bool bottom = false}) async {
    await ensureLogin();
    final path = bottom ? '/bottomSource' : '/topSource';
    final data = await _get(path, query: {'accessToken': _token, 'id': id});
    return data == true;
  }

  /// 批量改分组（ids 为 POST body）。
  Future<bool> setGroup(String group, {String? st, List<String>? ids}) async {
    await ensureLogin();
    final data = await _post(
      '/editsourcegroup',
      query: {
        'accessToken': _token,
        'st': st ?? group,
        'group': group,
      },
      body: jsonEncode(ids ?? []),
    );
    return data == true;
  }

  /// 导出完整书源 JSON（ids 为空则导出全部）。
  Future<List<Map<String, dynamic>>> exportSources(List<String>? ids) async {
    await ensureLogin();
    final data = await _post(
      '/getbookSourcejson',
      query: {'accessToken': _token},
      body: jsonEncode(ids ?? []),
    );
    if (data is! List) return [];
    final out = <Map<String, dynamic>>[];
    for (final e in data) {
      if (e is Map) out.add(e.cast<String, dynamic>());
    }
    return out;
  }

  /// 拉单个书源完整 JSON。
  Future<Map<String, dynamic>?> getSource(String id) async {
    await ensureLogin();
    final data = await _get(
      '/getbookSources',
      query: {'accessToken': _token, 'id': id},
    );
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  // ── 搜索 / 探索（书源页壳） ───────────────────────────────

  /// 单源搜索（qread 服务端执行规则）。
  Future<List<QreadSearchResult>> searchBook(
    String sourceUrl,
    String key, {
    int page = 1,
  }) async {
    await ensureLogin();
    final data = await _get(
      '/searchBook',
      query: {
        'accessToken': _token,
        'bookSourceUrl': sourceUrl,
        'page': '$page',
        'key': key,
      },
    );
    return _toResults(data);
  }

  /// 探索/分类（qread 服务端执行规则）。
  Future<List<QreadSearchResult>> exploreBook(
    String sourceUrl,
    String ruleFindUrl, {
    int page = 1,
  }) async {
    await ensureLogin();
    final data = await _get(
      '/exploreBook',
      query: {
        'accessToken': _token,
        'bookSourceUrl': sourceUrl,
        'page': '$page',
        'ruleFindUrl': ruleFindUrl,
      },
    );
    return _toResults(data);
  }

  /// 源探索 URL 列表（每个启用了探索的源 → exploreUrl）。
  Future<List<Map<String, dynamic>>> getExploreUrls() async {
    await ensureLogin();
    final data = await _get(
      '/getBookSourcesExploreUrl',
      query: {'accessToken': _token},
    );
    if (data is! List) return [];
    return data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 源探索 URL/分类列表（服务端解析 exploreKinds）。
  /// 返回 `{found: [{title,url},...], checkKeyWord, loginUrl, loginUi}`。
  Future<Map<String, dynamic>> getExploreKinds(
    String sourceUrl, {
    bool need = false,
  }) async {
    await ensureLogin();
    final data = await _get(
      '/getBookSourcesExploreUrl',
      query: {
        'accessToken': _token,
        'bookSourceUrl': sourceUrl,
        'need': need ? '1' : '0',
      },
    );
    if (data is! Map) return <String, dynamic>{};
    return data.cast<String, dynamic>();
  }

  // ── 阅读链路（详情/目录/正文，全部服务端执行） ──────────────

  /// 详情：qread 服务端执行 ruleBookInfo，返回 Legado Book 的 JSON Map。
  Future<Map<String, dynamic>> getBookInfo2(String bookUrl) async {
    await ensureLogin();
    final data = await _get(
      '/getBookinfo2',
      query: {
        'accessToken': _token,
        'url': bookUrl,
      },
    );
    if (data is! Map) return <String, dynamic>{};
    return data.cast<String, dynamic>();
  }

  /// 目录：服务端执行 ruleToc，返回章节列表（BookChapter 的 url/title）。
  Future<List<QreadChapter>> getChapterList(
    String sourceUrl,
    String tocUrl,
  ) async {
    await ensureLogin();
    final data = await _get(
      '/getChapterList',
      query: {
        'accessToken': _token,
        'bookSourceUrl': sourceUrl,
        'url': tocUrl,
      },
    );
    final out = <QreadChapter>[];
    if (data is List) {
      for (final e in data) {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final url = (m['url'] ?? '').toString().trim();
        final title = cleanChapterTitle((m['title'] ?? '').toString().trim());
        if (url.isEmpty || title.isEmpty) continue;
        out.add(QreadChapter(url: url, title: title));
      }
    }
    return out;
  }

  /// 正文：服务端执行 ruleContent（含翻页聚合、净化），返回纯文本。
  Future<String> getBookContent(String sourceUrl, String chapterUrl) async {
    await ensureLogin();
    final data = await _get(
      '/getBookContent',
      query: {
        'accessToken': _token,
        'bookSourceUrl': sourceUrl,
        'url': chapterUrl,
      },
    );
    return (data ?? '').toString();
  }

  List<QreadSearchResult> _toResults(dynamic data) {
    final out = <QreadSearchResult>[];
    if (data is List) {
      for (final e in data) {
        if (e is! Map) continue;
        final r = QreadSearchResult.fromJson(e.cast<String, dynamic>());
        if (r != null) out.add(r);
      }
    }
    return out;
  }
}
