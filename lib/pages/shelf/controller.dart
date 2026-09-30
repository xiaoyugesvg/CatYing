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

  /// 当前 tab：0 = 播放历史，1 = 我的收藏
  final tab = 0.obs;

  /// 是否处于编辑模式
  final editing = false.obs;

  /// 已选中的项（key = "<source>|<vodId>"，避免历史与收藏同名冲突）
  final selected = <String>{}.obs;

  static String keyOf(String source, String vodId) => '$source|$vodId';

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
