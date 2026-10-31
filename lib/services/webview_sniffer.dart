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

  int get count => _map.length;

  List<String> get logs => List.unmodifiable(_log);

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
    if (_map.containsKey(u)) return false;
    final isMedia = MediaSniffer.isMediaUrl(u);
    final c = SniffCandidate(
      url: u,
      kind: kind,
      via: via,
      isMedia: isMedia,
      score: isMedia ? MediaSniffer.score(u) : 0,
    );
    _map[u] = c;
    _log.insert(0, '[${via.isEmpty ? "?" : via}] ${kind.isEmpty ? "?" : kind}  $u');
    if (_log.length > 150) _log.removeLast();
    return true;
  }

  void clear() {
    _map.clear();
    _log.clear();
  }
}

/// 桌面版 Chrome 的移动 UA —— 解析站常按 UA 决定给不给地址，
/// 用真实浏览器 UA 比 Dart 默认 UA 命中率高。
const String kChromeMobileUA =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
