import 'package:get/get.dart';

/// 「史藏」页（播放历史 + 我的收藏）共享的编辑模式状态。
///
/// 为什么单独抽一个控制器：
/// 合并页是父 widget，网格子页是子 widget；编辑模式的「是否编辑 / 选中了哪些」
/// 需要跨越父子两层。用 GetxController 比通过构造函数层层透传更干净，
/// 也顺带解决了"切 tab 后选中态要保留"的问题。
class ShelfController extends GetxController {
  static ShelfController get instance {
    if (!Get.isRegistered<ShelfController>()) {
      Get.put<ShelfController>(ShelfController(), permanent: true);
    }
    return Get.find<ShelfController>();
  }

  /// 当前 tab：0 = 历史，1 = 收藏
  final tab = 0.obs;

  /// 是否处于编辑模式
  final editing = false.obs;

  /// 已选中的项（key = "<source>|<vodId>"，避免历史与收藏同名冲突）
  final selected = <String>{}.obs;

  /// 当前 tab 的搜索词。
  ///
  /// **刻意放在这里而不是 PlayerPrefs**：原来历史/收藏各有一个独立的
  /// keyword，两个子页同时存在于 IndexedStack 里 → 搜索会同时命中两边。
  /// 现在全页只有一个搜索框、一个词，且 [switchTab] 时清空。
  final keyword = ''.obs;

  /// 搜索框是否展开
  final searching = false.obs;

  /// 收藏排序：0 时间倒序 / 1 时间正序 / 2 名称
  final favSort = 0.obs;

  static String keyOf(String source, String vodId) => '$source|$vodId';

  /// 切 tab：**清空搜索与选中**，避免上一条 tab 的状态污染
  void switchTab(int v) {
    if (tab.value == v) return;
    tab.value = v;
    keyword.value = '';
    exitEdit();
  }

  void setKeyword(String v) => keyword.value = v.trim();

  void toggleSearching() {
    searching.value = !searching.value;
    if (!searching.value) keyword.value = '';
  }

  void setFavSort(int v) => favSort.value = v;

  bool isSelected(String key) => selected.contains(key);

  void toggleSelect(String key) {
    if (selected.contains(key)) {
      selected.remove(key);
    } else {
      selected.add(key);
    }
    selected.refresh();
  }

  /// 全选 / 取消全选（对所有可见项批量设置）
  void setAll(Iterable<String> keys, bool on) {
    if (on) {
      selected.addAll(keys);
    } else {
      selected.removeAll(keys);
    }
    selected.refresh();
  }

  void enterEdit() => editing.value = true;

  void exitEdit() {
    editing.value = false;
    selected.clear();
  }

  void toggleEdit() => editing.value ? exitEdit() : enterEdit();
}
