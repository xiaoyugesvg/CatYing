import 'package:flutter/material.dart';

import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/common/theme.dart';

/// 音乐模块的**页面骨架**组件：大标题 / 返回按钮 / 统计格 / 卡片式导航行。
///
/// ── 为什么单独一个文件（而不是留在 music_components.dart）──────
/// `music_components.dart` 里挂着「添加到歌单」入口，它要 import
/// `pages/playlist_page.dart`；而 `playlist_page.dart` 现在也要用这几个骨架
/// 组件 —— 如果组件留在 `music_components.dart`，就会形成
/// **循环依赖**（能编，但很脏，且改一个文件会牵连另一个）。
///
/// 所以把「不依赖任何页面」的纯展示组件抽到这里：
///   `music_components.dart` → 转导出（老调用点零改动）
///   `playlist_page.dart`    → 直接 import 本文件
/// 依赖方向变成单向：pages → skeleton，components → skeleton + pages ✓
///
/// ── 为什么加这几个（2026-10-30）──────────────────────────────────
/// 用户：「音乐按你设计的 UI 界面，优化美化每一个分类界面吧，还有其余页面。」
///
/// 对照设计稿（outputs/music_ui/「墨律」），各分类页的差距不在内容，
/// 而在**骨架**：
///   · 设计稿每页都是「大标题 + 一行副标题 + 右侧动作」，
///     而代码里只有一行 22 号字，副标题和动作散落各处；
///   · 乐库顶部有「收藏 / 歌单 / 最近 / 下载」四个统计格，代码里没有；
///   · 「我的内容」用的是裸 `ListTile` —— 系统列表长相，
///     跟旁边圆角卡片完全不是一个语言。
///
/// 所以把这几样抽成组件，各页统一换上去，观感自然就一致了。

// ============================================================
// 大标题
// ============================================================

/// 分类页的大标题区（设计稿每页顶部那一块）。
class MusicPageHeader extends StatelessWidget {
  const MusicPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.leading,
    this.padding = const EdgeInsets.fromLTRB(16, 10, 12, 8),
  });

  final String title;

  /// 标题下那一行小字（如「全部存在本机 · 不需要账号」）
  final String? subtitle;

  /// 右侧动作（如「编辑」「新建 +」）
  final Widget? action;

  /// 左侧返回按钮（**push 进来的子页面**用）。
  ///
  /// 子页面不再用 AppBar 的标题（否则和这里的大标题重复两遍），
  /// 但必须留一个返回入口 —— 放在大标题左边就是 iOS「大标题」的常见长相。
  final Widget? leading;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final lead = leading;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (lead != null) ...[
            lead,
            const SizedBox(width: 2),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    height: 1.15,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// 子页面大标题左边的返回按钮（配合 [MusicPageHeader.leading]）。
///
/// 尺寸比 AppBar 默认的小一号（17 图标 / 34 触达区），
/// 因为它是「大标题的一部分」而不是一条独立导航栏。
class MusicBackButton extends StatelessWidget {
  const MusicBackButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap ?? () => Navigator.maybePop(context),
          child: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 17,
            color: MusicTheme.label,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 圆形动作按钮
// ============================================================

/// 大标题右侧那种「圆形淡色动作按钮」（新建 / 播放全部）。
///
/// 和大标题同高（34）。不用 `IconButton` 是因为它自带 48 的触达区，
/// 会把标题行撑高、看起来像独立的一行工具栏。
class MusicRoundAction extends StatelessWidget {
  const MusicRoundAction({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;

  /// 传 null = 按钮不可用（图标变淡、不响应点击）。
  final VoidCallback? onTap;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: enabled
              ? MusicTheme.tint.withValues(alpha: 0.14)
              : MusicTheme.label.withValues(alpha: 0.05),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Icon(
              icon,
              size: 19,
              color: enabled
                  ? MusicTheme.tint
                  : MusicTheme.secondary.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 统计格
// ============================================================

/// 一个统计格的内容（[MusicStatRow] 用）。
class MusicStat {
  const MusicStat({
    required this.value,
    required this.label,
    this.onTap,
  });

  final String value;
  final String label;
  final VoidCallback? onTap;
}

/// 乐库顶部那排统计格（收藏 / 歌单 / 最近 / 下载）。
///
/// 等分排布：2 个两等分、3 个三等分、4 个四等分 —— 与用户对
/// 「源切换按钮」的要求同一套规则，不做固定宽度。
class MusicStatRow extends StatelessWidget {
  const MusicStatRow({super.key, required this.stats, this.spacing = 10});

  final List<MusicStat> stats;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            Expanded(child: _tile(stats[i])),
          ],
        ],
      ),
    );
  }

  Widget _tile(MusicStat s) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: MusicTheme.label.withValues(alpha: 0.05),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.tint,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontCaption,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
    if (s.onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: s.onTap,
      child: content,
    );
  }
}

// ============================================================
// 卡片式导航行
// ============================================================

/// 圆角卡片式的导航行（替代裸 `ListTile`）。
///
/// 左侧图标装在一个淡色圆角方块里 —— 这是设计稿全篇的统一手法，
/// 比裸图标更像"App 里的东西"，而不是系统设置列表。
class MusicNavTile extends StatelessWidget {
  const MusicNavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;

  /// 自定义右侧（如「更多」菜单）；给了它就不再显示箭头。
  final Widget? trailing;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Material(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: MusicTheme.tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 18, color: MusicTheme.tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      if (sub != null && sub.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontCaption,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  trailing!
                else ...[
                  if (trailingText != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        trailingText!,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: MusicTheme.secondary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
