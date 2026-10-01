import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// 音乐库：**最近播放 + 我的收藏 + 播放队列**（#4 / #5 / #11）。
///
/// ── 为什么三样放一个 Store ────────────────────────────────────
/// 它们都是"用户对歌曲的本地记录"，共用同一套序列化
/// （[Song.listToJson] / [Song.listFromJson]）与同一把锁（`_prefs`）。
/// 分成三个 Store 只会重复三遍初始化/持久化逻辑，没有好处。
///
/// ── 为什么用 `identityKey` 去重 ───────────────────────────────
/// 同一首歌在不同平台的 id 可能相同 —— 用 `source-key` 才唯一。
/// 直接按 `id` 去重会把"网易云的 123"和"QQ音乐的 123"当成同一首。
class MusicLibraryStore extends ChangeNotifier {
  MusicLibraryStore._();
  static final MusicLibraryStore instance = MusicLibraryStore._();

  static const _kRecent = 'music.recent.v1';
  static const _kFavorites = 'music.favorites.v1';
  static const _kQueue = 'music.queue.v1';

  /// 最近播放最多保留多少首（#4 建议 50~100）
  static const int recentLimit = 100;

  /// 最近播放（**新的在前**）
  final List<Song> _recent = [];
  List<Song> get recent => List.unmodifiable(_recent);

  /// 我的收藏（新的在前）
  final List<Song> _favorites = [];
  List<Song> get favorites => List.unmodifiable(_favorites);

  /// 变更计数（供 UI 做"列表要刷新"的信号）。
  ///
  /// 为什么单独给一个 `ValueNotifier<int>` 而不是让 UI 监听整个 Store：
  /// 旧代码（`library_page.dart`）依赖的是 `FavoriteStore.revision`，
  /// 保持这个语义可以让那 3 个调用点不用改。
  final ValueNotifier<int> revisionProxy = ValueNotifier<int>(0);

  SharedPreferences? _prefs;
  bool _inited = false;

  /// 任何变更后统一 bump 一次
  void _bump() {
    revisionProxy.value++;
    _bump();
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      _recent
        ..clear()
        ..addAll(Song.listFromJson(_prefs!.getString(_kRecent) ?? ''));
      _favorites
        ..clear()
        ..addAll(Song.listFromJson(_prefs!.getString(_kFavorites) ?? ''));
      _bump();
    } catch (_) {
      // 读不出来就当空库，不影响播放
    }
  }

  // ============================================================
  // #4 最近播放
  // ============================================================

  /// 记录一次播放。同一首已存在时**移到最前**（不是简单追加），
  /// 这样"最近"的顺序才符合直觉。
  Future<void> addRecent(Song song) async {
    await init();
    final key = song.identityKey;
    _recent.removeWhere((s) => s.identityKey == key);
    _recent.insert(0, song);
    // 超出上限裁掉最旧的 —— 不裁的话这个列表会无限增长
    if (_recent.length > recentLimit) {
      _recent.removeRange(recentLimit, _recent.length);
    }
    _bump();
    await _persist(_kRecent, _recent);
  }

  Future<void> clearRecent() async {
    await init();
    _recent.clear();
    _bump();
    await _persist(_kRecent, _recent);
  }

  // ============================================================
  // #5 收藏
  // ============================================================

  bool isFavorite(Song song) =>
      _favorites.any((s) => s.identityKey == song.identityKey);

  /// 收藏 / 取消收藏。返回**操作后**是否已收藏（方便 UI 直接显示结果）。
  Future<bool> toggleFavorite(Song song) async {
    await init();
    final key = song.identityKey;
    final had = _favorites.any((s) => s.identityKey == key);
    if (had) {
      _favorites.removeWhere((s) => s.identityKey == key);
    } else {
      _favorites.insert(0, song);
    }
    _bump();
    await _persist(_kFavorites, _favorites);
    return !had;
  }

  Future<void> clearFavorites() async {
    await init();
    _favorites.clear();
    _bump();
    await _persist(_kFavorites, _favorites);
  }

  // ============================================================
  // #11 队列持久化
  // ============================================================

  /// 存队列（下次启动能恢复上次听到哪）。
  ///
  /// ⚠️ 队列**允许为空**：用户清空队列是正常操作，
  /// 不能因为"空"就跳过保存（否则重启又冒出旧队列）。
  Future<void> saveQueue(List<Song> queue, int index) async {
    await init();
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString(_kQueue, Song.listToJson(queue));
      await p.setInt('${_kQueue}.index', index);
    } catch (_) {
      /* 存不下不影响当前播放 */
    }
  }

  /// 读回队列。返回 `(songs, index)`；没有则返回空。
  Future<({List<Song> songs, int index})> loadQueue() async {
    await init();
    final p = _prefs;
    if (p == null) return (songs: <Song>[], index: 0);
    try {
      final songs = Song.listFromJson(p.getString(_kQueue) ?? '');
      final idx = p.getInt('${_kQueue}.index') ?? 0;
      if (songs.isEmpty) return (songs: <Song>[], index: 0);
      return (songs: songs, index: idx.clamp(0, songs.length - 1));
    } catch (_) {
      return (songs: <Song>[], index: 0);
    }
  }

  Future<void> _persist(String key, List<Song> list) async {
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString(key, Song.listToJson(list));
    } catch (_) {
      /* 忽略：持久化失败不该影响界面 */
    }
  }
}
