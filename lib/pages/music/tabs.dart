import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/music_service.dart';
import '../settings/sub/music_source_settings_page.dart';
import 'player_controller.dart';
import 'player_page.dart';

// ============================================================
// 通用：曲目行
// ============================================================

/// 一首歌的列表行（封面 + 歌名 + 歌手 + 时长），点一下播放
class MusicTrackTile extends StatelessWidget {
  const MusicTrackTile({super.key, required this.track, this.queue});

  final MusicTrack track;

  /// 点播放时一起入队的列表（不传则单曲入队）
  final List<MusicTrack>? queue;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerController.instance;
    return Obx(() {
      final active = p.current?.id == track.id;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          await p.playTrack(track, list: queue);
          if (context.mounted) {
            Get.to(() => const MusicPlayerPage());
          }
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.accentColor.withValues(alpha: 0.10)
                : AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
            border: Border.all(
              color: active
                  ? AppTheme.accentColor.withValues(alpha: 0.5)
                  : AppTheme.glassBorderSoft,
              width: 0.6,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: track.coverUrl.isEmpty
                      ? _ph()
                      : CachedNetworkImage(
                          imageUrl: track.coverUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _ph(),
                          errorWidget: (_, __, ___) => _ph(),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: active
                                ? AppTheme.accentColor
                                : AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead + 1,
                            fontWeight: FontWeight.w500)),
                    if (track.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(track.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(track.durationText,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      fontFamily: 'monospace')),
              const SizedBox(width: 4),
            ],
          ),
        ),
      );
    });
  }

  Widget _ph() => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Icon(Icons.music_note, size: 20, color: AppTheme.textTertiary),
      );
}

/// 「还没导入音源」的统一引导
class MusicEmptySource extends StatelessWidget {
  const MusicEmptySource({super.key, this.title = '还没有导入音乐音源'});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.extension_outlined,
                  size: 30, color: AppTheme.accentColor),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '导入落雪(LX)自定义音源脚本后即可搜索与播放。\n'
              'App 本身不内置任何音源。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.5),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Get.to(() => const MusicSourceSettingsPage()),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.circular(21),
                ),
                child: const Text('去导入音源',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 榜单
// ============================================================

/// 榜单：内置一批常用关键词，点进去就是搜索结果。
///
/// 说明：LX 脚本没有统一的"榜单接口"（各家 source 排行字段不同），
/// 所以这里用「热门关键词 → 搜索」的方式实现，稳定且各源通用。
class MusicRankTab extends StatelessWidget {
  const MusicRankTab({super.key});

  static const _ranks = [
    ('热歌榜', '热门歌曲', Icons.local_fire_department),
    ('新歌榜', '新歌', Icons.fiber_new),
    ('飙升榜', '飙升', Icons.trending_up),
    ('网络红歌', '网络红歌', Icons.wifi),
    ('华语流行', '华语流行', Icons.language),
    ('欧美热歌', '欧美', Icons.public),
    ('日韩热歌', '日韩', Icons.translate),
    ('纯音乐', '纯音乐', Icons.piano),
    ('古风', '古风', Icons.auto_stories),
    ('DJ舞曲', 'DJ', Icons.headphones),
    ('经典老歌', '经典老歌', Icons.history_edu),
    ('儿歌', '儿歌', Icons.child_care),
  ];

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!MusicService.instance.configured) return const MusicEmptySource();
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, 4, AppTheme.spacingLG, 20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 2.5,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: _ranks.length,
        itemBuilder: (context, i) {
          final r = _ranks[i];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Get.to(() => MusicSearchPage(initialKeyword: r.$2)),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundCard,
                borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
                border:
                    Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(r.$3,
                        size: 17, color: AppTheme.accentColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(r.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead + 1,
                            fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}

// ============================================================
// 歌单
// ============================================================

/// 歌单：粘贴歌单链接/ID → 交给音源的 songList action 解析。
///
/// 本轮先做"输入 + 调用 + 展示"，脚本返回结构各异时至少能看到原始报错。
class MusicPlaylistTab extends StatefulWidget {
  const MusicPlaylistTab({super.key});

  @override
  State<MusicPlaylistTab> createState() => _MusicPlaylistTabState();
}

class _MusicPlaylistTabState extends State<MusicPlaylistTab> {
  final _ctrl = TextEditingController();
  final list = <MusicTrack>[].obs;
  final busy = false.obs;
  final err = ''.obs;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!MusicService.instance.configured) return const MusicEmptySource();
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG, 4, AppTheme.spacingLG, 10),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: AppTheme.glassBorder, width: 0.8),
                    ),
                    child: TextField(
                      controller: _ctrl,
                      cursorColor: AppTheme.accentColor,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead),
                      decoration: InputDecoration(
                        hintText: '粘贴歌单链接或 ID',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _parse(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: busy.value ? null : _parse,
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: busy.value
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('解析',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          if (err.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingLG),
              child: Text(err.value,
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: AppTheme.fontCaption)),
            ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('解析后的歌单会显示在这里',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacingLG, 4, AppTheme.spacingLG, 20),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (c, i) =>
                        MusicTrackTile(track: list[i], queue: list),
                  ),
          ),
        ],
      );
    });
  }

  Future<void> _parse() async {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    busy.value = true;
    err.value = '';
    try {
      // 用 search 的扩展：把链接当 filter 交给脚本的 songList action。
      // 目前 MusicService 只暴露 search；这里先用搜索兜底，
      // 等确认了你用的脚本支持哪个 action 再切到 songList。
      final r = await MusicService.instance.search(v, type: 'songlist');
      list.assignAll(r.tracks);
      if (r.tracks.isEmpty) err.value = r.message;
    } finally {
      busy.value = false;
    }
  }
}

// ============================================================
// 我的
// ============================================================

/// 我的：本地收藏 / 最近播放。
///
/// 本轮先做「最近播放」（来自播放器队列，已在内存里），
/// 收藏需要落盘，等确认数据结构后再加。
class MusicMineTab extends StatelessWidget {
  const MusicMineTab({super.key});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerController.instance;
    return Obx(() {
      if (!MusicService.instance.configured) return const MusicEmptySource();
      final q = p.queue;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG, 4, AppTheme.spacingLG, 10),
            child: Text('最近播放',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 2,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: q.isEmpty
                ? Center(
                    child: Text('还没有播放记录',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacingLG, 0, AppTheme.spacingLG, 20),
                    itemCount: q.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (c, i) =>
                        MusicTrackTile(track: q[i], queue: q),
                  ),
          ),
        ],
      );
    });
  }
}

// ============================================================
// 首页（音乐里的首页 = 推荐）
// ============================================================

/// 音乐首页：推荐歌单式入口 + 最近在听
class MusicHomeTab extends StatelessWidget {
  const MusicHomeTab({super.key});

  static const _recommend = [
    ('每日推荐', '每日推荐', Icons.today),
    ('私人电台', '电台', Icons.radio),
    ('轻音乐', '轻音乐', Icons.spa),
    ('运动歌单', '运动', Icons.fitness_center),
    ('睡前放松', '助眠', Icons.bedtime),
    ('开车必备', '车载', Icons.directions_car),
    ('学习专注', '学习', Icons.menu_book),
    ('咖啡时光', '咖啡', Icons.local_cafe),
  ];

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerController.instance;
    return Obx(() {
      if (!MusicService.instance.configured) return const MusicEmptySource();
      return ListView(
        padding:
            const EdgeInsets.fromLTRB(AppTheme.spacingLG, 4, AppTheme.spacingLG, 20),
        children: [
          // 正在播放
          if (p.hasTrack) ...[
            Text('正在播放',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            MusicTrackTile(track: p.current!),
            const SizedBox(height: 20),
          ],
          Text('推荐',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontSubhead + 2,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 2.5,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: _recommend.length,
            itemBuilder: (context, i) {
              final r = _recommend[i];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    Get.to(() => MusicSearchPage(initialKeyword: r.$2)),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundCard,
                    borderRadius:
                        BorderRadius.circular(AppTheme.glassRadiusSmall),
                    border: Border.all(
                        color: AppTheme.glassBorderSoft, width: 0.6),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(r.$3,
                            size: 17, color: AppTheme.accentColor),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(r.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead + 1,
                                fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      );
    });
  }
}

// ============================================================
// 搜索
// ============================================================

class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key, this.initialKeyword});

  final String? initialKeyword;

  @override
  State<MusicSearchPage> createState() => _MusicSearchPageState();
}

class _MusicSearchPageState extends State<MusicSearchPage> {
  final _ctrl = TextEditingController();
  final _svc = MusicService.instance;

  @override
  void initState() {
    super.initState();
    final k = widget.initialKeyword;
    if (k != null && k.isNotEmpty) {
      _ctrl.text = k;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景：让全局壁纸层透出（与首页/史藏统一）
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('搜索',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG, 0, AppTheme.spacingLG, AppTheme.spacingSM),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(21),
                      border:
                          Border.all(color: AppTheme.glassBorder, width: 0.8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search,
                            size: 17, color: AppTheme.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            autofocus: widget.initialKeyword == null,
                            cursorColor: AppTheme.accentColor,
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead + 1),
                            decoration: InputDecoration(
                              hintText: '搜索歌曲 / 歌手 / 专辑',
                              hintStyle: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: AppTheme.fontSubhead + 1),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onSubmitted: (_) => _run(),
                          ),
                        ),
                        if (_ctrl.text.isNotEmpty)
                          GestureDetector(
                            onTap: () => setState(() => _ctrl.clear()),
                            child: Icon(Icons.cancel,
                                size: 16, color: AppTheme.textTertiary),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _run,
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor,
                      borderRadius: BorderRadius.circular(21),
                    ),
                    child: const Text('搜索',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Obx(() {
              if (!_svc.configured) return const MusicEmptySource();
              if (_svc.isSearching.value) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: AppTheme.accentColor),
                      ),
                      const SizedBox(height: 14),
                      Text('正在搜索…',
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontSubhead)),
                    ],
                  ),
                );
              }
              final list = _svc.results;
              if (list.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.music_note_outlined,
                          size: 40,
                          color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                      const SizedBox(height: 12),
                      Text('输入关键词开始搜索',
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontSubhead)),
                      if (_svc.lastError.value.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(_svc.lastError.value,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: AppTheme.fontCaption)),
                        ),
                      ],
                    ],
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.spacingLG, 4, AppTheme.spacingLG, 20),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (c, i) =>
                    MusicTrackTile(track: list[i], queue: list),
              );
            }),
          ),
        ],
      ),
    );
  }

  Future<void> _run() async {
    final k = _ctrl.text.trim();
    if (k.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入关键词')));
      return;
    }
    FocusScope.of(context).unfocus();
    final r = await _svc.search(k);
    if (!mounted) return;
    if (r.tracks.isEmpty && r.message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.message)));
    }
  }
}
