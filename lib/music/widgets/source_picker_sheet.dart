import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/models.dart';
import '../services/unblock_service.dart';
import '../theme/music_theme.dart';

/// 选音源弹窗 —— 内置接口拿不到地址时，把**所有能播的音源**列出来让用户决定。
///
/// ── 为什么要用户选，而不是程序自动挑 ────────────────────────────
/// 实测：**同一个音源对不同歌的可用性差别很大**，而且多个源都能播时
/// 它们往往**不是同一个版本/音质**：
///   · 一个源给 320K，另一个给 128K
///   · 一个给原版，另一个给 Live
/// 程序"挑第一个成功的"等于**替用户做了他更清楚的选择**。
///
/// 所以：全试一遍 → 全列出来 → 用户点哪个放哪个。
///
/// ── 交互 ──────────────────────────────────────────────────────
/// · 列表项显示：**音源名** + 类型标签（洛雪/MusicFree/模板）+ 音质
/// · 点了直接播（返回该项），点外面/下滑关闭 = 放弃（返回 null）
/// · 只有一条时**照样弹** —— 让用户知道"这首歌是靠哪个源播的"，
///   而不是莫名其妙开始播放
class SourcePickerSheet extends StatelessWidget {
  const SourcePickerSheet({
    super.key,
    required this.song,
    required this.results,
    this.failedNote = '',
  });

  /// 正在解析的歌（弹窗标题显示它，避免用户忘了点的是哪首）
  final Song song;

  /// 所有**成功**的解析结果（按用户导入音源的顺序）
  final List<SourceResolveResult> results;

  /// 失败摘要（可空）。显示在底部，让用户知道"有些源试了但不行"
  final String failedNote;

  /// 弹出并等待用户选择。返回 null = 用户放弃。
  static Future<SourceResolveResult?> show(
    BuildContext context, {
    required Song song,
    required List<SourceResolveResult> results,
    String failedNote = '',
  }) {
    return showModalBottomSheet<SourceResolveResult>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SourcePickerSheet(
        song: song,
        results: results,
        failedNote: failedNote,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        // 最多占屏幕 62%，避免长列表把弹窗拉满
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 拖动条 ──────────────────────────────────────
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 12),
              decoration: BoxDecoration(
                color: MusicTheme.label.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // ── 标题：当前歌 ────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '选择音源播放',
                    style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    results.length == 1
                        ? '「${song.name}」找到 1 个可用的音源'
                        : '「${song.name}」找到 ${results.length} 个可用的音源',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── 音源列表 ────────────────────────────────────
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (c, i) => _row(context, results[i], i),
              ),
            ),

            // ── 失败摘要 + 取消 ─────────────────────────────
            if (failedNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: MusicTheme.secondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        failedNote,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('取消',
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontSubhead)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SourceResolveResult r, int index) {
    final s = r.source;
    // 类型标签：让用户一眼看出这是洛雪还是 MusicFree（两者跑法不同，
    // 出问题时排查方向也不同）
    final kindTag = r.kind == 'musicfree'
        ? 'MusicFree'
        : (r.kind == 'script' ? '洛雪' : '模板');
    final quality = (s?.quality ?? '').trim();

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(context, r),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: MusicTheme.fill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // 序号：默认第一个是"最靠前导入的源"，用户往往想点它
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: index == 0
                    ? MusicTheme.tint.withValues(alpha: 0.18)
                    : MusicTheme.label.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: index == 0 ? MusicTheme.tint : MusicTheme.secondary,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s?.name ?? '未知音源',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    quality.isEmpty ? kindTag : '$kindTag · $quality',
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.play_circle_outline, size: 22, color: MusicTheme.tint),
          ],
        ),
      ),
    );
  }
}
