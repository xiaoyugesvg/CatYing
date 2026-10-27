/// 内置阅读背景壁纸清单（资源在 `assets/images/reader_bg/`）。
///
/// 阅读器的「背景壁纸」弹窗与「样式编辑器」共用这一份，
/// 避免两处各写一遍、加图时漏掉其中一个入口。
class ReaderBgAssets {
  ReaderBgAssets._();

  /// 普通壁纸（14 张）
  static const plain = <String>[
    'assets/images/reader_bg/annie-spratt-6a3nqQ1YwBw-unsplash.jpg',
    'assets/images/reader_bg/augustine-wong-oebTM5wHTfw-unsplash.jpg',
    'assets/images/reader_bg/danielle-suijkerbuijk-66ydMRXW-b8-unsplash.jpg',
    'assets/images/reader_bg/h-co-mjPs0heWsek-unsplash.jpg',
    'assets/images/reader_bg/heather-green-1ITG8U0udqM-unsplash.jpg',
    'assets/images/reader_bg/jacob-dyer-rtA0U8QJHSg-unsplash.jpg',
    'assets/images/reader_bg/janke-laskowski-jz-ayLjk2nk-unsplash.jpg',
    'assets/images/reader_bg/marjan-blan-794QUz5-cso-unsplash.jpg',
    'assets/images/reader_bg/noita-digital-zcx5ztIjQAM-unsplash.jpg',
    'assets/images/reader_bg/p0074_m.jpg',
    'assets/images/reader_bg/p0087_m.jpg',
    'assets/images/reader_bg/resource-boy-t5-DgEcAUUg-unsplash.jpg',
    'assets/images/reader_bg/the-new-york-public-library-atDr7NECc_k-unsplash.jpg',
    'assets/images/reader_bg/tina-dawson-Kim9COAIEGc-unsplash.jpg',
  ];

  /// 微信读书背景包（朔望 / 碧落 / 荒沙 × 白 / 绿 / 黄 / 暗）
  static const weRead = <String>[
    'assets/images/reader_bg/reading_bg_moon_white.jpg',
    'assets/images/reader_bg/reading_bg_moon_green.jpg',
    'assets/images/reader_bg/reading_bg_moon_yellow.jpg',
    'assets/images/reader_bg/reading_bg_moon_dark.jpg',
    'assets/images/reader_bg/reading_bg_sky_white.jpg',
    'assets/images/reader_bg/reading_bg_sky_green.jpg',
    'assets/images/reader_bg/reading_bg_sky_yellow.jpg',
    'assets/images/reader_bg/reading_bg_sky_dark.jpg',
    'assets/images/reader_bg/reading_bg_sand_white.jpg',
    'assets/images/reader_bg/reading_bg_sand_green.jpg',
    'assets/images/reader_bg/reading_bg_sand_yellow.jpg',
    'assets/images/reader_bg/reading_bg_sand_dark.jpg',
  ];

  /// 古风 / 泼墨（Legado 原背景，日间 + 夜间成对）
  static const gufengDay =
      'assets/images/reader_bg/reading_bg_gufeng_day.webp';
  static const gufengNight =
      'assets/images/reader_bg/reading_bg_gufeng_night.webp';
  static const pomoDay = 'assets/images/reader_bg/reading_bg_pomo_day.webp';
  static const pomoNight =
      'assets/images/reader_bg/reading_bg_pomo_night.webp';

  /// 皮卡丘主题（白天 / 黑夜 / 粉色插画）
  static const pikaDay = 'assets/images/reader_bg/reading_bg_pika_day.webp';
  static const pikaNight =
      'assets/images/reader_bg/reading_bg_pika_night.webp';
  static const pikaPink = 'assets/images/reader_bg/reading_bg_pika_pink.webp';

  /// 雲和·無青（源阅读主题，日 / 夜成对）
  static const wuqingDay =
      'assets/images/reader_bg/reading_bg_wuqing_day.webp';
  static const wuqingNight =
      'assets/images/reader_bg/reading_bg_wuqing_night.webp';

  /// 夜间竹林（刘海屏）
  /// ⚠️ 原为 `.png`（1170×2532 RGBA 但**全不透明**，920 KB）；
  ///    2026-10-27 缩包时转成 JPEG q90（350 KB），视觉一致。
  static const nightForest =
      'assets/images/reader_bg/reading_bg_night_forest.jpg';

  /// 黑白成对的壁纸（编辑样式时，选一张自动带出另一张）
  static const pairs = <String, String>{
    gufengDay: gufengNight,
    pomoDay: pomoNight,
    pikaDay: pikaNight,
    wuqingDay: wuqingNight,
  };

  /// 与某张壁纸成对的另一张（没有则返回 null）
  static String? pairOf(String? asset) =>
      asset == null ? null : pairs[asset];

  /// 全部（阅读器壁纸弹窗用）
  static const all = <String>[
    ...plain,
    ...weRead,
    nightForest,
    gufengDay,
    gufengNight,
    pomoDay,
    pomoNight,
    pikaDay,
    pikaNight,
    pikaPink,
    wuqingDay,
    wuqingNight,
  ];

  /// 选「日间壁纸」时用的清单：成对的夜间版不再重复占格
  /// （选中日版会自动带出夜版，见 [pairOf]）。
  static const picker = <String>[
    ...plain,
    ...weRead,
    nightForest,
    gufengDay,
    pomoDay,
    pikaDay,
    pikaPink,
    wuqingDay,
  ];
}
