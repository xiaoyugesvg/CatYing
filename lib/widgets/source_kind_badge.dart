import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../services/source_kind.dart';

/// 源「内容类型」小徽章 —— 显示单个汉字（影/听/漫/书）。
///
/// 影视是默认类，用**低调的中性灰**，不抢视线；听/漫/书用强调色，
/// 让"这个源不是普通影视源"一眼可见。
class SourceKindBadge extends StatelessWidget {
  final MediaKind kind;

  const SourceKindBadge({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final isDefault = kind.isVideo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: isDefault ? AppTheme.backgroundTertiary : AppTheme.accentColor,
        borderRadius: BorderRadius.circular(4),
        border: isDefault
            ? Border.all(color: AppTheme.borderLight, width: 0.5)
            : null,
      ),
      child: Text(
        kind.tag,
        style: TextStyle(
          color: isDefault ? AppTheme.textTertiary : Colors.white,
          fontSize: 9,
          height: 1.15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
