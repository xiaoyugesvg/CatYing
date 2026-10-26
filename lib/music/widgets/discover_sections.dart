import 'package:flutter/material.dart';

// ⚠️ 这里原来写的是 `'../../../common/theme.dart'`（**多了一层 `../`**）。
//    实测它**不会报错** —— Dart 解析相对 import 时会把超出包根（`lib/`）的
//    层级收敛掉，所以两层和三层都落到 `lib/common/theme.dart`。
//    但那个多出来的 `../` 表达的是"再往外一层"的错误意图，
//    对读代码的人是误导（同目录的 `music_components.dart` 写的就是两层）。
//    改成正确写法，行为不变。
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/theme/discover_preset.dart';
import 'package:tvbox/music/widgets/music_components.dart';

/// 发现页的三个区块组件 —— **对齐 Beans 的 DiscoverView 规格**。
///
/// ── 与旧实现的差别（照 Beans 抄的部分）─────────────────────────
/// | 区块 | 旧 | 新（Beans）|
/// |---|---|---|
/// | 每日推荐 | 152 宽通用卡 | **108 封面 + VIP 标 + 播放徽标（含均衡器动画）** |
/// | 排行榜 | 横向大卡 | **单卡片内竖排列**，前 3 名用主题色，收起 3 / 展开 10 |
/// | 歌单广场 | 单列横滑 | **2 列网格**，144 封面，收起 6 / 展开 |
///
/// ── 🔴 主题统一（用户要求）────────────────────────────────────
/// 这些组件**全部接收 [DiscoverStyle]**，颜色只从中取（而它又派生自
/// `MusicTheme`/`JellyPalette`）。所以：
///   · 换全局 7 套主题 → 这里跟着变
///   · 切三套预设 → 只有材质（alpha / 描边）变，**颜色不变**
/// 组件内**不出现任何写死的色值**（除了 VIP 红这种语义色）。

/// 卡片容器：按预设给"玻璃 / 实心"两种材质。
///
/// Beans 用 `BeansGlass`（iOS 26 玻璃 / 降级 ultraThinMaterial）。
/// Flutter 侧不用 `BackdropFilter` —— 它在滚动列表里**逐帧重算模糊**，
/// 在 iOS 上很容易掉帧。这里用"半透明填充 + 细描边"达到近似观感，
/// 代价几乎为零（这也是 paper 预设最省电的原因）。
class PresetCard extends StatelessWidget {
  const PresetCard({
    super.key,
    required this.style,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.onTap,
  });

  final DiscoverStyle style;
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isPaper = style.preset == DiscoverPreset.paper;
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: style.cardFill.withValues(alpha: style.fillAlpha),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: style.primary.withValues(alpha: isPaper ? 0.07 : 0.10),
          width: 0.8,
        ),
      ),
      child: child,
    );
    if (onTap == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: body,
    );
  }
}

/// 「展开 / 收起」按钮（Beans：主题色文字 + chevron，撑满宽，上下 11）
class ExpandToggle extends StatelessWidget {
  const ExpandToggle({
    super.key,
    required this.style,
    required this.expanded,
    required this.total,
    required this.onTap,
    this.collapsedLabel = '展开全部',
    this.expandedLabel = '收起',
    this.collapsedCount = 6,
  });

  final DiscoverStyle style;
  final bool expanded;
  final int total;
  final VoidCallback onTap;
  final String collapsedLabel;
  final String expandedLabel;
  final int collapsedCount;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              expanded ? expandedLabel : '$collapsedLabel（$total）',
              style: TextStyle(
                color: style.accent,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 18,
              color: style.accent,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 区块 1：每日推荐（横滑卡）
// ============================================================

/// 每日推荐横滑卡。
///
/// Beans 规格：封面 **108**、圆角 16、卡片间距 12、最多 **8** 张。
/// 封面上有两个角标：
///   · 左上 **VIP**（语义色红，仅 isVIP）
///   · 右下 **播放徽标 24×24** → 播放中显示 3 根跳动的均衡器（主题色）
class DailySongsRow extends StatefulWidget {
  const DailySongsRow({
    super.key,
    required this.style,
    required this.songs,
    required this.playingKey,
    required this.isPlaying,
    required this.onPlay,
    this.maxCount = 8,
  });

  final DiscoverStyle style;
  final List<Song> songs;

  /// 当前播放歌的 [Song.identityKey]（用来决定哪张卡显示徽标状态）
  final String? playingKey;
  final bool isPlaying;
  final void Function(int index) onPlay;
  final int maxCount;

  @override
  State<DailySongsRow> createState() => _DailySongsRowState();
}

class _DailySongsRowState extends State<DailySongsRow>
    with SingleTickerProviderStateMixin {
  /// 均衡器动画控制器。
  ///
  /// 🔴 **必须在这里声明、在 `initState()` 里创建** —— 不能写成
  ///     `late final _eq = AnimationController(...)`
  ///
  /// 原因是 `late final` 是**惰性**的：如果组件从头到尾**没被 build 过**
  ///（典型场景：`songs` 为空 → `build` 直接返回 `SizedBox.shrink()`），
  /// `_eq` 就**从未被初始化**。而 `dispose()` 的第一句通常是
  /// `_eq.dispose()` → **反而触发了惰性初始化** → 此时 element 已经
  /// deactivated → `AnimationController` 构造里去查 `TickerMode` 祖先
  /// → 抛 `Looking up a deactivated widget's ancestor is unsafe`。
  ///
  /// 实测栈（`discover_sections_test.dart` 抓到）：
  ///   `_eq (discover_sections.dart:158)` ← `dispose (…:165)`
  ///   ← `StatefulElement.unmount`
  ///
  /// 这个坑在真机上同样会发生（不是测试环境特有）——
  /// 只要进过一次"空列表"的发现页再离开就会踩到。
  late final AnimationController _eq;

  @override
  void initState() {
    super.initState();
    _eq = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // ⚠️ 只在**真的要显示均衡器**时才转：空列表/没有当前歌时白转是浪费
    if (_needsEqualizer) _eq.repeat(reverse: true);
  }

  /// 是否需要均衡器（当前播放歌在本列表里，且正在播）
  bool get _needsEqualizer {
    final key = widget.playingKey;
    if (key == null || !widget.isPlaying) return false;
    return widget.songs.take(widget.maxCount).any((s) => s.identityKey == key);
  }

  @override
  void didUpdateWidget(DailySongsRow old) {
    super.didUpdateWidget(old);
    // 播放状态/当前歌变化时，决定是否继续转
    if (_needsEqualizer) {
      if (!_eq.isAnimating) _eq.repeat(reverse: true);
    } else {
      if (_eq.isAnimating) {
        _eq.stop();
        _eq.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _eq.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.songs.take(widget.maxCount).toList();
    if (list.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (c, i) => _card(list[i], i),
      ),
    );
  }

  Widget _card(Song s, int i) {
    final isCurrent = widget.playingKey != null &&
        widget.playingKey == s.identityKey;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onPlay(i),
      child: SizedBox(
        width: 108,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                CoverImage(url: s.coverUrl, size: 108, cornerRadius: 16),
                // 左上 VIP
                if (s.isVIP)
                  const Positioned(top: 6, left: 6, child: VipBadge()),
                // 右下播放徽标
                Positioned(
                  right: 7,
                  bottom: 7,
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    // ── 🔴 徽标必须区分"在播"和"暂停"（修一个死分支）────
                    //
                    // 原来写的是：
                    //   child: isCurrent
                    //       ? _equalizer()
                    //       : Icon(isCurrent && widget.isPlaying
                    //              ? Icons.pause_rounded
                    //              : Icons.play_arrow_rounded, ...)
                    //
                    // 进入 `else` 时 `isCurrent` **必为 false** →
                    // `isCurrent && widget.isPlaying` 恒 false →
                    // **`pause_rounded` 永远取不到**（死代码）。
                    // 而 `isCurrent == true` 时**无条件**渲染 `_equalizer()`，
                    // 即使已暂停（此时 `didUpdateWidget` 已 `_eq.stop()`、
                    // 相位归零）→ 三根柱子**静止不动**，看起来仍像"正在播放" ✗
                    //
                    // 现在：只有"正在播"才显示均衡器，暂停/未播显示三角。
                    child: (isCurrent && widget.isPlaying)
                        ? _equalizer()
                        : Icon(
                            Icons.play_arrow_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.style.primary,
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              // 歌手空则回落到专辑（Beans 同款兜底）
              s.artists.trim().isNotEmpty ? s.artists : s.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.style.secondary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 3 根跳动的均衡器（Beans 的 NowPlayingIndicator）
  Widget _equalizer() {
    return AnimatedBuilder(
      animation: _eq,
      builder: (c, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(3, (k) {
            // 每根错开相位（Beans 是 delay index×0.12）
            final t = ((_eq.value + k * 0.33) % 1.0);
            final h = 4.0 + 8.0 * (t < 0.5 ? t * 2 : (1 - t) * 2);
            return Padding(
              padding: EdgeInsets.only(left: k == 0 ? 0 : 2),
              child: Container(
                width: 2.5,
                height: h,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ============================================================
// 区块 2：排行榜（单卡片内竖排）
// ============================================================

/// 排行榜列表 —— **单张卡片内竖排行**（Beans 规格）。
///
/// 关键规格：
///   · 卡片圆角 **22**，内边距 水平14/垂直6
///   · 行：名次（宽 24，**前 3 名主题色**）→ 封面 52 圆角 12 → 榜名/副标题
///   · 行间距 vertical 8，行间 1px 分隔线
///   · 收起 **3** 行，展开最多 **10** 行
class RankListCard extends StatefulWidget {
  const RankListCard({
    super.key,
    required this.style,
    required this.items,
    required this.onTap,
    this.collapsedCount = 3,
    this.maxCount = 10,
  });

  final DiscoverStyle style;
  final List<TopList> items;
  final void Function(TopList item) onTap;
  final int collapsedCount;
  final int maxCount;

  @override
  State<RankListCard> createState() => _RankListCardState();
}

class _RankListCardState extends State<RankListCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;
    final limit = _expanded
        ? total.clamp(0, widget.maxCount)
        : total.clamp(0, widget.collapsedCount);
    final shown = widget.items.take(limit).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          PresetCard(
            style: widget.style,
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      color: widget.style.secondary.withValues(alpha: 0.12),
                    ),
                  _row(shown[i], i),
                ],
              ],
            ),
          ),
          // 收起时只有"确实还有更多"才给展开按钮（Beans 同款判断）
          if (total > widget.collapsedCount || _expanded)
            ExpandToggle(
              style: widget.style,
              expanded: _expanded,
              total: total.clamp(0, widget.maxCount),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
    );
  }

  Widget _row(TopList t, int i) {
    // 前 3 名用主题色（Beans：名次 font 16 bold rounded）
    final rankColor = i < 3 ? widget.style.accent : widget.style.secondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${i + 1}',
                style: TextStyle(
                  color: rankColor,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            CoverImage(url: t.coverUrl, size: 52, cornerRadius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.style.primary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((t.updateFrequency ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      t.updateFrequency!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.style.secondary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: widget.style.secondary.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 区块 3：歌单广场（2 列网格）
// ============================================================

/// 歌单广场 —— **固定 2 列网格**（Beans 规格）。
///
/// 关键规格：封面 **144** 圆角 18（Beans 是固定 144 居中，
/// 不是随列宽拉伸 —— 这里照抄，避免大屏上封面被拉得很大很糊）。
/// 收起 **6** 个，展开全部。
class PlaylistGrid extends StatefulWidget {
  const PlaylistGrid({
    super.key,
    required this.style,
    required this.items,
    required this.onTap,
    this.collapsedCount = 6,
  });

  final DiscoverStyle style;
  final List<Playlist> items;
  final void Function(Playlist item) onTap;
  final int collapsedCount;

  @override
  State<PlaylistGrid> createState() => _PlaylistGridState();
}

class _PlaylistGridState extends State<PlaylistGrid> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;
    final shown = _expanded
        ? widget.items
        : widget.items.take(widget.collapsedCount).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              // 封面 144 + 文字两行 + 内边距
              mainAxisExtent: 196,
            ),
            itemCount: shown.length,
            itemBuilder: (c, i) => _card(shown[i]),
          ),
          if (total > widget.collapsedCount)
            ExpandToggle(
              style: widget.style,
              expanded: _expanded,
              total: total,
              onTap: () => setState(() => _expanded = !_expanded),
              // ⚠️ **不要**在这里再拼一次计数：`ExpandToggle` 内部已经
              //    渲染成 `'$collapsedLabel（$total）'`（见 `ExpandToggle.build`）。
              //    原来传的是 `'展开全部（$total）'` → 界面上显示
              //    「展开全部（12）（12）」，两个计数挨在一起 ✗
              collapsedLabel: '展开全部',
              expandedLabel: '收起歌单广场',
            ),
        ],
      ),
    );
  }

  Widget _card(Playlist p) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap(p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面固定 144 居中（Beans 同款：不是撑满列宽）
          Center(
            child: CoverImage(url: p.coverUrl, size: 144, cornerRadius: 18),
          ),
          const SizedBox(height: 6),
          Text(
            p.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: widget.style.primary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
