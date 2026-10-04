import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../services/tts_service.dart';

/// 独立听书全屏页（参考图 IMG_8509）：
/// 封面为背景深色渐变 + 书名/作者 + 章节名 + 当前句预览
/// + 进度条（8/71句 · 本章10%）+ 控制按钮 + 倍速 + 播放列表 + 收起。
class TtsFullPlayerPage extends StatelessWidget {
  const TtsFullPlayerPage({
    super.key,
    required this.bookName,
    required this.author,
    required this.chapterName,
    required this.segments,
    this.coverUrl,
    this.chapterNames = const [],
    this.onSelectChapter,
  });

  final String bookName;
  final String author;
  final String chapterName;
  final List<String> segments;
  final String? coverUrl;
  final List<String> chapterNames;
  final ValueChanged<int>? onSelectChapter;

  TtsService get _tts => TtsService.instance;

  @override
  Widget build(BuildContext context) {
    final tts = _tts;
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 背景：封面图（失败/无封面 → 深色渐变）────────────
          if (coverUrl != null && coverUrl!.isNotEmpty)
            CachedNetworkImage(
              imageUrl: coverUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const _BgGradient(),
              placeholder: (_, __) => const _BgGradient(),
            )
          else
            const _BgGradient(),
          // 遮罩：保证文字可读
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.35),
                  Colors.black.withValues(alpha: 0.8),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // ── 顶栏：收起 + 书名 + 章号 ────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '收起',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded,
                            color: Colors.white),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          bookName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (chapterNames.isNotEmpty)
                        Text('${_curChapterNo()}/${chapterNames.length}章',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: AppTheme.fontFootnote)),
                    ],
                  ),
                ),
                const Spacer(),
                // ── 中部：书名/章节 + 当前句预览 ──────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bookName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              height: 1.25)),
                      if (author.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: AppTheme.fontSubhead),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        chapterName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: AppTheme.fontBody),
                      ),
                      const SizedBox(height: 26),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16)),
                        ),
                        child: Obx(() {
                          final i = tts.currentIndex.value;
                          final cur =
                              (i >= 0 && i < segments.length) ? segments[i] : '';
                          return Text(
                            cur.isEmpty ? '点下方播放开始朗读本章' : cur,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: AppTheme.fontBody,
                                height: 1.55),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // ── 进度：Slider + 8/71句 · 本章10% ───────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Obx(() {
                        final i = tts.currentIndex.value;
                        final n = segments.isEmpty ? 1 : segments.length;
                        final pct = ((i + 1) / n * 100).round();
                        return Row(
                          children: [
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor:
                                      Colors.white.withValues(alpha: 0.25),
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  value: i.toDouble().clamp(
                                      0.0, (n - 1).toDouble()),
                                  max: (n - 1).toDouble().clamp(1.0, 1e9),
                                  onChanged: (v) =>
                                      tts.jumpTo(v.round()),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('${i + 1}/$n句 · 本章$pct%',
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: AppTheme.fontFootnote)),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
                // ── 控制行 ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Obx(() {
                    final speaking = tts.isSpeaking.value;
                    final paused = tts.isPaused.value;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundBtn(
                          tooltip: '上一句',
                          icon: Icons.skip_previous_rounded,
                          onTap: () =>
                              tts.jumpTo(tts.currentIndex.value - 1),
                        ),
                        _RoundBtn(
                          tooltip: '播放列表',
                          icon: Icons.queue_music_rounded,
                          onTap: () => _showPlaylist(context),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (speaking) {
                              tts.pause();
                            } else if (paused) {
                              tts.resume();
                            } else {
                              final text = segments.join('\n');
                              if (text.trim().isNotEmpty) tts.speak(text);
                            }
                          },
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              speaking
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                              color: const Color(0xFF141419),
                            ),
                          ),
                        ),
                        _RoundBtn(
                          tooltip: '下一句',
                          icon: Icons.skip_next_rounded,
                          onTap: () =>
                              tts.jumpTo(tts.currentIndex.value + 1),
                        ),
                        _RoundBtn(
                          tooltip: '倍速',
                          icon: Icons.speed_rounded,
                          text: tts.rate.value == 1.0
                              ? '1×'
                              : '${tts.rate.value.toStringAsFixed(1).replaceAll('.0', '')}×',
                          onTap: () {
                            const rates = [0.5, 1.0, 1.5, 2.0];
                            var next = rates.first;
                            for (final r in rates) {
                              if (r > tts.rate.value + 1e-6) {
                                next = r;
                                break;
                              }
                            }
                            if (next <= tts.rate.value) next = rates.first;
                            tts.setRate(next);
                          },
                        ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 当前章在播放列表里的序号（找不到时按 1 计）
  int _curChapterNo() {
    final i = chapterNames.indexOf(chapterName);
    return i < 0 ? 1 : i + 1;
  }

  /// 播放列表：章节选择（选择后回阅读器由 onSelectChapter 跳章续读）
  void _showPlaylist(BuildContext context) {
    if (chapterNames.isEmpty || onSelectChapter == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.75,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E26),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Text('播放列表',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapterNames.length,
                  itemBuilder: (c, i) => ListTile(
                    dense: true,
                    leading: Text(
                      '${i + 1}',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: AppTheme.fontFootnote),
                    ),
                    title: Text(
                      chapterNames[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppTheme.fontBody),
                    ),
                    trailing: chapterNames[i] == chapterName
                        ? const Icon(Icons.graphic_eq_rounded,
                            color: Colors.white, size: 18)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx); // 播放列表
                      Navigator.pop(context); // 全屏页
                      onSelectChapter!(i);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BgGradient extends StatelessWidget {
  const _BgGradient();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF2B2B38),
            Color(0xFF141419),
            Color(0xFF0B0B10),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.text,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final String? text;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: text != null
            ? Center(
                child: Text(text!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w700)),
              )
            : Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }
}
