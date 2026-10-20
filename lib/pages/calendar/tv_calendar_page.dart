import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../services/douban_service.dart';
import '../webview/view.dart';

/// 「追剧日历」—— 首页右上角日历入口。
///
/// 数据参考 <https://github.com/SunMoonWithYou/minetrakt> 的「豆瓣热播 / 最新」
/// 思路：按 今日 / 本周 / 本月 三个周期，分别拉豆瓣公开列表（剧集 / 电影），
/// 展示最新、热播与更新情况。
class TvCalendarPage extends StatefulWidget {
  const TvCalendarPage({super.key});

  @override
  State<TvCalendarPage> createState() => _TvCalendarPageState();
}

class _TvCalendarPageState extends State<TvCalendarPage> {
  static const List<String> _periodLabels = ['今天', '本周', '本月'];

  int _period = 0;
  bool _loading = true;
  String? _error;

  /// 每个周期读取的豆瓣列表：section 标题 → (type, tag)
  static const List<List<(String, String, String)>> _sections = [
    // 今天
    [('今日热播剧集', 'tv', '热门'), ('今日热门电影', 'movie', '热门')],
    // 本周（豆瓣 tv 分类没有「最新」标签，用「国产剧」代表近期新剧）
    [('本周新剧', 'tv', '国产剧'), ('本周新片', 'movie', '最新')],
    // 本月
    [('本月热播剧集', 'tv', '热门'), ('本月高分电影', 'movie', '豆瓣高分')],
  ];

  final Map<String, List<DoubanSubject>> _data = {};

  @override
  void initState() {
    super.initState();
    _loadDefaultPeriod().then((_) {
      if (mounted) _load();
    });
  }

  /// 「设置 → 追剧日历 → 默认打开周期」
  Future<void> _loadDefaultPeriod() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = (prefs.getInt('calendar_default_period') ?? 0).clamp(0, 2);
      if (mounted) setState(() => _period = p);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final sections = _sections[_period];
    final results = await Future.wait([
      for (final s in sections)
        DoubanService.instance.fetch(type: s.$2, tag: s.$3),
    ]);
    if (!mounted) return;
    for (var i = 0; i < sections.length; i++) {
      _data[_keyOf(sections[i])] = results[i];
    }
    final empty = results.every((r) => r.isEmpty);
    setState(() {
      _loading = false;
      if (empty) _error = '暂时拿不到豆瓣数据，请检查网络后重试';
    });
  }

  String _keyOf((String, String, String) s) => '${s.$2}|${s.$3}';

  void _switchPeriod(int i) {
    if (i == _period) return;
    setState(() => _period = i);
    final sections = _sections[_period];
    final missing = sections.any((s) => !_data.containsKey(_keyOf(s)));
    if (missing) {
      _load();
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _load,
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.accentColor,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _buildDateHeader(now),
            const SizedBox(height: 14),
            _buildPeriodChips(),
            const SizedBox(height: 18),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_error != null)
              _buildError()
            else
              for (final s in _sections[_period]) ...[
                _buildSection(s.$1, _data[_keyOf(s)] ?? const []),
                const SizedBox(height: 22),
              ],
          ],
        ),
      ),
    );
  }

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
                weekdayLabel(now, weekdays),
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '今天追什么 · 豆瓣热播 / 最新',
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

  String weekdayLabel(DateTime now, List<String> weekdays) =>
      weekdays[(now.weekday - 1).clamp(0, 6)];

  Widget _buildPeriodChips() {
    return Row(
      children: [
        for (var i = 0; i < _periodLabels.length; i++) ...[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _switchPeriod(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == _period
                      ? AppTheme.accentColor
                      : AppTheme.backgroundSecondary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: i == _period
                        ? Colors.transparent
                        : AppTheme.borderLight,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  _periodLabels[i],
                  style: TextStyle(
                    color: i == _period ? Colors.white : AppTheme.textSecondary,
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

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_rounded,
            size: 46,
            color: AppTheme.textTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<DoubanSubject> list) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
            const Spacer(),
            Text(
              '${list.length} 部',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              '暂无数据',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          )
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
            itemBuilder: (_, i) => _posterCard(list[i]),
          ),
      ],
    );
  }

  Widget _posterCard(DoubanSubject s) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showDetail(s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: s.cover.isEmpty
                        ? Container(color: AppTheme.backgroundSecondary)
                        : CachedNetworkImage(
                            imageUrl: s.cover,
                            httpHeaders: DoubanService.imageHeaders,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                              color: AppTheme.backgroundSecondary,
                            ),
                            errorWidget: (_, __, ___) => Container(
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
                if (s.rate > 0)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        s.rate.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Color(0xFFFFC53D),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (s.isNew)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'NEW',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontCaption,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(DoubanSubject s) async {
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
                      child: s.cover.isEmpty
                          ? Container(color: AppTheme.backgroundPrimary)
                          : CachedNetworkImage(
                              imageUrl: s.cover,
                              httpHeaders: DoubanService.imageHeaders,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  Container(color: AppTheme.backgroundPrimary),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.rate > 0 ? '豆瓣评分 ${s.rate.toStringAsFixed(1)}' : '暂无评分',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontCaption,
                          ),
                        ),
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
                        Get.toNamed('/search', arguments: s.title);
                      },
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('搜索资源'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        if (s.url.isEmpty) return;
                        Get.to(
                          () => InAppWebViewPage(url: s.url, title: s.title),
                        );
                      },
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: const Text('豆瓣详情'),
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
}
