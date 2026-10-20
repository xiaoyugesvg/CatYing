import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../services/calendar_feed_service.dart';
import '../../services/tmdb_service.dart';
import '../../services/trakt_service.dart';
import '../settings/sub/calendar_settings_page.dart';
import '../webview/view.dart';

/// 「追剧日历」—— 首页右上角日历入口。
///
/// 顶部 4 个 tab：
///   1. 追剧日历：Trakt 设备码登录后，按天展示你追的剧未来 30 天的待播集；
///   2. 豆瓣热播 / 3. 平台剧场 / 4. 骨朵热榜：
///      来自 MineTrakt 用的公开 JSON，再按 今天 / 本周 / 本月 过滤：
///        · 今天：今日更新的剧
///        · 本周：最近 7 天更新的剧
///        · 本月：近 30 天首播的新剧
class TvCalendarPage extends StatefulWidget {
  const TvCalendarPage({super.key});

  @override
  State<TvCalendarPage> createState() => _TvCalendarPageState();
}

class _TvCalendarPageState extends State<TvCalendarPage> {
  static const List<String> _periodLabels = ['今天', '本周', '本月'];
  static const List<String> _tabLabels = ['追剧日历', '豆瓣热播', '平台剧场', '骨朵热榜'];
  static const List<IconData> _tabIcons = [
    Icons.event_note_rounded,
    Icons.local_movies_rounded,
    Icons.subscriptions_rounded,
    Icons.local_fire_department_rounded,
  ];

  int _tab = 0;
  int _period = 0;
  int _guduoCat = 0; // 0 全部 / 1 剧集 / 2 电影 / 3 综艺 / 4 动漫

  CalendarFeedBundle? _bundle;
  bool _feedLoading = true;
  String? _feedError;
  Timer? _feedWatchdog;

  List<TraktCalendarEntry> _trakt = const [];
  bool _traktLoading = false;
  String? _traktError;

  @override
  void initState() {
    super.initState();
    _loadDefaultPeriod();
    _loadFeed();
    _loadTrakt();
  }

  Future<void> _loadDefaultPeriod() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = (prefs.getInt('calendar_default_period') ?? 0).clamp(0, 2);
      if (mounted) setState(() => _period = p);
    } catch (_) {}
  }

  Future<void> _loadFeed({bool force = false}) async {
    // 兜底看门狗：即使数据层因为任何原因卡住（DNS 挂起 / 平台侧阻塞），
    // 也必须在 26 秒内把转圈收掉，换成可见的错误 + 重试按钮。
    _feedWatchdog?.cancel();
    _feedWatchdog = Timer(const Duration(seconds: 26), () {
      if (!mounted || !_feedLoading) return;
      setState(() {
        _feedLoading = false;
        _feedError = '加载超时了，检查网络后点「重新加载」';
      });
    });
    setState(() {
      _feedLoading = true;
      _feedError = null;
    });
    try {
      final bundle = await CalendarFeedService.instance.fetch(
        force: force,
        // 哪一份 JSON 先回来就先渲染，不让最慢的那份拖住整页。
        onPartial: (partial) {
          if (!mounted) return;
          if (_bundle != null && !_bundle!.isEmpty) return;
          if (partial.isEmpty) return;
          setState(() => _bundle = partial);
        },
      );
      _feedWatchdog?.cancel();
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _feedLoading = false;
        if (bundle.isEmpty) _feedError = '暂时拿不到榜单数据，请检查网络后重试';
      });
    } catch (e) {
      // 任何异常都必须收掉 loading —— 否则页面会永远停在转圈（用户实测）
      _feedWatchdog?.cancel();
      if (!mounted) return;
      setState(() {
        _feedLoading = false;
        _feedError = '榜单加载失败：$e';
      });
    }
  }

  Future<void> _loadTrakt() async {
    final svc = TraktService.instance;
    try {
      await svc.load();
    } catch (_) {}
    if (!mounted) return;
    if (!svc.configured || !svc.loggedIn) {
      setState(() {
        _trakt = const [];
        _traktLoading = false;
        _traktError = null;
      });
      return;
    }
    setState(() {
      _traktLoading = true;
      _traktError = null;
    });
    try {
      final list = await svc
          .fetchCalendar()
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _trakt = list;
        _traktLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _traktLoading = false;
        _traktError = e is TraktNotLoggedIn
            ? 'Trakt 登录已失效，请重新登录'
            : '追剧日历加载失败：$e';
      });
    }
  }

  Future<void> _refresh() async {
    if (_tab == 0) {
      await _loadTrakt();
    } else {
      await _loadFeed(force: true);
    }
  }

  @override
  void dispose() {
    _feedWatchdog?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AppTheme 的颜色 getter 是静态的，换肤/明暗切换不会通知 widget；
    // 这里主动监听，保证日历页在浅色/深色和不同配色下都跟着变。
    return ValueListenableBuilder<bool>(
      valueListenable: AppBrightness.isLight,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        valueListenable: AppTheme.paletteRevision,
        builder: (_, ___, ____) => _buildPage(context),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '追剧日历',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refresh,
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.accentColor,
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _buildDateHeader(now),
            const SizedBox(height: 14),
            _buildTabs(),
            const SizedBox(height: 14),
            if (_tab != 0) ...[
              _buildPeriodChips(),
              const SizedBox(height: 14),
            ],
            if (_tab == 0)
              _buildTraktTab(now)
            else
              _buildFeedTab(now),
          ],
        ),
      ),
    );
  }

  // ── 顶部 ──────────────────────────────────────────────────────

  Widget _buildDateHeader(DateTime now) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.accentColor,
                AppTheme.accentColor.withValues(alpha: 0.55),
              ],
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${now.day}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
              Text(
                '${now.month}月',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                weekdays[(now.weekday - 1).clamp(0, 6)],
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _tab == 0
                    ? '我的追剧 · Trakt 未来 30 天待播'
                    : '今天追什么 · 豆瓣 / 剧场 / 骨朵',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _tabLabels.length; i++) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_tab == i) return;
                setState(() => _tab = i);
                if (i == 0) _loadTrakt();
                if (i != 0 && (_bundle == null || _bundle!.isEmpty)) {
                  _loadFeed();
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: i == _tab
                      ? AppTheme.accentColor
                      : AppTheme.backgroundSecondary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: i == _tab
                        ? Colors.transparent
                        : AppTheme.borderLight,
                    width: 0.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _tabIcons[i],
                      size: 15,
                      color:
                          i == _tab ? Colors.white : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _tabLabels[i],
                      style: TextStyle(
                        color:
                            i == _tab ? Colors.white : AppTheme.textSecondary,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight:
                            i == _tab ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (i != _tabLabels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildPeriodChips() {
    return Row(
      children: [
        for (var i = 0; i < _periodLabels.length; i++) ...[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _period = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == _period
                      ? AppTheme.accentColor.withValues(alpha: 0.18)
                      : AppTheme.backgroundSecondary,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: i == _period
                        ? AppTheme.accentColor.withValues(alpha: 0.55)
                        : AppTheme.borderLight,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  _periodLabels[i],
                  style: TextStyle(
                    color: i == _period
                        ? AppTheme.accentColor
                        : AppTheme.textSecondary,
                    fontSize: AppTheme.fontFootnote,
                    fontWeight:
                        i == _period ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          if (i != _periodLabels.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }

  // ── Tab 1：Trakt 追剧日历 ─────────────────────────────────────

  Widget _buildTraktTab(DateTime now) {
    final svc = TraktService.instance;
    if (!svc.configured) {
      return _hintCard(
        icon: Icons.key_rounded,
        title: '先填写 Trakt Client ID',
        subtitle: '到「设置 → 追剧日历」填入 Trakt 应用的 Client ID，'
            '登录后这里会按天显示你追的剧的待播集。',
        action: '去设置',
        onTap: () => Get.to(() => const CalendarSettingsPage()),
      );
    }
    if (!svc.loggedIn) {
      return _hintCard(
        icon: Icons.login_rounded,
        title: '登录 Trakt',
        subtitle: '用设备码登录（不需要密码），登录后自动同步你在 Trakt 追的剧。',
        action: '开始登录',
        onTap: _startTraktLogin,
      );
    }
    if (_traktLoading && _trakt.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_traktError != null && _trakt.isEmpty) {
      return _errorBlock(_traktError!, () => _loadTrakt());
    }
    if (_trakt.isEmpty) {
      return _emptyBlock(
        '未来 30 天没有待播剧集',
        '在 Trakt 里加入待看 / 标记观看后，这里会自动出现。',
      );
    }

    // 按北京时间分组
    final groups = <String, List<(TraktCalendarEntry, String)>>{};
    for (final e in _trakt) {
      final utc = DateTime.tryParse(e.firstAired);
      if (utc == null) continue;
      final bj = utc.toUtc().add(const Duration(hours: 8));
      final key =
          '${bj.year}-${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')}';
      final time =
          '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add((e, time));
    }
    final keys = groups.keys.toList()..sort();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '未来 30 天 · ${_trakt.length} 集',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: _logoutTrakt,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '退出登录',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final day in keys) ...[
          _buildTraktDayHeader(day, day == todayKey, weekdays),
          const SizedBox(height: 10),
          GridView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.47,
            ),
            itemCount: groups[day]!.length,
            itemBuilder: (_, i) {
              final (entry, time) = groups[day]![i];
              return _traktCard(entry, time);
            },
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildTraktDayHeader(String day, bool isToday, List<String> weekdays) {
    final d = DateTime.tryParse(day);
    final wd = d == null ? '' : weekdays[(d.weekday - 1).clamp(0, 6)];
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: AppTheme.accentColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${day.substring(5).replaceAll('-', '月')}日',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          wd,
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontCaption,
          ),
        ),
        if (isToday) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.accentColor,
              borderRadius: BorderRadius.circular(5),
            ),
            child: const Text(
              '今天',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _traktCard(TraktCalendarEntry e, String time) {
    final poster = e.poster;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showTraktDetail(e, time),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: poster.isEmpty
                  ? Container(color: AppTheme.backgroundSecondary)
                  : CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          Container(color: AppTheme.backgroundSecondary),
                      errorWidget: (_, _, _) => Container(
                        color: AppTheme.backgroundSecondary,
                        child: Icon(
                          Icons.live_tv_rounded,
                          color: AppTheme.textTertiary,
                          size: 22,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            e.showTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontCaption,
              height: 1.25,
            ),
          ),
          Text(
            '${e.episodeLabel} · $time',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.accentColor,
              fontSize: 10,
              height: 1.35,
            ),
          ),
          if (e.episodeTitle.isNotEmpty)
            Text(
              e.episodeTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 10,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _startTraktLogin() async {
    final svc = TraktService.instance;
    try {
      final auth = await svc.startDeviceAuth();
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _TraktLoginDialog(auth: auth),
      );
      if (ok == true) await _loadTrakt();
    } catch (e) {
      if (!mounted) return;
      _toast('Trakt 登录失败：$e');
    }
  }

  Future<void> _logoutTrakt() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('退出 Trakt 登录？',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('退出后追剧日历会清空，公开榜单不受影响。',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (yes != true) return;
    await TraktService.instance.logout();
    if (!mounted) return;
    setState(() => _trakt = const []);
    _toast('已退出 Trakt');
  }

  // ── Tab 2/3/4：公开榜单 ─────────────────────────────────────

  Widget _buildFeedTab(DateTime now) {
    final bundle = _bundle;
    if (_feedLoading && bundle == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 64),
        child: Column(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 14),
            Text(
              '正在加载公开榜单…',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '按数据源分片加载，慢的时候会先显示已到的内容',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
      );
    }
    if (bundle == null || bundle.isEmpty) {
      if (_feedError != null) {
        return _errorBlock(_feedError!, () => _loadFeed(force: true));
      }
      return _emptyBlock('暂时没有榜单数据', '下拉刷新重试。');
    }
    final list = _feedListFor(bundle, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_tab == 3) ...[
          _buildGuduoCats(),
          const SizedBox(height: 12),
        ],
        _buildSectionHeader(_sectionTitle()),
        const SizedBox(height: 10),
        if (list.isEmpty && _feedLoading)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Column(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(height: 10),
                Text(
                  '正在加载…',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ],
            ),
          )
        else if (list.isEmpty && _feedError != null)
          _errorBlock(_feedError!, () => _loadFeed(force: true))
        else if (list.isEmpty)
          _emptyBlock(_emptyHint(), '切换周期或下拉刷新试试。')
        else
          GridView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.52,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) => _feedCard(list[i]),
          ),
        if (bundle.updatedAt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '数据更新：${bundle.updatedAt}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ),
      ],
    );
  }

  List<CalendarFeedItem> _feedListFor(CalendarFeedBundle b, DateTime now) {
    final List<CalendarFeedItem> base;
    switch (_tab) {
      case 2:
        base = b.theaterAired;
        break;
      case 3:
        final all = <CalendarFeedItem>[
          ...b.guduoTv,
          ...b.guduoMovie,
          ...b.guduoVariety,
          ...b.guduoAnime,
        ];
        final seen = <String>{};
        base = [
          for (final e in all)
            if (seen.add('${e.tmdbId}|${e.title}')) e,
        ];
        break;
      default:
        base = b.doubanTv;
    }
    var list = base.where((e) {
      switch (_period) {
        case 1:
          return e.updatedWithin(now, 7);
        case 2:
          return e.releasedWithin(now, 30);
        default:
          return e.updatedOn(now);
      }
    }).toList();

    if (_tab == 3) {
      if (_guduoCat == 1) list = list.where((e) => e.category == '剧集').toList();
      if (_guduoCat == 2) list = list.where((e) => e.category == '电影').toList();
      if (_guduoCat == 3) list = list.where((e) => e.category == '综艺').toList();
      if (_guduoCat == 4) list = list.where((e) => e.category == '动漫').toList();
    }

    // 当天没有更新时，豆瓣热播用热度榜兜底，避免整页空白
    if (list.isEmpty && _period == 0 && _tab == 1 && _guduoCat == 0) {
      list = base.take(9).toList();
    }
    if (_tab == 3) {
      list.sort((a, b) {
        final ra = a.rank > 0 ? a.rank : 999;
        final rb = b.rank > 0 ? b.rank : 999;
        return ra.compareTo(rb);
      });
    } else {
      list.sort((a, b) => b.popularity.compareTo(a.popularity));
    }
    return list.take(30).toList();
  }

  String _sectionTitle() {
    final period = _periodLabels[_period];
    switch (_tab) {
      case 2:
        return '$period · 平台剧场';
      case 3:
        return '$period · 骨朵热榜';
      default:
        return '$period · 豆瓣热播';
    }
  }

  String _emptyHint() {
    switch (_period) {
      case 1:
        return '最近 7 天没有更新';
      case 2:
        return '近 30 天没有新剧';
      default:
        return '今天没有更新';
    }
  }

  Widget _buildGuduoCats() {
    const labels = ['全部', '剧集', '电影', '综艺', '动漫'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _guduoCat = i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: i == _guduoCat
                      ? AppTheme.accentColor.withValues(alpha: 0.18)
                      : AppTheme.backgroundSecondary,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: i == _guduoCat
                        ? AppTheme.accentColor.withValues(alpha: 0.55)
                        : AppTheme.borderLight,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: i == _guduoCat
                        ? AppTheme.accentColor
                        : AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight:
                        i == _guduoCat ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            if (i != labels.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: AppTheme.accentColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _feedCard(CalendarFeedItem item) {
    final imageBase = TmdbService.instance.effectiveImgBase;
    final poster = item.posterUrl(imageBase);
    final updateNote = item.lastUpdateDate.length >= 10
        ? item.lastUpdateDate.substring(5)
        : item.lastUpdateDate;
    final note = updateNote.isNotEmpty
        ? '更新 $updateNote'
        : (item.rank > 0 ? '热榜 #${item.rank}' : item.genre);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showFeedDetail(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: poster.isEmpty
                        ? Container(color: AppTheme.backgroundSecondary)
                        : CachedNetworkImage(
                            imageUrl: poster,
                            httpHeaders: item.coverHeaders,
                            fit: BoxFit.cover,
                            placeholder: (_, _) =>
                                Container(color: AppTheme.backgroundSecondary),
                            errorWidget: (_, _, _) => Container(
                              color: AppTheme.backgroundSecondary,
                              child: Icon(
                                Icons.movie_outlined,
                                color: AppTheme.textTertiary,
                                size: 22,
                              ),
                            ),
                          ),
                  ),
                ),
                if (item.rating > 0)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        item.rating.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Color(0xFFFFC53D),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontCaption,
              height: 1.25,
            ),
          ),
          if (note.isNotEmpty)
            Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 10,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }

  // ── 详情 / 通用块 ────────────────────────────────────────────

  Future<void> _showFeedDetail(CalendarFeedItem item) async {
    final imageBase = TmdbService.instance.effectiveImgBase;
    final poster = item.posterUrl(imageBase);
    await _showDetailSheet(
      title: item.title,
      poster: poster,
      coverHeaders: item.coverHeaders,
      meta: [
        if (item.rating > 0) '评分 ${item.rating.toStringAsFixed(1)}',
        if (item.region.isNotEmpty) item.region,
        if (item.genre.isNotEmpty) item.genre,
      ].join(' · '),
      sub: [
        if (item.releaseDate.isNotEmpty) '首播 ${item.releaseDate}',
        if (item.lastUpdateDate.isNotEmpty) '更新 ${item.lastUpdateDate}',
      ].join(' · '),
      onSearch: () => Get.toNamed('/search', arguments: item.title),
      onTmdb: item.tmdbId <= 0
          ? null
          : () => Get.to(
                () => InAppWebViewPage(
                  url:
                      'https://www.themoviedb.org/${item.mediaType == 'movie' ? 'movie' : 'tv'}/${item.tmdbId}',
                  title: item.title,
                ),
              ),
    );
  }

  Future<void> _showTraktDetail(TraktCalendarEntry e, String time) async {
    await _showDetailSheet(
      title: e.showTitle,
      poster: e.poster,
      meta: '${e.episodeLabel} · $time'
          '${e.episodeTitle.isNotEmpty ? ' · ${e.episodeTitle}' : ''}',
      sub: e.overview,
      onSearch: () => Get.toNamed('/search', arguments: e.showTitle),
      onTmdb: e.tmdbId <= 0
          ? null
          : () => Get.to(
                () => InAppWebViewPage(
                  url: 'https://www.themoviedb.org/tv/${e.tmdbId}',
                  title: e.showTitle,
                ),
              ),
    );
  }

  Future<void> _showDetailSheet({
    required String title,
    required String poster,
    required String meta,
    required String sub,
    required VoidCallback onSearch,
    VoidCallback? onTmdb,
    Map<String, String>? coverHeaders,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 84,
                      height: 118,
                      child: poster.isEmpty
                          ? Container(color: AppTheme.backgroundPrimary)
                          : CachedNetworkImage(
                              imageUrl: poster,
                              httpHeaders: coverHeaders,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                color: AppTheme.backgroundPrimary,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            meta,
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontCaption,
                              height: 1.4,
                            ),
                          ),
                        ],
                        if (sub.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            sub,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onSearch();
                      },
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('搜索资源'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onTmdb == null
                          ? null
                          : () {
                              Navigator.of(ctx).pop();
                              onTmdb();
                            },
                      icon:
                          const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: const Text('TMDB 详情'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hintCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String action,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 50),
      child: Column(
        children: [
          Icon(icon, size: 52, color: AppTheme.accentColor.withValues(alpha: 0.7)),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: onTap, child: Text(action)),
        ],
      ),
    );
  }

  Widget _errorBlock(String message, VoidCallback retry) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Icon(Icons.event_busy_rounded,
              size: 46, color: AppTheme.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }

  Widget _emptyBlock(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 50),
      child: Column(
        children: [
          Icon(Icons.video_library_outlined,
              size: 46, color: AppTheme.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead)),
          const SizedBox(height: 6),
          Text(hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption)),
        ],
      ),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// Trakt 设备码登录弹窗：展示 user_code、打开激活页、按 interval 轮询。
class _TraktLoginDialog extends StatefulWidget {
  const _TraktLoginDialog({required this.auth});

  final TraktDeviceAuth auth;

  @override
  State<_TraktLoginDialog> createState() => _TraktLoginDialogState();
}

class _TraktLoginDialogState extends State<_TraktLoginDialog> {
  Timer? _timer;
  bool _polling = false;
  bool _finished = false;
  String _status = '等待你在 Trakt 上确认…';
  late final DateTime _deadline = DateTime.now()
      .add(Duration(seconds: widget.auth.expiresIn.clamp(60, 1800)));

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(
      Duration(seconds: widget.auth.interval.clamp(3, 30)),
      _poll,
    );
  }

  Future<void> _poll() async {
    if (_polling || _finished || !mounted) return;
    if (DateTime.now().isAfter(_deadline)) {
      _finished = true;
      setState(() => _status = '设备码已过期，请重新登录');
      return;
    }
    _polling = true;
    final status = await TraktService.instance.pollDeviceAuth(widget.auth);
    _polling = false;
    if (!mounted || _finished) return;
    switch (status) {
      case TraktPollStatus.success:
        _finished = true;
        _timer?.cancel();
        Navigator.of(context).pop(true);
        break;
      case TraktPollStatus.pending:
        setState(() => _status = '等待你在 Trakt 上确认…');
        _schedule();
        break;
      case TraktPollStatus.slowDown:
        setState(() => _status = '请求太频繁，稍等一下…');
        _schedule();
        break;
      case TraktPollStatus.denied:
        _finished = true;
        setState(() => _status = '你在 Trakt 上拒绝了授权');
        break;
      case TraktPollStatus.expired:
        _finished = true;
        setState(() => _status = '设备码已过期，请重新登录');
        break;
      case TraktPollStatus.error:
        setState(() => _status = '网络异常，正在重试…');
        _schedule();
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.backgroundSecondary,
      title: Text(
        '登录 Trakt',
        style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1. 打开 trakt.tv/activate',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: AppTheme.fontFootnote),
          ),
          Text(
            '2. 输入下面的设备码',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: AppTheme.fontFootnote),
          ),
          const SizedBox(height: 12),
          Center(
            child: SelectableText(
              widget.auth.userCode,
              style: TextStyle(
                color: AppTheme.accentColor,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!_finished)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (!_finished) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _status,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _finished = true;
            _timer?.cancel();
            Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Get.to(
            () => InAppWebViewPage(
              url: widget.auth.verificationUrl,
              title: 'Trakt 激活',
            ),
          ),
          child: const Text('打开激活页'),
        ),
      ],
    );
  }
}
