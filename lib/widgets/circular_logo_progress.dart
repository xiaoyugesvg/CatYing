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
                  backgroundColor: Colors.white.withValues(alpha: 0.10),
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
                          fontSize: 18,
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
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      percentText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
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
