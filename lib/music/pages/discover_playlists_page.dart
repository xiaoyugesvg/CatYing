import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/pages/playlist_detail_page.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/mei_cards.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/widgets/music_skeleton.dart';

/// 歌单分类选项。
///
/// [key] 是**真正传给接口的值**：网易云传分类名（`'华语'`），QQ 传数字
/// categoryId 的字符串（`'10000000'`）—— 两边语义不同，所以不能只用名字。
/// [group] 只用于分类弹层的分组标题（网易云的语种/风格/场景/情感/主题）。
class DiscoverCat {
  const DiscoverCat(this.key, this.label, [this.group = '']);

  final String key;
  final String label;
  final String group;
}

/// 排序方式 —— 对齐 Mei 的 `DiscoverOrder`（默认 / 最新 / 最热）。
///
/// [wire] 是传给接口的值：
///   · 网易云 `playlist/list` 收 `hot` / `new` / `default`
///   · QQ 收 `hot` / `new`（`qq_source.playlistSquare` 内部映射成 sortId）
enum DiscoverOrder {
  recommended('default', '默认'),
  latest('new', '最新'),
  hottest('hot', '最热');

  const DiscoverOrder(this.wire, this.label);

  final String wire;
  final String label;
}

/// 网易云的**完整**歌单分类表。
///
/// ── 为什么写死在客户端（2026-10-30）─────────────────────────────
/// 网易云的 `playlist/catalogue` 接口只回**分组名**（`{0:'语种',1:'风格',…}`）
/// 和一组"热门"分类，**根本不回各分组下的子分类**。原来 Node 侧直接把分组名
/// 当分类吐给 Dart ⇒ 分类条上显示的是「语种 / 风格 / 场景 / 情感 / 主题」，
/// 拿这些词去查歌单当然是空的（用户看到的"分类没内容"就是这个）。
///
/// 各家网易云客户端都是内置这张表的，这里照抄同一份。
const _neteaseCatGroups = <String, List<String>>{
  '语种': ['华语', '欧美', '日语', '韩语', '粤语'],
  '风格': [
    '流行', '摇滚', '民谣', '电子', '舞曲', '说唱', '轻音乐', '爵士', //
    '乡村', 'R&B/Soul', '古典', '民族', '英伦', '金属', '朋克', '蓝调',
    '雷鬼', '世界音乐', '拉丁', '另类/独立', 'New Age', '古风', '后摇',
    'Bossa Nova',
  ],
  '场景': [
    '清晨', '夜晚', '学习', '工作', '午休', '下午茶', //
    '地铁', '驾车', '运动', '旅行', '散步', '酒吧',
  ],
  '情感': [
    '怀旧', '清新', '浪漫', '伤感', '治愈', '放松', //
    '孤独', '感动', '兴奋', '快乐', '安静', '思念',
  ],
  '主题': [
    '影视原声', '动漫', '游戏', '综艺', '儿童', '校园', '翻唱', //
    '吉他', '钢琴', '器乐', '榜单', '00后', '90后', '80后', '70后', '10后',
  ],
};

/// 网易云全部分类（含"全部"），供分类弹层与横滑条使用。
List<DiscoverCat> neteaseDiscoverCats() {
  final out = <DiscoverCat>[const DiscoverCat('全部', '全部')];
  _neteaseCatGroups.forEach((group, names) {
    for (final n in names) {
      out.add(DiscoverCat(n, n, group));
    }
  });
  return out;
}

/// 网易云「热门」分类（横滑条上默认露出的那 8 个）。
///
/// 取语种 + 最常用的几个风格 —— 和网易云 App 首页分类条的顺序一致。
const neteaseHotCats = <String>[
  '华语', '流行', '摇滚', '民谣', '电子', '说唱', '轻音乐', '古风',
];

/// 「全部歌单」页 —— 严格对齐 Mei 的 `DiscoverPlaylistsScreen`。
///
/// ── 为什么要单独一页（2026-10-30 重构）──────────────────────────
/// 用户：「推荐、网易这些分页整个要重构，严格按照刚才这个仓库的界面来」。
///
/// Mei 的发现页只放**概览**（探索歌单横滑 + 新碟上架横滑），完整的歌单集合
/// 是**独立的导航目的地**：进去之后才有排序、分类切换、分页加载。
/// 原来本项目把分类塞成一级 tab 下面的二级横滑条、歌单直接铺在发现页里，
/// 既占满首屏又翻不了页。现在按 Mei 拆开。
///
/// 结构（自上而下）：
///   · 大标题 = 当前分类名（`全部` → 「全部歌单」）
///   · 控件行：默认 / 最新 / 最热 三个胶囊 + 右侧「分类」
///   · 2 列网格（平板自适应），滚到底自动加载下一页
///   · 「分类」→ 底部弹层，按分组列出全部分类
class DiscoverPlaylistsPage extends StatefulWidget {
  const DiscoverPlaylistsPage({
    super.key,
    required this.source,
    required this.initialCat,
    required this.cats,
    this.title,
  });

  final SongSource source;

  /// 初始分类 key（网易云是名字，QQ 是 id 字符串）
  final String initialCat;

  /// 全部分类（含"全部"）
  final List<DiscoverCat> cats;

  /// 自定义标题；不传就按分类名生成
  final String? title;

  @override
  State<DiscoverPlaylistsPage> createState() => _DiscoverPlaylistsPageState();
}

class _DiscoverPlaylistsPageState extends State<DiscoverPlaylistsPage> {
  static const _pageSize = 30;

  final api = MusicApi.instance;
  final _scroll = ScrollController();

  late DiscoverCat _cat;
  DiscoverOrder _order = DiscoverOrder.hottest;

  final List<Playlist> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _cat = widget.cats.firstWhere(
      (c) => c.key == widget.initialCat,
      orElse: () => widget.cats.isEmpty
          ? const DiscoverCat('全部', '全部')
          : widget.cats.first,
    );
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // 距底部不足 400 就预取：等真正见底再请求，用户会看到明显的空白等待
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  String get _title {
    if (widget.title != null && widget.title!.isNotEmpty) return widget.title!;
    return _cat.key == '全部' ? '全部歌单' : _cat.label;
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = '';
      _hasMore = true;
      _items.clear();
    });
    final list = await api.playlistSquare(
      cat: _cat.key,
      order: _order.wire,
      limit: _pageSize,
      offset: 0,
      source: widget.source,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items.addAll(list);
      // 接口不给 total，只能靠"这一页够不够数"判断还有没有下一页
      _hasMore = list.length >= _pageSize;
    });
    if (list.isEmpty && _error.isEmpty) {
      // 空分类不是错误，网格区会显示「这个分类还没有歌单」
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    setState(() => _loadingMore = true);
    final list = await api.playlistSquare(
      cat: _cat.key,
      order: _order.wire,
      limit: _pageSize,
      offset: _items.length,
      source: widget.source,
    );
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      _items.addAll(list);
      _hasMore = list.length >= _pageSize;
    });
  }

  void _pickOrder(DiscoverOrder o) {
    if (o == _order) return;
    setState(() => _order = o);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _reload();
  }

  void _pickCat(DiscoverCat c) {
    if (c.key == _cat.key) return;
    setState(() => _cat = c);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _reload();
  }

  Future<void> _openCatSheet() async {
    // ⚠️ 这里**不用** `showMusicSheet`：它是"居中弹窗 + 最多 34% 屏高"，
    //    而分类有 60+ 项，必须给足高度（Mei 用的是 ModalBottomSheet）。
    final picked = await showModalBottomSheet<DiscoverCat>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DiscoverCatSheet(cats: widget.cats, current: _cat.key),
    );
    if (picked != null) _pickCat(picked);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MusicPageHeader(
            title: _title,
            subtitle: '${widget.source.displayName} · ${_items.length} 个歌单',
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 18, color: MusicTheme.label),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 4),
          ),
          _controls(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 排序胶囊 + 「分类」入口（Mei 的 `controls` 插槽）
  Widget _controls() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 16),
              children: [
                for (final o in DiscoverOrder.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: MeiFilterPill(
                      label: o.label,
                      selected: _order == o,
                      onTap: () => _pickOrder(o),
                    ),
                  ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openCatSheet,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune_rounded, size: 16, color: MusicTheme.tint),
                  const SizedBox(width: 4),
                  Text(
                    '分类',
                    style: TextStyle(
                      color: MusicTheme.tint,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error,
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: AppTheme.fontBody)),
            const SizedBox(height: 12),
            TextButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          '这个分类还没有歌单',
          style:
              TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontBody),
        ),
      );
    }
    return RefreshIndicator(
      color: MusicTheme.tint,
      onRefresh: _reload,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 160),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 18,
          // 封面 1:1 + 标题两行 + 副标题一行：0.62 在 375dp 宽屏上刚好
          // 让"两行标题"不被裁（Mei 的 PlaylistCard 也是 maxTitleLine = 2）
          childAspectRatio: 0.62,
        ),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (c, i) {
          if (i >= _items.length) return _moreIndicator();
          final p = _items[i];
          return MeiPlaylistCard(
            playlist: p,
            width: double.infinity,
            subtitle: p.creator?.isNotEmpty == true ? p.creator : null,
            onTap: () => openPlaylist(
              context,
              p.id,
              p.name,
              source: widget.source,
              coverUrl: p.coverUrl,
            ),
          );
        },
      ),
    );
  }

  Widget _moreIndicator() {
    return Center(
      child: _loadingMore
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          : Text(
              '上滑加载更多',
              style: TextStyle(
                  color: MusicTheme.secondary, fontSize: AppTheme.fontCaption),
            ),
    );
  }
}

/// 弹出分类选择器，返回用户选的分类（取消 → null）。
///
/// 发现页的「全部分类」胶囊也要用同一套弹层，所以做成公开函数，
/// 避免两个文件各写一份长得不一样的分类表。
Future<DiscoverCat?> showDiscoverCatSheet(
  BuildContext context, {
  required List<DiscoverCat> cats,
  required String current,
}) {
  return showModalBottomSheet<DiscoverCat>(
    context: context,
    backgroundColor: MusicTheme.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => DiscoverCatSheet(cats: cats, current: current),
  );
}

/// 分类弹层 —— 按 [DiscoverCat.group] 分组，空分组直接列成一行。
class DiscoverCatSheet extends StatelessWidget {
  const DiscoverCatSheet({super.key, required this.cats, required this.current});

  final List<DiscoverCat> cats;
  final String current;

  @override
  Widget build(BuildContext context) {
    // 保持插入顺序（LinkedHashMap 语义），分组顺序就是分类表里的顺序
    final groups = <String, List<DiscoverCat>>{};
    for (final c in cats) {
      groups.putIfAbsent(c.group, () => []).add(c);
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '歌单分类',
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: MusicTheme.secondary),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  for (final entry in groups.entries) ...[
                    if (entry.key.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                        child: Text(
                          entry.key,
                          style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 4,
                      runSpacing: 0,
                      children: [
                        for (final c in entry.value)
                          MeiFilterPill(
                            label: c.label,
                            selected: c.key == current,
                            onTap: () => Navigator.of(context).pop(c),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
