import 'dart:ui';
import 'package:flutter/material.dart';
import '../common/theme.dart';

/// iOS 27 Liquid Glass 玻璃面板
///
/// 对应 Apple Liquid Glass 设计语言在 Flutter 上的实现：
/// - 真实毛玻璃（BackdropFilter 高斯模糊 + 背景透出）
/// - 顶部镜面高光（specular highlight，iOS 27 增强的深度/分离感）
/// - 亮描边（brighter edge highlights）
/// - 柔和深投影（depth separation）
///
/// 使用建议：
/// - 低频/静态面板（导航栏、AppBar、弹窗、详情信息卡）：[blur] = true
/// - 列表内高频卡片（VodCard 等）：[blur] = false，仅用半透明 tint +
///   高光 + 描边模拟玻璃，避免大量 BackdropFilter 造成卡顿
class GlassPanel extends StatelessWidget {
  final Widget child;

  /// 圆角（默认玻璃大圆角）
  final double radius;

  /// 是否启用真实毛玻璃模糊（BackdropFilter）
  final bool blur;

  /// 高斯模糊强度 sigma
  final double blurSigma;

  /// 玻璃底色；默认 [AppTheme.glassTint]
  final Color? tint;

  /// 顶部镜面高光强度 0~1（0 关闭）
  final double highlightStrength;

  /// 描边颜色；默认 [AppTheme.glassBorder]
  final Color? borderColor;

  /// 描边宽度
  final double borderWidth;

  /// 是否显示柔和深投影（iOS 27 深度分离）
  final bool shadow;

  /// 自定义投影（覆盖 [shadow] 默认投影）
  final List<BoxShadow>? boxShadow;

  final EdgeInsetsGeometry? padding;

  /// 外边距（包在最外层投影容器外）
  final EdgeInsetsGeometry? margin;

  /// 固定宽度约束
  final double? width;

  /// 固定高度约束
  final double? height;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = AppTheme.glassRadius,
    this.blur = false,
    this.blurSigma = AppTheme.glassBlurSigma,
    this.tint,
    this.highlightStrength = 0.6,
    this.borderColor,
    this.borderWidth = 1,
    this.shadow = true,
    this.boxShadow,
    this.padding,
    this.margin,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final radiusValue = radius;
    final border = Border.all(
      color: borderColor ?? AppTheme.glassBorder,
      width: borderWidth,
    );
    final tintColor = tint ?? AppTheme.glassTint;
    final shadows = boxShadow ??
        (shadow
            ? const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 28,
                  offset: Offset(0, 10),
                ),
              ]
            : null);

    Widget panel = Container(
      decoration: BoxDecoration(
        color: tintColor,
        borderRadius: BorderRadius.circular(radiusValue),
        border: border,
      ),
      child: Stack(
        children: [
          // ---- 内侧双色边缘（Liquid Glass 的"玻璃厚度"）----
          // 顶部亮、底部暗。只有外侧一圈描边时面板像"贴纸"，
          // 补上内侧这两条才有折射出来的厚度感。
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radiusValue - 1),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppTheme.glassInnerTop,
                      Colors.transparent,
                      AppTheme.glassInnerBottom,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // 顶部镜面高光层（大面积柔光）
          if (highlightStrength > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radiusValue),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.18 * highlightStrength),
                        Colors.white.withValues(alpha: 0.06 * highlightStrength),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35, 0.6],
                    ),
                  ),
                ),
              ),
            ),
          // ---- 顶部镜面弧线（窄，模拟折射光带）----
          // 高 1.5，贴在顶边内 1px，左右淡出到透明。
          if (highlightStrength > 0)
            Positioned(
              top: 1,
              left: radiusValue * 0.5,
              right: radiusValue * 0.5,
              child: IgnorePointer(
                child: Container(
                  height: 1.5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        AppTheme.glassSpecular
                            .withValues(alpha: 0.9 * highlightStrength),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          if (padding != null)
            Padding(padding: padding!, child: child)
          else
            child,
        ],
      ),
    );

    if (blur) {
      panel = ClipRRect(
        borderRadius: BorderRadius.circular(radiusValue),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: panel,
        ),
      );
    }

    // 外层投影容器（阴影不能被 ClipRRect 裁掉）
    return Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radiusValue),
        boxShadow: shadows,
      ),
      child: panel,
    );
  }
}

/// 玻璃胶囊标签（iOS 27 pill 风格：半透明 + 细亮描边）
class GlassPill extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;

  const GlassPill({
    super.key,
    required this.text,
    this.color,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? AppTheme.accentColor;
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
  }
}

/// 玻璃分隔线（iOS 27 细亮分隔）
class GlassDivider extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  const GlassDivider({super.key, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Container(
        height: 0.6,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0.02),
              Colors.white.withValues(alpha: 0.14),
              Colors.white.withValues(alpha: 0.02),
            ],
          ),
        ),
      ),
    );
  }
}


/// Liquid Glass 按压反馈
///
/// iOS 26+ 的玻璃控件按下时会轻微缩小并加深，松手弹回 ——
/// 这是"玻璃有实体感"的关键，纯 Material 水波纹已不属于这套语言。
class GlassPress extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 按下时缩到多小。0.97 是列表/卡片的常见幅度；
  /// 小控件或网格卡片可用更小的值让反馈更明显。
  final double pressedScale;

  const GlassPress({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
  });

  @override
  State<GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<GlassPress> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: AppTheme.motionFast,
        curve: AppTheme.motionCurve,
        child: AnimatedOpacity(
          // 按下同时轻微压暗，强化"被按进去"的感觉
          opacity: _down ? 0.82 : 1.0,
          duration: AppTheme.motionFast,
          curve: AppTheme.motionCurve,
          child: widget.child,
        ),
      ),
    );
  }
}