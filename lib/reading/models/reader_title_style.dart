/// 「标题样式」= 章标题的版式。
///
/// 用户提供的三套是「源阅读」的 HTML 标题样式，这里内置成模板（图片换成
/// 随包 asset），由 `TitleHtml`（HTML/CSS 子集解析器）解析成 Widget 并度量。
/// 用户还可以选「自定义」，直接粘贴源阅读的标题 HTML（支持 http 图片 /
/// data URI / asset:）。
enum ReaderTitleStyle {
  none('默认', ''),
  xianheDay('仙鹤·日间', 'xianhe_day'),
  xianheNight('仙鹤·夜间', 'xianhe_night'),
  weRead('微信读书', 'weread'),
  guFeng('古风·蓝章', 'gufeng'),
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
    ReaderTitleStyle.xianheDay => _xianheDay,
    ReaderTitleStyle.xianheNight => _xianheNight,
    ReaderTitleStyle.weRead => _weRead,
    ReaderTitleStyle.guFeng => _guFeng,
    ReaderTitleStyle.qingLan => _qingLan,
    _ => '',
  };

  static ReaderTitleStyle fromId(String? id) {
    final v = id ?? '';
    for (final e in values) {
      if (e.id == v) return e;
    }
    return none;
  }

  /// 自定义编辑框的初始模板（用户没存过时给仙鹤日间，方便改颜色/换图）
  static String get starterTemplate => _xianheDay;

  // ── 内置模板（参数来自用户提供的源阅读样式，图片改成本地 asset）──

  static const _xianheDay = '''
<div style="background-image:url('asset:assets/images/reader_title/xianhe.png');
            background-repeat:no-repeat; background-position:left; background-size:auto 100%;">
  <div style="text-align:right;">
    <h3 style="color:#3a4654; margin:0.5em 0.5em 3em 0; font-size:1.5em; font-weight:200;">章节数</h3>
    <h4 style="box-shadow:0px 15px 10px -15px #000; display:inline-block;
               background-color:rgba(58,70,84,0.8); border-radius:16px;
               margin:0 0 5em 0; padding:0.5em 2em; text-align:right;
               color:#cbba75; font-weight:200; font-size:1em;">章节名</h4>
  </div>
</div>''';

  static const _xianheNight = '''
<div style="background-image:url('asset:assets/images/reader_title/xianhe.png');
            background-repeat:no-repeat; background-position:left; background-size:auto 100%;">
  <div style="text-align:right;">
    <h3 style="color:#97897a; margin:0.5em 0.5em 3em 0; font-size:1.5em; font-weight:200;">章节数</h3>
    <h4 style="box-shadow:0px 15px 10px -15px #000; display:inline-block;
               background-color:rgba(151,137,122,0.8); border-radius:16px;
               margin:0 0 5em 0; padding:0.5em 2em; text-align:right;
               color:#2d3b6c; font-weight:200; font-size:1em;">章节名</h4>
  </div>
</div>''';

  static const _weRead = '''
<p style="text-align:left; color:#386068; font-size:1.5em; margin-top:2em;
          margin-bottom:0; padding-bottom:1.5em;">章节数</p>
<p style="text-align:left; font-weight:bold; color:#386068; font-size:2em;
          padding-bottom:4em;">章节名</p>''';

  /// 用户 2026 提供的「古风·完美版」（蓝底白字章节数 + 蓝色大标题）
  ///
  /// 与原文的差异：补了 `padding:0.1em 0.5em`（原文没有内衬，字会顶到圆角；
  /// 截图里明显有内衬），其余参数原样。
  static const _guFeng = '''
<h3 style="border-bottom:2px solid #D8D2C1; text-align:center; color:#ffffff;
           float:left; display:inline-block; background-color:#485F8B;
           border-radius:5px; font-weight:Light; font-size:2.6em;
           margin:0; padding:0.1em 0.5em;">章节数</h3>
<h3 style="border-bottom:1px solid #485F8B; text-align:center; color:#485F8B;
           font-weight:Light; font-size:2.3em; margin:0.3em 0 0.5em 0;
           padding-bottom:0.15em;">章节名</h3>''';

  /// 用户 2026 提供的「青蓝·光晕」（山峦插画 + 文字发光 + 半透明药丸）。
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
}
