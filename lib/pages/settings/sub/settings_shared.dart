import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';

/// 设置子页的共享构件。
///
/// 为什么需要它：把 1807 行的设置页拆成 8 个分类子页后，每页都要用
/// 「选项选择弹窗」「多行文本编辑弹窗」「说明卡片」这类东西。
/// 不抽出来就会在 8 个文件里各写一遍（原来的 settings/view.dart 就是这样
/// 堆积到 1807 行的）。
class SettingsDialogs {
  SettingsDialogs._();

  /// 底部弹窗式单选（用于外观模式、自动清理、播放内核、画质…）
  ///
  /// 返回选中项；用户取消返回 null。
  static Future<T?> pick<T>({
    required BuildContext context,
    required String title,
    required List<T> options,
    required T? selected,
    required String Function(T) labelBuilder,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      builder: (ctx) => kbSheet(SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title,
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: 15)),
            ),
            for (final o in options)
              ListTile(
                title: Text(labelBuilder(o),
                    style: TextStyle(color: AppTheme.textSecondary)),
                trailing: selected == o
                    ? Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      )),
    );
  }

  /// 多行文本编辑弹窗（用于弹幕 API、屏蔽关键词、源地址等）
  ///
  /// 返回编辑后的文本；取消返回 null。
  static Future<String?> editText({
    required BuildContext context,
    required String title,
    required String initial,
    String? hint,
    int maxLines = 1,
    String? helper,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(title, style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                maxLines: maxLines,
                autofocus: true,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  filled: true,
                  fillColor: AppTheme.backgroundTertiary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (helper != null) ...[
                const SizedBox(height: 8),
                Text(helper,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.4)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child:
                Text('保存', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  /// 二次确认弹窗
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmText = '确定',
    Color confirmColor = Colors.redAccent,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(title, style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(message,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
                height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText, style: TextStyle(color: confirmColor)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 分类子页的统一外壳：标题栏 + 可滚动的分组内容。
///
/// 让 8 个子页外观一致，也省掉每页重复写 Scaffold/AppBar。
class SettingsSubPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// 右上角可选操作（如"重置"）
  final Widget? action;

  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(title,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        actions: action == null ? null : [action!],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: children,
      ),
    );
  }
}

/// 子页里的一个分组：小标题 + 卡片。
///
/// 对应参考图那种「数据 / 偏好」分区 + 白卡列表的样式。
class SettingsGroup extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final String? hint;

  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              title!,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
        // dense：纵向内边距 4，配合行高 38 → 单行卡片约 46px
        //（原来 72px，列表显得又高又空）
        AppCard(
          dense: true,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                      color: AppTheme.borderLight,
                      height: 1,
                      thickness: 0.5,
                      indent: 28,
                      endIndent: 4),
                children[i],
              ],
            ],
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8),
            child: Text(
              hint!,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.4),
            ),
          ),
      ],
    );
  }
}


/// 统一的「图标 + 标题 + 可选副标题 + 开关」行。
///
/// 之前 playback / danmu 两页各自实现了一份 `_switchRow` / `_switchTile`，
/// 样式与间距容易走偏。现在收敛到这里，所有设置页共用同一种观感。
Widget unifiedSwitchRow({
  required IconData icon,
  required String title,
  String? subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
  bool enabled = true,
}) {
  return SettingsRow(
    icon: icon,
    title: title,
    trailingSwitch: true,
    switchValue: value,
    switchEnabled: enabled,
    onSwitchChanged: onChanged,
  );
}
