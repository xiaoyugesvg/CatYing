import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条阅读划线 / 批注。
///
/// 定位键 = 源 + 书名 + 章节下标 + 段落下标（章节下标会因源规则
/// 更新而漂移，但段落文本同时存了一份，展示端有兜底）。
class ReaderNote {
  const ReaderNote({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.bookName,
    required this.chapterIndex,
    required this.chapterName,
    required this.paragraphIndex,
    required this.text,
    this.note = '',
    this.color = 0xFFF5C842,
    required this.createdAt,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String bookName;
  final int chapterIndex;
  final String chapterName;
  final int paragraphIndex;
  final String text;
  final String note; // 批注文字；空 = 纯划线
  final int color; // 划线颜色（ARGB）
  final int createdAt; // epoch millis

  bool get hasNote => note.trim().isNotEmpty;

  ReaderNote copyWith({String? note}) => ReaderNote(
        id: id,
        sourceId: sourceId,
        sourceName: sourceName,
        bookName: bookName,
        chapterIndex: chapterIndex,
        chapterName: chapterName,
        paragraphIndex: paragraphIndex,
        text: text,
        note: note ?? this.note,
        color: color,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'bookName': bookName,
        'chapterIndex': chapterIndex,
        'chapterName': chapterName,
        'paragraphIndex': paragraphIndex,
        'text': text,
        'note': note,
        'color': color,
        'createdAt': createdAt,
      };

  static ReaderNote? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    if (id.isEmpty) return null;
    return ReaderNote(
      id: id,
      sourceId: (j['sourceId'] ?? '').toString(),
      sourceName: (j['sourceName'] ?? '').toString(),
      bookName: (j['bookName'] ?? '').toString(),
      chapterIndex: (j['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterName: (j['chapterName'] ?? '').toString(),
      paragraphIndex: (j['paragraphIndex'] as num?)?.toInt() ?? 0,
      text: (j['text'] ?? '').toString(),
      note: (j['note'] ?? '').toString(),
      color: (j['color'] as num?)?.toInt() ?? 0xFFF5C842,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// 同位置判定（源+书名+章+段），用于"再点一次取消划线"。
  bool sameSpot(ReaderNote other) =>
      sourceId == other.sourceId &&
      bookName == other.bookName &&
      chapterIndex == other.chapterIndex &&
      paragraphIndex == other.paragraphIndex;
}

/// 划线 / 批注存储（SharedPreferences 持久化）。
///
/// 设计：
///   · 一份 flat 列表，按 源+书名 分组给 UI
///   · 划线 = 无 note 的 ReaderNote；批注 = 带 note 的 ReaderNote
///   · 同一位置只允许一条（再划线 = 取消划线；有批注时只清划线不清批注）
class ReaderNotesService {
  ReaderNotesService._();
  static final ReaderNotesService instance = ReaderNotesService._();

  static const _key = 'reader_notes_v1';

  List<ReaderNote> _items = const [];

  void _log(String msg) => debugPrint('[ReaderNotes] $msg');

  /// 全部笔记（最新在前）。
  List<ReaderNote> get all => List.of(_items.reversed);

  /// 某本书的笔记（最新在前）。
  List<ReaderNote> forBook(String sourceId, String bookName) => all
      .where((n) => n.sourceId == sourceId && n.bookName == bookName)
      .toList();

  /// 全部书（有笔记的），按最近时间排序。
  List<({String sourceId, String bookName, int lastAt, int count})>
      bookGroups() {
    final map = <String, ({String sourceId, String bookName, int lastAt, int count})>{};
    for (final n in _items) {
      final k = '${n.sourceId}::${n.bookName}';
      final old = map[k];
      map[k] = (
        sourceId: n.sourceId,
        bookName: n.bookName,
        lastAt: n.createdAt > (old?.lastAt ?? 0) ? n.createdAt : (old?.lastAt ?? 0),
        count: (old?.count ?? 0) + 1,
      );
    }
    final out = map.values.toList()
      ..sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return out;
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(_items.map((n) => n.toJson()).toList()));
    } catch (e) {
      _log('保存失败: $e');
    }
  }

  /// 是否已从磁盘加载过（幂等闩锁，见 [init]）
  bool _loaded = false;

  Future<void> init() async {
    // 🔴 **必须幂等** ✓：页面在 `initState` 里会反复调它 ✗，而它用磁盘内容
    // **整体替换** `_items` ✓ → 会把"本次会话中刚建、还没落盘的划线/批注"
    // **静默回滚** ✗（`_persist` 是异步的，中间窗口就在这儿 ✓）。
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final arr = jsonDecode(raw);
      if (arr is List) {
        _items = arr
            .whereType<Map>()
            .map((e) => ReaderNote.fromJson(e.cast<String, dynamic>()))
            .whereType<ReaderNote>()
            .toList();
      }
    } catch (e) {
      _log('加载失败: $e');
    }
    // ⚠️ "加载完立刻刷新笔记页首帧"这件事**这次没做** ✗：
    // 本类**不是** `ChangeNotifier`（analyze 当场报 `notifyListeners` 未定义 ✓），
    // 要让它能通知，得先 `extends ChangeNotifier` 并让
    // `notes_and_journey_page.dart` 改成监听它 ✓ —— 那是跨文件改动，
    // 我**宁可只做已验证的这一半**（幂等闩锁 ✓，它修的是"回滚"✗），
    // 也不留一个编译不过的仓库 ✗。
    // 遗留：笔记页首帧仍可能为空（下一次 setState 后正常 ✓），已记入待办 ✓
  }

  /// 划线/取消划线。返回操作后该位置是否还有笔记。
  Future<bool> toggleHighlight({
    required String sourceId,
    required String sourceName,
    required String bookName,
    required int chapterIndex,
    required String chapterName,
    required int paragraphIndex,
    required String text,
    int color = 0xFFF5C842,
  }) async {
    final spot = _items.indexWhere(
      (n) =>
          n.sourceId == sourceId &&
          n.bookName == bookName &&
          n.chapterIndex == chapterIndex &&
          n.paragraphIndex == paragraphIndex,
    );
    if (spot >= 0) {
      final existing = _items[spot];
      if (existing.hasNote) {
        // 有批注：只清划线（保留批注）
        _items = List.of(_items)..removeAt(spot);
        await _persist();
        return true;
      }
      _items = List.of(_items)..removeAt(spot);
      await _persist();
      return false;
    }
    _items = List.of(_items)
      ..add(ReaderNote(
        id: 'n${DateTime.now().microsecondsSinceEpoch}',
        sourceId: sourceId,
        sourceName: sourceName,
        bookName: bookName,
        chapterIndex: chapterIndex,
        chapterName: chapterName,
        paragraphIndex: paragraphIndex,
        text: text,
        color: color,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    await _persist();
    return true;
  }

  /// 划线 + 批注（同一位置再批注 = 更新批注文字）。
  Future<void> addNote({
    required String sourceId,
    required String sourceName,
    required String bookName,
    required int chapterIndex,
    required String chapterName,
    required int paragraphIndex,
    required String text,
    required String note,
    int color = 0xFFF5C842,
  }) async {
    final spot = _items.indexWhere(
      (n) =>
          n.sourceId == sourceId &&
          n.bookName == bookName &&
          n.chapterIndex == chapterIndex &&
          n.paragraphIndex == paragraphIndex,
    );
    if (spot >= 0) {
      _items = List.of(_items)
        ..[spot] = _items[spot].copyWith(note: note);
      await _persist();
      return;
    }
    _items = List.of(_items)
      ..add(ReaderNote(
        id: 'n${DateTime.now().microsecondsSinceEpoch}',
        sourceId: sourceId,
        sourceName: sourceName,
        bookName: bookName,
        chapterIndex: chapterIndex,
        chapterName: chapterName,
        paragraphIndex: paragraphIndex,
        text: text,
        note: note,
        color: color,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    await _persist();
  }

  /// 删除一条。
  Future<void> remove(String id) async {
    _items = List.of(_items)
      ..removeWhere((n) => n.id == id);
    await _persist();
  }

  /// 删除某本书全部笔记。
  Future<void> clearBook(String sourceId, String bookName) async {
    _items = List.of(_items)
      ..removeWhere(
          (n) => n.sourceId == sourceId && n.bookName == bookName);
    await _persist();
  }
}
