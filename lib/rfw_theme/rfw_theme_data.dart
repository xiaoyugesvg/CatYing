import 'package:flutter/material.dart';

import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';

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
}

/// 把首页状态压成 RFW 主题能吃的 `Map`。
Map<String, Object?> buildRfwHomeData(RfwHomeDataInput input) {
  final width = input.screenWidth > 0 ? input.screenWidth : 390.0;
  final filterPanelHeight =
      input.filters.isEmpty ? 0.0 : input.filters.length * 40.0 + 12.0;
  final stickyHeaderHeight = 84.0 + (input.showFilters ? filterPanelHeight : 0.0);
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
  return <String, Object?>{
    'icons': <String, Object?>{
      'expand': Icons.keyboard_arrow_down.codePoint,
      'refresh': Icons.refresh.codePoint,
      'filter': Icons.filter_list.codePoint,
      'layout': Icons.grid_view.codePoint,
      'topBar': Icons.tune.codePoint,
      'open': Icons.open_in_new.codePoint,
      'back': Icons.arrow_back.codePoint,
      'search': Icons.search.codePoint,
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
    'heroHeight': recommend.isEmpty ? 0.0 : 150.0,
    'immersive': <String, Object?>{
      'imageUrl': firstCover,
      // 首页沉浸头的渐变：跟主题自身配色一致（主题里可覆盖）
      'primaryColor': 0xFF8A7CFF,
      'secondaryColor': 0xFF4A3A8A,
      'backgroundColor': 0xFF0D0D19,
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
