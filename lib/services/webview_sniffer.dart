import 'package:tvbox/services/media_sniffer.dart';

/// 嗅探到的一条候选地址。
class SniffCandidate {
  final String url;

  /// 分类：m3u8 / mpd / mp4 / seg / ''（未定）
  final String kind;

  /// 来源：xhr / fetch / dom / perf
  final String via;

  /// 是否被 [MediaSniffer] 认定为媒体直链（带已知扩展名）
  final bool isMedia;

  /// 打分（越高越可能是首选，m3u8 优先）
  final int score;

  const SniffCandidate({
    required this.url,
    required this.kind,
    required this.via,
    required this.isMedia,
    required this.score,
  });
}

/// 嗅探结果收集器：去重、分类、打分、排序。
///
/// Phase 1 由「嗅探探针页」使用；Phase 2 可直接复用于播放链路兜底。
class SnifferCollector {
  final Map<String, SniffCandidate> _map = {};
  final List<String> _log = [];

  /// 嗅到的 iframe 地址（按发现顺序、去重）。
  ///
  /// 解析站几乎都是「壳 + iframe 嵌播放器」，主 frame 读不到 iframe 内部的
  /// 变量（跨域），但**读得到 iframe 的 src**。把这些地址回传上来，就能把
  /// 那一层当**顶层页**重新加载一次 —— 于是不需要"注入所有 frame"
  /// （那个能力 `webview_flutter` 没暴露，只能改原生）。
  final List<String> _frames = [];

  int get count => _map.length;

  List<String> get frames => List.unmodifiable(_frames);

  List<String> get logs => List.unmodifiable(_log);

  /// 下一层该跟的 iframe。
  ///
  /// 优先挑带 `url=` 的：解析链每一层都会把**原始播放地址**当参数带着走
  /// （`ckplayer.vip/jiexi/?url=...`），而广告落地页（`xxx.top/?shareName=`）
  /// 不带 —— 这个优先级能避开广告页。
  String? nextFrame(Set<String> visited) {
    for (final f in _frames) {
      if (visited.contains(f)) continue;
      if (f.contains('url=')) return f;
    }
    for (final f in _frames) {
      if (visited.contains(f)) continue;
      return f;
    }
    return null;
  }

  /// 按分数从高到低排序的候选
  List<SniffCandidate> get sorted {
    final list = _map.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return list;
  }

  /// 首选：优先返回被认定为媒体的第一条，否则返回分数最高的一条。
  SniffCandidate? get best {
    for (final c in sorted) {
      if (c.isMedia) return c;
    }
    return sorted.isEmpty ? null : sorted.first;
  }

  /// 加入一条候选；有新增返回 true。
  bool add(String url, {String kind = '', String via = ''}) {
    final u = url.trim();
    if (u.isEmpty) return false;
    // iframe 地址单独存：它不是播放候选，是"下一层要跟的地址"
    if (via == 'frame' || kind == 'frame') {
      if (_frames.contains(u)) return false;
      _frames.add(u);
      _log.insert(0, '[frame]  $u');
      if (_log.length > 150) _log.removeLast();
      return true;
    }
    if (_map.containsKey(u)) return false;
    // 播放器页 URL 里塞着真地址（`artplayer.html?url=<编码后的 m3u8>`）时，
    // 存真地址而不是那个 HTML 页 —— 否则首选会是个页面，播放必挂。
    final real = MediaSniffer.unwrapEmbeddedUrl(u);
    if (_map.containsKey(real)) return false;
    final isMedia = MediaSniffer.isMediaUrl(real);
    final c = SniffCandidate(
      url: real,
      kind: kind,
      via: via,
      isMedia: isMedia,
      score: isMedia ? MediaSniffer.score(real) : 0,
    );
    _map[real] = c;
    _log.insert(0, '[${via.isEmpty ? "?" : via}] ${kind.isEmpty ? "?" : kind}  $real');
    if (_log.length > 150) _log.removeLast();
    return true;
  }

  void clear() {
    _map.clear();
    _frames.clear();
    _log.clear();
  }
}

/// 桌面版 Chrome 的移动 UA —— 解析站常按 UA 决定给不给地址，
/// 用真实浏览器 UA 比 Dart 默认 UA 命中率高。
const String kChromeMobileUA =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
