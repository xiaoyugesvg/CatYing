/// 源「内容类型」标注 —— 让用户在源列表上一眼看出这个源点开是
/// 播放影视、听书（音乐）、看漫画还是看小说。
///
/// ── 为什么要靠"名字/地址关键词"猜 ───────────────────────────────
/// 订阅 JSON 里的 `type` 只说明**用哪个引擎取数据**（0/1/3/4），
/// 跟"内容是视频还是漫画/小说"完全无关；py 脚本也不会声明自己是哪一类。
/// （注意：这与 [SourceBean.sourceKind] 是**两回事** —— 那个分的是
/// CMS/JS/Python/Jar 的**引擎类型**，本文件分的是**内容类型**。）
///
/// 所以这里按**名字与地址**做保守猜测（用户 2026-10-14 要求"加个字符"），
/// 猜错也只是标错一个字符，不影响任何功能。
library;

/// 四种内容类型（与用户口径一致：听书与音乐合并成一类）。
enum MediaKind {
  /// 影视（默认）
  video('影'),

  /// 听书 / 音乐
  audio('听'),

  /// 漫画 / 图片
  manga('漫'),

  /// 小说 / 书籍
  book('书');

  const MediaKind(this.tag);

  /// 显示用的**单个汉字**（用户要求"加个字符"）
  final String tag;

  /// 是否影视（影视是默认类，界面上可以弱化显示）
  bool get isVideo => this == MediaKind.video;
}

/// 漫画 / 图片类关键词
const List<String> _kMangaKeys = [
  '漫画', '漫', '图', 'pic', 'manga', 'comic', '禁漫',
];

/// 小说 / 书籍类关键词
const List<String> _kBookKeys = [
  '小说', '书源', '书籍', '读书', '阅读', '文学', 'novel', 'book', 'read',
];

/// 听书 / 音乐类关键词
const List<String> _kAudioKeys = [
  '听书', '听', '音乐', 'music', '歌', 'audio', '电台', 'podcast', 'mp3',
];

/// 推断一个源的内容类型。[name] 是显示名，[api] 是源地址（可为空）。
///
/// 判定顺序是**刻意的**：先漫画、再小说、最后听书 ——
/// 因为"听书小说"这类名字同时命中多组关键词时，语义上更偏小说，
/// 所以书类优先于听类。
MediaKind inferMediaKind(String name, {String api = ''}) {
  final s = '$name ${api.toLowerCase()}'.toLowerCase();
  for (final k in _kMangaKeys) {
    if (s.contains(k)) return MediaKind.manga;
  }
  for (final k in _kBookKeys) {
    if (s.contains(k)) return MediaKind.book;
  }
  for (final k in _kAudioKeys) {
    if (s.contains(k)) return MediaKind.audio;
  }
  return MediaKind.video;
}

/// 便捷方法：只要那个字符。
String mediaKindTag(String name, {String api = ''}) =>
    inferMediaKind(name, api: api).tag;
