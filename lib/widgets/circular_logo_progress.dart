import 'package:flutter/material.dart';

import '../common/theme.dart';

/// 启动加载：圆形进度环 + 中心 Logo + 百分比
class CircularLogoProgress extends StatelessWidget {
  final double? progress; // null=不确定转圈
  final String percentText;
  final String caption;
  final bool failed;
  final bool indeterminate;

  const CircularLogoProgress({
    super.key,
    required this.progress,
    required this.percentText,
    required this.caption,
    this.failed = false,
    this.indeterminate = false,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = failed ? Colors.redAccent : AppTheme.accentColor;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 进度环
              SizedBox(
                width: 160,
                height: 160,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 6,
                  strokeCap: StrokeCap.round,
                  // 圆环底色：用强调色的淡底，浅色/深色下都可见。
                  // 原来写死 Colors.white 10%，浅色模式下等于隐形。
                  backgroundColor:
                      AppTheme.accentColor.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation<Color>(ringColor),
                ),
              ),
              // 中心 Logo（圆形裁切 + 猫影）
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFF8F0),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accentColor.withValues(alpha: 0.35),
                      blurRadius: 28,
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.pets,
                          size: 36, color: Color(0xFFD4A574)),
                      const SizedBox(height: 4),
                      Text(
                        '猫影',
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF3A2A1A),
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 百分比（压在 logo 下方）
              if (percentText.isNotEmpty)
                Positioned(
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      // 百分比徽章压在米白色 Logo 圆上，用深色底更清晰
                      //（原 Colors.black 55% 在浅色模式下也是一块突兀的黑）
                      color: const Color(0xFF3A2A1A).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      percentText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text(
            caption,
            style: TextStyle(
              color: failed ? Colors.redAccent : AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ],
    );
  }
}
