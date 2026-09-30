# -*- coding: utf-8 -*-
"""Search debounce+cache, recommend title-first, font scale, cache clear note."""
from pathlib import Path

root = Path(r"C:\Users\24647\AppData\Local\Temp\New-Tv")

# ===== search debounce + cache =====
p = root / "lib/pages/search/controller.dart"
s = p.read_text(encoding="utf-8")
if "Timer" not in s:
    s = s.replace(
        "import 'package:get/get.dart';",
        "import 'dart:async';\nimport 'package:get/get.dart';",
        1,
    )

# find search method
import re
if "void onKeywordChanged" not in s and "debounce" not in s:
    # append at end of class before last }
    # insert after searchKeyword or similar field
    if "final keyword" in s or "searchKeyword" in s or "textController" in s:
        pass
    s = s.replace(
        "class TvSearchController extends GetxController {",
        """class TvSearchController extends GetxController {
  Timer? _debounce;
  final Map<String, List<Video>> _searchCache = {};

  /// 输入防抖 400ms，避免逐字发请求
  void onKeywordChanged(String kw, Future<void> Function(String) run) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (kw.trim().isEmpty) return;
      run(kw.trim());
    });
  }

  List<Video>? cachedSearch(String kw) => _searchCache[kw.trim()];

  void rememberSearch(String kw, List<Video> list) {
    final k = kw.trim();
    if (k.isEmpty) return;
    if (_searchCache.length > 50) _searchCache.clear();
    _searchCache[k] = list;
  }
""",
        1,
    )
    p.write_text(s, encoding="utf-8")
    print("search controller debounce/cache ok")

# ===== recommend: title first =====
p = root / "lib/pages/detail/controller.dart"
s = p.read_text(encoding="utf-8")
old_kw = """      final keywords = <String>[
        if (info.typeName.isNotEmpty) info.typeName,
        info.name,
        if (info.actor.isNotEmpty)
          ...info.actor.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).take(1),
      ];"""
new_kw = """      // 片名命中率最高，优先；类型/演员仅在片名无结果时兜底
      final keywords = <String>[
        info.name,
        if (info.typeName.isNotEmpty) info.typeName,
        if (info.actor.isNotEmpty)
          ...info.actor.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).take(1),
      ];"""
if old_kw in s:
    s = s.replace(old_kw, new_kw, 1)
    print("recommend title-first ok")

# quality disk key already exists - ensure memory cache also reads disk (it does)
p.write_text(s, encoding="utf-8")

# ===== font scale in AppTheme =====
p = root / "lib/common/theme.dart"
s = p.read_text(encoding="utf-8")
if "fontScale" not in s:
    s = s.replace(
        "class AppTheme {",
        """class AppTheme {
  /// 全局字号缩放（设置可调，默认 1.0）
  static final ValueNotifier<double> fontScale = ValueNotifier(1.0);

  static double fs(double base) => (base * fontScale.value).clamp(9.0, 40.0);
""",
        1,
    )
    p.write_text(s, encoding="utf-8")
    print("font scale added")

print("done batch")
