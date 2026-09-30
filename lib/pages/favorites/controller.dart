import 'package:get/get.dart';
import '../../models/cache_store.dart';

/// 收藏控制器
enum FavSort { timeDesc, timeAsc, nameAsc }

class FavoritesController extends GetxController {
  final favSortMode = FavSort.timeDesc.obs;

  List<VodCollect> get favoritesList {
    final list = CacheStore.instance.favorites.toList();
    switch (favSortMode.value) {
      case FavSort.nameAsc:
        list.sort((a, b) => a.vodName.compareTo(b.vodName));
      case FavSort.timeAsc:
        list.sort((a, b) => a.updateTime.compareTo(b.updateTime));
      case FavSort.timeDesc:
        list.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    }
    return list;
  }


  Future<void> removeItem(VodCollect item) async {
    await CacheStore.instance.removeCollect(item.vodId, item.sourceKey);
  }

  Future<void> clearAll() async {
    // 清空所有收藏
    final items = CacheStore.instance.favorites.toList();
    for (final item in items) {
      await CacheStore.instance.removeCollect(item.vodId, item.sourceKey);
    }
  }
}
