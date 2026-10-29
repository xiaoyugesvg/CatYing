import 'package:rfw/rfw.dart';

enum RfwThemeActionKind {
  openItem,
  openRecommend,
  longPressItem,
  selectCategory,
  selectFilter,
  toggleFilters,
  showDisplayStylePicker,
  showFilterPicker,
  showNativeAppBar,
  showApiConfigPicker,
  refresh,
  showCategoryPicker,
  showSourcePicker,
  openSearch,
  navigateBack,
}

class RfwThemeAction {
  const RfwThemeAction(
    this.kind, {
    this.index = -1,
    this.typeId = '',
    this.key = '',
    this.value = '',
  });

  final RfwThemeActionKind kind;
  final int index;
  final String typeId;
  final String key;
  final String value;
}

RfwThemeAction? parseRfwThemeEvent(String name, DynamicMap args) {
  switch (name) {
    case 'openItem':
      final index = args['index'];
      if (index is! int || index < 0) return null;
      return RfwThemeAction(RfwThemeActionKind.openItem, index: index);
    case 'openRecommend':
      final index = args['index'];
      if (index is! int || index < 0) return null;
      return RfwThemeAction(RfwThemeActionKind.openRecommend, index: index);
    case 'longPressItem':
      final index = args['index'];
      if (index is! int || index < 0) return null;
      return RfwThemeAction(RfwThemeActionKind.longPressItem, index: index);
    case 'selectType':
      final typeId = args['typeId'];
      if (typeId is! String) return null;
      return RfwThemeAction(RfwThemeActionKind.selectCategory, typeId: typeId);
    case 'selectFilter':
      final key = args['key'];
      final value = args['value'];
      if (key is! String || value is! String) return null;
      return RfwThemeAction(
        RfwThemeActionKind.selectFilter,
        key: key,
        value: value,
      );
    case 'toggleFilters':
      return const RfwThemeAction(RfwThemeActionKind.toggleFilters);
    case 'showDisplayStylePicker':
      return const RfwThemeAction(RfwThemeActionKind.showDisplayStylePicker);
    case 'showFilterPicker':
      return const RfwThemeAction(RfwThemeActionKind.showFilterPicker);
    case 'showNativeAppBar':
      return const RfwThemeAction(RfwThemeActionKind.showNativeAppBar);
    case 'showApiConfigPicker':
      return const RfwThemeAction(RfwThemeActionKind.showApiConfigPicker);
    case 'refresh':
      return const RfwThemeAction(RfwThemeActionKind.refresh);
    case 'showCategoryPicker':
      return const RfwThemeAction(RfwThemeActionKind.showCategoryPicker);
    case 'showSourcePicker':
      return const RfwThemeAction(RfwThemeActionKind.showSourcePicker);
    case 'openSearch':
      return const RfwThemeAction(RfwThemeActionKind.openSearch);
    case 'navigateBack':
      return const RfwThemeAction(RfwThemeActionKind.navigateBack);
    default:
      return null;
  }
}
