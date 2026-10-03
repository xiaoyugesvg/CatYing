import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/app_toast.dart';

/// 「匹配 TMDB」搜索页（媒体库详情页右上角 🔍 进入）
///
/// 手动搜索 TMDB → 候选列表（综合/电影/电视剧 分类）→
/// 点击条目后 `Navigator.pop` 返回 `(type, item)`，
/// 由媒体库详情页用该候选直接刮削填充数据。
class TmdbMatchPage extends StatefulWidget {
  const TmdbMatchPage({super.key, this.initialKeyword = ''});

  /// 进入页面时自动填入并搜索的片名（媒体库详情页传入当前视频名）
  final String initialKeyword;

  @override
  State<TmdbMatchPage> createState() => _TmdbMatchPageState();
}

class _TmdbMatchPageState extends State<TmdbMatchPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<(String, Map<String, dynamic>)> _candidates =
      const <(String, Map<String, dynamic>)>[];
  bool _loading = false;
  String? _error;
  String _kw = '';
  String _tab = '综合';

  static const _tabs = ['综合', '电影', '电视剧'];

  @override
  void initState() {
    super.initState();
    // 进入页面即用当前片名自动搜索（无需手动输入）
    if (widget.initialKeyword.trim().isNotEmpty) {
      _input.text = widget.initialKeyword.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(widget.initialKeyword.trim());
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _search(String kw) async {
    if (kw.isEmpty) {
      setState(() {
        _candidates = const <(String, Map<String, dynamic>)>[];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final list = await TmdbService.instance.searchCandidates(kw, null);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (list.isEmpty) {
        _error = TmdbService.instance.lastSearchError.value ??
            '搜索无结果（TMDB 可能未收录该片）';
        _candidates = const <(String, Map<String, dynamic>)>[];
      } else {
        _candidates = list;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        title: Text(
          '匹配 TMDB',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: AppTheme.textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(Icons.search,
                      color: AppTheme.textTertiary, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      cursorColor: AppTheme.accentColor,
                      cursorWidth: 1.5,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入片名搜索 TMDB…',
                        hintStyle: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) => _search(v.trim()),
                      onChanged: (v) {
                        // 输入防抖 400ms：停止输入即自动搜索
                        const wait = Duration(milliseconds: 400);
                        Future.delayed(wait, () {
                          if (!mounted || _input.text != v) return;
                          _search(v.trim());
                        });
                      },
                    ),
                  ),
                  if (_input.text.isNotEmpty)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _input.clear();
                        setState(() => _kw = '');
                        _search('');
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.cancel,
                            color: AppTheme.textTertiary, size: 16),
                      ),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // 分类 tabs：综合 / 电影 / 电视剧
          SizedBox(
            height: 34,
            child: Row(
              children: [
                for (final t in _tabs)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _tab = t),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _tab == t
                                ? AppTheme.accentColor
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            t,
                            style: TextStyle(
                              color: _tab == t
                                  ? Colors.white
                                  : AppTheme.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Divider(height: 1, color: AppTheme.borderLight),
          // 结果区
          Expanded(child: _buildResult()),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: AppTheme.accentColor,
          strokeWidth: 2.5,
        ),
      );
    }
    final list = _filtered();
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 36, color: AppTheme.textTertiary),
            const SizedBox(height: 10),
            Text(
              _error ?? '输入片名开始搜索',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) =>
          Divider(height: 20, color: AppTheme.borderLight),
      itemBuilder: (_, i) {
        final (type, item) = list[i];
        final name =
            (item['title'] ?? item['name'] ?? '').toString();
        final date =
            (item['release_date'] ?? item['first_air_date'] ?? '')
                .toString();
        final year = date.length >= 4 ? date.substring(0, 4) : '';
        final vote = (item['vote_average'] as num?)?.toDouble() ?? 0;
        final overview = (item['overview'] ?? '').toString().trim();
        final poster = (item['poster_path'] ?? '').toString();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (name.isEmpty) return;
            Navigator.pop(context, (type, item));
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 海报
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 66,
                  height: 92,
                  child: poster.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl:
                              '${TmdbService.instance.effectiveImgBase}/w185$poster',
                          fit: BoxFit.cover,
                          placeholder: (_, __) => ColoredBox(
                              color: AppTheme.backgroundSecondary),
                          errorWidget: (_, __, ___) => ColoredBox(
                              color: AppTheme.backgroundSecondary),
                        )
                      : ColoredBox(
                          color: AppTheme.backgroundSecondary,
                          child: Icon(
                            Icons.movie_outlined,
                            color: AppTheme.textTertiary,
                            size: 22,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              // 文字
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (year.isNotEmpty) year,
                        type == 'movie' ? '电影' : '电视剧',
                        if (vote > 0) '${vote.toStringAsFixed(1)}★',
                      ].join(' · '),
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                    if (overview.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        overview,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.4,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 按分类 tab 过滤候选
  List<(String, Map<String, dynamic>)> _filtered() {
    switch (_tab) {
      case '电影':
        return _candidates
            .where((e) => e.$1 == 'movie')
            .toList();
      case '电视剧':
        return _candidates
            .where((e) => e.$1 == 'tv')
            .toList();
      default:
        return _candidates;
    }
  }
}
