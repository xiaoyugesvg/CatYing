import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nodejs_manager.dart';
import 'remote_engine.dart';

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

  /// 代理总开关（默认关：**填了地址不等于启用**，用户 2026-10-25 要求）
  static const _kProxyOn = 'tg.proxy.on';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 45),
  ));

  /// 内置 Node 的管理端口（0 = 还没起来）
  int get port => NodeJSManager.instance.managementPort;

  /// 远程引擎基址（总开关 + TG 分开关都开才有值，否则 null = 走本机）
  String? get _remote => RemoteEngine.instance.baseFor(RemoteKind.tg);

  bool get ready => _remote != null || port > 0;

  String get _base =>
      _remote != null ? '$_remote/tg' : 'http://127.0.0.1:$port/tg';

  /// 相对地址 → 可给播放器/图片组件用的绝对地址
  ///
  /// 走远程时缩略图/流也指向服务器（同一份契约）；否则回落到本机回环。
  /// 远程还要补 `?token=` —— 播放器和 Image.network 不会带 `X-Token` 头。
  String absolute(String rel) {
    if (rel.startsWith('http')) return rel;
    final r = _remote;
    if (r != null) return RemoteEngine.instance.withToken('$r$rel');
    return 'http://127.0.0.1:$port$rel';
  }

  // ── 配置 ─────────────────────────────────────────────────
  /// 内置应用凭据（Telegram Desktop 公开的一组 api_id / api_hash）。
  ///
  /// 用户 2026-10-25：「不是扫码登录吗？为啥还要这个？」——
  /// gramjs 的二维码登录必须先有应用身份，但**没必要让用户去
  /// my.telegram.org 自己申请**。这里预置一组，开箱即可扫码；
  /// 高级设置里仍可覆盖成自己的。
  static const defaultApiId = '2040';
  static const defaultApiHash = 'b18441a1ff607e10a989891a5462e627';

  String apiId = defaultApiId;
  String apiHash = defaultApiHash;
  String proxyHost = '';
  String proxyPort = '';
  String proxyUser = '';
  String proxyPass = '';

  /// 代理总开关：关着时**一律直连**（哪怕上面填了地址）
  bool proxyOn = false;

  /// 代理是否真的可用（开关开 + 地址端口都填了）
  bool get proxyActive =>
      proxyOn && proxyHost.trim().isNotEmpty && proxyPort.trim().isNotEmpty;

  Future<void> loadSettings() async {
    final p = await SharedPreferences.getInstance();
    // 没存过 / 存的是空串 ⇒ 用内置凭据（老用户升级后也不用再填）
    final id = (p.getString(_kApiId) ?? '').trim();
    final hash = (p.getString(_kApiHash) ?? '').trim();
    apiId = id.isEmpty ? defaultApiId : id;
    apiHash = hash.isEmpty ? defaultApiHash : hash;
    proxyHost = p.getString(_kProxyHost) ?? '';
    proxyPort = p.getString(_kProxyPort) ?? '';
    proxyUser = p.getString(_kProxyUser) ?? '';
    proxyPass = p.getString(_kProxyPass) ?? '';
    proxyOn = p.getBool(_kProxyOn) ?? false;
  }

  /// 「内置代理池」开关：打开才启用上方填的节点（默认关）
  Future<void> setProxyOn(bool v) async {
    proxyOn = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kProxyOn, v);
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
    // 留空 = 用内置凭据（不写空串，免得下次又变成"没配置"）
    this.apiId = apiId.trim().isEmpty ? defaultApiId : apiId.trim();
    this.apiHash = apiHash.trim().isEmpty ? defaultApiHash : apiHash.trim();
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
    // ⚠️ 走远程时**不能**把手机上的这个路径发过去：服务器上没有
    //    `/var/mobile/.../Documents/tg`，旧实现会让 Node 按这个鬼路径建目录，
    //    非 root 直接写失败 ⇒ 登录态存不下来，每次重启都得重新扫码。
    //    不传时 Node 用自己工作目录下的默认路径。
    final remote = _remote != null;
    return post('tgConfig', {
      'apiId': int.tryParse(apiId) ?? 0,
      'apiHash': apiHash,
      if (!remote) 'sessionPath': sessionPath,
      // 开关关着 ⇒ 明确发 null，让 Node 直连（不能"填了地址就偷偷走代理"）
      if (proxyActive)
        'proxy': {
          'host': proxyHost.trim(),
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
    Duration? timeout,
  ]) async {
    if (!ready) {
      return {'ok': false, 'error': '后台服务未就绪，请稍后重试'};
    }
    try {
      final res = await _dio.post(
        _base,
        data: {'action': action, ...?extra},
        options: Options(
          contentType: Headers.jsonContentType,
          receiveTimeout: timeout,
          headers: _remote != null ? RemoteEngine.instance.headers : null,
        ),
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

  /// 内置免费代理池：Node 侧拉列表 + 并发测速，返回按延迟排序的可用项。
  /// 可能要 15~30 秒（30 个代理 × 10 秒超时，8 并发），UI 要给进度。
  Future<Map<String, dynamic>> probeProxies() => post(
        'tgProxyProbe',
        {'timeoutMs': 10000},
        const Duration(seconds: 90),
      );

  /// t.me 连通性自测：按**当前**设置（内置代理开关 + 手机系统 VPN）打一次
  /// `t.me/s/cctv1`，返回 {ok, ms, status, bytes, proxy, error}。
  /// 代理测试只能证明"那个节点通"，这个才是"能不能看公开频道"的直接答案。
  Future<Map<String, dynamic>> netTest() => post(
        'tgNetTest',
        {},
        const Duration(seconds: 30),
      );

  Future<Map<String, dynamic>> videos(String peer,
          {int offsetId = 0, int limit = 30}) =>
      post('tgVideos', {'peer': peer, 'offsetId': offsetId, 'limit': limit});

  /// 公开频道列表（不用登录，走 t.me/s 网页）
  Future<Map<String, dynamic>> publicList(String peer,
          {int offsetId = 0}) =>
      post('tgPublicList', {'peer': peer, 'offsetId': offsetId});

  // ── 收藏的频道（本地，跨启动保留）─────────────────────────
  static const _kChannels = 'tg.channels.v1';
  // v2：内置频道从 @telegram 换成 @cctv1（用户 2026-10-25 指定）
  static const _kSeeded = 'tg.seeded.v2';

  /// 首次开启 TG 时内置的公开频道
  ///
  /// 用户指定：`https://t.me/cctv1/53257` ⇒ 频道名是 **cctv1**。
  /// 实测（2026-10-25）：`t.me/s/cctv1` 一页有 19 个视频帖，
  /// `t.me/cctv1/53257?embed=1` 能解析出 `cdn5.telesco.pe/...mp4` 直链，
  /// 不用登录就能播。
  static const List<Map<String, String>> builtinChannels = [
    {'peer': 'cctv1', 'title': 'CCTV1（内置）', 'mode': 'public'},
  ];

  /// 首次运行塞入内置频道。已塞过或用户已有频道时什么都不做。
  ///
  /// 换内置频道时记得**同时升 [_kSeeded]**，否则老用户不会再触发一次；
  /// 这里会顺手把上一版的内置项（标题带「（内置）」）删掉，避免留两个。
  Future<void> seedDefaults() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_kSeeded) == true) return;
    final list = await channels();
    final wanted = builtinChannels.map((e) => e['peer']).toSet();
    list.removeWhere((e) =>
        (e['title'] ?? '').toString().contains('（内置）') &&
        !wanted.contains(e['peer']));
    for (final c in builtinChannels.reversed) {
      if (list.any((e) => e['peer'] == c['peer'])) continue;
      list.insert(0, {...c});
    }
    await _saveChannels(list);
    await p.setBool(_kSeeded, true);
  }

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
