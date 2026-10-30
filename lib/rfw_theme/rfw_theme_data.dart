import 'package:flutter/material.dart';

import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/rfw_theme/rfw_theme_palette.dart';

/// 构造 RFW 主题的 `data.home` 输入。
///
/// ⚠️ 作用域限定：**只服务影视模块的首页**（见 rfw_theme_store.dart 的说明）。
/// 主题文件里 `data.home.xxx` 的每个字段都由这里喂进去；
/// 想给主题加新字段，先在这里加，再去 `.rfwtxt` 里用。
class RfwHomeDataInput {
  const RfwHomeDataInput({
    required this.categories,
    required this.category,
    required this.items,
    required this.recommend,
    required this.filters,
    required this.selectedFilters,
    this.displayStyle = 'grid',
    this.showFilters = false,
    this.loading = false,
    this.errorMessage = '',
    this.totalLabel = '',
    this.sourceName = '',
    this.screenWidth = 390,
    this.gridColumns = 3,
    this.largeGridColumns = 2,
    this.bannerColumns = 1,
    this.isLandscape = false,
    this.canNavigateBack = false,
    this.themeId,
  });

  /// 分类（影视源的 type 列表）
  final List<SortData> categories;

  /// 当前选中的分类 id
  final String category;

  /// 当前分类的片单
  final List<Video> items;

  /// 轮播/推荐位
  final List<Video> recommend;

  /// 当前分类的筛选项组
  final List<SortFilter> filters;

  /// 已选筛选项（key → value）
  final Map<String, String> selectedFilters;

  /// grid / largeGrid / banner / list / list2 / textList / card
  final String displayStyle;
  final bool showFilters;
  final bool loading;
  final String errorMessage;
  final String totalLabel;
  final String sourceName;
  final double screenWidth;
  final int gridColumns;
  final int largeGridColumns;
  final int bannerColumns;
  final bool isLandscape;
  final bool canNavigateBack;

  /// 当前 RFW 主题 id（`chenguang` / `suyu` / `xinghe`，自定义主题为文件名）。
  ///
  /// 只影响**色调倾向**（见 [RfwThemePalette.of]），不影响数据内容。
  final String? themeId;
}

/// 把首页状态压成 RFW 主题能吃的 `Map`。
Map<String, Object?> buildRfwHomeData(RfwHomeDataInput input) {
  final width = input.screenWidth > 0 ? input.screenWidth : 390.0;
  // ── 吸顶头高度必须按**实际内容**算，不能拍脑袋（2026-10-30）──────────
  //
  // 用户截图里顶栏按钮显示成 `?`、分类行被压掉一截，两个问题同源：
  //   · 图标：DSL 写成了 `Icon(icon: args.icon)`，把整个 map 塞进了
  //     `iconData` 解码器读的 `icon` 键 ⇒ 取不到 int ⇒ 回落
  //     `Icons.flutter_dash`（豆腐块）。改成 `icon:` + `fontFamily:` 两段。
  //   · 高度：原来写死 84。实测 Header 内容 = 工具行 32 + 间距 8 +
  //     分类行 33 = 73，加 padding 上 12 / 下 4 = **89** ⇒ 84 差 5px，
  //     RenderFlex 直接报 overflow，分类行底部被裁。
  //     这里给到 96，留 7px 余量扛住系统字号放大。
  //
  // 筛选面板同理：原来按每组 40 算，实际每组 = padding 8 + 组名 17 +
  // 间距 6 + 胶囊 27 + 下边距 8 = **66**。差 26/组，展开筛选时必然溢出。
  const headerBase = 96.0;
  const filterGroupHeight = 66.0;
  final filterPanelHeight = input.filters.isEmpty
      ? 0.0
      : input.filters.length * filterGroupHeight + 12.0;
  final stickyHeaderHeight =
      headerBase + (input.showFilters ? filterPanelHeight : 0.0);
  final recommend = input.recommend
      .asMap()
      .entries
      .map((entry) => _itemMap(entry.key, entry.value))
      .toList();
  final firstCover = recommend.isNotEmpty
      ? recommend.first['pic'] as String? ?? ''
      : input.items.isNotEmpty
          ? input.items.first.pic
          : '';
  final palette = RfwThemePalette.of(input.themeId);
  return <String, Object?>{
    // 色板：`.rfwtxt` 里所有颜色都必须从这里取，不许写死字面量。
    // 详见 rfw_theme_palette.dart 顶部的说明（2026-10-30「不贴合软件界面」）。
    'theme': palette.toData(),

    // ⚠️ 图标必须带 `fontFamily`，不能只传 codePoint（2026-10-30）。
    //
    // RFW 的 `iconData` 解码器是按 `{ icon: <码点>, fontFamily: <字体名> }`
    // 两段取值的：只给码点 → `IconData(codePoint)` 的 fontFamily 为 null →
    // 用默认字体找字形 → 找不到就画成「?」豆腐块。
    // 之前这里只传了 `Icons.xxx.codePoint`，于是主题里所有图标
    // （搜索 / 刷新 / 筛选 / 布局 …）在首页全变成一排「?」，
    // 用户看到的就是「这个 RFW 主题没有贴合我的软件界面」。
    //
    // Material 图标的字体名固定是 `MaterialIcons`（见 rfw 的文档注释）。
    'icons': <String, Object?>{
      for (final e in <String, IconData>{
        'expand': Icons.keyboard_arrow_down,
        'refresh': Icons.refresh,
        'filter': Icons.filter_list,
        'layout': Icons.grid_view,
        'topBar': Icons.tune,
        'open': Icons.open_in_new,
        'back': Icons.arrow_back,
        'search': Icons.search,
        // 换源（2026-10-30）：主题的顶栏要能把「换源」放进功能按钮那一排，
        // 而不是在分组标题右边挂一个文字链接（用户：「换源也要在那个按钮边上」）。
        'source': Icons.swap_horiz,
      }.entries)
        e.key: <String, Object?>{
          'icon': e.value.codePoint,
          'fontFamily': e.value.fontFamily ?? 'MaterialIcons',
        },
    },
    'displayStyle': input.displayStyle,
    'gridColumns': input.gridColumns,
    'largeGridColumns': input.largeGridColumns,
    'bannerColumns': input.bannerColumns,
    'wideListRatio': width / 128.0,
    'textListRatio': width / 52.0,
    'showFilters': input.showFilters,
    'hasRecommend': recommend.isNotEmpty,
    'hasManyClasses': input.categories.length > 6,
    'hasFilters': input.filters.isNotEmpty,
    'errorMessage': input.errorMessage,
    'items': input.items
        .asMap()
        .entries
        .map((entry) => _itemMap(entry.key, entry.value))
        .toList(),
    'classes': input.categories
        .map(
          (category) => <String, Object?>{
            'typeId': category.id,
            'typeName': category.name,
            'selected': category.id == input.category,
          },
        )
        .toList(),
    'filters': input.filters
        .map(
          (group) => <String, Object?>{
            'key': group.key,
            'name': group.name,
            'canExpand': group.values.length > 6,
            'options': <Object?>[
              <String, Object?>{
                'filterKey': group.key,
                'value': '',
                'name': '全部',
                'selected': (input.selectedFilters[group.key] ?? '').isEmpty,
              },
              ...group.values.map(
                (option) => <String, Object?>{
                  'filterKey': group.key,
                  'value': option.v,
                  'name': option.n,
                  'selected': input.selectedFilters[group.key] == option.v,
                },
              ),
            ],
          },
        )
        .toList(),
    'home': <String, Object?>{'recommend': recommend},
    'stickyHeaderHeight': stickyHeaderHeight,
    'filterPanelHeight': filterPanelHeight,
    'loading': input.loading,
    'source': input.sourceName,
    'totalLabel': input.totalLabel,
    // 轮播高度按主题给：星河是"沉浸看片"皮肤，大图才有影院感；
    // 晨光/素影用中等高度，把首屏留给网格/列表本身。
    'heroHeight': recommend.isEmpty
        ? 0.0
        : (input.themeId == 'xinghe' ? 190.0 : 150.0),
    'immersive': <String, Object?>{
      'imageUrl': firstCover,
      // 沉浸头渐变也走色板：之前写死 `#8A7CFF`（紫），
      // 换到「碧青」「蕉红」等配色时这块紫就跟整页打架。
      'primaryColor': palette.accent.toARGB32(),
      'secondaryColor': palette.card.toARGB32(),
      'backgroundColor': palette.bg.toARGB32(),
    },
    'canNavigateBack': input.canNavigateBack,
    'isLandscape': input.isLandscape,
  };
}

Map<String, Object?> _itemMap(int index, Video video) {
  final remarks = video.note.isNotEmpty
      ? video.note
      : (video.type.isNotEmpty ? video.type : video.year);
  return <String, Object?>{
    'index': index,
    'name': video.name,
    'pic': video.pic,
    'remarks': remarks,
    'selected': false,
    'rankLabel': '${index + 1}',
    'typeName': video.type,
    'typeId': video.tid,
    'year': video.year,
    'indexLabel': '${index + 1}',
    'style': '',
    'titleLogo': '',
    'vodTag': '',
  };
}
