import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nodejs_manager.dart';

/// Telegram 源的 Dart 侧门面
///
/// 只做三件事：配置读写、把请求打到内置 Node 的 `/tg`、拼流地址。
/// **不做任何 MTProto 逻辑** —— 协议全在 Node（`assets/nodejs-project/src/tg`）。
class TgService {
  TgService._();
  static final TgService instance = TgService._();

  static const _kApiId = 'tg.apiId';
  static const _kApiHash = 'tg.apiHash';
  static const _kProxyHost = 'tg.proxy.host';
  static const _kProxyPort = 'tg.proxy.port';
  static const _kProxyUser = 'tg.proxy.user';
  static const _kProxyPass = 'tg.proxy.pass';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 45),
  ));

  /// 内置 Node 的管理端口（0 = 还没起来）
  int get port => NodeJSManager.instance.managementPort;
  bool get ready => port > 0;
  String get _base => 'http://127.0.0.1:$port/tg';

  /// 相对地址 → 可给播放器/图片组件用的绝对地址
  String absolute(String rel) =>
      rel.startsWith('http') ? rel : 'http://127.0.0.1:$port$rel';

  // ── 配置 ─────────────────────────────────────────────────
  String apiId = '';
  String apiHash = '';
  String proxyHost = '';
  String proxyPort = '';
  String proxyUser = '';
  String proxyPass = '';

  Future<void> loadSettings() async {
    final p = await SharedPreferences.getInstance();
    apiId = p.getString(_kApiId) ?? '';
    apiHash = p.getString(_kApiHash) ?? '';
    proxyHost = p.getString(_kProxyHost) ?? '';
    proxyPort = p.getString(_kProxyPort) ?? '';
    proxyUser = p.getString(_kProxyUser) ?? '';
    proxyPass = p.getString(_kProxyPass) ?? '';
  }

  Future<void> saveSettings({
    required String apiId,
    required String apiHash,
    String proxyHost = '',
    String proxyPort = '',
    String proxyUser = '',
    String proxyPass = '',
  }) async {
    final p = await SharedPreferences.getInstance();
    this.apiId = apiId.trim();
    this.apiHash = apiHash.trim();
    this.proxyHost = proxyHost.trim();
    this.proxyPort = proxyPort.trim();
    this.proxyUser = proxyUser.trim();
    this.proxyPass = proxyPass.trim();
    await p.setString(_kApiId, this.apiId);
    await p.setString(_kApiHash, this.apiHash);
    await p.setString(_kProxyHost, this.proxyHost);
    await p.setString(_kProxyPort, this.proxyPort);
    await p.setString(_kProxyUser, this.proxyUser);
    await p.setString(_kProxyPass, this.proxyPass);
  }

  /// 把本地配置推给 Node（每次进入 TG 页都推一次，保证 Node 重启后也一致）
  Future<Map<String, dynamic>> pushConfig() async {
    if (!ready) return {'ok': false, 'error': '后台服务未就绪'};
    final dir = await getApplicationDocumentsDirectory();
    // session 落 Documents/tg/session.txt：
    //   · 不进 iCloud 备份（Documents 默认会备份，但这是本地会话，
    //     交给系统备份反而会把凭据同步出去，所以 Dart 侧刻意不放 Library）
    //   · 文件名固定，Node 负责原子写
    final sessionPath = '${dir.path}/tg/session.txt';
    return post('tgConfig', {
      'apiId': int.tryParse(apiId) ?? 0,
      'apiHash': apiHash,
      'sessionPath': sessionPath,
      if (proxyHost.isNotEmpty && proxyPort.isNotEmpty)
        'proxy': {
          'host': proxyHost,
          'port': int.tryParse(proxyPort) ?? 1080,
          if (proxyUser.isNotEmpty) 'username': proxyUser,
          if (proxyPass.isNotEmpty) 'password': proxyPass,
        }
      else
        'proxy': null,
    });
  }

  // ── 请求 ─────────────────────────────────────────────────
  Future<Map<String, dynamic>> post(
    String action, [
    Map<String, dynamic>? extra,
  ]) async {
    if (!ready) {
      return {'ok': false, 'error': '后台服务未就绪，请稍后重试'};
    }
    try {
      final res = await _dio.post(
        _base,
        data: {'action': action, ...?extra},
        options: Options(contentType: Headers.jsonContentType),
      );
      final d = res.data;
      if (d is Map) return d.cast<String, dynamic>();
      return {'ok': false, 'error': '返回格式异常'};
    } on DioException catch (e) {
      return {'ok': false, 'error': _short(e)};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  String _short(Object e) {
    if (e is DioException) {
      final t = e.type;
      if (t == DioExceptionType.receiveTimeout ||
          t == DioExceptionType.connectionTimeout) {
        return '连接超时：Telegram 可能需要代理';
      }
      return e.message ?? '$e';
    }
    return '$e';
  }

  // ── 业务 ─────────────────────────────────────────────────
  Future<Map<String, dynamic>> status() => post('tgStatus');
  Future<Map<String, dynamic>> ping() => post('tgPing');
  Future<Map<String, dynamic>> startQr() => post('tgQr');
  Future<Map<String, dynamic>> pollQr() => post('tgQrPoll');
  Future<Map<String, dynamic>> submitPassword(String pw) =>
      post('tgPassword', {'password': pw});
  Future<Map<String, dynamic>> logout() => post('tgLogout');
  Future<Map<String, dynamic>> dialogs() => post('tgDialogs', {'limit': 150});

  Future<Map<String, dynamic>> videos(String peer,
          {int offsetId = 0, int limit = 30}) =>
      post('tgVideos', {'peer': peer, 'offsetId': offsetId, 'limit': limit});

  /// 公开频道列表（不用登录，走 t.me/s 网页）
  Future<Map<String, dynamic>> publicList(String peer,
          {int offsetId = 0}) =>
      post('tgPublicList', {'peer': peer, 'offsetId': offsetId});

  // ── 收藏的频道（本地，跨启动保留）─────────────────────────
  static const _kChannels = 'tg.channels.v1';

  /// 形如 [{peer, title, mode}]，mode ∈ public / login
  Future<List<Map<String, dynamic>>> channels() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kChannels);
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveChannels(List<Map<String, dynamic>> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kChannels, jsonEncode(list));
  }

  /// 添加收藏（同 peer 视为更新标题/模式）
  Future<void> addChannel(String peer,
      {String title = '', String mode = 'public'}) async {
    final list = await channels();
    list.removeWhere((e) => e['peer'] == peer);
    list.insert(0, {
      'peer': peer,
      'title': title.isEmpty ? peer : title,
      'mode': mode,
    });
    await _saveChannels(list);
  }

  Future<void> removeChannel(String peer) async {
    final list = await channels();
    list.removeWhere((e) => e['peer'] == peer);
    await _saveChannels(list);
  }

  /// 二维码 data URL → 原始字节（给 Image.memory）
  static List<int>? decodeQr(String dataUrl) {
    final i = dataUrl.indexOf(',');
    if (i < 0) return null;
    try {
      return base64Decode(dataUrl.substring(i + 1));
    } catch (_) {
      return null;
    }
  }
}
