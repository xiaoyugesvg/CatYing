import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
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
      ],
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
