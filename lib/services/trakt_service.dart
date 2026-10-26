import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/app_log.dart';

/// Trakt 设备码授权信息（第一步返回）。
class TraktDeviceAuth {
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final String codeVerifier;
  final int interval;
  final int expiresIn;

  const TraktDeviceAuth({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.codeVerifier,
    required this.interval,
    required this.expiresIn,
  });
}

enum TraktPollStatus { success, pending, slowDown, denied, expired, error }

/// Trakt 放送日历里的一集。
class TraktCalendarEntry {
  final int traktId;
  final int tmdbId;
  final String showTitle;
  final String episodeTitle;
  final String overview;
  final String poster;
  final String firstAired; // UTC ISO
  final int season;
  final int number;

  const TraktCalendarEntry({
    required this.traktId,
    required this.tmdbId,
    required this.showTitle,
    required this.episodeTitle,
    required this.overview,
    required this.poster,
    required this.firstAired,
    required this.season,
    required this.number,
  });

  String get episodeLabel =>
      'S${season.toString().padLeft(2, '0')}E${number.toString().padLeft(2, '0')}';

  /// 北京时间（Trakt 返回 UTC ISO）。
  DateTime? get firstAiredLocal {
    final d = DateTime.tryParse(firstAired);
    return d?.toLocal();
  }
}

class TraktNotConfigured implements Exception {
  const TraktNotConfigured();
}

class TraktNotLoggedIn implements Exception {
  const TraktNotLoggedIn();
}

/// Trakt 追剧日历（设备码 + PKCE，和 MineTrakt `_worker.js` 的授权方式一致）。
///
/// 只需要在「设置 → 追剧日历」里填 **Trakt Client ID**：
///   · 设备码授权：`/oauth/device/code` + `/oauth/device/token`（PKCE S256）；
///   · token 过期前 30 分钟自动用 refresh_token 续期；
///   · 日历：`/calendars/my/shows/{today}/{days}?extended=full&images=poster`，
///     返回你在 Trakt 追的剧未来 N 天的待播集。
class TraktService {
  TraktService._();
  static final TraktService instance = TraktService._();

  static const String _auth = 'https://api.trakt.tv';
  static const String _api = 'https://api.trakt.tv';
  static const String _activateUrl = 'https://trakt.tv/activate';
  static const String _ua = 'CatYing/1.0 (https://github.com/xiaoyugesvg/CatYing)';

  static const String _kClientId = 'trakt_client_id';
  static const String _kAccess = 'trakt_access_token';
  static const String _kRefresh = 'trakt_refresh_token';
  static const String _kExpires = 'trakt_expires_at';
  static const String _kVerifier = 'trakt_code_verifier';

  String _clientId = '';
  String _accessToken = '';
  String _refreshToken = '';
  String _verifier = '';
  int _expiresAt = 0; // epoch ms
  bool _loaded = false;

  bool get configured => _clientId.isNotEmpty;
  bool get loggedIn => _accessToken.isNotEmpty;
  String get clientId => _clientId;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _clientId = (prefs.getString(_kClientId) ?? '').trim();
      _accessToken = (prefs.getString(_kAccess) ?? '').trim();
      _refreshToken = (prefs.getString(_kRefresh) ?? '').trim();
      _verifier = (prefs.getString(_kVerifier) ?? '').trim();
      _expiresAt = prefs.getInt(_kExpires) ?? 0;
    } catch (e) {
      AppLog.instance.w('[Trakt] 读取配置失败: $e');
    }
  }

  Future<void> saveClientId(String id) async {
    _clientId = id.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kClientId, _clientId);
    } catch (_) {}
  }

  Future<void> logout() async {
    _accessToken = '';
    _refreshToken = '';
    _verifier = '';
    _expiresAt = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAccess);
      await prefs.remove(_kRefresh);
      await prefs.remove(_kExpires);
      await prefs.remove(_kVerifier);
    } catch (_) {}
  }

  Future<void> _saveAuth(Map data, String verifier) async {
    _accessToken = (data['access_token'] ?? '').toString();
    _refreshToken = (data['refresh_token'] ?? '').toString();
    _verifier = verifier;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 0;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAccess, _accessToken);
      await prefs.setString(_kRefresh, _refreshToken);
      await prefs.setString(_kVerifier, _verifier);
      await prefs.setInt(_kExpires, _expiresAt);
    } catch (_) {}
  }

  Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json', 'User-Agent': _ua},
      ));

  Map<String, String> _authHeaders() => {
        'Content-Type': 'application/json',
        'trakt-api-version': '2',
        'trakt-api-key': _clientId,
        'Authorization': 'Bearer $_accessToken',
        'User-Agent': _ua,
      };

  /// 第一步：申请设备码（PKCE S256）。
  Future<TraktDeviceAuth> startDeviceAuth() async {
    await load();
    if (_clientId.isEmpty) throw const TraktNotConfigured();
    final verifier = _randomVerifier();
    final challenge = _challengeOf(verifier);
    final res = await _dio().post<dynamic>(
      '$_auth/oauth/device/code',
      data: {
        'client_id': _clientId,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
      options: Options(validateStatus: (_) => true),
    );
    if (res.statusCode != 200 || res.data is! Map) {
      throw Exception('Trakt 设备码申请失败（HTTP ${res.statusCode}）');
    }
    final data = Map<String, dynamic>.from(res.data as Map);
    return TraktDeviceAuth(
      deviceCode: (data['device_code'] ?? '').toString(),
      userCode: (data['user_code'] ?? '').toString(),
      verificationUrl: _activateUrl,
      codeVerifier: verifier,
      interval: (data['interval'] as num?)?.toInt() ?? 5,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 600,
    );
  }

  /// 第二步：轮询授权结果。
  Future<TraktPollStatus> pollDeviceAuth(TraktDeviceAuth auth) async {
    try {
      final res = await _dio().post<dynamic>(
        '$_auth/oauth/device/token',
        data: {
          'code': auth.deviceCode,
          'client_id': _clientId,
          'code_verifier': auth.codeVerifier,
        },
        options: Options(validateStatus: (_) => true),
      );
      if (res.statusCode == 200 && res.data is Map) {
        await _saveAuth(Map<String, dynamic>.from(res.data as Map),
            auth.codeVerifier);
        return TraktPollStatus.success;
      }
      if (res.statusCode == 202) return TraktPollStatus.pending;
      if (res.statusCode == 403) return TraktPollStatus.denied;
      if (res.statusCode == 410) return TraktPollStatus.expired;
      if (res.statusCode == 429) return TraktPollStatus.slowDown;
      final body = res.data;
      final err = body is Map ? '${body['error'] ?? ''}' : '';
      if (err == 'slow_down') return TraktPollStatus.slowDown;
      if (err == 'authorization_pending' || err == 'pending') {
        return TraktPollStatus.pending;
      }
      if (err == 'access_denied') return TraktPollStatus.denied;
      if (err == 'expired_token') return TraktPollStatus.expired;
      return TraktPollStatus.error;
    } catch (e) {
      AppLog.instance.w('[Trakt] 授权轮询失败: $e');
      return TraktPollStatus.error;
    }
  }

  /// token 快过期（<30 分钟）时刷新。
  Future<bool> _refreshIfNeeded({bool force = false}) async {
    await load();
    if (_refreshToken.isEmpty) return false;
    final remain = _expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (!force && remain > 30 * 60 * 1000) return true;
    try {
      final res = await _dio().post<dynamic>(
        '$_auth/oauth/token',
        data: {
          'refresh_token': _refreshToken,
          'client_id': _clientId,
          'code_verifier': _verifier,
          'grant_type': 'refresh_token',
          'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
        },
        options: Options(validateStatus: (_) => true),
      );
      if (res.statusCode == 200 && res.data is Map) {
        await _saveAuth(Map<String, dynamic>.from(res.data as Map), _verifier);
        return true;
      }
      AppLog.instance.w('[Trakt] 刷新 token 失败: HTTP ${res.statusCode}');
    } catch (e) {
      AppLog.instance.w('[Trakt] 刷新 token 异常: $e');
    }
    return false;
  }

  /// 未来 [days] 天、我的追剧日历（北京时间日期由调用方分组）。
  Future<List<TraktCalendarEntry>> fetchCalendar({int days = 30}) async {
    await load();
    if (_clientId.isEmpty) throw const TraktNotConfigured();
    if (_accessToken.isEmpty) throw const TraktNotLoggedIn();
    await _refreshIfNeeded();

    final bj = DateTime.now().toUtc().add(const Duration(hours: 8));
    final start =
        '${bj.year}-${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')}';
    final url =
        '$_api/calendars/my/shows/$start/$days?extended=full&images=poster';

    Future<Response<dynamic>> once() => _dio()
        .get<dynamic>(
          url,
          options: Options(
            headers: _authHeaders(),
            validateStatus: (_) => true,
          ),
        )
        .timeout(const Duration(seconds: 15));

    var res = await once();
    if (res.statusCode == 401) {
      // token 失效：强制刷新一次再重试；刷新也失败 → 清掉登录态
      final ok = await _refreshIfNeeded(force: true);
      if (ok) res = await once();
      if (res.statusCode == 401) {
        await logout();
        throw const TraktNotLoggedIn();
      }
    }
    if (res.statusCode != 200 || res.data is! List) {
      throw Exception('Trakt 日历请求失败（HTTP ${res.statusCode}）');
    }
    final out = <TraktCalendarEntry>[];
    for (final e in res.data as List) {
      if (e is! Map) continue;
      final show = e['show'];
      final ep = e['episode'];
      if (show is! Map) continue;
      final showMap = Map<String, dynamic>.from(show);
      final epMap = ep is Map ? Map<String, dynamic>.from(ep) : const {};
      final ids = showMap['ids'];
      final idMap = ids is Map ? ids : const {};
      final images = showMap['images'];
      var poster = '';
      if (images is Map) {
        final list = images['poster'];
        if (list is List && list.isNotEmpty) {
          final first = list.first;
          if (first is Map) {
            poster = (first['medium'] ?? first['full'] ?? first['thumb'] ?? '')
                .toString();
          }
        }
      }
      out.add(TraktCalendarEntry(
        traktId: (idMap['trakt'] as num?)?.toInt() ?? 0,
        tmdbId: (idMap['tmdb'] as num?)?.toInt() ?? 0,
        showTitle: (showMap['title'] ?? '').toString(),
        episodeTitle: (epMap['title'] ?? '').toString(),
        overview: (epMap['overview'] ?? showMap['overview'] ?? '').toString(),
        poster: poster,
        firstAired: (e['first_aired'] ?? '').toString(),
        season: (epMap['season'] as num?)?.toInt() ?? 0,
        number: (epMap['number'] as num?)?.toInt() ?? 0,
      ));
    }
    out.sort((a, b) => a.firstAired.compareTo(b.firstAired));
    AppLog.instance.log('[Trakt] 日历 ${out.length} 集（未来 $days 天）');
    return out;
  }

  // ── PKCE ─────────────────────────────────────────────────────

  static String _randomVerifier() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final r = Random.secure();
    return List.generate(64, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String _challengeOf(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
