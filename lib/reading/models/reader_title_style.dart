import 'package:flutter/material.dart';

/// 「标题样式」= 章标题的版式。
///
/// 参考用户提供的三个「源阅读」标题样式（HTML）：
///   · 仙鹤·日间 / 仙鹤·夜间：左侧仙鹤插画 + 右上角章节数 + 圆角药丸里的章节名
///     （插画是透明 PNG，已随包内置 `assets/images/reader_title/xianhe.png`）
///   · 微信读书：小号章节数 + 大号加粗章节名，大留白
///
/// 为什么不用 HTML：源阅读是 WebView 渲染，Flutter 侧没有 HTML/CSS 引擎；
/// 这里把这三套的**版式与配色**原样搬成原生 Widget，分页高度按同一套常量算，
/// 所以度量与渲染一致（不会页底被裁）。任意 HTML 不支持，但颜色/字号都能改。
enum ReaderTitleStyle {
  none('默认', '', ''),
  xianheDay('仙鹤·日间', 'xianhe_day', 'assets/images/reader_title/xianhe.png'),
  xianheNight('仙鹤·夜间', 'xianhe_night', 'assets/images/reader_title/xianhe.png'),
  weRead('微信读书', 'weread', '');

  const ReaderTitleStyle(this.label, this.id, this.artAsset);

  /// 卡片/按钮上的名字
  final String label;

  /// 持久化 id（空串 = 默认，不写 prefs 也行）
  final String id;

  /// 左侧插画 asset（空串 = 无插画）
  final String artAsset;

  bool get custom => this != ReaderTitleStyle.none;

  bool get hasArt => artAsset.isNotEmpty;

  static ReaderTitleStyle fromId(String? id) {
    final v = id ?? '';
    for (final e in values) {
      if (e.id == v) return e;
    }
    return none;
  }

  /// 章节数（右上角小字）颜色
  Color get numberColor => switch (this) {
    ReaderTitleStyle.xianheDay => const Color(0xFF3A4654),
    ReaderTitleStyle.xianheNight => const Color(0xFF97897A),
    ReaderTitleStyle.weRead => const Color(0xFF386068),
    ReaderTitleStyle.none => const Color(0xFF888888),
  };

  /// 药丸底色（仅仙鹤样式）
  Color get pillColor => switch (this) {
    ReaderTitleStyle.xianheDay => const Color(0xCC3A4654),
    ReaderTitleStyle.xianheNight => const Color(0xCC97897A),
    _ => Colors.transparent,
  };

  /// 章节名颜色（微信读书是纯文字，用 numberColor）
  Color get nameColor => switch (this) {
    ReaderTitleStyle.xianheDay => const Color(0xFFCBBA75),
    ReaderTitleStyle.xianheNight => const Color(0xFF2D3B6C),
    ReaderTitleStyle.weRead => const Color(0xFF386068),
    ReaderTitleStyle.none => const Color(0xFF888888),
  };
}
