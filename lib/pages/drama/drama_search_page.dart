import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/source_bean.dart';
import '../../services/source_service.dart';
import 'drama_entry.dart';
import 'drama_settings.dart';

/// 短剧搜索页（2026-10-23）。
///
/// 短剧原来只有「分类浏览」，没有关键词搜索 —— 用户想找一部具体短剧时
/// 只能挨个分类翻。这里复用 [SourceService.search]：
///   · 搜索范围 = 「短剧设置 → 聚合范围」里选中的源（与列表页同一份）。
///     没选就是当前源，不会把几百条线路全打一遍；
///   · 4 路并发，结果按源分组展示，单源失败不影响其它源。
class DramaSearchPage extends StatefulWidget {
  const DramaSearchPage({super.key});

  @override
  State<DramaSearchPage> createState() => _DramaSearchPageState();
}

/// 一个源的搜索结果
class _GroupResult {
  const _GroupResult(this.source, this.videos);
  final SourceBean source;
  final List<Video> videos;
}

class _DramaSearchPageState extends State<DramaSearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  String _kw = '';
  bool _searching = false;

  /// 是否已经搜过一次（区分"还没搜"和"搜了没结果"）
  bool _searched = false;

  final List<_GroupResult> _groups = [];
  int _done = 0;
  int _total = 0;
  int _failed = 0;

  /// 请求代次：连续搜两次时，先把旧结果作废，避免旧的循环继续往列表里塞
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    // 进页面直接弹键盘，少一次点击
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  Future<void> _search(String raw) async {
    final kw = raw.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    final token = ++_seq;
    setState(() {
      _searching = true;
      _searched = true;
      _kw = kw;
      _groups.clear();
      _failed = 0;
      _done = 0;
      _total = 0;
    });

    final targets = await DramaSettings.targets();
    if (!mounted || token != _seq) return;
    if (targets.isEmpty) {
      setState(() => _searching = false);
      return;
    }
    _total = targets.length;

    // 4 个一批：既压住并发，又不会让用户等太久
    for (var i = 0; i < targets.length; i += 4) {
      final batch = targets.skip(i).take(4).toList();
      final results = await Future.wait(batch.map((s) async {
        try {
          final list = await SourceService.instance
              .search(s, kw)
              .timeout(const Duration(seconds: 20));
          return (s, list, null as String?);
        } catch (e) {
          return (s, <Video>[], e.toString().split('\n').first);
        }
      }));
      if (!mounted || token != _seq) return;
      setState(() {
        for (final r in results) {
          _done++;
          if (r.$3 != null) {
            _failed++;
            continue;
          }
          if (r.$2.isNotEmpty) _groups.add(_GroupResult(r.$1, r.$2));
        }
      });
    }
    if (mounted && token == _seq) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: SizedBox(
          height: 38,
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
            decoration: InputDecoration(
              hintText: '搜索短剧名称',
              hintStyle: TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
              prefixIcon: Icon(Icons.search_rounded, size: 18, color: _sub),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 34, minHeight: 34),
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      icon: Icon(Icons.close_rounded, size: 17, color: _sub),
                      onPressed: () => setState(() {
                        _ctrl.clear();
                        _groups.clear();
                        _searched = false;
                      }),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
              filled: true,
              fillColor: _isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : Colors.black.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: _search,
            onChanged: (_) => setState(() {}), // 让清除按钮跟着出现/消失
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              // 与 AppBar 内其它图标同一视觉权重，别用默认 14 号粗体抢焦点
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              foregroundColor: AppTheme.accentOnSurface,
              textStyle: const TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () => _search(_ctrl.text),
            child: const Text('搜索'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_searching && _groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _total == 0 ? '正在准备…' : '已搜 $_done / $_total 个源',
              style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
            ),
          ],
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Text(
          '输入关键词，在「聚合范围」内的源里搜索',
          textAlign: TextAlign.center,
          style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote),
        ),
      );
    }
    if (_groups.isEmpty && !_searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off_rounded, size: 34, color: _sub),
              const SizedBox(height: 10),
              Text('没搜到「$_kw」',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                _failed > 0
                    ? '$_total 个源里 $_failed 个搜索失败（站点可能已失效）'
                    : '换个关键词，或到「短剧设置」里多勾几个源',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontCaption, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    final totalHits = _groups.fold<int>(0, (s, g) => s + g.videos.length);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _searching
                      ? '已找到 $totalHits 条 · 正在搜 $_done / $_total 个源'
                      : '「$_kw」共 $totalHits 条',
                  style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                ),
              ),
              if (_searching)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
            ],
          ),
        ),
        for (final g in _groups) _groupSection(g),
      ],
    );
  }

  Widget _groupSection(_GroupResult g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 13,
                decoration: BoxDecoration(
                  color: AppTheme.accentOnSurface,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  g.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text('${g.videos.length}',
                  style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ],
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 10,
            childAspectRatio: 0.55,
          ),
          itemCount: g.videos.length,
          itemBuilder: (_, i) => _card(g.videos[i]),
        ),
      ],
    );
  }

  Widget _card(Video v) {
    return GestureDetector(
      onTap: () => DramaEntry.open(v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: v.pic.isEmpty
                  ? _ph()
                  : CachedNetworkImage(
                      imageUrl: v.pic,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, __, ___) => _ph(),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            v.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              height: 1.25,
              color: _fg,
            ),
          ),
          if (v.note.isNotEmpty)
            Text(
              v.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: _sub),
            ),
        ],
      ),
    );
  }

  Widget _ph() => Container(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
        child: const Icon(Icons.movie_outlined, size: 26),
      );
}
