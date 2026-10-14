import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../reading/services/settings_service.dart';
import '../../../services/nav_feature_service.dart';
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
    NavFeature.webhome: Icons.language_outlined,
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
        // ---------- 首页幻灯片（顶部轮播）样式 ----------
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
                      // ⚠️ 样式从 2 种加到 5 种后，原来"和标题挤在同一行"必然溢出
                      //    ⇒ 标题/说明单独一行，选项用 Wrap 自动换行。
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final st in HomeBannerStyle.values)
                            _styleChip(
                              st,
                              s.homeBannerStyle == st,
                              () => s.setHomeBannerStyle(st),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 幻灯片样式选项（选中=强调色实底）。
  /// 间距由外层 `Wrap` 的 spacing/runSpacing 给，这里不再自带 margin。
  Widget _styleChip(HomeBannerStyle st, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.5),
        ),
        child: Text(
          st.label,
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: AppTheme.fontCaption + 0.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
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
