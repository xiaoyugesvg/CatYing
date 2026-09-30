import 'dart:convert';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底部导航栏可管理的一项
enum NavFeature {
  home('home', '首页', true), // required
  live('live', '直播', false),
  music('music', '音乐', false),
  shelf('shelf', '史藏', false),
  settings('settings', '设置', true), // required
  search('search', '搜索', false);

  const NavFeature(this.id, this.label, this.required);

  final String id;
  final String label;

  /// 必需页面：不能关闭（首页 / 设置）
  final bool required;
}

/// 首页导航栏的功能开关与顺序。
///
/// 对应「设置 → 主页页面」：已启用 / 未启用两段，可拖动排序，可开关。
/// 直接影响底部悬浮导航栏渲染哪些项、以什么顺序。
class NavFeatureService extends GetxService {
  static NavFeatureService get instance {
    if (!Get.isRegistered<NavFeatureService>()) {
      Get.put<NavFeatureService>(NavFeatureService(), permanent: true);
    }
    return Get.find<NavFeatureService>();
  }

  static const String _enabledKey = 'nav_enabled_features_v1';
  static const String _orderKey = 'nav_feature_order_v1';

  /// 启用中的功能（**顺序即底栏顺序**，不含 search —— 搜索是按钮不是 tab）
  final enabled = <NavFeature>[
    NavFeature.home,
    NavFeature.music,
    NavFeature.shelf,
    NavFeature.settings,
  ].obs;

  /// 未启用的功能（按用户排序展示）
  final disabled = <NavFeature>[
    NavFeature.live,
  ].obs;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final orderRaw = prefs.getString(_orderKey);
    final enabledRaw = prefs.getStringList(_enabledKey);

    // 顺序：优先用持久化的顺序，缺失的补到末尾（新增枚举时兼容）
    List<NavFeature> order = [];
    if (orderRaw != null && orderRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(orderRaw);
        if (decoded is List) {
          for (final id in decoded) {
            final f = _byId(id as String);
            if (f != null && !order.contains(f)) order.add(f);
          }
        }
      } catch (_) {/* 忽略损坏数据，回落默认 */}
    }
    if (order.isEmpty) order = NavFeature.values.toList();
    for (final f in NavFeature.values) {
      if (!order.contains(f)) order.add(f);
    }
    // 底栏不显示「搜索」（搜索是顶栏按钮）
    order.remove(NavFeature.search);

    final enabledSet = enabledRaw?.map(_byId).whereType<NavFeature>().toSet();
    final on = <NavFeature>[];
    final off = <NavFeature>[];
    for (final f in order) {
      final isOn = enabledSet == null ? true : enabledSet.contains(f);
      // 必需页面强制启用
      if (f.required) {
        on.add(f);
      } else if (isOn) {
        on.add(f);
      } else {
        off.add(f);
      }
    }
    // 未启用段：展示所有可选但未启用的（含不常上底栏的，供以后扩展）
    for (final f in NavFeature.values) {
      if (f == NavFeature.search) continue;
      if (!on.contains(f) && !off.contains(f)) off.add(f);
    }

    enabled.assignAll(on);
    disabled.assignAll(off);
    await _persist();
  }

  static NavFeature? _byId(String id) {
    for (final f in NavFeature.values) {
      if (f.id == id) return f;
    }
    return null;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_enabledKey, enabled.map((f) => f.id).toList());
    await prefs.setString(
        _orderKey, jsonEncode([...enabled, ...disabled].map((f) => f.id).toList()));
  }

  Future<void> setEnabled(NavFeature f, bool v) async {
    if (f.required) return;
    if (v) {
      if (enabled.contains(f)) return;
      disabled.remove(f);
      enabled.add(f);
    } else {
      enabled.remove(f);
      if (!disabled.contains(f)) disabled.add(f);
    }
    await _persist();
  }

  /// 已启用段内部重排（拖动排序）
  Future<void> reorderEnabled(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= enabled.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= enabled.length) target = enabled.length - 1;
    final item = enabled.removeAt(oldIndex);
    enabled.insert(target, item);
    await _persist();
  }

  /// 未启用段内部重排
  Future<void> reorderDisabled(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= disabled.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= disabled.length) target = disabled.length - 1;
    final item = disabled.removeAt(oldIndex);
    disabled.insert(target, item);
    await _persist();
  }
}
