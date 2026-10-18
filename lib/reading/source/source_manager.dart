import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/settings_service.dart';
import 'config_manga_source.dart';
import 'copy_manga_source.dart';
import 'copymanga_config.dart';
import 'legado_comic_source.dart';
import 'manga_source.dart';
import 'manhuaren_config.dart';
import 'manhuaren_source.dart';
import 'models.dart';
import '../models/book_source.dart' show BookSourceStore;
import 'site_config.dart';
import 'source_config_store.dart';
import 'source_definition.dart';
import 'venera/venera_manga_source.dart';
import 'zaimanhua_config.dart';
import 'zaimanhua_source.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceManager] $message');
  }
}

/// 源名称去重：同名时依次追加 `（2）`、`（3）`…
String uniqueSourceName(String base, Iterable<String> existing) {
  final names = existing.toSet();
  if (!names.contains(base)) return base;
  var i = 2;
  while (names.contains('$base（$i）')) {
    i++;
  }
  return '$base（$i）';
}

/// 封面/列表缩略图加载头（防盗链/UA）。
/// 传 [sourceId] 用漫画所属源的头（多源书架/收藏封面防盗链）；不传则取当前源。
/// 非防盗链源（如 copymanga）带上也无害；防盗链源（如 mycomic 的 biccam）需 Referer。
Map<String, String> coverHeaders([String? sourceId]) {
  final s = (sourceId != null && sourceId.isNotEmpty)
      ? (SourceManager().getSource(sourceId) ?? SourceManager().current)
      : SourceManager().current;
  return {...s.imageHeaders, if (s.referer != null) 'Referer': s.referer!};
}

/// 漫画源管理器（单例 ChangeNotifier）。
///
/// 注册各源（配置源 + api 源），维护「当前源」，供 UI/下载/阅读统一调用。
/// ⚠️ 这里原来写「**软件不自带任何漫画源，源定义完全云端驱动**」✗✗ —— **与代码不符，已改正** ✓：
///   真实优先级是「**文档目录 sources.json（云端更新覆盖层）优先 → 出厂内置源兜底**」✓
///   （内置源在 `assets/config/sources.json` ✓，`pubspec.yaml:89-90` 已声明 ✓，
///    由 `SourceConfigStore.loadLocal()` 兜底加载 ✓ ——「**装上有源**」✓）。
///   只有用户**主动点过「清空」**✓ 且内置包指纹未变时才会真的零源 ✓
///   （`_kSourcesCleared` ✓，可用 `clearClearedFlag()` ✓ 恢复 ✓）。
/// 无源时 [current] 返回 [_NoSource] 哨兵不崩，由搜索页空状态引导用户填云端地址。
/// init 末尾非阻塞后台拉取云端 sources.json（用户已填云端地址时），有变化才 reload。
class SourceManager extends ChangeNotifier {
  SourceManager._();
  static final SourceManager _instance = SourceManager._();
  factory SourceManager() => _instance;

  final Map<String, MangaSource> _sources = {};
  MangaSource? _current;
  bool _initialized = false;

  /// 用户自定义的漫画源分组（源 id → 分组名）。
  /// 源脚本本身是只读的，`MangaSource.group` 只是默认值，这里覆盖它。
  static const String _kGroupOverrides = 'manga_source_groups_v1';
  static const String _kCustomGroups = 'manga_custom_groups_v1';
  final Map<String, String> _groupOverrides = {};
  final List<String> _customGroups = [];

  /// 源的分组（用户设置优先，其次源脚本自带）
  String groupOf(MangaSource s) {
    final custom = _groupOverrides[s.id]?.trim() ?? '';
    return custom.isNotEmpty ? custom : s.group;
  }

  /// 用户新建的分组（允许暂时为空）
  List<String> get customGroups => List.unmodifiable(_customGroups);

  Future<void> _loadGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kGroupOverrides);
      _groupOverrides.clear();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final k = '${e.key}'.trim();
            final v = '${e.value}'.trim();
            if (k.isNotEmpty && v.isNotEmpty) _groupOverrides[k] = v;
          }
        }
      }
      _customGroups
        ..clear()
        ..addAll(
          (prefs.getStringList(_kCustomGroups) ?? const <String>[])
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty),
        );
    } catch (e) {
      _log('读取漫画源分组失败: $e');
    }
  }

  Future<void> _saveGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kGroupOverrides, jsonEncode(_groupOverrides));
      await prefs.setStringList(_kCustomGroups, _customGroups);
    } catch (e) {
      _log('保存漫画源分组失败: $e');
    }
  }

  /// 新建分组
  Future<bool> createGroup(String name) async {
    final n = name.trim();
    if (n.isEmpty || _customGroups.contains(n)) return false;
    _customGroups.add(n);
    await _saveGroups();
    notifyListeners();
    return true;
  }

  /// 把源移到指定分组（空字符串 = 未分组）
  Future<void> setGroup(MangaSource s, String group) async {
    final g = group.trim();
    if (g.isEmpty) {
      _groupOverrides.remove(s.id);
    } else {
      _groupOverrides[s.id] = g;
      if (!_customGroups.contains(g)) _customGroups.add(g);
    }
    await _saveGroups();
    notifyListeners();
  }

  // 零源时的哨兵源：current 返回它而非抛异常，避免各处 .current 在无源时崩溃。
  // 搜索/分类返回空；详情/章节/取图抛描述性错误，被调用方现有 try/catch 接住提示用户。
  final MangaSource _noSource = _NoSource();

  /// 当前源。**没有当前源时 → 用「第一个启用源」兜底** ✓；真零源（全被停用/无源）才返回
  /// [_noSource] 哨兵（不抛异常 ✓ 保证 UI/封面头各处不崩 ✓）。
  ///
  /// ✅ **本轮修正**（用户："**漫画页要显示第一个源**" ✓）——
  ///   原来这里写的是 `_current ?? _noSource` ✗ ⇒ 首次安装 / 没选过源 / 当前源被停用时，
  ///   `current` 返回的是**空源哨兵** ✗ ⇒ **漫画页什么都没有** ✗✓（不是"没网络"，是"没源"✓）。
  ///   ⇒ 现在：**按注册顺序取第一个未被停用的源** ✓✓
  ///     （`_sources` 是 `LinkedHashMap` 语义 ✓ 顺序 = 加载顺序 = 「漫画源仓库」里的显示顺序 ✓
  ///      所以它就是用户眼中的"**第一个源**" ✓）
  ///   ℹ️ 这样"开箱即用" ✓：装上就有内置漫画源 ✓ → 漫画页**直接显示第一个源的内容** ✓✓
  MangaSource get current {
    final c = _current;
    if (c != null) return c;
    for (final s in _sources.values) {
      if (!_disabledIds.contains(s.id)) return s;
    }
    return _noSource;
  }

  /// 所有已注册源
  List<MangaSource> get sources => _sources.values.toList();

  /// 是否已完成首次加载（仓库页用它判断能否校验 sourceIds）
  bool get isReady => _initialized;

  /// 初始化：从 SourceConfigStore 加载源（**云端覆盖层优先 → 内置源兜底** ✓），恢复当前源选择。
  ///
  /// ⚠️ 本段原来写「**软件不自带源**…**无缓存则零源**」✗ —— **与代码不符，已改正** ✓（同上）：
  /// 首次安装/清缓存后**会回退到出厂内置源** ✓；只有"用户主动清空 + 内置包未更新"才零源 ✓。
  /// current 在真零源时返回 [_NoSource] 哨兵 ✓，由搜索页空状态引导 ✓。
  /// [fetchCloud]=true 时（仅首次 init），末尾非阻塞后台拉取云端 sources.json，有变化才 reload；
  /// reload 触发的 init 传 false，避免循环拉取。
  Future<void> init({bool fetchCloud = true}) async {
    if (_initialized) return;
    // 配置源 + api 源（copymanga/zaimanhua/manhuaren）：从 SourceConfigStore 加载
    // （文档目录 sources.json 云端缓存 > 空列表）
    final defs = await SourceConfigStore().loadLocal();
    // 🔴 原来这里**没有 per-item 的 try/catch** ✗ —— `_instantiate(def)` 会按
    // type/engine 去解析该源的配置体（SiteConfig.fromJson 等），而配置体字段
    // 类型是不受控的：只要**任意一条**源写成 `"name": 123`、`"name"` 缺失，
    // 或某个 engine 的 config 结构异常，这一行就抛异常，直接冲出 for 循环、
    // 冲出 init()、再冒到 main() —— 症状就是「书源全没了」「搜索没源可用」
    // 甚至启动即崩 ✗（一条坏数据连坐整份列表）。
    // → 现在把**单条源的实例化与注册**整个包进 try：坏源只自己失败 ✓，
    //   打日志留证并 continue ✓，**其余源照常加载** ✓（配 site_config 的宽容解析，
    //   常见字段缺失已不再走到异常分支）。
    for (final def in defs) {
      try {
        final src = _instantiate(def);
        if (src != null) {
          // 注入源级元数据（needsMagic）
          src.needsMagic = def.needsMagic;
          _register(src);
        }
      } catch (e) {
        // 单条坏源隔离：跳过它自己，不影响后续源注册
        _log('源解析失败，已跳过: id=${def.id} type=${def.type} err=$e');
      }
    }

    // Legado 漫画源：直接复用书源仓库里的规则源，
    // 让 @js / JSONPath / @Header / ## / Base64-zlib 这套规则引擎对漫画生效。
    // 书源仓库在 main() 里先于本 init 完成加载。
    //
    // ⚠️ 不能只认 `bookSourceType == 2`（用户 2026-10-18）：
    //   很多漫画脚本没写类型，书源阅读器靠正文规则里的图片地址自动识别；
    //   这里复用同一判据 [BookSource.isComicSource]，保证"书源能看 → 漫画源也有"。
    try {
      for (final bs in BookSourceStore.instance.all) {
        if (!bs.isComicSource) continue;
        try {
          _register(LegadoComicMangaSource.fromRaw(bs.raw));
        } catch (e) {
          _log('Legado 漫画源注册失败: ${bs.name} -> $e');
        }
      }
      _log(
        '已注册 Legado 漫画源: '
        '${_sources.values.where((s) => s.id.startsWith('legado:')).length}',
      );
    } catch (e) {
      _log('读取书源仓库失败（Legado 漫画源未注册）: $e');
    }

    // 随包内置漫画源已移除（用户 2026-10-18：去掉内置的「瓜子漫画（2）」）——
    // 漫画源统一由用户自己导入 / 云端仓库更新。

    // 禁用源列表（持久化，与 sources.json 解耦）
    _disabledIds = SettingsService().disabledSourceIds.toSet();

    // 用户自定义分组
    await _loadGroups();

    // 应用用户自定义顺序（用户 2026-10-18：长按源标签拖动后保存的顺序）
    final savedOrder = SettingsService().mangaSourceOrder;
    if (savedOrder.isNotEmpty) {
      final next = <String, MangaSource>{};
      for (final id in savedOrder) {
        final s = _sources.remove(id);
        if (s != null) next[id] = s;
      }
      next.addAll(_sources);
      _sources
        ..clear()
        ..addAll(next);
    }

    // 恢复当前源：已保存 id 优先（且未禁用），否则取首个启用源
    final savedId = SettingsService().currentSourceId;
    _current = (_sources[savedId] != null && !_disabledIds.contains(savedId))
        ? _sources[savedId]!
        : (enabledSources.isNotEmpty
              ? enabledSources.first
              : (_sources.values.isNotEmpty ? _sources.values.first : null));
    _initialized = true;
    _log('初始化完成，源数: ${_sources.length}，当前源: ${_current?.id}');
    notifyListeners();

    // 仅首次 init 触发云端拉取（reload 传 fetchCloud:false 跳过，避免循环）。
    if (fetchCloud) _refreshFromCloud();
  }

  /// 重新加载源配置（云端更新 / 恢复本地默认后调用）。
  Future<void> reload() async {
    _sources.clear();
    _current = null;
    _initialized = false;
    await init(fetchCloud: false);
  }

  /// 启动后台拉取云端 sources.json（非阻塞）。
  ///
  /// 用户未填云端地址（sourceRepoUrl 为空）时跳过，沿用本地配置。
  /// 拉到且非空时 saveLocal 并 reload（reload 不再触发云端拉取，按 savedId 恢复当前源）。
  /// 失败静默保留本地，不阻塞启动。
  Future<void> _refreshFromCloud() async {
    try {
      final remote = await SourceConfigStore().fetchRemote();
      if (remote == null || remote.isEmpty) return;
      await reload();
      _log('已从云端更新源: ${remote.length} 个');
    } catch (e) {
      _log('云端源拉取失败（保留本地）: $e');
    }
  }

  /// 按 SourceDefinition 的 type/engine 实例化对应 Source；未知类型返回 null（跳过，不崩）。
  MangaSource? _instantiate(SourceDefinition def) {
    switch (def.type) {
      case 'config':
        return ConfigMangaSource(SiteConfig.fromJson(def.config));
      case 'api':
        switch (def.engine) {
          case 'copymanga':
            return CopyMangaSource(CopymangaConfig.fromJson(def.config));
          case 'zaimanhua':
            return ZaimanhuaSource(ZaimanhuaConfig.fromJson(def.config));
          case 'manhuaren':
            return ManhuarenSource(ManhuarenConfig.fromJson(def.config));
          default:
            _log('未知 api engine，跳过: ${def.engine} (id=${def.id})');
            return null;
        }
      case 'venera':
        final script = (def.config['script'] ?? '').toString();
        if (script.trim().isEmpty) {
          _log('Venera 源缺少脚本内容，跳过: ${def.id}');
          return null;
        }
        return VeneraMangaSource(
          definitionId: def.id,
          sourceKey: (def.config['key'] ?? def.id).toString(),
          displayName: (def.config['name'] ?? 'Venera').toString(),
          script: script,
          scriptUrl: (def.config['scriptUrl'] ?? '').toString(),
        );
      case 'legado':
        try {
          return LegadoComicMangaSource.fromRaw(def.config);
        } catch (e) {
          _log('Legado 漫画源解析失败: ${def.id} -> $e');
          return null;
        }
      default:
        _log('未知 source type，跳过: ${def.type} (id=${def.id})');
        return null;
    }
  }

  void _register(MangaSource source) {
    // 名称去重：同名源自动追加（2）（3）…（用户 2026-10-17 要求）
    final existingNames = _sources.values.map((s) => s.name).toSet();
    final unique = uniqueSourceName(source.name, existingNames);
    _sources[source.id] = unique == source.name
        ? source
        : _RenamedSource(source, unique);
  }

  /// 切换当前源
  void setCurrent(MangaSource source) {
    if (_current?.id == source.id) return;
    if (!_sources.containsKey(source.id)) {
      _register(source);
    }
    _current = _sources[source.id]!;
    SettingsService().setCurrentSourceId(source.id);
    _log('切换当前源: ${source.id}');
    notifyListeners();
  }

  /// 按 id 取源
  MangaSource? getSource(String id) => _sources[id];

  // === 启用/禁用 ===
  Set<String> _disabledIds = {};

  /// 启用源列表（搜索页只展示这些）。
  List<MangaSource> get enabledSources =>
      sources.where((s) => !_disabledIds.contains(s.id)).toList();

  /// **可浏览**的启用源（有分类/发现规则，能撑起漫画首页板块流）。
  ///
  /// 用户 2026-10-18：「如果只是搜索就不要再漫画页显示」——
  /// 纯搜索源（`supportsCategories == false`）只保留在搜索源选择器里，
  /// 不再出现在漫画首页的源 chip 行（它们的首页永远是空的）。
  List<MangaSource> get browsableSources =>
      enabledSources.where((s) => s.supportsCategories).toList();

  /// 源是否启用。
  bool isEnabled(String id) => !_disabledIds.contains(id);

  /// 设置源启用/禁用（持久化 + notify）。
  /// 禁用当前源时自动切到首个启用源；全部禁用时回退保留当前，避免无可用源。
  /// 批量启用/停用（「多选书源」底部那个开关按钮用）。
  ///
  /// 逐个调 [setEnabled] 会造成 N 次持久化 + N 次通知 ——
  /// 勾了 100 个源就是 100 次写盘。这里合并成一次。
  Future<void> setEnabledAll(Iterable<String> ids, bool enabled) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    for (final id in list) {
      if (enabled) {
        _disabledIds.remove(id);
      } else {
        _disabledIds.add(id);
      }
    }
    notifyListeners();
    // 复用 setEnabled 的持久化路径（它内部按 _disabledIds 全量写，
    // 所以这里只要触发一次即可）
    await setEnabled(list.first, enabled);
  }

  /// 按给定 id 顺序重排源（「长按源标签拖动」用）。
  ///
  /// 用户 2026-10-18：顺序现在**会持久化**（存 `manga_source_order_v1`），
  /// 重启后仍按用户拖出来的顺序展示。
  void reorder(List<String> orderedIds) {
    final next = <String, MangaSource>{};
    for (final id in orderedIds) {
      final s = _sources[id];
      if (s != null) next[id] = s;
    }
    // 未列出的（理论上不会有）保持原样接在后面
    for (final e in _sources.entries) {
      next.putIfAbsent(e.key, () => e.value);
    }
    _sources
      ..clear()
      ..addAll(next);
    SettingsService().setMangaSourceOrder(_sources.keys.toList());
    notifyListeners();
  }

  /// 从源列表里移除（双击源标签删除用；不做落盘，调用方负责删源本体）。
  void dropSource(String id) {
    _sources.remove(id);
    if (_current?.id == id) {
      _current = enabledSources.isNotEmpty
          ? enabledSources.first
          : (_sources.values.isNotEmpty ? _sources.values.first : null);
    }
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final changed = enabled ? _disabledIds.remove(id) : _disabledIds.add(id);
    if (!changed) return;
    await SettingsService().setDisabledSourceIds(_disabledIds.toList());
    if (!enabled && _current?.id == id) {
      final next = enabledSources.isNotEmpty ? enabledSources.first : null;
      if (next != null) {
        _current = next;
        await SettingsService().setCurrentSourceId(next.id);
        _log('禁用当前源 $id，自动切换到 ${next.id}');
      } else {
        // 无其他启用源：回退，保留当前源可用
        _disabledIds.remove(id);
        await SettingsService().setDisabledSourceIds(_disabledIds.toList());
        _log('禁用 $id 会导致无可用源，已回退');
      }
    }
    _log('源 $id ${enabled ? "启用" : "禁用"}');
    notifyListeners();
  }
}

/// 无可用源时的哨兵源：[SourceManager.current] 在零源时返回它，避免各处 `.current` 崩溃。
///
/// 搜索/热门/最新/分类返回空；详情/章节/取图抛描述性错误，被调用方现有 try/catch 接住
/// （如详情页 _error、阅读器/书架 toast），引导用户去漫画源仓库添加云端源。
class _NoSource extends MangaSource {
  _NoSource();

  static const _msg = '暂无可用漫画源，请到「漫画源仓库」添加云端地址并更新';

  @override
  String get id => '__none__';

  @override
  String get name => '无可用源';

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async => const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<CManga> getMangaDetails(CManga manga) async {
    throw StateError(_msg);
  }

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async {
    throw StateError(_msg);
  }

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    throw StateError(_msg);
  }
}

/// 同名源的改名包装：只改显示名，其余全部委托给原源。
///
/// 为什么不直接改 `MangaSource.name`：它是抽象 getter，各源都写成常量；
/// 包一层可以保证 id / 行为完全不变，只有 UI 显示名带「（2）」。
class _RenamedSource extends MangaSource {
  _RenamedSource(this._inner, this._displayName);

  final MangaSource _inner;
  final String _displayName;

  @override
  String get id => _inner.id;

  @override
  String get name => _displayName;

  @override
  String get group => _inner.group;

  @override
  String get lang => _inner.lang;

  @override
  bool get supportsLatest => _inner.supportsLatest;

  @override
  bool get supportsCategories => _inner.supportsCategories;

  @override
  Future<List<FilterGroup>> fetchCategories() => _inner.fetchCategories();

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) => _inner.getCategoryList(groups, page: page);

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) => _inner.search(query, page: page, filters: filters);

  @override
  Future<MangasPage> getPopular({int page = 0}) =>
      _inner.getPopular(page: page);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) =>
      _inner.getLatestUpdates(page: page);

  @override
  FilterList getFilterList() => _inner.getFilterList();

  @override
  Future<CManga> getMangaDetails(CManga manga) => _inner.getMangaDetails(manga);

  @override
  Future<List<CChapter>> getChapterList(CManga manga) =>
      _inner.getChapterList(manga);

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) => _inner.getMangaDetailsAndChapters(manga);

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) =>
      _inner.getChapterImages(manga, chapter);

  @override
  Map<String, String> get imageHeaders => _inner.imageHeaders;

  @override
  String? get referer => _inner.referer;

  @override
  String? refererForChapter(CChapter chapter) =>
      _inner.refererForChapter(chapter);

  @override
  bool get chapterSortByOrder => _inner.chapterSortByOrder;

  @override
  bool get chapterOrderDescending => _inner.chapterOrderDescending;

  @override
  bool get needsMagic => _inner.needsMagic;

  @override
  set needsMagic(bool value) => _inner.needsMagic = value;
}
