// 「宿主顶栏跟随网页配色」的公共实现 —— 「网页首页」模块与小程序 WebView 页共用。
//
// ── 为什么需要（用户 2026-10-14）──────────────────────────────────
// 「网页那个和顶栏要和根据不同页面的颜色变化和网页一样，包含小程序里面也是
//   一样的」：状态栏那一条原来透的是 App 壁纸/主题色，而网页自己是另一套颜色
// （很多小程序自带彩色 header）⇒ 顶上一条颜色和网页对不上，看着像"断了一截"。
//
// ── 做法 ────────────────────────────────────────────────────────
// 页面加载完后向 WebView 要一个「页面主色」，宿主拿它在**状态栏那一条**上刷
// 同色 ⇒ 视觉上和网页连成一片。取色优先级：
//    ① `<meta name="theme-color">`（网页作者显式声明的浏览器 chrome 颜色）
//    ② `body` 的计算背景色
//    ③ `html` 的计算背景色
// 都取不到就返回 null —— **宁可不上色**（保持原样透出壁纸），也不要刷错颜色。

import 'dart:ui' show Color;

import 'package:webview_flutter/webview_flutter.dart';

/// 探测页面主色的 JS。返回 CSS 颜色串（如 `#0a84ff` / `rgb(247, 245, 241)`），
/// 取不到返回空串。写成 IIFE，配合 `runJavaScriptReturningResult` 直接取返回值。
const String kPageColorProbeJs = r'''
(function () {
  try {
    function bg(el) {
      if (!el) return '';
      var v = getComputedStyle(el).backgroundColor;
      if (!v) return '';
      v = String(v).trim();
      if (v === 'transparent' || v === 'rgba(0, 0, 0, 0)') return '';
      return v;
    }
    var c = '';
    var m = document.querySelector('meta[name="theme-color"]');
    if (m && m.content) c = String(m.content).trim();
    if (!c) c = bg(document.body);
    if (!c) c = bg(document.documentElement);
    return c || '';
  } catch (e) {
    return '';
  }
})()
''';

/// 读当前页面的主色；读不到（或解析不出来）返回 null。
///
/// 注意返回值形态跨平台不一致：Android 侧 `evaluateJavascript` 回的是 JSON 串
/// （带引号），iOS 侧回裸串 ⇒ 这里统一把外层引号剥掉再解析。
Future<Color?> probeWebViewPageColor(WebViewController controller) async {
  String raw;
  try {
    final res =
        await controller.runJavaScriptReturningResult(kPageColorProbeJs);
    raw = res.toString();
  } catch (_) {
    return null;
  }
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    raw = raw.substring(1, raw.length - 1);
  }
  return parseCssColor(raw);
}

/// 解析 CSS 颜色串：`#RGB` / `#RRGGBB` / `#RRGGBBAA` / `rgb()` / `rgba()`。
///
/// 具名色（`white` / `red`…）与 `hsl()` 一律返回 null —— 只认这几种确定的形式，
/// 认不出就不上色（见文件头说明）。
Color? parseCssColor(String? raw) {
  final s = (raw ?? '').trim().toLowerCase();
  if (s.isEmpty) return null;

  if (s.startsWith('#')) {
    var h = s.substring(1);
    if (h.length == 3) {
      // #abc → #aabbcc
      h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
    }
    if (h.length == 6) h = '${h}ff';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    // CSS 是 #RRGGBBAA，Flutter 的 Color 是 0xAARRGGBB ⇒ 要换序
    final r = (v >> 24) & 0xff;
    final g = (v >> 16) & 0xff;
    final b = (v >> 8) & 0xff;
    final a = v & 0xff;
    return Color.fromARGB(a, r, g, b);
  }

  final m = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(s);
  if (m == null) return null;
  final parts = m.group(1)!.split(',').map((e) => e.trim()).toList();
  if (parts.length < 3) return null;

  /// 通道值：支持 `128` 与 `50%` 两种写法；解析不了返回 -1。
  int channel(String t) {
    if (t.endsWith('%')) {
      final p = double.tryParse(t.substring(0, t.length - 1));
      if (p == null) return -1;
      return ((p / 100) * 255).round().clamp(0, 255);
    }
    final v = double.tryParse(t);
    if (v == null) return -1;
    return v.round().clamp(0, 255);
  }

  final r = channel(parts[0]);
  final g = channel(parts[1]);
  final b = channel(parts[2]);
  if (r < 0 || g < 0 || b < 0) return null;

  var a = 255;
  if (parts.length >= 4) {
    final t = parts[3];
    if (t.endsWith('%')) {
      final p = double.tryParse(t.substring(0, t.length - 1));
      if (p != null) a = ((p / 100) * 255).round().clamp(0, 255);
    } else {
      // rgba() 的 alpha 是 0~1
      final v = double.tryParse(t);
      if (v != null) a = (v * 255).round().clamp(0, 255);
    }
  }
  return Color.fromARGB(a, r, g, b);
}
