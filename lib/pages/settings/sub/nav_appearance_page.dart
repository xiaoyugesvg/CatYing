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
  List<({String label, IconData icon, String? asset, bool tinted})> get _tabs => [
        for (final f in NavFeatureService.instance.enabled)
          (
            label: f.label,
            icon: f.activeIcon,
            asset: f.iconAsset,
            tinted: f.iconAssetTinted,
          ),
        // 音乐菜单（同样是 JellyNavBar，但标签与主菜单不同）
        (label: '主页', icon: Icons.home_rounded, asset: 'assets/icons/home.png', tinted: false),
        (label: '乐库', icon: Icons.library_music_rounded, asset: null, tinted: false),
        (label: '榜单', icon: Icons.leaderboard_rounded, asset: null, tinted: false),
        (label: '搜索', icon: Icons.search_rounded, asset: null, tinted: false),
        // 阅读菜单
        (label: '漫画', icon: Icons.palette_rounded, asset: null, tinted: false),
        (label: '图书', icon: Icons.book_rounded, asset: null, tinted: false),
        (label: '书架', icon: Icons.menu_book_rounded, asset: null, tinted: false),
        (label: '收藏', icon: Icons.favorite_rounded, asset: null, tinted: false),
        (label: '我的', icon: Icons.person_rounded, asset: null, tinted: false),
      ];

  @override
  Widget build(BuildContext context) {
    final s = SettingsService();
    return SettingsSubPage(
      title: '底栏风格与图标',
      children: [
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            // ⚠️ 必须在这里读 navStyle：放到 build 顶层会导致
            //   ListenableBuilder 重建时用的还是旧值，点其它风格"像是选不了"。
            final style = FloatingNavStyle.fromId(s.navStyle);
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
        // ── 不透明度（2026-10-24 用户：「菜单栏太他么透明了」）────────
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            final v = s.navBarOpacity;
            return SettingsGroup(
              title: '底栏不透明度',
              hint: '所有风格通用。觉得底栏太透、字压在内容上看不清就往上调；'
                  '100% = 完全不透明。',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 6),
                          Icon(Icons.opacity_rounded,
                              size: 18, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          Text(
                            '${(v * 100).round()}%',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => s.setNavBarOpacity(1.0),
                            child: const Text('不透明'),
                          ),
                          TextButton(
                            onPressed: () => s.setNavBarOpacity(0.60),
                            child: const Text('通透'),
                          ),
                        ],
                      ),
                      Slider(
                        value: v,
                        min: FloatingNavSpec.minOpacity,
                        max: FloatingNavSpec.maxOpacity,
                        divisions: 14,
                        onChanged: (x) => s.setNavBarOpacity(x),
                      ),
                    ],
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
              hint: '点图标上传图片；右上角 × 恢复默认。建议 96×96 以上透明 PNG。',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      const gap = 10.0;
                      final w = (box.maxWidth - gap * 3) / 4;
                      return Wrap(
                        spacing: gap,
                        runSpacing: 14,
                        children: [
                          for (final t in _tabs)
                            SizedBox(
                              width: w,
                              child: _iconTile(
                                label: t.label,
                                icon: t.icon,
                                asset: t.asset,
                                assetTinted: t.tinted,
                                customPath: s.navIconFor(t.label),
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
      case FloatingNavStyle.frost:
        // 磨砂：半透玻璃 + 顶部高光细边
        deco = BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.16),
                    Colors.white.withValues(alpha: 0.06),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.74),
                    Colors.white.withValues(alpha: 0.52),
                  ],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.85),
            width: 0.8,
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
      case FloatingNavStyle.reverse:
        // 反色：与界面明暗相反
        deco = BoxDecoration(
          color: isDark
              ? const Color(0xFFF3F3F5).withValues(alpha: 0.96)
              : const Color(0xFF1E2024).withValues(alpha: 0.94),
          border: Border.all(
            color: isDark
                ? Colors.black.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.10),
            width: 0.6,
          ),
        );
        dot = isDark ? Colors.black : Colors.white;
        break;
      case FloatingNavStyle.solid:
        // 实心：实底 + 主题色实心选中块
        deco = BoxDecoration(
          color: isDark
              ? const Color(0xFF17171A)
              : const Color(0xFFFDFDFE),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
            width: 0.6,
          ),
        );
        dot = FloatingNavSpec.styleIndicatorColor(
          FloatingNavStyle.solid,
          isDark: isDark,
          palette: pal,
        );
        break;
    }
    // 预览也跟随不透明度滑杆
    final preview = FloatingNavSpec.applyOpacity(
      deco,
      SettingsService().navBarOpacity,
    );
    return Container(
      decoration: preview,
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

  // ── 图标块（一行 4 个）──────────────────────────────────────

  Widget _iconTile({
    required String label,
    required IconData icon,
    required String? customPath,
    String? asset,
    bool assetTinted = false,
  }) {
    final hasCustom = customPath != null && customPath.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pickIcon(label),
      child: Column(
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: hasCustom
                          ? AppTheme.accentColor.withValues(alpha: 0.45)
                          : Colors.transparent,
                      width: 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: hasCustom
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.file(
                            File(customPath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Icon(
                              icon,
                              size: 24,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        )
                      : (asset != null
                          ? Padding(
                              padding: const EdgeInsets.all(8),
                              child: Image.asset(
                                asset,
                                fit: BoxFit.contain,
                                // 白色蒙版图按图标色着色，与其它图标一致
                                color: assetTinted
                                    ? AppTheme.textSecondary
                                    : null,
                                colorBlendMode:
                                    assetTinted ? BlendMode.srcIn : null,
                              ),
                            )
                          : Icon(icon, size: 24, color: AppTheme.textSecondary)),
                ),
                if (hasCustom)
                  Positioned(
                    top: -5,
                    right: -5,
                    child: GestureDetector(
                      onTap: () async {
                        await SettingsService().clearNavCustomIcon(label);
                        if (mounted) setState(() {});
                      },
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            hasCustom ? '已替换' : '点按上传',
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: 9.5,
            ),
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
