import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import 'player_controller.dart';

/// 音乐播放页 —— 旋转唱片 + 歌曲信息 + 进度 + 控制栏
///
/// 参照你的截图：
///   顶栏  ♡        歌名/歌手        ＋
///   中间  缓慢旋转的圆形唱片（封面）
///   下方  「歌名 - 歌手」 + 词作者
///   右侧  转发 / 收藏 / 更多 三个圆形按钮
///   进度条 + 时间
///   底部  ⏮  ▶  ⏭   以及 随机 / 评论 / 列表
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  final p = MusicPlayerController.instance;

  /// 唱片旋转动画
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void initState() {
    super.initState();
    if (p.playing.value) _spin.repeat();
    // 播放状态驱动旋转：暂停时停住（像真唱片机）
    ever(p.playing, (v) {
      if (v) {
        _spin.repeat();
      } else {
        _spin.stop();
      }
    });
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景：让全局壁纸层透出（与首页/史藏统一）
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingXL),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    _buildDisc(),
                    const SizedBox(height: 28),
                    _buildTitleBlock(),
                    const SizedBox(height: 18),
                    _buildProgress(),
                    const SizedBox(height: 10),
                    _buildControls(),
                    const SizedBox(height: 16),
                    _buildBottomRow(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 顶栏
  // ============================================================

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingMD, AppTheme.spacingMD, AppTheme.spacingMD, 0),
      child: Row(
        children: [
          _circleBtn(Icons.favorite_border, '收藏', () {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('收藏功能待接入')));
          }),
          const Spacer(),
          // 中间：歌名 + 歌手（两行）
          Obx(() {
            final t = p.current;
            if (t == null) {
              return Text('未在播放',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead + 1));
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 1,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(t.artist.isEmpty ? '未知歌手' : t.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption)),
              ],
            );
          }),
          const Spacer(),
          _circleBtn(Icons.add, '添加到歌单', () {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('歌单功能待接入')));
          }),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
          ),
          child: Icon(icon, size: 18, color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  // ============================================================
  // 旋转唱片
  // ============================================================

  Widget _buildDisc() {
    return Obx(() {
      final t = p.current;
      final size = math.min(MediaQuery.of(context).size.width * 0.78, 330.0);
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 外圈：缓慢旋转
            RotationTransition(
              turns: _spin,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 唱片边缘的暗色环
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.backgroundCard,
                      AppTheme.backgroundSecondary,
                      AppTheme.backgroundPrimary,
                    ],
                    stops: const [0.0, 0.86, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(18),
                child: ClipOval(
                  child: (t == null || t.coverUrl.isEmpty)
                      ? _discPlaceholder(size)
                      : CachedNetworkImage(
                          imageUrl: t.coverUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _discPlaceholder(size),
                          errorWidget: (_, __, ___) => _discPlaceholder(size),
                        ),
                ),
              ),
            ),
            // 中心轴（不旋转，压在封面之上，像唱片中孔）
            Container(
              width: size * 0.14,
              height: size * 0.14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.backgroundPrimary,
                border: Border.all(
                    color: AppTheme.glassBorderSoft, width: 1.5),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _discPlaceholder(double size) => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: Icon(Icons.music_note,
              size: size * 0.22, color: AppTheme.textTertiary),
        ),
      );

  // ============================================================
  // 标题 / 信息
  // ============================================================

  Widget _buildTitleBlock() {
    return Obx(() {
      final t = p.current;
      if (t == null) {
        return Column(
          children: [
            Text('还没有播放任何歌曲',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead + 1)),
            const SizedBox(height: 8),
            Text('去搜索页找一首歌试试',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption)),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左：歌名 - 歌手 + 词作者
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.artist.isEmpty ? t.title : '${t.title} - ${t.artist}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1.25),
                ),
                const SizedBox(height: 8),
                Text(
                  t.album.isEmpty ? '词： 未知' : '专辑： ${t.album}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 右：转发 / 收藏 / 更多（竖排）
          Column(
            children: [
              _roundAction(Icons.share_outlined, () {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分享功能待接入')));
              }),
              const SizedBox(height: 10),
              _roundAction(Icons.favorite, () {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('收藏功能待接入')));
              }),
              const SizedBox(height: 10),
              _roundAction(Icons.more_horiz, _openMoreSheet),
            ],
          ),
        ],
      );
    });
  }

  Widget _roundAction(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Icon(icon, size: 19, color: AppTheme.textSecondary),
      ),
    );
  }

  // ============================================================
  // 进度
  // ============================================================

  Widget _buildProgress() {
    return Obx(() {
      final total = p.duration.value.inMilliseconds.toDouble();
      final cur = p.position.value.inMilliseconds
          .clamp(0, total > 0 ? total.toInt() : 0)
          .toDouble();
      return Column(
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2.5,
              activeTrackColor: AppTheme.textPrimary,
              inactiveTrackColor:
                  AppTheme.textTertiary.withValues(alpha: 0.28),
              thumbColor: AppTheme.textPrimary,
              overlayColor: AppTheme.textPrimary.withValues(alpha: 0.1),
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: total > 0 ? cur.clamp(0, total) : 0,
              max: total > 0 ? total : 1,
              onChanged: total > 0
                  ? (v) => p.seek(Duration(milliseconds: v.round()))
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(p.position.value),
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        fontFamily: 'monospace')),
                Text(_fmt(p.duration.value),
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
        ],
      );
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 控制栏
  // ============================================================

  Widget _buildControls() {
    return Obx(() {
      final busy = p.resolving.value;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _bigBtn(Icons.skip_previous, 52, p.prev),
          const SizedBox(width: AppTheme.spacingXXL),
          // 播放 / 暂停（最大）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: busy ? null : p.togglePlay,
            child: Container(
              width: 68,
              height: 68,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.textPrimary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: busy
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: AppTheme.textPrimary),
                    )
                  : Icon(
                      p.playing.value ? Icons.pause : Icons.play_arrow,
                      size: 34,
                      color: AppTheme.textPrimary,
                    ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingXXL),
          _bigBtn(Icons.skip_next, 52, p.next),
        ],
      );
    });
  }

  Widget _bigBtn(IconData icon, double size, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Icon(icon, size: 24, color: AppTheme.textPrimary),
      ),
    );
  }

  // ============================================================
  // 底部行：随机 / 评论 / 列表
  // ============================================================

  Widget _buildBottomRow() {
    return Row(
      children: [
        Obx(() => _plainIcon(
              p.playMode.value == 2 ? Icons.shuffle : Icons.repeat,
              p.playModeLabel,
              p.cyclePlayMode,
            )),
        const Spacer(),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('评论功能待接入'))),
          child: Row(
            children: [
              Text('609 评论',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption)),
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_up,
                  size: 15, color: AppTheme.textTertiary),
            ],
          ),
        ),
        const Spacer(),
        _plainIcon(Icons.queue_music, '播放列表', _openQueueSheet),
      ],
    );
  }

  Widget _plainIcon(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Icon(icon, size: 21, color: AppTheme.textTertiary),
      ),
    );
  }

  // ============================================================
  // 弹窗
  // ============================================================

  Future<void> _openQueueSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Obx(() {
          final q = p.queue;
          if (q.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text('播放列表是空的',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontSubhead)),
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: Row(
                  children: [
                    Text('播放列表（${q.length}）',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: q.length,
                  itemBuilder: (c, i) {
                    final t = q[i];
                    final active = i == p.index.value;
                    return ListTile(
                      leading: Icon(
                        active ? Icons.graphic_eq : Icons.music_note,
                        size: 18,
                        color: active
                            ? AppTheme.accentColor
                            : AppTheme.textTertiary,
                      ),
                      title: Text(t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: active
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead)),
                      subtitle: Text(t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption)),
                      trailing: Text(t.durationText,
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption)),
                      onTap: () {
                        Navigator.pop(ctx);
                        p.playTrack(t);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
          );
        }),
      ),
    );
  }

  Future<void> _openMoreSheet() async {
    final t = p.current;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            if (t != null && t.audioUrl.isNotEmpty)
              ListTile(
                leading: Icon(Icons.link,
                    size: 18, color: AppTheme.textSecondary),
                title: Text('查看播放地址',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead)),
                subtitle: Text(t.audioUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption)),
              ),
            ListTile(
              leading: Icon(Icons.timer_outlined,
                  size: 18, color: AppTheme.textSecondary),
              title: Text('睡眠定时',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead)),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('睡眠定时待接入')));
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
