import 'dart:convert';

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
  static const _kPlaylists = 'music.playlists.v1';

  /// 最近播放最多保留多少首（#4 建议 50~100）
  static const int recentLimit = 100;

  /// 最近播放（**新的在前**）
  final List<Song> _recent = [];
  List<Song> get recent => List.unmodifiable(_recent);

  /// 我的收藏（新的在前）
  final List<Song> _favorites = [];
  List<Song> get favorites => List.unmodifiable(_favorites);

  /// 本地歌单（**不需要账号** —— 这是"没有账号时最接近云端歌单的形态"）。
  final List<MusicPlaylist> _playlists = [];
  List<MusicPlaylist> get playlists => List.unmodifiable(_playlists);

  /// 变更计数（供 UI 做"列表要刷新"的信号）。
  ///
  /// 为什么单独给一个 `ValueNotifier<int>` 而不是让 UI 监听整个 Store：
  /// 旧代码（`library_page.dart`）依赖的是 `FavoriteStore.revision`，
  /// 保持这个语义可以让那 3 个调用点不用改。
  final ValueNotifier<int> revisionProxy = ValueNotifier<int>(0);

  SharedPreferences? _prefs;
  bool _inited = false;

  /// 任何变更后统一 bump 一次。
  ///
  /// 🔴 原来这里最后还有一行**无条件自递归** `_bump();` —— 于是任何音乐库变更
  /// 都会 `StackOverflowError`；而 `addRecent()` / `toggleFavorite()` 都是
  /// **先 `_bump()` 再 `_persist()`**，异常直接把方法中断 →
  /// **「最近播放」和「收藏」永远不落盘、重启就丢**。
  /// `init()` 里那次调用被 `catch (_)` 吞掉了，所以启动不崩、问题被掩盖。
  void _bump() {
    revisionProxy.value++;
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
      // 本地歌单（逐条容错：一条坏数据不该让整份歌单消失）
      _playlists.clear();
      final rawPlaylists = _prefs!.getString(_kPlaylists);
      if (rawPlaylists != null && rawPlaylists.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawPlaylists);
          if (decoded is List) {
            for (final e in decoded) {
              if (e is! Map) continue;
              final p = MusicPlaylist.fromJson(e.cast<String, dynamic>());
              if (p != null) _playlists.add(p);
            }
          }
        } catch (_) {
          /* 歌单读不出来就当没有，不影响播放 */
        }
      }
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

  // ============================================================
  // 本地歌单（歌单编辑）
  // ============================================================
  //
  // 全部用 `identityKey`（`source-key`）判重，与收藏/最近播放一致 ——
  // 否则"网易云的 123"和"酷狗的 123"会被当成同一首混进同一个歌单。

  MusicPlaylist? playlistById(String id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 新建歌单，返回它（UI 建完可以直接进去加歌）。
  Future<MusicPlaylist> createPlaylist(String name) async {
    await init();
    final n = name.trim();
    final p = MusicPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: n.isEmpty ? '新建歌单' : n,
    );
    _playlists.insert(0, p);
    _bump();
    await _persistPlaylists();
    return p;
  }

  Future<void> renamePlaylist(String id, String name) async {
    await init();
    final p = playlistById(id);
    if (p == null) return;
    final n = name.trim();
    if (n.isEmpty || n == p.name) return;
    p.name = n;
    _bump();
    await _persistPlaylists();
  }

  Future<void> deletePlaylist(String id) async {
    await init();
    final before = _playlists.length;
    _playlists.removeWhere((p) => p.id == id);
    if (_playlists.length == before) return;
    _bump();
    await _persistPlaylists();
  }

  /// 加歌进歌单。已在里面时**移到最前**（与"最近播放"同一语义，不重复）。
  Future<void> addToPlaylist(String id, Song song) async {
    await init();
    final p = playlistById(id);
    if (p == null) return;
    p.songs.removeWhere((s) => s.identityKey == song.identityKey);
    p.songs.insert(0, song);
    _bump();
    await _persistPlaylists();
  }

  Future<void> removeFromPlaylist(String id, Song song) async {
    await init();
    final p = playlistById(id);
    if (p == null) return;
    final before = p.songs.length;
    p.songs.removeWhere((s) => s.identityKey == song.identityKey);
    if (p.songs.length == before) return;
    _bump();
    await _persistPlaylists();
  }

  /// 这首歌已经在哪些歌单里（「添加到歌单」弹层给已有项打勾用）。
  List<String> playlistIdsContaining(Song song) => _playlists
      .where((p) => p.songs.any((s) => s.identityKey == song.identityKey))
      .map((p) => p.id)
      .toList();

  Future<void> _persistPlaylists() async {
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString(
        _kPlaylists,
        jsonEncode(_playlists.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      /* 忽略：持久化失败不该影响界面 */
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

/// 本地歌单（用户自己建的，**不需要账号**）。
///
/// 为什么放在这里而不是 `models.dart`：它是**纯本地**概念 ——
/// 不来自任何接口、只存本机，和 `Song`/`Artist` 那类接口模型不同源。
class MusicPlaylist {
  MusicPlaylist({required this.id, required this.name, List<Song>? songs})
      : songs = songs ?? [];

  /// 微秒时间戳字符串（本机唯一即可，不需要全局 id）
  final String id;
  String name;
  final List<Song> songs;

  int get length => songs.length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  /// 逐条容错：单首坏数据只丢那一首，不影响整个歌单。
  static MusicPlaylist? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final list = <Song>[];
    final raw = j['songs'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        try {
          list.add(Song.fromJson(e.cast<String, dynamic>()));
        } catch (_) {
          /* 跳过坏条目 */
        }
      }
    }
    return MusicPlaylist(
      id: id,
      name: (j['name'] ?? '未命名歌单').toString(),
      songs: list,
    );
  }
}
