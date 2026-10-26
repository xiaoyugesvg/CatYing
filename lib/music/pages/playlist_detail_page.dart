import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/widgets/app_page_loading.dart';
import 'package:tvbox/common/theme.dart';

/// 歌单/榜单详情 —— 对齐 Beans 的 `PlaylistView` + 详情页。
///
/// 顶部大头图 + 歌单信息 + 「播放全部 / 随机播放」，
/// 下面是歌曲列表。点歌从该列表位置开始播（这样"下一首"才正确）。
Future<void> openPlaylist(
  BuildContext context,
  int id,
  String title, {
  SongSource source = SongSource.netease,
  bool isTopList = false,
  String? coverUrl,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
      builder: (_) => PlaylistDetailPage(
        id: id,
        title: title,
        source: source,
        isTopList: isTopList,
        coverUrl: coverUrl,
      ),
    ),
  );
}

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.id,
    required this.title,
    this.source = SongSource.netease,
    this.isTopList = false,
    this.coverUrl,
  });

  final int id;
  final String title;
  final SongSource source;

  /// 列表页带过来的封面。
  ///
  /// 榜单（`isTopList`）没有歌单信息接口，详情页只能拿歌名/封面；
  /// 不传的话头部只能是灰占位（用户截图里的"音符占位"）。
  final String? coverUrl;

  /// 这个 id 是**榜单**还是**歌单**？
  ///
  /// 🔴 **QQ 必须区分**：QQ 的榜单 id（topId，如 62）**不是歌单 id** ——
  /// 拿它去查歌单接口（`playlistDetail`）会得到**空列表**
  ///（实测：topListSongs 5 条，playlistDetail 0 条）。
  /// 网易云/酷狗两者恰好通用，但显式标记更清楚，
  /// 也避免"QQ 榜单点进去是空的"这个坑。
  final bool isTopList;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final api = MusicApi.instance;
  Playlist? _pl;
  List<Song> _songs = const [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });

    // ── 榜单 vs 歌单：走**不同接口**（QQ 必须区分，见 isTopList 的说明）──
    if (widget.isTopList) {
      final r = await api.topListSongs(widget.id, source: widget.source);
      if (!mounted) return;
      setState(() {
        // 榜单没有"歌单信息"（名字/封面/描述）→ 用一个最小占位，
        // 让标题走 widget.title（调用方从榜单列表带过来的名字）
        _pl = Playlist(
          id: widget.id,
          name: widget.title,
          // 优先用列表页带来的封面（榜单列表本来就有封面）；
          // 兜底才取第一首歌的封面 —— 前者才是用户点的那张图。
          coverUrl: widget.coverUrl ??
              (r.list.isNotEmpty ? r.list.first.coverUrl : null),
          // ⚠️ `trackCount` 必须给：头部副标题是
          //    `'$trackCount 首 · $creator'`，不填就是 **0 首** ——
          //    而 0 会被当成"没有"，整行副标题**不显示** ✗
          //   （用户截图里"69 首 · 寻找维恩斯"那行在榜单页缺失，就是这个）
          trackCount: r.list.length,
        );
        _songs = r.list;
        _loading = false;
        if (!r.ok && r.list.isEmpty) {
          // ⚠️ 区分"接口失败"和"榜单确实没歌"，否则用户不知道要不要重试
          _error = r.error.isNotEmpty ? r.error : '该榜单暂无歌曲';
        }
      });
      return;
    }

    final (pl, songs) = await api.playlistDetail(widget.id, source: widget.source);
    if (!mounted) return;
    setState(() {
      // 接口没给封面时（部分歌单接口字段缺失），用列表页带来的封面兜底，
      // 避免详情页只剩一个音符占位（IMG_9021）。
      _pl = pl ??
          (songs.isNotEmpty || (widget.coverUrl ?? '').isNotEmpty
              ? Playlist(
                  id: widget.id,
                  name: widget.title,
                  coverUrl: widget.coverUrl,
                  trackCount: songs.length,
                )
              : null);
      if (_pl != null && (_pl!.coverUrl ?? '').isEmpty) {
        _pl = Playlist(
          id: _pl!.id,
          name: _pl!.name,
          coverUrl: widget.coverUrl,
          trackCount: _pl!.trackCount,
          description: _pl!.description,
          creator: _pl!.creator,
        );
      }
      _songs = songs;
      _loading = false;
      if (pl == null && songs.isEmpty) {
        // ⚠️ 原来只写一句"歌单加载失败"，用户既不知道**为什么**、
        //    也不知道**能做什么**。这里把最可能的原因和下一步说清楚：
        //    最常见就是"平台选错了"（拿 A 平台的 id 去查 B 平台）——
        //    那正是 `discover_page` 漏传 `source` 时的表现（已修）。
        _error = '这个内容在「${widget.source.displayName}」上没找到。\n'
            '可以试试：返回后在顶部切换平台，或下拉刷新。';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = _pl?.name ?? widget.title;
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: _loading
            ? AppPageLoading(color: MusicTheme.tint)
            : CustomScrollView(
                slivers: [
                  _header(name),
                  // ── 错误 / 空态：卡片 + 重试（原来是两行灰字，看着像坏了）──
                  if (_error.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: MusicTheme.fill,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            children: [
                              Icon(Icons.cloud_off_rounded,
                                  size: 32, color: MusicTheme.secondary),
                              const SizedBox(height: 10),
                              Text(
                                _error,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: MusicTheme.secondary,
                                    fontSize: AppTheme.fontSubhead,
                                    height: 1.5),
                              ),
                              const SizedBox(height: 14),
                              GestureDetector(
                                onTap: _load,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 9),
                                  decoration: BoxDecoration(
                                    color: MusicTheme.tint,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Text(
                                    '重新加载',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: AppTheme.fontSubhead,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // ── 歌曲列表标题（有歌时才显示，避免空态下面还挂个标题）──
                  if (_songs.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Row(
                          children: [
                            Text(
                              '歌曲',
                              style: TextStyle(
                                color: MusicTheme.label,
                                fontSize: AppTheme.fontSubhead,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '共 ${_songs.length} 首',
                              style: TextStyle(
                                color: MusicTheme.secondary,
                                fontSize: AppTheme.fontCaption,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SliverList.builder(
                    itemCount: _songs.length,
                    itemBuilder: (c, i) => SongCell(
                      song: _songs[i],
                      index: i,
                      playbackContext: _songs,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              ),
      ),
    );
  }

  Widget _header(String name) {
    return SliverAppBar(
      pinned: true,
      // 🔴 原来 `expandedHeight: 300` → 头部**可用高度只有 300-84-12 = 204px**，
      // 而内容最少 ≈221px（128 封面 + 12 + 标题 + 4 + 副标题 + 12 + 33 按钮行）✗
      // → FlexibleSpaceBar 里**必然 RenderFlex overflow**（按钮被裁掉）✗；
      // 标题两行时约 257px，溢出更多 ✗。抬到 360 给足余量 ✓
      expandedHeight: 360,
      backgroundColor: Colors.transparent,
      iconTheme: IconThemeData(color: MusicTheme.label),
      // ── 返回键：深色半透明圆底 ────────────────────────────────
      // 封面是任意图片，浅色封面 + 浅色箭头会糊在一起（用户截图反馈过），
      // 给个圆底让它在任何封面上都清晰可辨。
      leading: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.30),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: Colors.white),
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // 背景：封面模糊放大（Beans 的 CoverBlurBackground）
            if ((_pl?.coverUrl ?? '').isNotEmpty)
              CachedNetworkImage(
                imageUrl: _pl!.coverUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                // ── 🔴 顶部再叠一层**专门给返回按钮看的压暗**（修"看不清"）──
                //
                // 封面是任意图片：浅色封面 + `MusicTheme.label`（浅色主题下
                // 是深色）→ 返回箭头糊在图上**看不见**；
                // 深色封面 + 深色主题同理。用户截图反映的就是
                // "左上角返回按钮看着有问题"。
                //
                // 主渐变（下面那段）在顶部只有 0.55 黑，对**浅色封面**
                // 还不够；这里再加一段从 0.55 衰减到 0 的黑色，
                // 只覆盖状态栏 + 工具栏那 ≈110px ——
                // **视觉问题用视觉手段解决，不动布局预算**
                //（抬高内边距会把 `expandedHeight` 撑爆，见下面 Padding 的注释）。
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.18),
                    MusicTheme.background,
                  ],
                  // 0~0.30 这一段就是顶部 ≈110px（360 × 0.30）
                  stops: const [0.0, 0.30, 1.0],
                ),
              ),
            ),
            Padding(
              // ── ⚠️ 这个顶边距为什么是 84（别再随手改大）────────────────
              //
              // 它必须同时满足两件事：
              //   ① 让过**状态栏**（428×926 机型安全区顶 ≈59）
              //   ② **不和返回按钮抢位置** —— 返回按钮落在 ≈59~103
              // 84 是"封面刚好压在返回按钮下缘"的位置，所以**必然重叠**。
              //
              // 我试过把它抬到 `安全区 + 52`（≈111），但那样内容总高变成
              // ≈378，而 `expandedHeight: 360` 扣掉工具栏后只剩 ≈245 可用 →
              // **反而会 RenderFlex overflow**（按钮被裁掉）✗
              // 要真按安全区推开，得把 `expandedHeight` 也一起抬到 420+，
              // 那会占掉太多首屏 —— 不值得。
              //
              // 所以这里**保持 84**，改用**在返回按钮后面加一层压暗渐变**
              //（见上面 `DecoratedBox` 的第一段）保证它看得清 ——
              // 视觉问题用视觉手段解决，不动布局预算。
              padding: const EdgeInsets.fromLTRB(16, 84, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面 + 柔和投影：让它在模糊背景上"立起来"，
                  // 同时高光描边防止深色封面和深色背景糊成一片。
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                        width: 1,
                      ),
                    ),
                    child: CoverImage(
                        url: _pl?.coverUrl, size: 128, cornerRadius: 15),
                  ),
                  const SizedBox(height: 12),
                  Text(name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle2,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  // 副标题行：首数做成小胶囊，与灰字并列，信息层级更清楚
                  Row(
                    children: [
                      if (_songs.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: MusicTheme.fill,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${_songs.length} 首',
                            style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          (_pl?.creator ?? '').trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontFootnote),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _playBtn('播放全部', Icons.play_arrow_rounded, () {
                        if (_songs.isNotEmpty) {
                          MusicPlayerManager.instance
                              .playQueue(_songs, index: 0);
                        }
                      }),
                      const SizedBox(width: 10),
                      _playBtn('随机播放', Icons.shuffle_rounded, () {
                        if (_songs.isNotEmpty) {
                          final p = MusicPlayerManager.instance;
                          p.setMode(PlayMode.shuffle);
                          p.playQueue(List<Song>.of(_songs)..shuffle(),
                              index: 0);
                        }
                      }, outlined: true),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playBtn(String label, IconData icon, VoidCallback onTap,
      {bool outlined = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          gradient: outlined
              ? null
              : LinearGradient(colors: MusicTheme.accentGradient),
          color: outlined ? Colors.black.withValues(alpha: 0.20) : null,
          borderRadius: BorderRadius.circular(999),
          border: outlined
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.22), width: 1)
              : null,
          boxShadow: outlined
              ? null
              : [
                  BoxShadow(
                    color: MusicTheme.tint.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 头部始终压在深色渐变/封面上 → 两个按钮都用白字，
            // 否则浅色主题下 `MusicTheme.label` 是深色，直接看不见
            Icon(icon, size: 17, color: Colors.white),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
