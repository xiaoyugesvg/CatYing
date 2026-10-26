import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/listen_view_toggle.dart';
import 'package:tvbox/music/widgets/music_components.dart';

/// 听书专辑单集列表（公共）。
///
/// 博看 / 喜雅 / 一五的专辑单集列表共用一个实现，内置：
///   · 搜索集数（按标题 / 序号过滤，本地）
///   · 视图切换（列表 / 2 列宫格，持久化到 `SettingsStore.albumGrid`）
///   · 定位（滚到当前播放集，`Scrollable.ensureVisible`）
///   · 排序（正序 / 倒序，持久化到 `SettingsStore.albumSortDesc`）
///
/// [songs] 为**原始（正序）**单集列表；[onPlay] 的回调下标是
/// [songs] 里的**原始下标**（与排序/过滤无关），确保播放索引正确。
class ListenEpisodeList extends StatefulWidget {
  const ListenEpisodeList({
    super.key,
    required this.songs,
    required this.onPlay,
    this.currentIdentityKey,
    this.sourceLabel = '听书',
    this.albumCoverUrl,
    this.albumName,
    this.albumIntro,
    this.albumProgress,
  });

  final List<Song> songs;
  final void Function(int index) onPlay;
  final String? currentIdentityKey;
  final String sourceLabel;

  /// 专辑头部卡片（封面 / 名称 / 简介 / 更新进展），任一字段有值即显示。
  final String? albumCoverUrl;
  final String? albumName;
  final String? albumIntro;
  final String? albumProgress;

  @override
  State<ListenEpisodeList> createState() => _ListenEpisodeListState();
}

class _ListenEpisodeListState extends State<ListenEpisodeList> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 显示列表：过滤 → 排序。元素带原始下标，序号永远按原始位置算。
  List<({Song song, int index})> get _visible {
    final q = _query.trim().toLowerCase();
    final total = widget.songs.length;
    final list = <({Song song, int index})>[];
    for (var i = 0; i < total; i++) {
      final s = widget.songs[i];
      if (q.isEmpty) {
        list.add((song: s, index: i));
        continue;
      }
      final no = '${i + 1}';
      if (s.name.toLowerCase().contains(q) || no == q || '第$no集'.contains(q)) {
        list.add((song: s, index: i));
      }
    }
    return SettingsStore.instance.albumSortDesc.value
        ? list.reversed.toList()
        : list;
  }

  /// 序号显示：正序 = 原始下标 + 1；倒序 = 总数 - 原始下标。
  int _showNo(int originalIndex) =>
      SettingsStore.instance.albumSortDesc.value
          ? widget.songs.length - originalIndex
          : originalIndex + 1;

  /// 子页面底部预留：迷你播放条(56) + 底间隙(8) + Home 指示条安全区。
  ///
  /// 播放条是全局悬浮层（会盖住内容底部），列表底部要留出这段，
  /// 否则最后一集/最后一个专辑会被播放条压住点不到。
  double get _bottomReserve {
    final pad = MediaQuery.paddingOf(context).bottom;
    return 56 + 8 + pad;
  }

  /// 定位到当前播放集。
  Future<void> _locate() async {
    final key = widget.currentIdentityKey;
    if (key == null || key.isEmpty) {
      AppToast.show('无法定位', '还没有正在播放的这一集');
      return;
    }
    ({Song song, int index})? item;
    for (final e in _visible) {
      if (e.song.identityKey == key) {
        item = e;
        break;
      }
    }
    // 被搜索过滤掉了 → 清空搜索再试；仍不在（不在本专辑）→ 提示。
    if (item == null && _query.trim().isNotEmpty) {
      _searchCtrl.clear();
      setState(() => _query = '');
      for (final e in _visible) {
        if (e.song.identityKey == key) {
          item = e;
          break;
        }
      }
    }
    if (item == null) {
      AppToast.show('无法定位', '当前播放集不在此专辑');
      return;
    }
    final target = item;
    // 先让当前搜索/排序状态下的 item 挂载完成，再滚动到它
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = GlobalObjectKey('ep-${target.song.identityKey}').currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        alignment: 0.4,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SettingsStore.instance.albumSortDesc,
      builder: (_, __, ___) => _body(),
    );
  }

  Widget _body() {
    final hasHeader = (widget.albumName ?? '').isNotEmpty ||
        (widget.albumCoverUrl ?? '').isNotEmpty ||
        (widget.albumIntro ?? '').isNotEmpty ||
        (widget.albumProgress ?? '').isNotEmpty;
    return Column(
      children: [
        if (hasHeader) _albumHeader(),
        _toolbar(),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: SettingsStore.instance.albumGrid,
            builder: (_, grid, __) {
              final visible = _visible;
              if (visible.isEmpty) {
                return Center(
                  child: Text(
                    _query.trim().isEmpty
                        ? '这个专辑暂时没有可播放的集数'
                        : '没有匹配「${_query.trim()}」的集数',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontBody),
                  ),
                );
              }
              if (grid == 2) return _grid(visible);
              return _list(visible);
            },
          ),
        ),
      ],
    );
  }

  /// 专辑详情卡片：封面 + 名称 + 更新进展 + 简介（任一字段有值才显示）。
  Widget _albumHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MusicTheme.fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: MusicTheme.secondary.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverImage(url: widget.albumCoverUrl, size: 96, cornerRadius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((widget.albumName ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.albumName!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                  ),
                if ((widget.albumProgress ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      widget.albumProgress!,
                      style: TextStyle(
                        color: MusicTheme.tint,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                if ((widget.albumIntro ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      widget.albumIntro!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                        height: 1.45,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具条：搜索 + 定位 + 排序 + 视图。
  Widget _toolbar() {
    final hasCurrent = (widget.currentIdentityKey ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: MusicTheme.fill,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: MusicTheme.secondary.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded,
                      size: 16, color: MusicTheme.secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontSubhead),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '搜索集数',
                        hintStyle: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontSubhead),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                      child: Icon(Icons.close_rounded,
                          size: 15, color: MusicTheme.secondary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),
          AlbumLocateButton(
            enabled: hasCurrent,
            onLocate: _locate,
          ),
          const AlbumSortToggle(),
          const AlbumViewToggle(),
        ],
      ),
    );
  }

  Widget _list(List<({Song song, int index})> visible) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(0, 4, 0, _bottomReserve),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = visible[i];
        final playing = e.song.identityKey == widget.currentIdentityKey;
        return ListTile(
          key: GlobalObjectKey('ep-${e.song.identityKey}'),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: playing
                  ? MusicTheme.tint.withValues(alpha: 0.18)
                  : MusicTheme.fill,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: playing
                ? Icon(Icons.graphic_eq_rounded,
                    size: 17, color: MusicTheme.tint)
                : Text(
                    '${_showNo(e.index)}',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w600),
                  ),
          ),
          title: Text(
            e.song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: playing ? MusicTheme.tint : MusicTheme.label,
              fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          trailing: playing
              ? Icon(Icons.volume_up_rounded,
                  size: 18, color: MusicTheme.tint)
              : Icon(Icons.play_arrow_rounded,
                  size: 18, color: MusicTheme.secondary),
          onTap: () => widget.onPlay(e.index),
        );
      },
    );
  }

  Widget _grid(List<({Song song, int index})> visible) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 8, 16, _bottomReserve),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 116,
      ),
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final e = visible[i];
        final playing = e.song.identityKey == widget.currentIdentityKey;
        return GestureDetector(
          key: GlobalObjectKey('ep-${e.song.identityKey}'),
          onTap: () => widget.onPlay(e.index),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            decoration: BoxDecoration(
              color: playing
                  ? MusicTheme.tint.withValues(alpha: 0.14)
                  : MusicTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: playing
                    ? MusicTheme.tint.withValues(alpha: 0.5)
                    : MusicTheme.label.withValues(alpha: 0.06),
                width: 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: playing
                            ? MusicTheme.tint
                            : MusicTheme.tint.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: playing
                          ? Icon(Icons.graphic_eq_rounded,
                              size: 16, color: Colors.white)
                          : Text(
                              '${_showNo(e.index)}',
                              style: TextStyle(
                                color: MusicTheme.tint,
                                fontSize: AppTheme.fontCaption,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    const Spacer(),
                    Icon(
                      playing
                          ? Icons.volume_up_rounded
                          : Icons.play_arrow_rounded,
                      size: 16,
                      color: playing
                          ? MusicTheme.tint
                          : MusicTheme.secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  e.song.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: playing ? MusicTheme.tint : MusicTheme.label,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.3,
                    fontWeight: playing ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
