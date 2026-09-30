import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

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

  const MusicTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.audioUrl = '',
    this.coverUrl = '',
    this.duration = 0,
    this.quality = '',
  });

  /// 从任意兼容协议的 JSON 里宽松解析。
  ///
  /// 设计意图：各家音源字段名不统一（title/songName/name、
  /// artist/singer/author、audioUrl/url），这里做**别名兼容**，
  /// 尽量避免"换个源就解析不出来"。
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

    final durRaw = j['duration'] ?? j['interval'] ?? j['length'];
    var dur = 0;
    if (durRaw is num) {
      dur = durRaw.toInt();
    } else if (durRaw is String) {
      // "03:45" 或 "225"
      if (durRaw.contains(':')) {
        final parts = durRaw.split(':');
        if (parts.length == 2) {
          dur = (int.tryParse(parts[0]) ?? 0) * 60 +
              (int.tryParse(parts[1]) ?? 0);
        } else if (parts.length == 3) {
          dur = (int.tryParse(parts[0]) ?? 0) * 3600 +
              (int.tryParse(parts[1]) ?? 0) * 60 +
              (int.tryParse(parts[2]) ?? 0);
        }
      } else {
        dur = int.tryParse(durRaw) ?? 0;
      }
    }

    return MusicTrack(
      id: pick(['id', 'songId', 'songmid', 'hash', 'rid']).isEmpty
          ? '$title|${pick(['artist', 'singer', 'author'])}'
          : pick(['id', 'songId', 'songmid', 'hash', 'rid']),
      title: title,
      artist: pick(['artist', 'singer', 'author', 'artists']),
      album: pick(['album', 'albumName', 'album_name']),
      audioUrl: url,
      coverUrl: pick(['coverUrl', 'cover', 'pic', 'albumPic', 'img']),
      duration: dur,
      quality: pick(['quality', 'level', 'bitrate']),
    );
  }

  String get durationText {
    if (duration <= 0) return '--:--';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// 搜索结果
class MusicSearchResult {
  final List<MusicTrack> tracks;
  final String message;

  const MusicSearchResult(this.tracks, {this.message = ''});
}

/// 音乐音源服务（**通用 HTTP 协议**）
///
/// 目前只做骨架 + 地址配置 + 连通性测试，协议按"最小公约数"对接：
///
///   搜索：GET {地址}?query={关键词}&quality={音质}&key={密钥}
///         或  GET {地址}/aurora?query=...（Aurora 约定）
///         或  地址里含 {query} 占位符 → 原样替换
///
/// 响应兼容数组 或 {results}/{data}/{songs}/{list} 包裹，
/// 每项按 [MusicTrack.fromJson] 的别名规则解析。
///
/// 这样任何**兼容 Aurora 协议**的服务、或简单自建接口都能接上，
/// 不必改动 App 代码。
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

  /// 音源地址（可含 ?key=xxx，也可含 {query} 占位符）
  final sourceUrl = ''.obs;

  /// 期望音质：128 / 320 / flac
  final quality = '320'.obs;

  /// 自定义请求头（JSON 字符串，用于 Referer / UA / 鉴权）
  final headersJson = ''.obs;

  /// 正在搜索
  final isSearching = false.obs;

  /// 最近一次错误（给 UI 提示用）
  final lastError = ''.obs;

  /// 搜索结果
  final results = <MusicTrack>[].obs;

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
  }

  bool get configured => sourceUrl.value.trim().isNotEmpty;

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

  /// 把配置的地址组装成实际请求 URL。
  ///
  /// 三种形态（按优先级）：
  ///   1. 含 `{query}` → 模板替换（适配第三方接口）
  ///   2. 以 `/aurora` 结尾或路径为空 → Aurora 约定，补 `/aurora?query=...`
  ///   3. 其它 → 直接把 query 作为查询参数拼上去
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

  /// 从地址里取 key 参数（部分音源要求回传）
  String _keyFromUrl() {
    final u = Uri.tryParse(sourceUrl.value.trim());
    return u?.queryParameters['key'] ?? '';
  }

  /// 搜索。任何异常都转成中文提示，不抛给 UI。
  Future<MusicSearchResult> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const MusicSearchResult([], message: '请输入关键词');
    if (!configured) {
      return const MusicSearchResult([], message: '还没有配置音乐音源');
    }
    isSearching.value = true;
    lastError.value = '';
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 18),
      ));
      final res = await dio.get(buildSearchUrl(kw), options: Options(
        headers: _headers,
        responseType: ResponseType.plain,
      ));
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
      AppLog.instance.log('[MusicService] 搜索失败: $e');
      return MusicSearchResult(const [], message: msg);
    } finally {
      isSearching.value = false;
    }
  }

  /// 从任意响应文本里挖出歌曲数组。
  ///
  /// 如果整段不是 JSON（例如音源返回 JSONP），会做一次宽松裁剪。
  List<dynamic> _extractList(dynamic data) {
    dynamic parsed = data;
    if (data is String) {
      var s = data.trim();
      if (s.isEmpty) return const [];
      if (!s.startsWith('[') && !s.startsWith('{')) {
        // JSONP / 前后有杂质：取第一个 { 到最后一个 }
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

  /// 测试连通性：发一次固定关键词搜索，返回可读结论。
  Future<({bool ok, String message})> testConnection() async {
    if (!configured) return (ok: false, message: '请先填写音源地址');
    final r = await search('test');
    if (r.tracks.isNotEmpty) {
      return (ok: true, message: '音源可用（返回 ${r.tracks.length} 条）');
    }
    if (r.message.isNotEmpty && r.message != '该音源没有返回结果') {
      return (ok: false, message: r.message);
    }
    // 能连通但 "test" 搜不到，也算可用
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
