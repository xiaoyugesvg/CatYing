// lib/reading/cores/reader_core.dart
//
// 阅读核心（ReaderCore）—— 「数据从哪来」的引擎抽象。
//
// ── 与影视/音乐播放器核心的关系 ─────────────────────────────
// 同构，但**完全隔离**：
//   · 本目录（lib/reading/cores/）**禁止** import 音乐模块 / 影视播放器相关文件；
//   · 唯一允许的"引擎层"外部依赖是 PythonManager（CPython 调用）与 Node 书源引擎；
//   · 核心只负责拿到数据（正文 / 图片 URL 列表），不负责阅读器 UI、不负责排版。
//
// ── 为什么需要它（用户 2026-10-14）────────────────────────────
// py 的书籍 / 图片 / 漫画源原先没有统一入口，只能零散塞进现有链路 ——
// 结果是音乐 / 影视 / 阅读三块容易互相牵连。有了核心抽象：
//   **新增一种源 = 新增一个 ReaderCore 实现**，阅读器 UI 一行都不用改。
//
// ── 极简原则 ────────────────────────────────────────────────
// 只定义"阅读器真正要用到的最小面"：文本四个方法 + 图片两个方法。
// 不认识的字段一律留空字符串，由界面按空值处理（不做 try/兜底噪音）。

/// 文本搜索命中的一本书（图片搜索也复用这个形状，cover 就是封面图）。
class CoreBookHit {
  final String id; // 给 bookInfo/toc 用的 id（各核心自定义编码）
  final String name;
  final String author;
  final String cover;

  const CoreBookHit({
    required this.id,
    required this.name,
    this.author = '',
    this.cover = '',
  });
}

/// 书籍详情（能拿到的都放上来，拿不到的留空）
class CoreBookDetail {
  final String id;
  final String name;
  final String author;
  final String cover;
  final String intro;

  const CoreBookDetail({
    required this.id,
    required this.name,
    this.author = '',
    this.cover = '',
    this.intro = '',
  });
}

/// 目录里的一章 / 话
class CoreChapter {
  final String name;

  /// 章节定位串（各核心自定义：可能是 URL、可能是 index、也可能是 JSON）
  final String url;

  const CoreChapter({required this.name, required this.url});
}

/// 阅读核心接口。
///
/// 实现类必须**无副作用地**声明自己的能力（[supportsText] / [supportsImages]），
/// 上层据此决定"这本书能不能用这个核心打开"。
abstract class ReaderCore {
  /// 稳定标识，用于持久化用户选择（如 `'python'`）
  String get id;

  /// 设置里显示的名字（如 `'Python 源'`）
  String get label;

  /// 能否提供**正文**（书 / 听书都靠它）
  bool get supportsText;

  /// 能否提供**图片列表**（图片 / 漫画靠它）
  bool get supportsImages;

  // ── 文本能力（supportsText 为 false 时可不实现，直接抛 UnimplementedError）──

  /// 搜索书籍
  Future<List<CoreBookHit>> searchText(String keyword);

  /// 书籍详情
  Future<CoreBookDetail?> bookInfo(String id);

  /// 目录
  Future<List<CoreChapter>> toc(String id);

  /// 第 [chapterIndex] 章的正文字符串（纯文本或 HTML，由阅读器决定怎么渲染）
  Future<String> content(String id, int chapterIndex);

  // ── 图片能力（supportsImages 为 false 时可不实现）──────────────────

  /// 搜索（图片 / 漫画）
  Future<List<CoreBookHit>> searchImages(String keyword);

  /// 第 [chapterIndex] 话的图片 URL 列表（按顺序）
  Future<List<String>> images(String id, int chapterIndex);
}

/// 核心注册表。
///
/// 只负责"有哪些核心可用"；**用户选了哪个核心**由上层用独立的 prefs key
/// 持久化（与影视/直播核心各自独立持久化同一个约定，互不影响）。
class ReaderCoreRegistry {
  ReaderCoreRegistry._();

  static final List<ReaderCore> _cores = [];

  /// 注册一个核心（同 id 重复注册时保留先注册的那个）
  static void register(ReaderCore core) {
    if (_cores.any((c) => c.id == core.id)) return;
    _cores.add(core);
  }

  /// 当前可用的核心（顺序即注册顺序）
  static List<ReaderCore> get all => List.unmodifiable(_cores);

  static ReaderCore? byId(String id) {
    for (final c in _cores) {
      if (c.id == id) return c;
    }
    return null;
  }
}
