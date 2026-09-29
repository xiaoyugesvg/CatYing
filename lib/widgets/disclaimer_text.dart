import 'package:flutter/material.dart';

import '../common/theme.dart';

/// 免责声明段落（启动弹窗用）
class DisclaimerText extends StatelessWidget {
  final String title;
  final String body;

  const DisclaimerText({super.key, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
