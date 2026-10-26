// lib/music/services/mf_quickjs_engine.dart
//
// MusicFree 插件的 **QuickJS 实验引擎**（2026-10-21）。
//
// ── 为什么要有它 ──────────────────────────────────────────────
// 插件目前全部跑在 Node（nodejs-mobile）里。QuickJS 是仓库里已有的内嵌
// 引擎（书源 / Venera 在用），启动与调用都更轻。这里把「只用 axios / he」
// 的插件放到 QuickJS 里跑，跑不了（需要 cheerio / crypto-js 等）就**返回
// null**，由调用方回退 Node —— 两条路并存，不会因为换引擎把插件跑挂。
//
// ── 支持范围 ──────────────────────────────────────────────────
//   · search（type=music）
//   · getMediaSource / getMusicUrl / getMusicInfo
//   · getLyric / getLyricNew
//   · userVariables 声明读取
// 榜单 / 歌单 / 歌手 / 专辑详情仍走 Node（那几条链路在 Node 侧已经很稳）。
//
// ⚠️ 单例内部按「脚本 hash + 变量 hash」缓存运行时（最多 2 个）：
//    QuickJS 的全局上下文不便宜，不能每次调用都新建。

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/quickjs/mf_js_prelude.dart';

class MfQuickJsEngine {
  MfQuickJsEngine._();
  static final MfQuickJsEngine instance = MfQuickJsEngine._();

  static const int _cacheLimit = 4;
  static const Duration _callTimeout = Duration(seconds: 25);

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    followRedirects: true,
  ));

  final List<_MfInstance> _cache = [];

  /// 已知「加载就失败（缺少模块）」的脚本 hash —— 不再反复尝试
  final Set<String> _unsupported = {};

  // ============================================================
  // 对外：三个高频动作
  // ============================================================

  /// 搜索（只支持歌曲；歌手/专辑返回 null → 交给 Node）
  Future<List<Map<String, dynamic>>?> search(
    ThirdPartySource src,
    String keyword,
    int page,
  ) async {
    final raw = await _call(src, 'search', [keyword, page, 'music']);
    if (raw == null) return null;
    return _normalizeSongs(raw);
  }

  /// 取播放地址
  Future<({String url, Map<String, String> headers})?> resolveMedia(
    ThirdPartySource src,
    Song song,
    String quality,
  ) async {
    final item = _songItem(song);
    final raw = await _call(src, 'media', [item, quality]);
    if (raw == null) return null;
    return _normalizeMedia(raw);
  }

  /// 歌词
  Future<({String lyric, String tlyric})?> lyric(
    ThirdPartySource src,
    Song song,
  ) async {
    final raw = await _call(src, 'lyric', [_songItem(song)]);
    if (raw == null) return null;
    if (raw is String) return (lyric: raw, tlyric: '');
    if (raw is Map) {
      final l = (raw['lyric'] ?? raw['rawLrc'] ?? raw['lrc'] ?? '').toString();
      final t = (raw['tlyric'] ?? raw['translation'] ?? '').toString();
      if (l.trim().isEmpty && t.trim().isEmpty) return null;
      return (lyric: l, tlyric: t);
    }
    return null;
  }

  /// 插件的 userVariables 声明
  Future<List<({String key, String name, String hint})>?> variables(
    ThirdPartySource src,
  ) async {
    final inst = await _ensure(src);
    if (inst == null) return null;
    final raw = inst.runtime.evaluate('__mfVariables()').stringResult;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <({String key, String name, String hint})>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final key = (e['key'] ?? '').toString().trim();
        if (key.isEmpty) continue;
        out.add((
          key: key,
          name: (e['name'] ?? key).toString(),
          hint: (e['hint'] ?? '').toString(),
        ));
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 释放全部运行时（测试 / 内存紧张时用）
  void disposeAll() {
    for (final i in _cache) {
      i.runtime.dispose();
    }
    _cache.clear();
    _unsupported.clear();
  }

  // ============================================================
  // 运行时管理
  // ============================================================

  Future<_MfInstance?> _ensure(ThirdPartySource src) async {
    final script = (src.script ?? '');
    if (script.trim().isEmpty) return null;
    final key = '${_hash(script)}-${_hash(jsonEncode(src.variables))}';
    if (_unsupported.contains(key)) return null;

    // ── 先做一次**静态预检**（2026-10-21）────────────────────────
    // 脚本里 require 了 cheerio / crypto-js 等模块 ⇒ QuickJS 一定跑不了。
    // 提前判掉，避免为每个这样的插件都建一次运行时（试源时白花几十毫秒）。
    if (_needsHeavyModules(script)) {
      _unsupported.add(key);
      return null;
    }

    for (var i = 0; i < _cache.length; i++) {
      if (_cache[i].key == key) {
        final hit = _cache.removeAt(i);
        _cache.add(hit);
        return hit;
      }
    }

    final runtime = getJavascriptRuntime(
      // 不启用 fetch 扩展：我们走 sendMessage('mf_http')，避免依赖 JS 资源
      xhr: false,
      extraArgs: const {
        'timeout': 30000,
        'memoryLimit': 96 * 1024 * 1024,
      },
    );
    runtime.onMessage('mf_http', _hostHttp);

    final pre = runtime.evaluate(mfJsPrelude);
    if (pre.isError) {
      runtime.dispose();
      _unsupported.add(key);
      return null;
    }

    final loaded = runtime.evaluate(
      '__mfLoad(${jsonEncode(script)}, ${jsonEncode(jsonEncode(src.variables))})',
    );
    if (loaded.isError) {
      // 缺模块 / 语法不兼容 → 记下来，之后直接走 Node
      _unsupported.add(key);
      runtime.dispose();
      return null;
    }

    final inst = _MfInstance(key: key, runtime: runtime);
    _cache.add(inst);
    while (_cache.length > _cacheLimit) {
      _cache.removeAt(0).runtime.dispose();
    }
    return inst;
  }

  Future<dynamic> _call(
    ThirdPartySource src,
    String kind,
    List<dynamic> args,
  ) async {
    final inst = await _ensure(src);
    if (inst == null) return null;
    return inst.serial(() async {
      final started = inst.runtime.evaluate(
        '__mfRun(${jsonEncode(kind)}, ${jsonEncode(jsonEncode(args))})',
      );
      if (started.isError || started.stringResult != 'OK') return null;

      final sw = Stopwatch()..start();
      while (true) {
        inst.runtime.executePendingJob();
        final state = inst.runtime.evaluate('__mfState').stringResult;
        if (state == 'ok') {
          final raw =
              inst.runtime.evaluate('__mfStringify(__mfValue)').stringResult;
          if (raw.isEmpty || raw == 'undefined') return null;
          try {
            return jsonDecode(raw);
          } catch (_) {
            return null;
          }
        }
        if (state == 'err') return null;
        if (sw.elapsed > _callTimeout) return null;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  // ============================================================
  // 宿主能力
  // ============================================================

  Future<Map<String, dynamic>> _hostHttp(dynamic raw) async {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final url = (m['url'] ?? '').toString();
    if (url.isEmpty) throw StateError('empty url');

    final headers = <String, String>{};
    if (m['headers'] is Map) {
      (m['headers'] as Map).forEach((k, v) => headers[k.toString()] = v.toString());
    }
    final method = (m['method'] ?? 'GET').toString().toUpperCase();
    final body = (m['data'] ?? '').toString();
    final isBytes = (m['responseType'] ?? 'text').toString() == 'arraybuffer';
    final timeoutMs =
        (m['timeoutMs'] is num) ? (m['timeoutMs'] as num).toInt() : 15000;

    final resp = await _dio.request<dynamic>(
      url,
      data: body.isEmpty ? null : body,
      options: Options(
        method: method,
        headers: headers,
        responseType: isBytes ? ResponseType.bytes : ResponseType.plain,
        receiveTimeout: Duration(milliseconds: timeoutMs),
        validateStatus: (_) => true,
      ),
    );

    final data = resp.data;
    final bytes = data is List<int> ? data : null;
    return {
      'status': resp.statusCode ?? 0,
      'headers': {
        for (final e in resp.headers.map.entries) e.key: e.value.join(','),
      },
      'bodyText': bytes == null ? (resp.data?.toString() ?? '') : '',
      'bodyBase64': bytes == null ? '' : base64Encode(bytes),
      'responseType': isBytes ? 'arraybuffer' : 'text',
    };
  }

  // ============================================================
  // 归一化（输出与 Node 侧同形，Dart 直接 Song.fromJson）
  // ============================================================

  Map<String, dynamic> _songItem(Song song) => {
        'id': song.songmid.isNotEmpty ? song.songmid : '${song.id}',
        'songmid': song.songmid,
        'title': song.name,
        'name': song.name,
        'artist': song.artists,
        'artists': song.artists,
        'album': song.album,
        'artwork': song.coverUrl ?? '',
        'duration': song.duration,
        if (song.srcMap.isNotEmpty) '_src': song.srcMap,
      };

  List<Map<String, dynamic>> _normalizeSongs(dynamic raw) {
    if (raw == null) return const [];
    List? arr;
    if (raw is List) {
      arr = raw;
    } else if (raw is Map) {
      if (raw['data'] is List) {
        arr = raw['data'] as List;
      } else if (raw['data'] is Map && (raw['data'] as Map)['list'] is List) {
        arr = (raw['data'] as Map)['list'] as List;
      } else if (raw['list'] is List) {
        arr = raw['list'] as List;
      }
    }
    if (arr == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in arr) {
      if (e is! Map) continue;
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      out.add({
        'id': id,
        'songmid': (e['songmid'] ?? e['mid'] ?? id).toString(),
        'name': (e['title'] ?? e['name'] ?? e['songName'] ?? '').toString(),
        'artist': (e['artist'] ?? e['artists'] ?? e['singer'] ?? '').toString(),
        'artists': (e['artist'] ?? e['artists'] ?? e['singer'] ?? '').toString(),
        'album': (e['album'] ?? e['albumName'] ?? '').toString(),
        'cover': (e['artwork'] ?? e['coverUrl'] ?? e['cover'] ?? e['picUrl'] ?? '')
            .toString(),
        'duration': (e['duration'] is num) ? (e['duration'] as num).toDouble() : 0,
        if (e['_src'] is Map) '_src': Map<String, dynamic>.from(e['_src'] as Map),
      });
    }
    return out;
  }

  ({String url, Map<String, String> headers})? _normalizeMedia(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      final s = raw.trim();
      if (s.startsWith('http')) return (url: s, headers: const {});
      return null;
    }
    if (raw is List) {
      for (final e in raw) {
        final r = _normalizeMedia(e);
        if (r != null) return r;
      }
      return null;
    }
    if (raw is Map) {
      final headers = <String, String>{};
      if (raw['headers'] is Map) {
        (raw['headers'] as Map).forEach((k, v) {
          if (v != null) headers[k.toString()] = v.toString();
        });
      }
      for (final k in const ['url', 'musicUrl', 'src', 'play_url', 'playUrl']) {
        final v = raw[k];
        if (v is String && v.trim().startsWith('http')) {
          return (url: v.trim(), headers: headers);
        }
      }
      if (raw['data'] != null) {
        final inner = _normalizeMedia(raw['data']);
        if (inner != null) {
          return (
            url: inner.url,
            headers: headers.isEmpty ? inner.headers : headers,
          );
        }
      }
    }
    return null;
  }

  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }

  /// 脚本是否 require 了 QuickJS 垫片没实现的模块（cheerio / crypto-js …）
  static bool _needsHeavyModules(String script) {
    final re = RegExp(r'''require\s*\(\s*['"]([^'"]+)['"]\s*\)''');
    for (final m in re.allMatches(script)) {
      final name = m.group(1) ?? '';
      if (name != 'axios' && name != 'he') return true;
    }
    return false;
  }
}

class _MfInstance {
  _MfInstance({required this.key, required this.runtime});

  final String key;
  final JavascriptRuntime runtime;
  Future<void> _tail = Future<void>.value();

  /// QuickJS 的运行时是**单线程**的：并发调用必须排队，否则 job/promise
  /// 状态会串（上一次的 `__mfValue` 被下一次读走）。
  Future<T> serial<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
