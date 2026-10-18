import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../common/floating_nav_spec.dart';
import '../../../common/theme.dart';
import '../../../reading/services/settings_service.dart';
import '../../../services/nav_feature_service.dart';
import '../../../widgets/app_toast.dart';
import 'settings_shared.dart';

/// 设置 → 主页页面 → 底栏风格与图标。
///
/// 用户 2026-10-18：
///   · 悬浮底栏要能换风格（液态玻璃 / 炫彩 / 霓虹…）；
///   · 每个 tab 的图标要能上传图片替换。
///
/// 风格与图标都存 [SettingsService]，底栏（JellyNavBar / JellyNavRail）
/// 读取同一份配置 ⇒ 改完立刻生效。
class NavAppearancePage extends StatefulWidget {
  const NavAppearancePage({super.key});

  @override
  State<NavAppearancePage> createState() => _NavAppearancePageState();
}

class _NavAppearancePageState extends State<NavAppearancePage> {
  /// 可自定义图标的 tab：主菜单（当前启用的）+ 音乐菜单 + 阅读菜单。
  List<({String label, IconData icon})> get _tabs => [
        for (final f in NavFeatureService.instance.enabled)
          (label: f.label, icon: f.activeIcon),
        // 音乐菜单（同样是 JellyNavBar，但标签与主菜单不同）
        (label: '主页', icon: Icons.home_rounded),
        (label: '乐库', icon: Icons.library_music_rounded),
        (label: '榜单', icon: Icons.leaderboard_rounded),
        (label: '搜索', icon: Icons.search_rounded),
        // 阅读菜单
        (label: '漫画', icon: Icons.palette_rounded),
        (label: '图书', icon: Icons.book_rounded),
        (label: '书架', icon: Icons.menu_book_rounded),
        (label: '收藏', icon: Icons.favorite_rounded),
        (label: '我的', icon: Icons.person_rounded),
      ];

  @override
  Widget build(BuildContext context) {
    final s = SettingsService();
    final style = FloatingNavStyle.fromId(s.navStyle);
    return SettingsSubPage(
      title: '底栏风格与图标',
      children: [
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            return SettingsGroup(
              title: '底栏风格',
              hint: '主菜单与阅读菜单共用同一种风格，切换后立即生效。',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      const gap = 10.0;
                      final w = (box.maxWidth - gap) / 2;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final st in FloatingNavStyle.values)
                            SizedBox(
                              width: w,
                              child: _styleCard(
                                st,
                                st == style,
                                () => s.setNavStyle(st.id),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppTheme.spacingLG),
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            return SettingsGroup(
              title: '自定义图标',
              hint: '建议上传 96×96 以上的透明 PNG；未选中时会自动降低透明度。',
              children: [
                for (final t in _tabs)
                  _iconRow(
                    label: t.label,
                    icon: t.icon,
                    customPath: s.navIconFor(t.label),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  // ── 风格卡片 ────────────────────────────────────────────────

  Widget _styleCard(FloatingNavStyle style, bool selected, VoidCallback onTap) {
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
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppTheme.accentOnSurface
                    : AppTheme.glassBorderSoft,
                width: selected ? 1.6 : 0.5,
              ),
            ),
            child: _stylePreview(style),
          ),
          const SizedBox(height: 6),
          Text(
            style.label,
            style: TextStyle(
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stylePreview(FloatingNavStyle style) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pal = AppTheme.palette;
    BoxDecoration deco;
    Color dot = Colors.white;
    switch (style) {
      case FloatingNavStyle.ink:
        deco = BoxDecoration(color: FloatingNavSpec.barColor(isDark, pal));
        dot = pal.primary;
        break;
      case FloatingNavStyle.liquid:
        deco = BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.20),
                    Colors.white.withValues(alpha: 0.06),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.50),
                  ],
          ),
        );
        dot = pal.primary;
        break;
      case FloatingNavStyle.aurora:
        deco = const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: FloatingNavSpec.auroraColors,
          ),
        );
        dot = Colors.white;
        break;
      case FloatingNavStyle.neon:
        deco = BoxDecoration(
          color: const Color(0xFF101116),
          border: Border.all(
            color: FloatingNavSpec.neonColor.withValues(alpha: 0.9),
          ),
        );
        dot = FloatingNavSpec.neonColor;
        break;
    }
    return Container(
      decoration: deco,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _previewDot(dot, active: true),
            const SizedBox(width: 6),
            _previewDot(dot.withValues(alpha: 0.55)),
            const SizedBox(width: 6),
            _previewDot(dot.withValues(alpha: 0.55)),
          ],
        ),
      ),
    );
  }

  Widget _previewDot(Color color, {bool active = false}) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.30) : Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  // ── 图标行 ──────────────────────────────────────────────────

  Widget _iconRow({
    required String label,
    required IconData icon,
    required String? customPath,
  }) {
    final hasCustom = customPath != null && customPath.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: hasCustom
                ? Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.file(
                      File(customPath),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          Icon(icon, size: 20, color: AppTheme.textSecondary),
                    ),
                  )
                : Icon(icon, size: 20, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (hasCustom)
            IconButton(
              tooltip: '恢复默认',
              icon: Icon(Icons.restart_alt_rounded,
                  size: 20, color: AppTheme.textTertiary),
              onPressed: () async {
                await SettingsService().clearNavCustomIcon(label);
                if (mounted) setState(() {});
              },
            ),
          IconButton(
            tooltip: '上传图片',
            icon: Icon(Icons.upload_file_outlined,
                size: 20,
                color: hasCustom
                    ? AppTheme.accentOnSurface
                    : AppTheme.textSecondary),
            onPressed: () => _pickIcon(label),
          ),
        ],
      ),
    );
  }

  Future<void> _pickIcon(String label) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    if (result.isEmpty) return;
    final path = result.first.path;
    if (path == null) return;
    final ok = await SettingsService().setNavCustomIcon(label, path);
    if (!mounted) return;
    setState(() {});
    AppToast.show(ok ? '已更新「$label」图标' : '图标保存失败，请重试', '');
  }
}
