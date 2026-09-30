import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'nodejs_manager.dart';

/// 一首歌（几个音源协议的最小公约数）
class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String audioUrl;

  /// 封面（可空）
  final String coverUrl;

  /// 时长（秒，0 = 未知）
  final int duration;

  /// 音质标签（如 320k / flac，可空）
  final String quality;

  /// 音源代号（lx 脚本里返回的 source，如 kw / tx / wy / mg）
  final String source;

  /// LX 脚本需要回传的原始 musicInfo（取播放地址时要用它）
  final Map<String, dynamic> raw;

  const MusicTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.audioUrl = '',
    this.coverUrl = '',
    this.duration = 0,
    this.quality = '',
    this.source = '',
    this.raw = const {},
  });

  MusicTrack copyWith({String? audioUrl, String? quality}) => MusicTrack(
        id: id,
        title: title,
        artist: artist,
        album: album,
        audioUrl: audioUrl ?? this.audioUrl,
        coverUrl: coverUrl,
        duration: duration,
        quality: quality ?? this.quality,
        source: source,
        raw: raw,
      );

  /// 从 LX 脚本返回的 list 项解析（字段名按 LX 约定）
  static MusicTrack? fromLx(Map<String, dynamic> j) {
    String s(Object? v) => v == null ? '' : v.toString().trim();

    final title = s(j['name']).isEmpty ? s(j['title']) : s(j['name']);
    if (title.isEmpty) return null;

    // singer 可能是字符串或数组
    var artist = s(j['singer']);
    if (artist.isEmpty && j['singer'] is List) {
      artist = (j['singer'] as List).map((e) => e.toString()).join('、');
    }
    if (artist.isEmpty) artist = s(j['artist']);

    // interval 可能是 "03:45" 或秒数
    final iv = j['interval'];
    var dur = 0;
    if (iv is num) {
      dur = iv.toInt();
    } else if (iv is String && iv.isNotEmpty) {
      final parts = iv.split(':');
      if (parts.length == 2) {
        dur = (int.tryParse(parts[0]) ?? 0) * 60 +
            (int.tryParse(parts[1]) ?? 0);
      } else {
        dur = int.tryParse(iv) ?? 0;
      }
    }

    return MusicTrack(
      id: s(j['songmid']).isEmpty ? '$title|$artist' : s(j['songmid']),
      title: title,
      artist: artist,
      album: s(j['albumName']),
      coverUrl: s(j['img']).isEmpty ? s(j['picUrl']) : s(j['img']),
      duration: dur,
      source: s(j['source']),
      raw: Map<String, dynamic>.from(j),
    );
  }

  /// 从任意兼容 HTTP 协议的 JSON 里宽松解析（备用通道）
  static MusicTrack? fromJson(Map<String, dynamic> j) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) return s;
        }
      }
      return '';
    }

    final title = pick(['title', 'songName', 'name', 'song']);
    final url = pick(['audioUrl', 'url', 'src', 'playUrl', 'link']);
    if (title.isEmpty || url.isEmpty) return null;
    return MusicTrack(
      id: pick(['id', 'songId', 'songmid', 'hash', 'rid']),
      title: title,
      artist: pick(['artist', 'singer', 'author', 'artists']),
      album: pick(['album', 'albumName', 'album_name']),
      audioUrl: url,
      coverUrl: pick(['coverUrl', 'cover', 'pic', 'albumPic', 'img']),
      quality: pick(['quality', 'level', 'bitrate']),
      raw: Map<String, dynamic>.from(j),
    );
  }

  String get durationText {
    if (duration <= 0) return '--:--';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 给 UI 显示的副标题
  String get subtitle =>
      [artist, album].where((e) => e.isNotEmpty).join(' · ');
}

class MusicSearchResult {
  final List<MusicTrack> tracks;
  final String message;

  const MusicSearchResult(this.tracks, {this.message = ''});
}

/// 音乐音源服务
///
/// **两条通道，按优先级**：
///   1. 落雪(LX)自定义音源脚本 —— 在 Node 沙箱里执行（主通道）
///   2. 通用 HTTP 音源地址 —— 直接 Dio 请求（备用，兼容 Aurora 那类协议）
class MusicService extends GetxService {
  static MusicService get instance {
    if (!Get.isRegistered<MusicService>()) {
      Get.put<MusicService>(MusicService(), permanent: true);
    }
    return Get.find<MusicService>();
  }

  static const String _keyUrl = 'music_source_url';
  static const String _keyQuality = 'music_quality';
  static const String _keyHeaders = 'music_source_headers';
  static const String _keyLxScript = 'music_lx_script';
  static const String _keyLxName = 'music_lx_name';

  // ============================================================
  // 落雪(LX)音源
  // ============================================================

  /// 已导入的 LX 脚本源码（空 = 没导入）
  final lxScript = ''.obs;

  /// 音源显示名（脚本名或用户填的）
  final lxName = ''.obs;

  bool get hasLxScript => lxScript.value.trim().isNotEmpty;

  /// 音源是否可用（两条通道任一即可）
  bool get configured =>
      hasLxScript || sourceUrl.value.trim().isNotEmpty;

  /// 用于顶栏显示的当前音源名
  String get displaySourceName {
    if (hasLxScript) {
      final n = lxName.value.trim();
      return n.isEmpty ? '落雪音源' : n;
    }
    if (sourceUrl.value.trim().isNotEmpty) return 'HTTP 音源';
    return '未配置音源';
  }

  /// 长超时 Dio：LX 脚本要跑多轮网络请求，2 秒肯定不够
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 15),
  ));

  // ============================================================
  // 通用 HTTP 音源（备用通道）
  // ============================================================

  final sourceUrl = ''.obs;
  final quality = '320'.obs;
  final headersJson = ''.obs;

  /// 音乐平台代号（LX 协议里的 `source`）。
  ///
  /// ⚠️ 不是 'lx' —— 是**具体平台**：wy 网易 / tx QQ / kw 酷我 / kg 酷狗 / mg 咪咕。
  /// 脚本第一行就校验这个值，传错会直接抛「不支持的音乐源」。
  final platform = 'wy'.obs;

  Future<void> setPlatform(String v) async {
    platform.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString('music_platform', v);
  }

  /// 脚本声明的可用音源（`send(EVENT_NAMES.inited, {sources})` 回传）
  final lxSources = <String, dynamic>{}.obs;

  /// 脚本上报的提示（版本过低等）
  final lxAlerts = <dynamic>[].obs;

  // ============================================================
  // 运行时状态
  // ============================================================

  final isSearching = false.obs;
  final lastError = ''.obs;
  final results = <MusicTrack>[].obs;

  /// 正在取播放地址
  final isLoadingUrl = false.obs;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    sourceUrl.value = (p.getString(_keyUrl) ?? '').trim();
    quality.value = p.getString(_keyQuality) ?? '320';
    headersJson.value = (p.getString(_keyHeaders) ?? '').trim();
    lxScript.value = p.getString(_keyLxScript) ?? '';
    lxName.value = p.getString(_keyLxName) ?? '';
    platform.value = p.getString('music_platform') ?? 'wy';
  }

  Future<void> setSourceUrl(String v) async {
    sourceUrl.value = v.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyUrl, sourceUrl.value);
  }

  Future<void> setQuality(String v) async {
    quality.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyQuality, v);
  }

  Future<void> setHeaders(String v) async {
    headersJson.value = v.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyHeaders, headersJson.value);
  }

  // ============================================================
  // LX 脚本：导入 / 保存 / 删除
  // ============================================================

  /// 保存 LX 脚本。name 为空时从脚本里猜一个名字。
  Future<void> saveLxScript(String script, {String? name}) async {
    final src = script.trim();
    final p = await SharedPreferences.getInstance();
    if (src.isEmpty) {
      await clearLxScript();
      return;
    }
    lxScript.value = src;
    lxName.value = (name == null || name.trim().isEmpty)
        ? _guessName(src)
        : name.trim();
    await p.setString(_keyLxScript, lxScript.value);
    await p.setString(_keyLxName, lxName.value);
    AppLog.instance.log('[MusicService] LX 音源已保存: ${lxName.value}');
  }

  Future<void> clearLxScript() async {
    lxScript.value = '';
    lxName.value = '';
    results.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_keyLxScript);
    await p.remove(_keyLxName);
  }

  /// 从脚本内容里猜音源名（很多脚本头部有注释或 name 字段）
  static String _guessName(String src) {
    // 形如： * @name 六音  或  name: '六音'  或  // 六音音源
    final patterns = [
      RegExp(r'@name\s+(.+)'),
      RegExp(r'''name\s*[:=]\s*['"]([^'"]{2,30})['"]'''),
      RegExp(r'^//\s*(.{2,30})$', multiLine: true),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(src);
      if (m != null) {
        final v = m.group(1)!.trim();
        if (v.isNotEmpty && v.length <= 30) return v;
      }
    }
    return '落雪音源';
  }

  /// 从 URL 下载脚本（脚本通常就是一个 .js 直链）
  Future<({bool ok, String message})> importFromUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return (ok: false, message: '请填写地址');
    try {
      final res = await _dio.get<String>(
        u,
        options: Options(responseType: ResponseType.plain),
      );
      final body = res.data ?? '';
      if (body.trim().isEmpty) {
        return (ok: false, message: '下载内容为空');
      }
      // 极轻校验：必须能看到 lx.on 或 lx.request，避免把 HTML 当脚本存进来
      if (!body.contains('lx.') && !body.contains('module.exports')) {
        return (ok: false, message: '内容不像落雪音源脚本（未找到 lx.* 调用）');
      }
      await saveLxScript(body, name: _nameFromUrl(u));
      return (ok: true, message: '已导入：${lxName.value}');
    } on DioException catch (e) {
      return (ok: false, message: '下载失败：${_humanize(e)}');
    } catch (e) {
      return (ok: false, message: '下载失败：$e');
    }
  }

  static String _nameFromUrl(String url) {
    try {
      final seg = Uri.parse(url).pathSegments;
      if (seg.isNotEmpty) {
        final last = seg.last.replaceAll(RegExp(r'\.js$'), '');
        if (last.isNotEmpty) return last;
      }
    } catch (_) {}
    return '落雪音源';
  }

  /// 从本地文件导入（iOS 通过文件选择器拿到路径）
  Future<({bool ok, String message})> importFromFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return (ok: false, message: '文件不存在');
      }
      final body = await f.readAsString();
      if (body.trim().isEmpty) {
        return (ok: false, message: '文件内容为空');
      }
      if (!body.contains('lx.') && !body.contains('module.exports')) {
        return (ok: false, message: '内容不像落雪音源脚本（未找到 lx.* 调用）');
      }
      final base = path.split(Platform.pathSeparator).last;
      await saveLxScript(body,
          name: base.replaceAll(RegExp(r'\.js$'), ''));
      return (ok: true, message: '已导入：${lxName.value}');
    } catch (e) {
      return (ok: false, message: '读取失败：$e');
    }
  }

  // ============================================================
  // LX 执行桥（走 Node 沙箱）
  // ============================================================

  /// 调 Node 的 `/music/lx`。返回 {ok, data|error}
  Future<({bool ok, dynamic data, String error})> _callLx(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final mgr = NodeJSManager.instance;
    final port = mgr.managementPort;
    if (port <= 0) {
      return (ok: false, data: null, error: 'Node 服务未就绪（稍后重试）');
    }
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        'http://127.0.0.1:$port/music/lx',
        data: {
          'script': lxScript.value,
          'action': action,
          'payload': payload,
        },
        options: Options(
          contentType: 'application/json',
          // 脚本可能跑好几秒
          receiveTimeout: const Duration(seconds: 35),
        ),
      );
      final body = res.data ?? const {};
      final ok = body['ok'] == true;
      // 记录脚本声明的音源（哪些平台可用），供设置页展示
      final src = body['sources'];
      if (src is Map) {
        lxSources.assignAll(src.cast<String, dynamic>());
      }
      final al = body['alerts'];
      if (al is List && al.isNotEmpty) {
        lxAlerts.assignAll(al);
      }
      return (
        ok: ok,
        data: body['data'],
        error: (body['error'] ?? '').toString(),
      );
    } on DioException catch (e) {
      return (ok: false, data: null, error: _humanize(e));
    } catch (e) {
      return (ok: false, data: null, error: '$e');
    }
  }

  // ============================================================
  // 搜索
  // ============================================================

  /// 搜索：优先 LX 脚本，其次 HTTP 音源
  Future<MusicSearchResult> search(String keyword,
      {String type = 'song'}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const MusicSearchResult([], message: '请输入关键词');
    if (!configured) {
      return const MusicSearchResult([], message: '还没有导入音乐音源');
    }

    isSearching.value = true;
    lastError.value = '';
    try {
      if (hasLxScript) return await _searchViaLx(kw, type);
      return await _searchViaHttp(kw);
    } finally {
      isSearching.value = false;
    }
  }

  Future<MusicSearchResult> _searchViaLx(String kw, String type) async {
    final r = await _callLx('search', {
      'filter': kw,
      'type': type,
      'quality': quality.value,
    });
    if (!r.ok) {
      lastError.value = r.error;
      return MusicSearchResult(const [], message: r.error);
    }
    final list = _extractLxList(r.data);
    final tracks = <MusicTrack>[];
    for (final item in list) {
      if (item is Map) {
        final t = MusicTrack.fromLx(item.cast<String, dynamic>());
        if (t != null) tracks.add(t);
      }
    }
    results.assignAll(tracks);
    if (tracks.isEmpty) {
      return const MusicSearchResult([], message: '该音源没有返回结果');
    }
    return MusicSearchResult(tracks);
  }

  /// LX 搜索返回 { isEnd, total, list: [...] }
  List<dynamic> _extractLxList(dynamic data) {
    if (data is List) return data;
    if (data is Map) {
      final l = data['list'];
      if (l is List) return l;
    }
    return const [];
  }

  /// 备用通道：HTTP 音源地址
  Future<MusicSearchResult> _searchViaHttp(String kw) async {
    if (sourceUrl.value.trim().isEmpty) {
      return const MusicSearchResult([], message: '还没有配置音乐音源');
    }
    try {
      final res = await _dio.get(
        buildSearchUrl(kw),
        options: Options(
          headers: _headers,
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final list = _extractList(res.data);
      final tracks = <MusicTrack>[];
      for (final item in list) {
        if (item is Map) {
          final t = MusicTrack.fromJson(item.cast<String, dynamic>());
          if (t != null) tracks.add(t);
        }
      }
      results.assignAll(tracks);
      if (tracks.isEmpty) {
        return const MusicSearchResult([], message: '该音源没有返回结果');
      }
      return MusicSearchResult(tracks);
    } catch (e) {
      final msg = _humanize(e);
      lastError.value = msg;
      return MusicSearchResult(const [], message: msg);
    }
  }

  // ============================================================
  // 取播放地址
  // ============================================================

  /// 取某首歌的播放地址。
  ///
  /// LX 的 musicUrl 约定（**注意是 payload.source，不是顶层 source**）：
  ///   { source: 'wy'|'tx'|..., info: { type: 'song', musicInfo: {...} } }
  /// 脚本会校验 `info.musicInfo` 与 `info.type` 都存在，缺一个就报「参数不完整」。
  ///
  /// 返回可能是：字符串 / { url } / { source: 'xxx' }（需官方接口，不支持）
  Future<({String? url, String message})> resolveUrl(MusicTrack t,
      {String? quality}) async {
    if (t.audioUrl.isNotEmpty) return (url: t.audioUrl, message: '');
    if (!hasLxScript) {
      return (url: null, message: '该音源没有返回播放地址');
    }
    isLoadingUrl.value = true;
    try {
      final r = await _callLx('musicUrl', {
        // ⚠️ 平台代号必须传对，否则脚本抛「不支持的音乐源」
        'source': (t.source.isNotEmpty ? t.source : platform.value),
        'quality': quality ?? this.quality.value,
        'info': {
          'type': 'song',
          'musicInfo': t.raw.isEmpty
              ? {
                  'songmid': t.id,
                  'name': t.title,
                  'singer': t.artist,
                  'source': t.source.isEmpty ? platform.value : t.source,
                  'interval': t.duration.toString(),
                }
              : t.raw,
        },
      });
      if (!r.ok) return (url: null, message: r.error);

      final d = r.data;
      if (d is String && d.trim().isNotEmpty) {
        return (url: d.trim(), message: '');
      }
      if (d is Map) {
        final u = (d['url'] ?? '').toString().trim();
        if (u.isNotEmpty) return (url: u, message: '');
        if (d['source'] != null) {
          return (
            url: null,
            message: '该曲目需要「${d['source']}」官方接口取链，当前不支持',
          );
        }
      }
      return (url: null, message: '音源没有返回可用地址');
    } finally {
      isLoadingUrl.value = false;
    }
  }

  // ============================================================
  // 通用 HTTP 音源地址组装（备用通道）
  // ============================================================

  String buildSearchUrl(String query, {String? q}) {
    final base = sourceUrl.value.trim();
    final qq = q ?? quality.value;
    final enc = Uri.encodeQueryComponent(query);
    if (base.contains('{query}')) {
      return base
          .replaceAll('{query}', enc)
          .replaceAll('{quality}', qq)
          .replaceAll('{key}', _keyFromUrl());
    }
    final uri = Uri.tryParse(base);
    final path = uri?.path ?? '';
    final sep = base.contains('?') ? '&' : '?';
    if (path.isEmpty || path == '/' || path.endsWith('/aurora')) {
      final root = path.endsWith('/aurora')
          ? base
          : (base.endsWith('/') ? '${base}aurora' : '$base/aurora');
      final s = root.contains('?') ? '&' : '?';
      return '$root${s}query=$enc&quality=$qq';
    }
    return '$base${sep}query=$enc&quality=$qq';
  }

  String _keyFromUrl() {
    final u = Uri.tryParse(sourceUrl.value.trim());
    return u?.queryParameters['key'] ?? '';
  }

  Map<String, String> get _headers {
    final raw = headersJson.value.trim();
    if (raw.isEmpty) return const {};
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        return m.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e) {
      AppLog.instance.log('[MusicService] headers 解析失败: $e');
    }
    return const {};
  }

  List<dynamic> _extractList(dynamic data) {
    dynamic parsed = data;
    if (data is String) {
      var s = data.trim();
      if (s.isEmpty) return const [];
      if (!s.startsWith('[') && !s.startsWith('{')) {
        final a = s.indexOf('{');
        final b = s.lastIndexOf('}');
        if (a >= 0 && b > a) s = s.substring(a, b + 1);
      }
      try {
        parsed = jsonDecode(s);
      } catch (_) {
        return const [];
      }
    }
    if (parsed is List) return parsed;
    if (parsed is Map) {
      for (final k in const ['results', 'data', 'songs', 'list', 'items']) {
        final v = parsed[k];
        if (v is List) return v;
      }
    }
    return const [];
  }

  /// 测试：对 LX 脚本发一次固定关键词搜索
  Future<({bool ok, String message})> testConnection() async {
    if (!configured) return (ok: false, message: '请先导入音源');
    if (hasLxScript) {
      final r = await _callLx('search', {
        'filter': '告白气球',
        'type': 'song',
        'quality': quality.value,
      });
      if (!r.ok) return (ok: false, message: r.error);
      final n = _extractLxList(r.data).length;
      if (n == 0) return (ok: false, message: '脚本能跑，但搜索返回 0 条');
      // 再试一次取链，确认"能搜到也能播"
      final first = _extractLxList(r.data).first;
      if (first is Map) {
        final t = MusicTrack.fromLx(first.cast<String, dynamic>());
        if (t != null) {
          final u = await resolveUrl(t);
          if (u.url != null) {
            return (ok: true, message: '音源可用（搜索 $n 条，取链成功）');
          }
          return (ok: true, message: '搜索可用（$n 条），但取链失败：${u.message}');
        }
      }
      return (ok: true, message: '音源可用（搜索返回 $n 条）');
    }
    // HTTP 通道
    final r = await search('test');
    if (r.tracks.isNotEmpty) {
      return (ok: true, message: '音源可用（返回 ${r.tracks.length} 条）');
    }
    if (r.message.isNotEmpty && r.message != '该音源没有返回结果') {
      return (ok: false, message: r.message);
    }
    return (ok: true, message: '音源已连通（test 无结果，属正常）');
  }

  static String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('timeout')) return '连接超时，检查地址或网络';
    if (s.contains('SocketException')) return '网络不可达';
    if (s.contains('certificate')) return '证书错误（可试 https→http）';
    if (s.contains('404')) return '地址不存在（404）';
    if (s.contains('403')) return '被拒绝访问（403，可能需要 Referer/UA）';
    if (s.contains('401')) return '需要鉴权（401，检查 key）';
    if (s.contains('FormatException')) return '返回内容不是合法 JSON';
    return '请求失败：${s.length > 60 ? "${s.substring(0, 60)}…" : s}';
  }
}
