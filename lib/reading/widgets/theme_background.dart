import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/settings_service.dart';
import '../theme/jelly_palette.dart';
import 'theme_background_animation.dart';

/// 主题背景统一入口：按当前主题的背景配置（[SettingsService.currentBackground]）渲染。
///
/// - **图片**：用户上传图片全屏铺满 + 淡遮罩，**独立于面板右上角的「动画」总开关**
///   （图片是静态层，非动画）。
/// - **动画 / 纯色**：委托 [ThemeBackgroundAnimation]——其内部按「动画」总开关与
///   painter 是否存在决定画动画或返回空（SizedBox.shrink）。
///
/// 由 [SettingsService] 驱动重建（主题/暗色切换时刷新）。图片层是静态的，包在
/// [RepaintBoundary] 内，不随上层列表滚动重绘。
class ThemeBackground extends StatelessWidget {
  const ThemeBackground({super.key, this.topInset = 0, this.bottomInset = 0});

  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    // 监听设置：切换主题/明暗时即时刷新（图片分支不会自监听，动画分支自身已监听，
    // 套一层 ListenableBuilder 对其无副作用）。
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final settings = SettingsService();
        final cfg = settings.currentBackground;
        if (cfg.type == ThemeBackgroundType.image && cfg.imagePath != null) {
          return RepaintBoundary(
            child: _ThemeImageBackground(
              path: cfg.imagePath!,
              // ⚠️ 必须读全局唯一的明暗真源 `AppBrightness`，
              // **不能**用 `SettingsService.isDarkMode` ——
              // 那是阅读自己的第二套明暗状态，与 UI 实际用的
              // `Theme.of(context).brightness`（源自 ThemeModeStore）不同步，
              // 会出现"UI 是浅色、背景层已按深色画"这种同屏自相矛盾。
              isDark: !AppBrightness.isLight.value,
              opacity: cfg.opacity,
              blur: cfg.blur,
            ),
          );
        }
        final anim = ThemeBackgroundAnimation(
          topInset: topInset,
          bottomInset: bottomInset,
        );
        // 动画背景只支持整体淡出（模糊对逐帧画面代价过高，见 ThemeBackground.blur）
        return cfg.opacity >= 0.999
            ? anim
            : Opacity(opacity: cfg.opacity.clamp(0.2, 1.0), child: anim);
      },
    );
  }
}

/// 图片背景层：`BoxFit.cover` 全屏铺满 + 淡遮罩（保证标题/副标题可读）。
///
/// 按物理像素宽度 `cacheWidth` 下采样解码，限制内存占用（背景无需超清）。
/// 路径文件被手动删除等情况由 [Image.errorBuilder] 降级为空，透出 Scaffold 纯色。
class _ThemeImageBackground extends StatelessWidget {
  const _ThemeImageBackground({
    required this.path,
    required this.isDark,
    this.opacity = 1.0,
    this.blur = 0.0,
  });

  final String path;
  final bool isDark;

  /// 不透明度（1.0 = 原样）
  final double opacity;

  /// 模糊 sigma（0 = 不模糊）
  final double blur;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final widthPx = (MediaQuery.sizeOf(context).width * dpr).round();
    // 遮罩强度先固定，看效果再调（暗色更深以保证白色文字可读）。
    final scrim = isDark
        ? Colors.black.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.22);
    Widget img = Image.file(
      File(path),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      cacheWidth: widthPx,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    final sigma = blur.clamp(0.0, 40.0);
    if (sigma > 0.01) {
      // 轻微放大抵消高斯模糊在四边产生的透明羽化（decal 边缘）
      img = Transform.scale(
        scale: 1 + sigma / 60,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.decal,
          ),
          child: img,
        ),
      );
    }
    if (opacity < 0.999) {
      img = Opacity(opacity: opacity.clamp(0.2, 1.0), child: img);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        img,
        IgnorePointer(child: ColoredBox(color: scrim)),
      ],
    );
  }
}
