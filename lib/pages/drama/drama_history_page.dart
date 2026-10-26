import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/pages/drama/drama_entry.dart';

/// 短剧「观看记录」页（2026-10-23）。
///
/// 原来把「继续观看」横排塞在短剧列表顶上，占掉一整屏高度；
/// 现在收进顶栏右上角一个按钮，单独一页展示，点一下直接续播。
class DramaHistoryPage extends StatefulWidget {
  const DramaHistoryPage({super.key, required this.sourceKeys});

  /// 只显示这些短剧源下的记录（普通影视记录不混进来）
  final Set<String> sourceKeys;

  @override
  State<DramaHistoryPage> createState() => _DramaHistoryPageState();
}

class _DramaHistoryPageState extends State<DramaHistoryPage> {
  /// 短剧源下、存过播放进度的记录，按最近观看排序
  List<VodRecord> _records() {
    final keys = widget.sourceKeys;
    final out = <VodRecord>[];
    for (final r in CacheStore.instance.records) {
      if (keys.isNotEmpty && !keys.contains(r.sourceKey)) continue;
      final st = CacheStore.instance.getPlaybackState(r.vodId, r.sourceKey);
      if (st == null || st.progressSeconds <= 0) continue;
      out.add(r);
    }
    out.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return out;
  }

  Future<void> _open(VodRecord r) async {
    await DramaEntry.open(Video(
      id: r.vodId,
      name: r.vodName,
      pic: r.vodPic,
      sourceKey: r.sourceKey,
    ));
    if (mounted) setState(() {});
  }

  Future<void> _delete(VodRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除记录',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline)),
        content: Text('删除「${r.vodName}」的观看记录？',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await CacheStore.instance.removeRecord(r.vodId, r.sourceKey);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text('观看记录',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: fg)),
      ),
      body: Obx(() {
        final items = _records();
        if (items.isEmpty) {
          return Center(
            child: Text('还没有观看记录\n看过的短剧会出现在这里',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black45,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.7)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 120),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _row(items[i], isDark),
        );
      }),
    );
  }

  Widget _row(VodRecord r, bool isDark) {
    final st = CacheStore.instance.getPlaybackState(r.vodId, r.sourceKey);
    final ep = (st?.episodeIndex ?? 0) + 1;
    final sec = st?.progressSeconds.toInt() ?? 0;
    final time = '${(sec ~/ 60).toString().padLeft(2, '0')}:'
        '${(sec % 60).toString().padLeft(2, '0')}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(r),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 66,
                height: 88,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (r.vodPic.isEmpty)
                      ColoredBox(color: AppTheme.backgroundTertiary)
                    else
                      CachedNetworkImage(
                        imageUrl: r.vodPic,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            ColoredBox(color: AppTheme.backgroundTertiary),
                      ),
                    Center(
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    r.vodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '第 $ep 集 · $time',
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.accentColor),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _ago(r.updateTime),
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除记录',
              icon: Icon(Icons.delete_outline_rounded,
                  size: 19,
                  color: isDark ? Colors.white38 : Colors.black38),
              onPressed: () => _delete(r),
            ),
          ],
        ),
      ),
    );
  }

  /// 相对时间：今天 / 昨天 / MM-dd
  static String _ago(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} $hm';
  }
}
