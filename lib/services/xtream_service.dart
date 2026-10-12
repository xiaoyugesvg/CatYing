import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/live_models.dart';

/// Xtream Codes 直播账号（provider 的 player_api 接口体系）。
///
/// 一个账号就是「服务地址 + 用户名 + 密码」三件套：
/// - 账号信息：`{base}/player_api.php?username=&password=`
/// - 直播分类：`...&action=get_live_categories`
/// - 直播频道：`...&action=get_live_streams`
/// - 播放地址：`{base}/live/{user}/{pass}/{stream_id}.m3u8`
class XtreamAccount {
  /// `http(s)://host:port`（不含路径末尾斜杠、不含脚本名）
  final String base;
  final String user;
  final String pass;

  /// 账号状态（Active / Expired / Disabled …），未获取到时为 null
  final String? status;

  /// 到期时间，未获取到或永久时可能为 null
  final DateTime? expDate;

  /// 最大同时连接数
  final int? maxConnections;

  const XtreamAccount({
    required this.base,
    required this.user,
    required this.pass,
    this.status,
    this.expDate,
    this.maxConnections,
  });

  XtreamAccount copyWith({
    String? status,
    DateTime? expDate,
    int? maxConnections,
  }) {
    return XtreamAccount(
      base: base,
      user: user,
      pass: pass,
      status: status ?? this.status,
      expDate: expDate ?? this.expDate,
      maxConnections: maxConnections ?? this.maxConnections,
    );
  }

  /// 账号是否已被标记为不可用（Expired / Disabled / Banned …）
  bool get isDisabled {
    final s = status?.toLowerCase();
    if (s == null || s.isEmpty) return false;
    return s.contains('expired') ||
        s.contains('disabled') ||
        s.contains('banned');
  }

  /// 是否已过到期时间
  bool get isExpired {
    final d = expDate;
    if (d == null) return false;
    return d.isBefore(DateTime.now());
  }
}

/// [XtreamService] 抛出的异常：`message` 已是可直接展示给用户的中文。
class XtreamException implements Exception {
  final String message;
  const XtreamException(this.message);
  @override
  String toString() => message;
}

/// Xtream Codes 接口客户端（单例）。
class XtreamService {
  XtreamService._();
  static final XtreamService instance = XtreamService._();

  static const Duration _timeout = Duration(seconds: 10);

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: _timeout,
    receiveTimeout: _timeout,
    sendTimeout: _timeout,
    headers: const {
      'User-Agent': 'Mozilla/5.0 (NewTv Live)',
    },
  ));

  // ============================================================
  // 识别与解析
  // ============================================================

  /// 该地址是否「看起来是 Xtream 账号」。
  ///
  /// - `.../get.php?username=x&password=y...`
  /// - `.../player_api.php?username=...`
  ///
  /// 注意：纯 `host:port` + 另外单独给账号的情况无法从地址本身判断，
  /// 由调用方（如设置页的 Xtream 模式）决定。
  bool looksLikeXtream(String url) {
    final s = url.trim().toLowerCase();
    if (s.isEmpty || !s.contains('username=')) return false;
    return s.contains('get.php') || s.contains('player_api.php');
  }

  /// 从任意「地址 + 账号」文本里抽出 base / user / pass。
  ///
  /// 兼容：
  /// - 完整链接（`http://host:port/get.php?username=..&password=..`）
  /// - `player_api.php?...` 链接
  /// - 纯 `host:port`（无账号 → user/pass 为空串，交由调用方另行补全）
  ///
  /// 无法解析出 base 时返回 null。
  XtreamAccount? parseAccount(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // 无 scheme 的 host:port 补 http://，让 Uri 可解析
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;

    final qp = uri.queryParameters;
    final user = (qp['username'] ?? '').trim();
    final pass = (qp['password'] ?? '').trim();

    // base = scheme://authority + 脚本名之前的路径前缀
    var path = uri.path;
    final lower = path.toLowerCase();
    for (final script in const ['/get.php', '/player_api.php']) {
      final i = lower.indexOf(script);
      if (i >= 0) {
        path = path.substring(0, i);
        break;
      }
    }
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);

    return XtreamAccount(
      base: '${uri.scheme}://${uri.authority}$path',
      user: user,
      pass: pass,
    );
  }

  /// 用 base/user/pass 拼出一条可持久化的账号链接（存进直播源 url 字段）。
  String buildAccountUrl(String base, String user, String pass) {
    final b = _trimSlash(base.trim());
    return '$b/get.php'
        '?username=${Uri.encodeComponent(user)}'
        '&password=${Uri.encodeComponent(pass)}';
  }

  /// 从已持久化的直播源配置（`_rawLives` 里的一项）还原账号信息。
  ///
  /// 优先用显式存的 user/pass 字段，缺失时回退到从 url 解析。
  XtreamAccount? accountFromStored(Map<String, dynamic> map) {
    final url = (map['url'] ?? '').toString();
    final parsed = parseAccount(url);
    final user = (map['user'] ?? '').toString().trim();
    final pass = (map['pass'] ?? map['password'] ?? '').toString().trim();
    final base = parsed?.base ?? '';
    final u = user.isNotEmpty ? user : (parsed?.user ?? '');
    final p = pass.isNotEmpty ? pass : (parsed?.pass ?? '');
    if (base.isEmpty || u.isEmpty || p.isEmpty) return null;
    return XtreamAccount(base: base, user: u, pass: p);
  }

  // ============================================================
  // 接口调用
  // ============================================================

  /// 拉取账号信息（状态 / 到期时间 / 最大连接数）。
  ///
  /// 失败时抛 [XtreamException]（中文 message）。
  Future<XtreamAccount> fetchAccount(XtreamAccount account) async {
    final data = await _getJson(_apiUri(account, null));
    String? status;
    DateTime? exp;
    int? maxConn;
    final info = data is Map ? data['user_info'] : null;
    if (info is Map) {
      status = info['status']?.toString();
      exp = _parseExp(info['exp_date']);
      maxConn = int.tryParse('${info['max_connections']}');
    }
    return account.copyWith(
      status: status,
      expDate: exp,
      maxConnections: maxConn,
    );
  }

  /// 拉取直播频道：先取分类，再取频道并映射为 [LiveChannel]。
  ///
  /// 分类接口失败时退化为「不带分类」继续取频道（分组统一为「未分组」）。
  ///
  /// [withEpg] 预留：当前 [LiveChannel] 模型没有 EPG 字段（本任务不改模型），
  /// 故该参数暂不产生额外字段，仅用于未来接入 epg_channel_id。
  Future<List<LiveChannel>> fetchChannels(
    XtreamAccount account, {
    bool withEpg = false,
  }) async {
    // 1) 分类（失败可降级，不致命）
    final catNames = <String, String>{};
    var catsOk = false;
    try {
      final cats = await _getJson(_apiUri(account, 'get_live_categories'));
      if (cats is List) {
        for (final c in cats) {
          if (c is! Map) continue;
          final id = (c['category_id'] ?? '').toString();
          if (id.isEmpty) continue;
          catNames[id] = (c['category_name'] ?? '未分组').toString();
        }
        catsOk = true;
      }
    } catch (_) {
      // 分类接口失败 → 退化为不带分类，继续拉频道
      catsOk = false;
    }

    // 2) 频道
    final raw = await _getJson(_apiUri(account, 'get_live_streams'));
    if (raw is! List) {
      throw const XtreamException('Xtream 未返回直播频道列表，账号可能无效或该服务器不支持。');
    }

    final result = <LiveChannel>[];
    for (final s in raw) {
      if (s is! Map) continue;
      final id = (s['stream_id'] ?? '').toString();
      if (id.isEmpty) continue;
      final name = (s['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final catId = (s['category_id'] ?? '').toString();
      final group = catsOk ? (catNames[catId] ?? '未分组') : '未分组';
      final logo = s['stream_icon']?.toString();
      result.add(LiveChannel(
        name: name,
        urls: [_playUrl(account, id)],
        group: group,
        logo: (logo == null || logo.isEmpty) ? null : logo,
      ));
    }
    return result;
  }

  // ============================================================
  // 内部工具
  // ============================================================

  String _playUrl(XtreamAccount a, String streamId) {
    final u = Uri.encodeComponent(a.user);
    final p = Uri.encodeComponent(a.pass);
    return '${_trimSlash(a.base)}/live/$u/$p/$streamId.m3u8';
  }

  Uri _apiUri(XtreamAccount a, String? action) {
    final params = <String, String>{
      'username': a.user,
      'password': a.pass,
      'action': ?action,
    };
    return Uri.parse('${_trimSlash(a.base)}/player_api.php')
        .replace(queryParameters: params);
  }

  Future<dynamic> _getJson(Uri uri) async {
    final String body;
    try {
      final res = await _dio.getUri<String>(
        uri,
        options: Options(responseType: ResponseType.plain),
      );
      body = res.data ?? '';
    } on DioException catch (e) {
      throw XtreamException(_humanize(e));
    }
    if (body.trim().isEmpty) {
      throw const XtreamException('Xtream 服务器返回空响应，请检查地址是否正确。');
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const XtreamException('Xtream 返回的数据无法解析，可能不是有效的 Xtream 账号。');
    }
  }

  String _humanize(DioException e) {
    switch (e.type) {
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'Xtream 服务器响应超时，请稍后重试。';
      case DioExceptionType.connectionTimeout:
        return '连接 Xtream 服务器超时，请检查网络。';
      case DioExceptionType.connectionError:
        return '无法连接 Xtream 服务器，请检查地址与网络。';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return 'Xtream 服务器返回错误${code == null ? '' : '（HTTP $code）'}。';
      case DioExceptionType.cancel:
        return '请求已取消。';
      default:
        return '加载 Xtream 账号失败，请稍后重试。';
    }
  }

  DateTime? _parseExp(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    final secs = int.tryParse(s);
    if (secs == null || secs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  }

  String _trimSlash(String s) {
    var r = s.trim();
    while (r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }
}
