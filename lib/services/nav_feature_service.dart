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
  // 「RSS」模块（订阅源阅读：Legado RSS 源 / 标准 RSS / OPML）
  rss('rss', 'RSS', false, tabIndex: 8),
  // 「海阔」模块（海阔视界 hiker/hipy 小程序规则；**独立于** TVBox 小程序体系，
  //  见 lib/hiker/）。同样默认不进底栏，用户在「设置 → 主页页面」里自行开启。
  hiker('hiker', '海阔', false, tabIndex: 9),
  // 「Emby」媒体库分类（自建 Emby 服务器：电影 / 剧集）。
  // 默认不进底栏，用户在「设置 → 菜单设置」里自行开启。
  emby('emby', 'Emby', false, tabIndex: 10),
  // 「短剧」分类（2026-10-22）：跨源短剧/微短剧聚合页。
  // ⚠️ 默认**不进底栏**（用户要求「悬浮菜单栏默认关闭」），
  //    在「设置 → 主页页面」打开后才会出现在底栏。
  drama('drama', '短剧', false, tabIndex: 11),
  // 「房间」分类（2026-10-22）：观影房间（服务器 / 局域网两种模式）。
  // ⚠️ 同样默认**不进底栏**，在「设置 → 主页页面」打开。
  room('room', '房间', false, tabIndex: 12),
  // 「REX」分类（2026-10-22）：ForwardWidget / REX 模块宿主。
  // 默认不进底栏，在「设置 → 主页页面」打开。
  rex('rex', 'REX', false, tabIndex: 13),
  // 「TG」分类（2026-10-25）：公开频道（t.me 网页）+ 自己登录的群。
  // ⚠️ 默认**不进底栏**，用户在「设置 → 主页页面」打开后才出现。
  tg('tg', 'TG', false, tabIndex: 14),
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
        NavFeature.live => Icons.live_tv_rounded,
        NavFeature.music => Icons.library_music_outlined,
        NavFeature.books => Icons.menu_book_outlined,
        NavFeature.apps => Icons.storefront_outlined,
        NavFeature.rss => Icons.rss_feed_outlined,
        NavFeature.hiker => Icons.rocket_launch_outlined,
        NavFeature.emby => Icons.video_settings_outlined,
        NavFeature.drama => Icons.movie_filter_outlined,
        NavFeature.room => Icons.groups_outlined,
        NavFeature.rex => Icons.extension_outlined,
        NavFeature.tg => Icons.telegram_outlined,
        NavFeature.shelf => Icons.schedule_outlined,
        NavFeature.settings => Icons.settings_outlined,
        NavFeature.search => Icons.search,
      };

  /// 默认图标**图片资源**（非 null 时优先于 [icon]/[activeIcon] 的 Material 图标）。
  ///
  /// 这几张图都做成了**白色 + 透明背景的蒙版**，渲染时按当前前景色着色
  /// ⇒ 选中/未选中、深色/浅色主题下颜色都会跟着变，与其它 Material 图标一致。
  /// （Emby 原来用彩色品牌图，暗色下深藏青底会糊进背景、浅色下又发灰，
  ///  用户 2026-10-20 要求「图标也根据主题变换」。）
  String? get iconAsset => switch (this) {
        NavFeature.home => 'assets/icons/home.png',
        NavFeature.emby => 'assets/icons/emby.png',
        NavFeature.music => 'assets/icons/music.png',
        NavFeature.books => 'assets/icons/books.png',
        NavFeature.live => 'assets/icons/live.png',
        // 用户指定的两张图（2026-10-23）：
        //   REX = 「C + 星」白色蒙版（跟随前景色）
        //   房间 = 紫/粉对话气泡（保留原色，不透明白描边）
        NavFeature.rex => 'assets/icons/rex.png',
        NavFeature.room => 'assets/icons/room.png',
        _ => null,
      };

  /// 图标资源是否用前景色着色（[iconAsset] 对应的图）。
  ///
  /// · 首页图标是**彩色徽标**（七彩花瓣）：着色会把颜色全抹掉 ⇒ 原样显示；
  /// · 其余几张（含房间的两个圆）都是**白色蒙版**：白色圆 alpha 全、
  ///   内部圆点 alpha 半，着色后颜色跟着主题走，圆点仍看得出层次。
  bool get iconAssetTinted => iconAsset != null && this != NavFeature.home;

  /// 选中图标
  IconData get activeIcon => switch (this) {
        NavFeature.home => Icons.home,
        NavFeature.live => Icons.live_tv_rounded,
        NavFeature.music => Icons.library_music,
        NavFeature.books => Icons.menu_book,
        NavFeature.apps => Icons.storefront_rounded,
        NavFeature.rss => Icons.rss_feed,
        NavFeature.hiker => Icons.rocket_launch,
        NavFeature.emby => Icons.video_settings,
        NavFeature.drama => Icons.movie_filter,
        NavFeature.room => Icons.groups_rounded,
        NavFeature.rex => Icons.extension_rounded,
        NavFeature.tg => Icons.telegram,
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

  /// 一次性迁移标记：见 [load] 里「把这三个请出底栏」那一段
  static const String _kDefaultOffOnce = 'nav_default_off_once_v1';

  /// **默认不进悬浮底栏**的新增模块（用户 2026-10-15 明确要求）：
  /// 「RSS」「海阔」。
  ///
  /// ⚠️ 注意语义：**只是不出现在底栏**，功能本身完全照常 ——
  ///    在「设置 → 菜单设置」里把开关打开，它们立刻回到悬浮底栏并正常工作。
  static const List<NavFeature> kDefaultOffFeatures = [
    NavFeature.rss,
    NavFeature.hiker,
    NavFeature.emby,
    NavFeature.drama,
    NavFeature.room,
    NavFeature.rex,
    NavFeature.tg,
  ];

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
    // ── 一次性迁移（2026-10-15）：把「网页 / RSS / 海阔」请出底栏 ────────
    // 「RSS」「网页」当初是**新增分类**直接加上的、「海阔」是今天新加的模块，
    // 一旦被"新增项 = 默认启用"写进过持久化记录，后面把默认值改成关闭
    // **对老用户就无效了** —— 记录里写着开，底栏里就一直挂着。
    // 这里在首次跑到这段代码时，把这三个**挪回未启用段一次**；
    // 之后就完全尊重用户在「菜单设置」里的选择（想开随时能开，不会再被重置）。
    final defaultOffMigrated = prefs.getBool(_kDefaultOffOnce) ?? false;
    final on = <NavFeature>[];
    final off = <NavFeature>[];
    for (final f in order) {
      // ⚠️ 2026-10-14：新增的可选模块**无记录时也默认关闭** ——
      //   否则全新安装（或老用户升级）后底栏会凭空多出一项，而用户从没开过它。
      //   其余项保持原有语义（无记录 = 启用），不动既有行为。
      var isOn = enabledSet == null
          ? !kDefaultOffFeatures.contains(f)
          : enabledSet.contains(f);
      // 迁移没跑过 ⇒ 这三个一律先按关闭算，并在下面写回磁盘
      if (!defaultOffMigrated && kDefaultOffFeatures.contains(f)) isOn = false;
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
    // 首页永远第一、设置永远最后（用户 2026-10-24：「不要我每次移」）：
    // 老用户存的乱序在这里一次性纠正，之后也不会再被拖动打乱。
    _normalize();
    // 🔴 2026-10-14：**没有持久化记录时不要回写**。
    //   原来无条件 _persist()：一旦 `_enabledKey` 因为没落盘而丢失，
    //   `enabledSet == null` 会被当成"全部启用"，紧接着把这份"全部启用"
    //   写回磁盘 —— 用户的配置就从"暂时丢了"变成"永久没了"。
    //   现在只有确实读到了持久化记录才回写，缺记录时保持不动：
    //   界面照常按默认值渲染，但不会覆盖掉任何可能存在的数据。
    if (!defaultOffMigrated) {
      // 迁移标记必须**本次就落下**：否则全新安装（enabledRaw == null、不回写）
      // 之后用户自己把 RSS 打开 → 下次启动又被"迁移"关掉一次。
      await prefs.setBool(_kDefaultOffOnce, true);
    }
    if (enabledRaw != null) {
      await _persist();
    } else if (!defaultOffMigrated) {
      // 没回写也要让镜像把迁移标记存下来（周期快照 15s 一次，这里提前一次）
      PrefsMirror.snapshotSoon();
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

  /// 规范化已启用列表：首页永远在最前、设置永远在最后。
  ///
  /// 用户 2026-10-24：「已启用里永远将首页和设置固定头尾，其余启用的加在设置前面，
  /// 不要我每次移。」
  /// 中间各项的相对顺序保持不变。
  void _normalize() {
    if (enabled.isEmpty) return;
    final middle = enabled
        .where((f) => f != NavFeature.home && f != NavFeature.settings)
        .toList();
    final next = <NavFeature>[
      NavFeature.home,
      ...middle,
      if (enabled.contains(NavFeature.settings)) NavFeature.settings,
    ];
    if (next.length == enabled.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != enabled[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    enabled.assignAll(next);
  }

  Future<void> setEnabled(NavFeature f, bool v) async {
    if (f.required) return;
    if (v) {
      if (enabled.contains(f)) return;
      disabled.remove(f);
      // 插到「设置」前面（设置永远是最后一项），而不是追加到末尾
      final settingsIdx = enabled.indexOf(NavFeature.settings);
      if (settingsIdx >= 0) {
        enabled.insert(settingsIdx, f);
      } else {
        enabled.add(f);
      }
    } else {
      enabled.remove(f);
      if (!disabled.contains(f)) disabled.add(f);
    }
    await _persist();
  }

  /// 已启用段内部重排（拖动排序）
  ///
  /// 首页（下标 0）与设置（最后一项）位置固定，不可拖动；
  /// 其余项也只能在两者之间的位置落位。
  Future<void> reorderEnabled(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= enabled.length) return;
    // 首页和设置不可拖动
    if (oldIndex == 0 || oldIndex == enabled.length - 1) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    // 落位夹在首页（1）与设置（末尾前一位）之间
    const minPos = 1;
    final maxPos = enabled.length - 2;
    if (target < minPos) target = minPos;
    if (target > maxPos) target = maxPos;
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
