import 'package:flutter/material.dart';
import 'package:rfw/formats.dart' show parseDataFile;
import 'package:rfw/rfw.dart';

import '../../services/app_log.dart';
import '../../services/rfw_theme_service.dart';
import 'peek_home_widgets.dart';

/// 自定义首页主题的渲染器。
///
/// 用法：把首页数据（影片列表/分类/筛选/推荐）交给它，它按当前 `.rfwtxt`
/// 主题描述渲染内容区。
///
/// 渲染失败的兜底很重要：主题是纯文本、可被用户随意编辑，语法/字段错误很常见。
/// 这里任何异常都回落到 [fallback]，避免整页白屏。
class RfwHomeView extends StatefulWidget {
  /// 主题文本
  final String themeSource;

  /// `data.home` 的内容（用 [RfwDataContract.build] 生成）
  final Map<String, Object?> data;

  /// 事件回调：name 是主题里 `event "openItem" {...}` 的名字
  final void Function(String name, DynamicMap arguments) onEvent;

  /// 主题渲染不了时的兜底 UI（通常是原生首页）
  final Widget fallback;

  const RfwHomeView({
    super.key,
    required this.themeSource,
    required this.data,
    required this.onEvent,
    required this.fallback,
  });

  @override
  State<RfwHomeView> createState() => _RfwHomeViewState();
}

class _RfwHomeViewState extends State<RfwHomeView> {
  static const LibraryName _coreName = LibraryName(<String>['core', 'widgets']);
  static const LibraryName _materialName = LibraryName(<String>['material']);
  static const LibraryName _themeName = LibraryName(<String>['theme']);

  final Runtime _runtime = Runtime();
  final DynamicContent _content = DynamicContent();

  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rebuildRuntime();
  }

  @override
  void didUpdateWidget(covariant RfwHomeView old) {
    super.didUpdateWidget(old);
    if (old.themeSource != widget.themeSource) {
      _rebuildRuntime();
    }
    if (!identical(old.data, widget.data)) {
      _pushData();
    }
  }

  /// 重建组件库（主题文本变化时）
  void _rebuildRuntime() {
    try {
      // rfw 自带的 core / material 组件库必须先注册，
      // 否则主题里的 Container / Row / Text 等全部解析不到。
      _runtime.update(_coreName, createCoreWidgets());
      _runtime.update(_materialName, createMaterialWidgets());
      // 自建的 peek.home 组件库
      _runtime.update(PeekHomeWidgets.libraryName, PeekHomeWidgets.create());

      final lib = RfwThemeService.instance.parse(widget.themeSource);
      if (lib == null) {
        setState(() {
          _ready = false;
          _error = RfwThemeService.instance.lastError.value;
        });
        return;
      }
      _runtime.update(_themeName, lib);
      _pushData();
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (e, st) {
      AppLog.instance.log('[RfwHome] 运行时构建失败: $e\n$st');
      setState(() {
        _ready = false;
        _error = '$e';
      });
    }
  }

  /// 把 Dart 数据推给 rfw。
  ///
  /// ⚠️ [RfwDataContract.build] 已做递归净化（剔除 null、只留 rfw 支持的
  /// 类型），因为 rfw 的 `_hasValidType` 不接受 null，而 spider 数据里
  /// null 很常见 —— 不净化会在 debug 触发 assert。
  void _pushData() {
    try {
      _content.update('home', widget.data);
    } catch (e, st) {
      AppLog.instance.log('[RfwHome] 数据推送失败: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      // 主题坏了就用原生首页，不让用户看到白屏
      return widget.fallback;
    }
    return RemoteWidget(
      runtime: _runtime,
      data: _content,
      widget: const FullyQualifiedWidgetName(_themeName, 'root'),
      onEvent: (String name, DynamicMap arguments) {
        widget.onEvent(name, arguments);
      },
    );
  }
}

/// `data.home.*` 数据契约。
///
/// 键名不是猜的：从 PeekPro 的 15 套模板里统计出来（`data.home.xxx` 共 27 个键、
/// `args.item.xxx` 共 13 个字段），按使用频次补齐。
class RfwDataContract {
  RfwDataContract._();

  /// 构建完整的 `data.home` 负载。
  ///
  /// [items] 每个元素会被补上主题需要的派生字段（index / indexLabel /
  /// rankLabel / selected 等），调用方只需给出基础字段。
  static Map<String, Object?> build({
    required List<Map<String, Object?>> items,
    List<Map<String, Object?>> recommend = const [],
    List<Map<String, Object?>> classes = const [],
    List<Map<String, Object?>> filters = const [],
    String source = '',
    String displayStyle = 'grid',
    int gridColumns = 3,
    bool loading = false,
    String errorMessage = '',
    bool isLandscape = false,
    String selectedTypeId = '',
    bool showFilters = false,
    String immersiveImageUrl = '',
    int immersivePrimaryColor = 0xFF0E1116,
    int immersiveSecondaryColor = 0xFF1B2230,
    int immersiveBackgroundColor = 0xFF0E1116,
  }) {
    // 给每个 item 补派生字段
    final normalizedItems = <Map<String, Object?>>[];
    for (var i = 0; i < items.length; i++) {
      final raw = Map<String, Object?>.from(items[i]);
      raw['index'] = i;
      raw['indexLabel'] = '${i + 1}';
      raw['rankLabel'] = '${i + 1}';
      raw['typeName'] = raw['typeName'] ?? '';
      raw['titleLogo'] = raw['titleLogo'] ?? '';
      raw['year'] = raw['year'] ?? '';
      raw['remarks'] = raw['remarks'] ?? '';
      raw['pic'] = raw['pic'] ?? '';
      raw['name'] = raw['name'] ?? '';
      normalizedItems.add(raw);
    }

    // 分类：标记选中态（主题用 args.item.selected 高亮）
    final normalizedClasses = <Map<String, Object?>>[];
    for (final c in classes) {
      final m = Map<String, Object?>.from(c);
      final id = '${m['typeId'] ?? ''}';
      m['selected'] = id.isNotEmpty && id == selectedTypeId;
      m['typeName'] = m['typeName'] ?? m['name'] ?? '';
      normalizedClasses.add(m);
    }

    // 筛选组：每个 option 补 selected
    final normalizedFilters = <Map<String, Object?>>[];
    for (final g in filters) {
      final m = Map<String, Object?>.from(g);
      final opts = (m['options'] as List?) ?? const [];
      final selectedValue = '${m['selected'] ?? ''}';
      m['options'] = opts.map((o) {
        final om = Map<String, Object?>.from(o as Map);
        om['selected'] = '${om['value'] ?? ''}' == selectedValue;
        om['filterKey'] = om['filterKey'] ?? m['key'] ?? '';
        return om;
      }).toList();
      normalizedFilters.add(m);
    }

    final home = <String, Object?>{
      // ---- 布局 ----
      'displayStyle': displayStyle,
      'gridColumns': gridColumns,
      'largeGridColumns': 2,
      'bannerColumns': 1,
      'wideListRatio': 2.4,
      'textListRatio': 5.0,
      'stickyHeaderHeight': 0.0,
      'immersiveStickyHeaderHeight': 0.0,
      'filterPanelHeight': 0.0,
      'immersiveFilterPanelHeight': 0.0,
      'heroHeight': 0.0,
      'isLandscape': isLandscape,
      // ---- 状态 ----
      'loading': loading,
      'errorMessage': errorMessage,
      'canNavigateBack': false,
      'source': source,
      'totalLabel': items.isEmpty ? '' : '共 ${items.length} 部',
      // ---- 数据 ----
      'items': normalizedItems,
      'classes': normalizedClasses,
      'filters': normalizedFilters,
      'hasFilters': normalizedFilters.isNotEmpty,
      'showFilters': showFilters,
      'hasManyClasses': normalizedClasses.length > 8,
      // 主题读取推荐位用的是 data.home.home.recommend（两层 home）
      'hasRecommend': recommend.isNotEmpty,
      'home': <String, Object?>{
        'recommend': recommend,
      },
      // 沉浸式主题用
      'immersive': <String, Object?>{
        'imageUrl': immersiveImageUrl,
        'primaryColor': immersivePrimaryColor,
        'secondaryColor': immersiveSecondaryColor,
        'backgroundColor': immersiveBackgroundColor,
      },
      // ---- 图标名（模板里 data.home.icons.xxx 高频使用）----
      'icons': _icons,
    };

    return RfwThemeService.sanitizeForRfw(home) as Map<String, Object?>;
  }

  /// Material 图标名 → Flutter IconData。
  ///
  /// 主题里以字符串给出图标名（`args.icon` 常是 `data.home.icons.search`），
  /// 这里映射成 codepoint。只收录模板实际用到的，避免引入全量图标表。
  static const Map<String, Object?> _icons = <String, Object?>{
    'search': 0xe8b6,
    'refresh': 0xe5d5,
    'history': 0xe889,
    'favorite': 0xe87d,
    'favoriteBorder': 0xe87e,
    'settings': 0xe8b8,
    'home': 0xe88a,
    'liveTv': 0xe639,
    'cast': 0xe307,
    'filterList': 0xe3ef,
    'gridView': 0xe3ec,
    'viewList': 0xe8ef,
    'sort': 0xe164,
    'arrowBack': 0xe5c4,
    'close': 0xe5cd,
    'moreHoriz': 0xe5d3,
    'playArrow': 0xe037,
    'pushPin': 0xe3f3,
    'apps': 0xe5c3,
    'tune': 0xe429,
  };
}

/// 把 `parseDataFile` 暴露给需要自定义数据格式的高级用法
DynamicMap parseRfwData(String text) => parseDataFile(text);
