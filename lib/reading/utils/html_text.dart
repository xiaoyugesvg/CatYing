// 阅读模块的 HTML 文本清洗。
//
// ── 为什么需要 ─────────────────────────────────────────────────
// 书源接口（Legado 规则只做"取文本"，不保证是纯文本）经常把
// `<br>`、`<em>`、`<span style="…">`、`&nbsp;` 这类片段直接塞进
// 书名 / 作者 / 章节名 / 简介 ⇒ 原样显示就会看到 `<br>` 这种代码。
//
// 用户 2026-10-13：「书源里面的详情的书籍名称、作者名还有更新日期、
// 简介里面不要有 <br> 这种类似的代码」。
//
// ── 顺序很关键 ─────────────────────────────────────────────────
// **先把换行类标签转成换行、再剥标签** —— 否则 `第一行<br>第二行`
// 会被粘成 `第一行第二行`（分段信息丢了）。
//
// [singleLine] = true 用于书名 / 作者 / 时间这类**必须单行**的字段：
// 最后把换行压成空格，免得一个 `<br>` 把书名劈成两行。

/// 去掉 HTML 标签 / 解码常见实体，并把空白收敛到正常人读的样子。
///
/// 纯函数、无副作用：只处理"显示用的文本"，不参与任何规则匹配。
String stripHtmlText(String raw, {bool singleLine = false}) {
  if (raw.isEmpty) return raw;
  var s = raw;

  // 1) 换行 / 分段标签 → 换行符
  s = s.replaceAll(
    RegExp(r'<\s*br\s*/?\s*>|</\s*(p|div|li|h[1-6])\s*>', caseSensitive: false),
    '\n',
  );

  // 2) 其余标签整体剥掉（<em> <span style="…"> …）
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');

  // 3) 常见 HTML 实体解码（&amp; 放最后：避免把 `&amp;lt;` 解成 `<`）
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&ldquo;', '“')
      .replaceAll('&rdquo;', '”')
      .replaceAll('&hellip;', '…')
      .replaceAll('&mdash;', '—')
      .replaceAll('&middot;', '·')
      .replaceAll('&amp;', '&');

  // 4) 收敛空白：行内连续空白压成一个；连续空行最多留一个；去首尾空行
  final out = <String>[];
  var blank = false;
  for (final line in s.split('\n')) {
    final l = line.replaceAll(RegExp(r'[ \t\u3000]+'), ' ').trim();
    if (l.isEmpty) {
      if (!blank && out.isNotEmpty) out.add('');
      blank = true;
    } else {
      out.add(l);
      blank = false;
    }
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }

  final joined = out.join('\n').trim();
  return singleLine
      ? joined.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim()
      : joined;
}

// ───────────────────────────────────────────────────────────────
// 站点噪声清洗（书名 / 章节名 / 简介）
//
// 用户 2026-10-18：
//   「漫画、书源的漫画名称、书籍名称，或是它们的章节名称这些，出现了要去掉
//    符号、网站名称、手机阅读、返回等等与内容无关的东西，简介里面不要出现
//    返回、符号等等无关的内容」
//
// 源站常把导航 / 站点名混进字段里，例如：
//   `斗破苍穹_手机阅读`、`【笔趣阁】斗破苍穹`、`第12话 返回目录`、
//   `www.xxx.com`、`★★★★` …
// 这些都不是内容本身，统一在这里清洗（只处理显示文本，不动规则匹配）。
// ───────────────────────────────────────────────────────────────

/// 任何位置出现都可以直接删掉的强噪声词（不可能是正文的一部分）。
const _strongNoise = <String>[
  '手机阅读',
  '手机版阅读',
  '移动版阅读',
  '手机站',
  '电脑版阅读',
  '全文阅读',
  '免费阅读',
  '在线阅读',
  '在线观看',
  '免费观看',
  '最新章节',
  '章节目录',
  '全部章节',
  '章节列表',
  '目录列表',
  '无弹窗',
  '无弹窗广告',
  '无广告',
  '更新最快',
  '免费下载',
  'txt下载',
  'TXT下载',
  '列表',
  '全文',
  '请记住本站',
  '加入书架',
  '投推荐票',
  '返回目录',
  '返回书页',
  '返回首页',
];

/// 只在**首尾 / 分隔符旁**删除的弱噪声词。
///
/// 这些词本身可能是正常内容的一部分（如书名《目录学》），
/// 所以不能像强噪声那样全文替换。
const _weakNoise = <String>[
  '返回',
  '目录',
  '首页',
  '上一章',
  '下一章',
  '上一页',
  '下一页',
  '登录',
  '注册',
  '书架',
];

/// 纯装饰符号（不带正常标点）——简介正文只剥这些，保留句末的「。，！？」。
const _decorJunk = r'\s\u3000·•◆◇★☆●○■□▲△▼▽※→←↑↓~～';

/// 装饰性符号 / 标点（标题首尾要剥掉的字符集合）。
const _edgeJunk =
    r'\s\u3000·•◆◇★☆●○■□▲△▼▽※→←↑↓~～`!！?？,，.。、:：;；|｜_\-—–/\\【】\[\]（）()<>《》「」『』'
    '"'
    "'"
    '“”‘’';

/// 域名 / URL（含裸域名，如 `www.xxx.com`、`m.xxx.cn/read`）。
final _domainRe = RegExp(
  r'(?:https?://)?(?:[A-Za-z0-9][A-Za-z0-9-]*\.)+'
  r'(?:com|cn|net|org|cc|info|xyz|la|tv|me|co|top|vip|biz|us|io|tw|hk|app|site|online|club|fun|shop|wang|ren|mobi|pro|name|link|live|icu|art|wiki)'
  r'(?::\d+)?(?:/[^\s，。；;、）)】〉》]*)?',
  caseSensitive: false,
);

/// 站点名后缀（`_笔趣阁小说网`、`-飘天文学网` …）。
final _siteSuffixRe = RegExp(
  r'[\s_|｜\-—–·/]+[^\s_|｜\-—–·/]{1,12}'
  r'(?:小说网|文学网|中文网|阅读网|漫画网|动漫网|书屋|书院|书吧|网站|官网)\s*$',
  caseSensitive: false,
);

/// 常见站点品牌词（只删**分隔符后的尾巴**，不碰正文里的同名单词）。
final _brandTailRe = RegExp(
  r'[\s_|｜\-—–·/]+(?:笔趣阁|新笔趣阁|顶点小说|飘天文学|八一中文|书趣阁|'
  r'燃文小说|无错小说|69书吧|落秋中文|龙腾小说)\s*$',
  caseSensitive: false,
);

final _weakNoiseAlt = _weakNoise.map(RegExp.escape).join('|');

/// 括号里是不是"站点名 / 状态标签"（`【笔趣阁】`、`（全文阅读）`、`【完结】`）。
///
/// 只用于**括号整组**的删除判断，不会碰括号外的正文
/// （如《名侦探柯南（特别篇）》里的「特别篇」会保留）。
bool _isSiteTag(String inner) {
  final t = inner.trim();
  if (t.isEmpty) return true;
  if (_domainRe.hasMatch(t)) return true;
  if (RegExp(r'(网|阁|轩|居|文学|小说|漫画|阅读|书屋|书院|书吧|网站|官网|站)$').hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'^(?:完结|全本|全集|精校|校对|无弹窗|免费|连载|首发|[Tt][Xx][Tt]|下载|手机|最新|热门)',
  ).hasMatch(t)) {
    return true;
  }
  return false;
}

/// 清理书名 / 漫画名 / 作者名（单行展示）。
///
/// 顺序：剥 HTML → 删域名 → 删强噪声 → 删首尾弱噪声 → 删站点名尾巴
///      → 删纯噪声括号 → 剥首尾装饰符号 → 收敛空白。
///
/// 清洗后为空说明整条都是噪声（纯网址 / 纯符号 / 纯导航），
/// 返回空串让调用方丢弃该条目，而不是把噪声原样显示出来。
String cleanSourceTitle(String raw) {
  final stripped = stripHtmlText(raw, singleLine: true);
  if (stripped.isEmpty) return stripped;
  var s = stripped;

  // 作者字段常带「作者：」前缀
  s = s.replaceFirst(RegExp(r'^\s*作\s*者\s*[:：]\s*'), '');

  // 0) 翻页页码（`（第1/2页）`）
  s = s.replaceAll(
    RegExp(r'[\(（]\s*(?:第\s*)?\d+\s*/\s*\d+\s*页?\s*[\)）]'),
    '',
  );

  // 1) URL / 裸域名
  s = s.replaceAll(_domainRe, ' ');

  // 2) 强噪声词（全文删）
  for (final w in _strongNoise) {
    s = s.replaceAll(w, ' ');
  }

  // 3) 首尾弱噪声（循环两次，处理「返回 目录」这种连续两个词）。
  //    ⚠️ 必须要求词后/词前是分隔符或字符串边界，否则《目录学》会被清成《学》。
  for (var i = 0; i < 2; i++) {
    s = s.replaceAll(
      RegExp(
        '^(?:$_weakNoiseAlt)(?=[\\s_|｜\\-—–·:：/]|\$)',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(RegExp('^[\\s_|｜\\-—–·:：/]+'), '');
    s = s.replaceAll(
      RegExp(
        '(?:^|[\\s_|｜\\-—–·:：/])(?:$_weakNoiseAlt)\$',
        caseSensitive: false,
      ),
      '',
    );
  }

  // 4) 站点名尾巴（如 `_笔趣阁小说网`、`-笔趣阁`）
  s = s.replaceAll(_siteSuffixRe, '');
  s = s.replaceAll(_brandTailRe, '');

  // 5) 括号里是噪声 / 域名 / 纯符号 → 整组删
  s = s.replaceAllMapped(
    RegExp(r'[\(（\[【]([^\)）\]】]{0,24})[\)）\]】]'),
    (m) {
      final inner = (m.group(1) ?? '').trim();
      final lower = inner.toLowerCase();
      final hasNoise = [
        ..._strongNoise,
        ..._weakNoise,
      ].any((w) => lower.contains(w));
      final isUrl = _domainRe.hasMatch(inner);
      final isSymbolOnly = RegExp('^[$_edgeJunk]*\$').hasMatch(inner);
      return (hasNoise || isUrl || isSymbolOnly || _isSiteTag(inner))
          ? ''
          : m.group(0)!;
    },
  );

  // 6) 剥首尾装饰符号 / 分隔符
  s = s.replaceAll(RegExp('^[$_edgeJunk]+'), '');
  s = s.replaceAll(RegExp('[$_edgeJunk]+\$'), '');

  // 7) 收敛空白与残留分隔符
  s = s.replaceAll(RegExp(r'[ \t\u3000]+'), ' ');
  s = s.replaceAll(RegExp(r'\s*([_|｜\-—–·/])\s*(?=[_|｜\-—–·/])'), '');
  s = s.replaceAll(RegExp(r'^[\s_|｜\-—–·/:：]+'), '');
  s = s.replaceAll(RegExp(r'[\s_|｜\-—–·/:：]+$'), '');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  return s;
}

/// 清理章节名（目录 / 阅读器 / 下载列表共用）。
///
/// 与书名同源，但额外处理：
///   · `返回目录` / `上一章` 等导航前缀；
///   · `（第 1/3 页）` 这类翻页页码；
///   · 章节名胜过空时回退原文。
String cleanChapterTitle(String raw) {
  final stripped = stripHtmlText(raw, singleLine: true);
  if (stripped.isEmpty) return stripped;

  var s = stripped;

  // 翻页页码：`(第1/3页)`、`（2/5）`
  s = s.replaceAll(
    RegExp(r'[\(（]\s*(?:第\s*)?\d+\s*/\s*\d+\s*页?\s*[\)）]'),
    '',
  );

  // 复用书名清洗的整套噪声逻辑
  s = cleanSourceTitle(s);

  // 导航前缀（⚠️ 长词在前：`返回目录` 不能被 `返回` 先吃掉一半）
  s = s.replaceAll(
    RegExp(
      r'^(?:返回目录|返回书页|返回首页|返回|章节目录|目录|上一章|下一章|上一页|下一页)'
      r'[\s:：_|｜\-—–·]*',
    ),
    '',
  );

  s = s.replaceAll(RegExp('^[$_edgeJunk]+'), '');
  s = s.replaceAll(RegExp('[$_edgeJunk]+\$'), '');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  return s;
}

/// 判断简介里的某一行是否只是导航 / 广告 / 纯网址。
bool _isJunkIntroLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return true;

  final withoutUrl = t.replaceAll(_domainRe, '').trim();
  final core = withoutUrl.replaceAll(RegExp('[$_edgeJunk]'), '').trim();

  // 整行只有符号 / 网址
  if (core.isEmpty) return true;

  // 整行就是某个噪声词 / 纯导航短语。
  // ⚠️ 只做**整行精确匹配**：像「返回故乡的他…」这种正文不能误删。
  final lower = core.toLowerCase();
  if ([..._strongNoise, ..._weakNoise].any((w) => lower == w)) return true;
  if (const {
    '返回',
    '返回目录',
    '返回书页',
    '返回首页',
    '上一章',
    '下一章',
    '上一页',
    '下一页',
    '目录',
    '首页',
    '书架',
    '登录',
    '注册',
  }.contains(core)) {
    return true;
  }

  return false;
}

/// 清理简介（保留段落换行）。
///
/// 逐行处理：丢掉导航 / 广告 / 纯网址行，删掉行内域名与首尾装饰符号，
/// 连续空行压成一个。不会动正文里的正常标点。
String cleanIntroText(String raw) {
  if (raw.trim().isEmpty) return '';
  final text = stripHtmlText(raw);
  final out = <String>[];

  for (final line in text.split('\n')) {
    var l = line.trim();
    if (l.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    if (_isJunkIntroLine(l)) continue;

    l = l
        .replaceAll(_domainRe, ' ')
        .replaceFirst(RegExp(r'^\s*简介\s*[:：]\s*'), '')
        // 只剥装饰符号，保留句末正常标点（「。」「！」等）
        .replaceAll(RegExp('^[$_decorJunk]+'), '')
        .replaceAll(RegExp('[$_decorJunk]+\$'), '')
        .replaceAll(RegExp(r'[ \t\u3000]{2,}'), ' ')
        .trim();

    if (l.isEmpty || RegExp('^[$_edgeJunk]*\$').hasMatch(l)) continue;
    out.add(l);
  }

  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n').trim();
}
