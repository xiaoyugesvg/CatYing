import 'package:flutter/material.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/unblock_service.dart';
import 'package:tvbox/music/theme/music_theme.dart';

/// 选音源弹窗 —— 内置接口拿不到地址时，把**所有能播的音源**列出来让用户决定。
///
/// ── 为什么要用户选，而不是程序自动挑 ────────────────────────────
/// 实测：**同一个音源对不同歌的可用性差别很大**，而且多个源都能播时
/// 它们往往**不是同一个版本/音质**（一个给 320K 一个给 128K，
/// 一个给原版一个给 Live）。程序"挑第一个成功的"等于替用户做了
/// 他更清楚的选择。
///
/// ── 🔴 弹窗内**可以反复换源**（用户 2026 要求）──────────────────
/// 原来点任意一行就 `Navigator.pop`，于是"想换个源听听"必须
/// **关掉弹窗 → 再点歌 → 重新等解析 → 弹窗再开**，一轮好几秒。
///
/// 现在：
///   · 列表项**点了不关弹窗** → 立刻用该源播放
///   · 被选中的那条**高亮**并显示"正在播放"
///   · 可以继续点别的源**当场换着试**
///   · 底部一个「完成」按钮用来收工（点弹窗外面也能关）
///
/// ── 🔴 绝不重复弹窗（修一个真实 bug）──────────────────────────
/// `player_manager._load` 在弹窗这里是 `await` 的 —— 而弹窗会**一直
/// 停留在屏幕上等用户操作**。所以"弹窗显示期间用户又点了同一首歌"
/// 会走完第二次解析，**再弹一个窗**，而第一个窗没关 → **叠窗** ✗
///
/// [_showing] 就是那个闸门：同一时间只允许一个选源弹窗存在。
/// 第二个请求直接返回 null（等于"用户没选"），由调用方安静收场 ——
/// 因为此时**已经有一个窗在替用户服务了**。
class SourcePickerSheet extends StatefulWidget {
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

  /// 🔴 闸门：当前是否已有一个选源弹窗在屏幕上。
  ///
  /// 用 `static` 而不是实例字段 —— 要拦的是"**同时存在两个**
  /// `SourcePickerSheet`"，那是跨实例的事实。
  static bool _showing = false;

  /// 弹出并等待用户选择。
  ///
  /// **返回值语义**（与原来不同，调用方务必看懂）：
  ///   · 非 null → 用户**最终选定**的源（用「完成」确认，或点了某行后
  ///     直接关窗）。调用方据此确定 `fromSource` 等信息。
  ///   · null    → **用户没在这一轮选定**（点外面关掉、或已有别的
  ///     弹窗在服务）。调用方**不应该报错**，但也不该把这次的 url 当真。
  ///
  /// ⚠️ 重要：**播放已经由弹窗内部触发**（点行即播），调用方拿到
  ///    非 null 返回值时**不要再播一次**，只需要取用 `fromSource`
  ///    之类的展示信息。见 `player_manager._load` 的处理。
  static Future<SourceResolveResult?> show(
    BuildContext context, {
    required Song song,
    required List<SourceResolveResult> results,
    String failedNote = '',
  }) async {
    // 已有弹窗在屏幕上 → 不叠第二个（见类注释里的 bug 说明）
    if (_showing) return null;
    _showing = true;
    try {
      return await showMusicSheet<SourceResolveResult>(
        context: context,
        backgroundColor: MusicTheme.card,
        isScrollControlled: true,
        builder: (_) => SourcePickerSheet(
          song: song,
          results: results,
          failedNote: failedNote,
        ),
      );
    } finally {
      // 无论正常关闭还是异常，闸门都要放开，否则以后再也弹不出来
      _showing = false;
    }
  }

  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  /// 用户最后一次点选的源（点了就立即试播，但**不关窗**）
  SourceResolveResult? _picked;

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
                    // 换源提示写在副标题里 —— 否则用户不知道"点了不会关"
                    '「${widget.song.name}」找到 ${widget.results.length} 个可用音源'
                    '${widget.results.length > 1 ? ' · 可以换着试' : ''}',
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
                itemCount: widget.results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (c, i) => _row(context, widget.results[i], i),
              ),
            ),

            // ── 失败摘要 ─────────────────────────────────────
            if (widget.failedNote.isNotEmpty)
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
                        widget.failedNote,
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

            // ── 底部按钮 ─────────────────────────────────────
            //
            // ⚠️ 文案随状态变（这很重要）：
            //   · 一次都没点 → 「取消」（此时关窗 = 放弃，不该说"完成"）
            //   · 点过至少一次 → 「完成」（此时关窗 = 保留正在放的这首）
            // 两态共用同一个按钮位，避免底部堆两个按钮。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, _picked),
                  child: Text(
                    _picked == null ? '取消' : '完成',
                    style: TextStyle(
                      color:
                          _picked == null ? MusicTheme.secondary : MusicTheme.tint,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight:
                          _picked == null ? FontWeight.normal : FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点行 = **立即用这个源播放，但弹窗不关**（可以接着换）
  Future<void> _use(SourceResolveResult r) async {
    setState(() => _picked = r);
    // 立刻把音频切到这个源 —— 用户点了就想听到，不该再点一次"确认"
    try {
      await MusicPlayerManager.instance.playResolved(widget.song, r);
    } catch (e) {
      // 播不出来也要把错误说出来，否则用户以为按钮没反应
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('这个音源播放失败：$e')),
        );
      }
    }
  }

  Widget _row(BuildContext context, SourceResolveResult r, int index) {
    final s = r.source;
    // 类型标签：让用户一眼看出这是洛雪还是 MusicFree（两者跑法不同，
    // 出问题时排查方向也不同）
    final kindTag = r.kind == 'musicfree'
        ? 'MusicFree'
        : (r.kind == 'script' ? '洛雪' : '模板');
    // 音质标签显示**这次实际拿到的**档位（各源支持的档位不同，Node 侧
    // 会按 `qualitys` 降级，所以同一个用户在两个源上可能分别是 flac / 320k）。
    // 没有回报时才退回音源默认档（模板法 / 老脚本）。
    final quality = (r.quality.isNotEmpty ? r.quality : (s?.quality ?? '')).trim();
    final isActive = _picked == r;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      // ⚠️ **不再 pop** —— 点了换源继续留在弹窗里（见类注释）
      onTap: () => _use(r),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          // 当前正在用的源高亮，否则用户换完忘了哪个是活的
          color: isActive
              ? MusicTheme.tint.withValues(alpha: 0.14)
              : MusicTheme.fill,
          borderRadius: BorderRadius.circular(12),
          border: isActive
              ? Border.all(color: MusicTheme.tint.withValues(alpha: 0.55), width: 1)
              : null,
        ),
        child: Row(
          children: [
            // 序号：默认第一个是"最靠前导入的源"，用户往往想点它
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive
                    ? MusicTheme.tint.withValues(alpha: 0.22)
                    : MusicTheme.label.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: isActive ? MusicTheme.tint : MusicTheme.secondary,
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
                    isActive
                        ? '正在播放'
                        : (quality.isEmpty ? kindTag : '$kindTag · $quality'),
                    style: TextStyle(
                      color: isActive ? MusicTheme.tint : MusicTheme.secondary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
            ),
            // 右侧图标：高亮那条用"正在播"的波形感，其余是播放键
            if (isActive)
              _PlayingBars(color: MusicTheme.tint)
            else
              Icon(Icons.play_circle_outline, size: 22, color: MusicTheme.tint),
          ],
        ),
      ),
    );
  }
}

/// 三根小竖条的"正在播放"指示（纯装饰，不跑动画 —— 弹窗里没必要
/// 为它开一个 `AnimationController`，静态也有足够辨识度）
class _PlayingBars extends StatelessWidget {
  const _PlayingBars({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    const heights = [8.0, 16.0, 11.0];
    return SizedBox(
      width: 20,
      height: 18,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 2.5),
            Container(
              width: 3,
              height: heights[i],
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
