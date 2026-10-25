import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TG 频道列表的**标题筛选**（用户 2026-10-25：「我先不写死，加个筛选功能」）。
///
/// 为什么放到 App 侧：
///   · 之前把「广告词 / 必须带《》」写死在 Node 里，用户想放宽或收紧都得改代码；
///   · 现在 Node 只负责把标题取出来，**要不要显示**由这里的规则决定。
///
/// 规则：
///   · [blockEmoji]（内置默认开）→ 名称里带 emoji 的直接隐藏；
///   · [words]（用户自己填）→ 名称包含任意一个词就隐藏，大小写不敏感；
///   · 两套规则对**公开频道和登录频道都生效**。
class TgTitleFilter extends ChangeNotifier {
  TgTitleFilter._();

  static final TgTitleFilter instance = TgTitleFilter._();

  static const _kEmoji = 'tg.filter.emoji';
  static const _kWords = 'tg.filter.words';

  /// 内置规则：去掉名称里带表情符号的（默认开）
  bool blockEmoji = true;

  /// 用户自定义的排除词
  List<String> words = const [];

  bool _loaded = false;

  bool get loaded => _loaded;

  /// emoji / 符号区（含变体选择符 ZWJ，覆盖常见的表情标题）
  static final RegExp _emojiRe = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2190}-\u{21FF}\u{2300}-\u{23FF}'
    r'\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      blockEmoji = p.getBool(_kEmoji) ?? true;
      words = p.getStringList(_kWords) ?? const [];
    } catch (_) {
      // 读不到就用默认规则，不影响列表
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setBlockEmoji(bool v) async {
    blockEmoji = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEmoji, v);
  }

  Future<void> addWord(String w) async {
    final s = w.trim();
    if (s.isEmpty) return;
    if (words.any((e) => e.toLowerCase() == s.toLowerCase())) return;
    words = [...words, s];
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kWords, words);
  }

  Future<void> removeWord(String w) async {
    words = words.where((e) => e != w).toList();
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kWords, words);
  }

  /// 这条要不要隐藏
  bool shouldHide(String? title) {
    final t = (title ?? '').trim();
    if (t.isEmpty) return false;
    if (blockEmoji && _emojiRe.hasMatch(t)) return true;
    final low = t.toLowerCase();
    for (final w in words) {
      final k = w.trim().toLowerCase();
      if (k.isNotEmpty && low.contains(k)) return true;
    }
    return false;
  }
}
