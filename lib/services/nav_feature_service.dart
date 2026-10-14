import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_mirror.dart';

/// 底部导航栏可管理的一项。
///
/// ── ⚠️ 图标与 tab 下标为什么放在枚举里 ──────────────────────────
/// 原来这两样散在 `app.dart` 的 `_navItemFor()` 里（一个 switch），
/// 而**顺序**在 `NavFeatureService.enabled` 里、**下标**又在那个 switch 里
/// —— 三处各写一遍，改顺序时极易漏。
///
/// 现在合成一处：枚举自己带 `icon` / `activeIcon` / `tabIndex`。
/// ⚠️ 加新项（或在列表里插入项）时**必须同步 `_tabPages` 的数组位置**，
/// 否则点它会跳到错的页面。
enum NavFeature {
  home('home', '首页', true, tabIndex: 0),
  live('live', '直播', false, tabIndex: 4),
  music('music', '音乐', false, tabIndex: 5),
  books('books', '阅读', false, tabIndex: 6),
  apps('apps', '程序', false, tabIndex: 7),
  // 「网页首页」模块（独立于小程序体系：加载用户自配的 HTML 首页）
  webhome('webhome', '网页', false, tabIndex: 8),
  shelf('shelf', '史藏', false, tabIndex: 1),
  settings('settings', '设置', true, tabIndex: 3),
  search('search', '搜索', false, tabIndex: 0);

  const NavFeature(this.id, this.label, this.required,
      {required this.tabIndex});

  final String id;
  final String label;

  /// 必需页面：不能关闭（首页 / 设置）
  final bool required;

  /// 对应 `app.dart` 里 `_tabPages` 的**真实下标**（不是底栏位置！）
  ///
  /// 底栏顺序由 `NavFeatureService.enabled` 决定，而下标是这里固定的。
  /// 两者**故意解耦**：用户拖动排序底栏时，不能把页面顺序也改了。
  final int tabIndex;

  /// 未选中图标
  IconData get icon => switch (this) {
        NavFeature.home => Icons.home_outlined,
        NavFeature.live => Icons.live_tv,
        NavFeature.music => Icons.library_music_outlined,
        NavFeature.books => Icons.menu_book_outlined,
        NavFeature.apps => Icons.widgets_outlined,
        NavFeature.webhome => Icons.language_outlined,
        NavFeature.shelf => Icons.schedule_outlined,
        NavFeature.settings => Icons.settings_outlined,
        NavFeature.search => Icons.search,
      };

  /// 选中图标
  IconData get activeIcon => switch (this) {
        NavFeature.home => Icons.home,
        NavFeature.live => Icons.live_tv,
        NavFeature.music => Icons.library_music,
        NavFeature.books => Icons.menu_book,
        NavFeature.apps => Icons.widgets,
        NavFeature.webhome => Icons.language,
        NavFeature.shelf => Icons.schedule,
        NavFeature.settings => Icons.settings,
        NavFeature.search => Icons.search,
      };
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
    // ⚠️ 这里**不要**再调 load()：`main.dart:254` 已经显式 `await
    // NavFeatureService.instance.load()` 过一次。两处都调会让 load() 并发跑两遍
    // （两次读同一个值、两次 _persist 并发写盘），纯属浪费且有竞态。
    // 保留 main 里那次显式 await —— 它保证"恢复设置之后、界面用到之前"已经加载完。
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
      // ⚠️ 2026-10-14：「网页首页」是新增的可选模块，**无记录时也默认关闭** ——
      //   否则全新安装（或老用户升级）后底栏会凭空多出一项，而用户从没开过它。
      //   其余项保持原有语义（无记录 = 启用），不动既有行为。
      final isOn = enabledSet == null
          ? f != NavFeature.webhome
          : enabledSet.contains(f);
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
    // 🔴 2026-10-14：**没有持久化记录时不要回写**。
    //   原来无条件 _persist()：一旦 `_enabledKey` 因为没落盘而丢失，
    //   `enabledSet == null` 会被当成"全部启用"，紧接着把这份"全部启用"
    //   写回磁盘 —— 用户的配置就从"暂时丢了"变成"永久没了"。
    //   现在只有确实读到了持久化记录才回写，缺记录时保持不动：
    //   界面照常按默认值渲染，但不会覆盖掉任何可能存在的数据。
    if (enabledRaw != null) {
      await _persist();
    }
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
    // 🔴 2026-10-14：菜单栏改动**立刻**落进文件镜像。
    //   用户实测「用菜单设置改了菜单栏，重启后又没了」——周期快照 15s 一次，
    //   改完马上杀 App 就丢；而这个键一丢，`load()` 会把"没有任何持久化记录"
    //   当成"全部启用"，再 _persist() 写回，用户的配置就被**永久**冲掉了。
    //   （恢复侧由 PrefsMirror.restoreIfLost 的逐键补齐兜底。）
    PrefsMirror.snapshotSoon();
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
