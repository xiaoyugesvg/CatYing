/// 阅读设置（截图 IMG_71a10）。
///
/// ── 字段对应关系（截图逐项）──────────────────────────────────
///   阅读模式    ：左右 / 上下 / 仿真 / 覆盖 / 无动画
///   翻页反转    ：左点下一页、右点上一页
///   单手模式    ：屏幕左右点击都是下一页
///   点击区域    ：自定义各区域触发上一页/菜单/下一页
///   双页模式    ：横屏左右并排（上下模式除外）
///   信息栏      ：页眉页脚显示的信息，可逐项开关
///                 时间 / 章节 / 电量 / 书名 / 页码 / 进度
///   音量键翻页  ：按音量上/下键翻页（会接管音量键）
///   屏幕休眠    ：默认 / 10分钟 / 永不息屏
class ReadingSettings {
  ReadingSettings({
    this.pageMode = PageMode.slide,
    this.flipReverse = false,
    this.oneHand = false,
    this.tapZones = const {},
    this.dualPage = false,
    this.statusItems = const {'章节', '页码', '进度'},
    this.volumeKeys = false,
    this.sleepMode = SleepMode.defaultMode,
  });

  final PageMode pageMode;

  /// 左点下一页、右点上一页
  final bool flipReverse;

  /// 屏幕左右点击都是下一页
  final bool oneHand;

  /// 点击区域映射：zone 下标(0~8，3×3) → 动作
  ///
  /// 截图里的默认是「上一页 / 菜单 / 下一页」这类的三列布局。
  /// 空的键表示该区不动作。
  final Map<int, TapAction> tapZones;

  /// 横屏左右并排（上下模式除外）
  final bool dualPage;

  /// 页眉页脚显示的信息项（可多选）
  final Set<String> statusItems;

  /// 按音量上/下键翻页（会接管音量键）
  final bool volumeKeys;

  final SleepMode sleepMode;

  ReadingSettings copyWith({
    PageMode? pageMode,
    bool? flipReverse,
    bool? oneHand,
    Map<int, TapAction>? tapZones,
    bool? dualPage,
    Set<String>? statusItems,
    bool? volumeKeys,
    SleepMode? sleepMode,
  }) {
    return ReadingSettings(
      pageMode: pageMode ?? this.pageMode,
      flipReverse: flipReverse ?? this.flipReverse,
      oneHand: oneHand ?? this.oneHand,
      tapZones: tapZones ?? this.tapZones,
      dualPage: dualPage ?? this.dualPage,
      statusItems: statusItems ?? this.statusItems,
      volumeKeys: volumeKeys ?? this.volumeKeys,
      sleepMode: sleepMode ?? this.sleepMode,
    );
  }

  /// 默认点击区域：左=上一页，中=菜单，右=下一页（截图里的三列）
  static Map<int, TapAction> defaultZones() => {
        0: TapAction.prev,
        1: TapAction.prev,
        2: TapAction.menu,
        3: TapAction.menu,
        4: TapAction.menu,
        5: TapAction.menu,
        6: TapAction.next,
        7: TapAction.next,
        8: TapAction.next,
      };

  Map<String, dynamic> toJson() => {
        'pageMode': pageMode.name,
        'flipReverse': flipReverse,
        'oneHand': oneHand,
        'tapZones': tapZones.map((k, v) => MapEntry('$k', v.name)),
        'dualPage': dualPage,
        'statusItems': statusItems.toList(),
        'volumeKeys': volumeKeys,
        'sleepMode': sleepMode.name,
      };

  static ReadingSettings fromJson(Map<String, dynamic> j) {
    PageMode pm = PageMode.slide;
    for (final v in PageMode.values) {
      if (v.name == j['pageMode']) pm = v;
    }
    SleepMode sm = SleepMode.defaultMode;
    for (final v in SleepMode.values) {
      if (v.name == j['sleepMode']) sm = v;
    }
    final zones = <int, TapAction>{};
    final zj = j['tapZones'];
    if (zj is Map) {
      zj.forEach((k, v) {
        final i = int.tryParse('$k');
        if (i == null) return;
        for (final a in TapAction.values) {
          if (a.name == v) zones[i] = a;
        }
      });
    }
    return ReadingSettings(
      pageMode: pm,
      flipReverse: j['flipReverse'] == true,
      oneHand: j['oneHand'] == true,
      tapZones: zones.isEmpty ? defaultZones() : zones,
      dualPage: j['dualPage'] == true,
      statusItems: (j['statusItems'] is List)
          ? (j['statusItems'] as List).map((e) => '$e').toSet()
          : {'章节', '页码', '进度'},
      volumeKeys: j['volumeKeys'] == true,
      sleepMode: sm,
    );
  }
}

/// 阅读模式（截图里的 5 个）
enum PageMode {
  /// 左右：水平滑动翻页（PageView 默认）
  slide('左右'),

  /// 上下：垂直滚动，不分页
  scroll('上下'),

  /// 仿真：翻书卷曲效果
  curl('仿真'),

  /// 覆盖：新页从侧面盖上来
  cover('覆盖'),

  /// 无动画：直接切换
  none('无动画');

  const PageMode(this.label);
  final String label;

  /// 这个模式是否分页（上下模式是滚动的，不分页）
  bool get paginates => this != PageMode.scroll;
}

/// 点击区域的三种动作（截图里是「上一页 / 菜单 / 下一页」）
enum TapAction {
  prev('上一页'),
  menu('菜单'),
  next('下一页'),
  none('无');

  const TapAction(this.label);
  final String label;
}

/// 屏幕休眠（截图里的三个按钮）
enum SleepMode {
  defaultMode('默认'),
  tenMinutes('10分钟'),
  never('永不息屏');

  const SleepMode(this.label);
  final String label;

  /// 对应 Duration；null = 不主动息屏（交给系统）
  Duration? get duration {
    switch (this) {
      case SleepMode.tenMinutes:
        return const Duration(minutes: 10);
      case SleepMode.never:
      case SleepMode.defaultMode:
        return null;
    }
  }
}
