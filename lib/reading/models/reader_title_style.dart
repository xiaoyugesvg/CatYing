/// 「标题样式」= 章标题的版式。
///
/// 用户 2026-10-25：**只保留两套**（跟阅读样式一一对应）——
///   · 青蓝·光晕 → 配「泼墨山水·退堂鼓·改」
///   · 微信读书 → 配「真·微信读书」
/// 其余（仙鹤日间/夜间/平板、古风蓝章）全部去掉。
/// 想加回来照现在的写法补一个枚举值 + 一段 HTML 即可。
enum ReaderTitleStyle {
  none('默认', ''),
  weRead('微信读书', 'weread'),
  qingLan('青蓝·光晕', 'qinglan'),
  custom('自定义', 'custom');

  const ReaderTitleStyle(this.label, this.id);

  /// 卡片/按钮上的名字
  final String label;

  /// 持久化 id（空串 = 默认）
  final String id;

  bool get isCustomTemplate => this != ReaderTitleStyle.none;

  /// 内置模板（custom 返回空串，用用户自己存的那份）
  String get html => switch (this) {
    ReaderTitleStyle.weRead => _weRead,
    ReaderTitleStyle.qingLan => _qingLan,
    _ => '',
  };

  /// 夜间版 HTML（空串 = 该模板没有夜版，沿用 [html]）。
  ///
  /// 内置模板的颜色是写死的：不换一套，夜间深底上就是深色标题（几乎看不见）。
  String get nightHtml => switch (this) {
    ReaderTitleStyle.weRead => _weReadNight,
    ReaderTitleStyle.qingLan => _qingLanNight,
    _ => '',
  };

  static ReaderTitleStyle fromId(String? id) {
    final v = id ?? '';
    for (final e in values) {
      if (e.id == v) return e;
    }
    return none;
  }

  /// 自定义编辑框的初始模板（用户没存过时给青蓝光晕，方便改颜色/换图）
  static String get starterTemplate => _qingLan;

  // ── 内置模板 ────────────────────────────────────────────────

  static const _weRead = '''
<p style="text-align:left; color:#386068; font-size:1.5em; margin-top:2em;
          margin-bottom:0; padding-bottom:1.5em;">章节数</p>
<p style="text-align:left; font-weight:bold; color:#386068; font-size:2em;
          padding-bottom:4em;">章节名</p>''';

  /// 微信读书·夜间版（深底浅字）
  static const _weReadNight = '''
<p style="text-align:left; color:#9BA6B2; font-size:1.5em; margin-top:2em;
          margin-bottom:0; padding-bottom:1.5em;">章节数</p>
<p style="text-align:left; font-weight:bold; color:#C9D2DB; font-size:2em;
          padding-bottom:4em;">章节名</p>''';

  /// 青蓝·光晕（山峦插画 + 文字发光 + 半透明药丸）—— 泼墨那套的标题。
  /// 原样式的背景图是网络地址，这里换成随包 asset（离线也能用）。
  static const _qingLan = '''
<div style="background-image:url('asset:assets/images/reader_title/qinglan.png');
            background-repeat:no-repeat; background-position:left; background-size:auto 100%;">
  <div style="text-align:left;">
    <h3 style="color:#236178; text-shadow:0 0 10px #236178; margin:0 0.5em 3em 0;
               font-weight:200; font-size:1.5em;">章节数</h3>
    <h4 style="box-shadow:0px 15px 10px -15px #000; display:inline-block;
               background-color:rgba(35,97,120,0.5); border-radius:16px;
               margin:3em 0 2em 0; padding:0.5em 2em; text-align:left;
               color:#f3f7fa; text-shadow:0 0 10px #f3f7fa;
               font-weight:200; font-size:1em;">章节名</h4>
  </div>
</div>''';

  /// 青蓝·光晕·夜间版（浅青字 + 更淡的药丸，夜间也有"光晕"感）
  static const _qingLanNight = '''
<div style="background-image:url('asset:assets/images/reader_title/qinglan.png');
            background-repeat:no-repeat; background-position:left; background-size:auto 100%;">
  <div style="text-align:left;">
    <h3 style="color:#8FB6C6; text-shadow:0 0 10px #8FB6C6; margin:0 0.5em 3em 0;
               font-weight:200; font-size:1.5em;">章节数</h3>
    <h4 style="box-shadow:0px 15px 10px -15px #000; display:inline-block;
               background-color:rgba(143,182,198,0.35); border-radius:16px;
               margin:3em 0 2em 0; padding:0.5em 2em; text-align:left;
               color:#EAF3F7; text-shadow:0 0 10px #EAF3F7;
               font-weight:200; font-size:1em;">章节名</h4>
  </div>
</div>''';
}
