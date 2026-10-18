import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../reading/services/settings_service.dart';
import '../../../services/nav_feature_service.dart';
import 'nav_appearance_page.dart';
import 'settings_shared.dart';

/// 设置 → 主页页面
///
/// 对应参考图：分「已启用 / 未启用」两段，长按拖动排序，开关控制是否出现在底栏。
/// 首页与设置是必需页面，不可关闭。
class HomePagesSettingsPage extends StatelessWidget {
  const HomePagesSettingsPage({super.key});

  static const _iconOf = <NavFeature, IconData>{
    NavFeature.home: Icons.home_outlined,
    NavFeature.live: Icons.live_tv_outlined,
    NavFeature.music: Icons.library_music_outlined,
    NavFeature.books: Icons.menu_book_outlined,
    NavFeature.apps: Icons.widgets_outlined,
    // RSS / 海阔：之前漏了这两项 ⇒ 菜单设置里它们显示成默认灰圆圈，
    // 与其它项不一致（NavFeature 自己带 icon getter，这里只是复刻一份）
    NavFeature.rss: Icons.rss_feed_outlined,
    NavFeature.hiker: Icons.rocket_launch_outlined,
    NavFeature.emby: Icons.video_settings_outlined,
    NavFeature.shelf: Icons.video_library_outlined,
    NavFeature.settings: Icons.settings_outlined,
    NavFeature.search: Icons.search,
  };

  @override
  Widget build(BuildContext context) {
    final svc = NavFeatureService.instance;
    return SettingsSubPage(
      title: '主页页面',
      children: [
        // ---------- 首页幻灯片（顶部轮播）样式 ----------
        // 用户 2026-10-14：这一组要排在「主页页面」的**最前面**
        //   （原来排在「悬浮导航栏」之后）。
        ListenableBuilder(
          listenable: SettingsService(),
          builder: (context, _) {
            final s = SettingsService();
            return SettingsGroup(
              title: '首页幻灯片',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('幻灯样式',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead + 0.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('切换首页顶部轮播的呈现方式',
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption)),
                      const SizedBox(height: 10),
                      // 用户 2026-10-14：卡片**一样宽**、**一行多排几个**
                      //   （原来是按文字宽度的胶囊 + Wrap，宽窄不齐、一行几个碰运气）
                      _styleGrid([
                        for (final st in HomeBannerStyle.values)
                          _styleCard(
                            st,
                            s.homeBannerStyle == st,
                            () => s.setHomeBannerStyle(st),
                          ),
                      ]),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppTheme.spacingLG),

        Obx(() {
          final on = svc.enabled;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- 已启用 ----------
              _sectionHeader('已启用', trailing: '长按拖动调整顺序'),
              _reorderable(on, isEnabled: true),
              const SizedBox(height: AppTheme.spacingLG),

              // ---------- 未启用 ----------
              Obx(() {
                final off = svc.disabled;
                if (off.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader('未启用'),
                    _reorderable(off, isEnabled: false),
                  ],
                );
              }),
            ],
          );
        }),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 悬浮导航栏（全 App 三条底栏统一生效） ----------
        ListenableBuilder(
          listenable: SettingsService(),
          builder: (context, _) {
            final s = SettingsService();
            return SettingsGroup(
              title: '悬浮导航栏',
              children: [
                // 底栏风格（水墨/液态玻璃/炫彩/霓虹）+ 每个 tab 的自定义图标
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NavAppearancePage(),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_mosaic_outlined,
                          size: 20,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '风格与图标',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '液态玻璃 / 炫彩 / 霓虹，支持上传图片替换图标',
                                style: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: AppTheme.fontCaption,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: AppTheme.textTertiary,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
                unifiedSwitchRow(
                  icon: Icons.filter_center_focus,
                  title: '悬浮样式',
                  subtitle: '胶囊型毛玻璃悬浮，关闭为底部固定样式',
                  value: s.navFloating,
                  onChanged: (v) => s.setNavFloating(v),
                ),
                unifiedSwitchRow(
                  icon: Icons.label_off_outlined,
                  title: '只显示图标',
                  subtitle: '隐藏文字标签，仅保留图标（图标自动放大）',
                  value: s.navIconOnly,
                  onChanged: (v) => s.setNavIconOnly(v),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 样式卡片网格：**定宽**卡片 + 一行 3~4 个。
  ///   · 内宽 ≥ 300 → 4 列，否则 3 列（窄屏才降级）；
  ///   · ⚠️ 这里的 `box.maxWidth` 是**卡片内层**宽度 = 屏宽 − 页面 16×2 −
  ///     卡片 12×2 − 我的 14×2 ⇒ 390 宽的手机上约 306 ⇒ 走 4 列 ✓；
  ///   · 用 `Wrap` + 定宽子项（不是 `GridView`）—— 行高按内容自适应，
  ///     外层本来就在滚动容器里。
  Widget _styleGrid(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 10.0;
        final cols = box.maxWidth >= 300 ? 4 : 3;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in cards) SizedBox(width: w, child: c),
          ],
        );
      },
    );
  }

  /// 幻灯片样式卡片 = 上方**迷你示意图** + 下方名称（选中 = 强调色描边 + 加粗）。
  ///
  /// 示意图全部用 Flutter 画（不用图片资源）：一眼能看出这个样式长什么样。
  /// 用户 2026-10-14：「叠卡堆 / 三格海报需要重画」⇒ 这两张的示意按**实际
  /// 版式**重新画的（叠卡堆 = 后卡向上错位露头；三格海报 = 三张竖版海报 + 图外小字）。
  Widget _styleCard(HomeBannerStyle st, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 56,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                // 「选中」那圈描边同理：深色下 accentColor 是墨灰，压在暗卡片上
                // 看不出"选中了" ⇒ 用 accentOnSurface（浅色下同值，观感不变）
                color: selected
                    ? AppTheme.accentOnSurface
                    : AppTheme.glassBorderSoft,
                width: selected ? 1.6 : 0.5,
              ),
            ),
            child: _stylePreview(st),
          ),
          const SizedBox(height: 5),
          Text(
            st.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  /// 每个样式的**迷你示意图**（纯 Flutter 图形，尺寸跟随卡片）。
  Widget _stylePreview(HomeBannerStyle st) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        // ⚠️ 深色下 `accentColor` 是调色板 primary（默认「水墨书香」= 墨灰 #3A3A3A），
        //    压在暗底上几乎看不见 ⇒ 示意图会变成"空盒子"。
        //    改用 `accentOnSurface`：浅色下与 accentColor 同值（观感不变），
        //    深色下自动换成亮的一档（用户 2026-10-16）。
        final accent = AppTheme.accentOnSurface;
        final block = accent.withValues(alpha: 0.42);
        final blockSoft = accent.withValues(alpha: 0.20);
        final line = AppTheme.textTertiary.withValues(alpha: 0.45);

        Widget rect(double rw, double rh, Color c, {double r = 3}) => Container(
              width: w * rw,
              height: h * rh,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(r)),
            );
        // 迷你"文字条"（代表标题行）
        Widget bar(double bw, {double bh = 2.6}) => Container(
              width: w * bw,
              height: bh,
              decoration: BoxDecoration(
                  color: line, borderRadius: BorderRadius.circular(2)),
            );

        switch (st) {
          // 横版大图：16:9 大图 + 左下标题
          case HomeBannerStyle.wide:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.07,
                    top: h * 0.18,
                    child: rect(0.86, 0.62, block)),
                Positioned(left: w * 0.12, top: h * 0.56, child: bar(0.42)),
                Positioned(left: w * 0.12, top: h * 0.68, child: bar(0.26)),
              ],
            );

          // 卡片轮播：中间竖版大卡，两侧小卡
          case HomeBannerStyle.cards:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.09, top: h * 0.30, child: rect(0.24, 0.46, blockSoft)),
                Positioned(
                    right: w * 0.09, top: h * 0.30, child: rect(0.24, 0.46, blockSoft)),
                Positioned(
                    left: w * 0.34, top: h * 0.12, child: rect(0.32, 0.62, block)),
              ],
            );

          // 沉浸大图：满宽出血 + 底部文字 + 分段进度条
          case HomeBannerStyle.hero:
            return Stack(
              children: [
                Positioned.fill(child: rect(1, 1, block, r: 0)),
                Positioned(left: w * 0.08, top: h * 0.46, child: bar(0.48)),
                Positioned(left: w * 0.08, top: h * 0.60, child: bar(0.30)),
                Positioned(
                  left: w * 0.08,
                  top: h * 0.76,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Container(
                            width: w * 0.16,
                            height: 3,
                            decoration: BoxDecoration(
                              color: i == 0 ? accent : line,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );

          // 主次三栏：左边一张大竖版海报 + 右侧竖排 3 条小卡
          case HomeBannerStyle.feature:
            return Stack(
              children: [
                // 左：大海报
                Positioned(
                    left: w * 0.06, top: h * 0.08, child: rect(0.34, 0.84, block)),
                // 右：3 条小卡（缩略图 + 标题条）
                for (var k = 0; k < 3; k++) ...[
                  Positioned(
                      left: w * 0.46,
                      top: h * (0.10 + k * 0.28),
                      child: rect(0.16, 0.20, blockSoft)),
                  Positioned(
                      left: w * 0.66,
                      top: h * (0.16 + k * 0.28),
                      child: bar(0.26)),
                ],
              ],
            );

          // 编辑推荐（新增）：左边竖版封面 + 右边文字条 + 播放胶囊
          case HomeBannerStyle.spotlight:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.06, top: h * 0.08, child: rect(0.30, 0.84, block)),
                Positioned(left: w * 0.42, top: h * 0.20, child: bar(0.50)),
                Positioned(left: w * 0.42, top: h * 0.34, child: bar(0.44)),
                Positioned(left: w * 0.42, top: h * 0.50, child: bar(0.40)),
                Positioned(left: w * 0.42, top: h * 0.62, child: bar(0.34)),
                Positioned(
                  left: w * 0.42,
                  top: h * 0.76,
                  child: Container(
                    width: w * 0.34,
                    height: h * 0.16,
                    decoration: BoxDecoration(
                        color: accent, borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            );

          // 高低错落（新增）：3 张竖版海报，中间抬高 / 左右下沉
          case HomeBannerStyle.stair:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.05, top: h * 0.28, child: rect(0.27, 0.64, blockSoft)),
                Positioned(
                    left: w * 0.365, top: h * 0.08, child: rect(0.27, 0.84, block)),
                Positioned(
                    left: w * 0.68, top: h * 0.28, child: rect(0.27, 0.64, blockSoft)),
              ],
            );

          // 走马灯（新增）：图内左右箭头 + 底部圆点
          case HomeBannerStyle.carousel:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.07,
                    top: h * 0.14,
                    child: rect(0.86, 0.58, block)),
                Positioned(
                  left: w * 0.10,
                  top: h * 0.36,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
                Positioned(
                  right: w * 0.10,
                  top: h * 0.36,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: h * 0.79,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          width: i == 0 ? 8 : 4,
                          height: 3,
                          decoration: BoxDecoration(
                            color: i == 0 ? accent : line,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );

          // 扑克牌（新增）：前后堆叠，左右各露一角
          case HomeBannerStyle.poker:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.08,
                    top: h * 0.20,
                    child: rect(0.24, 0.62, blockSoft, r: 2)),
                Positioned(
                    right: w * 0.08,
                    top: h * 0.20,
                    child: rect(0.24, 0.62, blockSoft, r: 2)),
                Positioned(
                    left: w * 0.36,
                    top: h * 0.10,
                    child: rect(0.28, 0.80, block, r: 3)),
              ],
            );

          // 标签页（新增）：上方标签条 + 下方卡片
          case HomeBannerStyle.tabs:
            return Stack(
              children: [
                for (var i = 0; i < 3; i++)
                  Positioned(
                    left: w * (0.07 + i * 0.21),
                    top: h * 0.08,
                    child: Container(
                      width: w * 0.17,
                      height: h * 0.17,
                      decoration: BoxDecoration(
                        color: i == 0 ? accent : blockSoft,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                Positioned(
                    left: w * 0.07,
                    top: h * 0.36,
                    child: rect(0.86, 0.52, block)),
              ],
            );

          // 交错瀑布（新增）：左 1 张满高大卡 + 右侧上下 2 张短卡
          case HomeBannerStyle.masonry:
            return Stack(
              children: [
                Positioned(
                    left: w * 0.06, top: h * 0.08, child: rect(0.34, 0.84, block)),
                Positioned(
                    right: w * 0.06,
                    top: h * 0.08,
                    child: rect(0.48, 0.38, blockSoft)),
                Positioned(
                    right: w * 0.06,
                    top: h * 0.54,
                    child: rect(0.48, 0.38, blockSoft)),
              ],
            );
        }
      },
    );
  }

  Widget _sectionHeader(String title, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4)),
          const Spacer(),
          if (trailing != null)
            Text(trailing,
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption)),
        ],
      ),
    );
  }

  /// 可拖动排序的一段
  Widget _reorderable(List<NavFeature> items, {required bool isEnabled}) {
    final svc = NavFeatureService.instance;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorder: (o, n) =>
          isEnabled ? svc.reorderEnabled(o, n) : svc.reorderDisabled(o, n),
      itemBuilder: (context, i) {
        final f = items[i];
        return _row(f, i, isEnabled);
      },
    );
  }

  Widget _row(NavFeature f, int index, bool isEnabled) {
    final svc = NavFeatureService.instance;
    return Padding(
      key: ValueKey('${isEnabled ? "on" : "off"}-${f.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Row(
          children: [
            // 拖动把手（仅已启用段，未启用段按参考图不显示把手）
            if (isEnabled)
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 4),
                  child: Icon(Icons.drag_indicator,
                      size: 18, color: AppTheme.textTertiary),
                ),
              )
            else
              const SizedBox(width: 14),
            // 图标
            // 图标容器：与 SettingsRow 保持一致（32 / 圆角 9 / 细描边）
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.22),
                    width: 0.5),
              ),
              child: Icon(_iconOf[f] ?? Icons.circle_outlined,
                  size: 17, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 12),
            // 名称（必需页面带说明）
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(f.label,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 0.5,
                          fontWeight: FontWeight.w600)),
                  if (f.required) ...[
                    const SizedBox(height: 1),
                    Text('必需页面，不可关闭',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption)),
                  ],
                ],
              ),
            ),
            // 开关
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: isEnabled,
                // 必需页面：开关禁用（参考图里也是灰的）
                onChanged: f.required
                    ? null
                    : (v) => svc.setEnabled(f, v),
                activeColor: AppTheme.accentColor,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
