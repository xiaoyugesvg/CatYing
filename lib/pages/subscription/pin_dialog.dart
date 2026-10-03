import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../common/theme.dart';

/// 6 位 PIN 输入弹窗（设置新 PIN / 验证 PIN 共用）
///
/// 返回：设置模式 → 新 PIN；验证模式 → 输入正确返回 true（错误返回 null）
class PinDialog extends StatefulWidget {
  /// true = 设置新 PIN（返回 String）；false = 验证（成功返回 'ok'）
  final bool setup;

  const PinDialog({super.key, required this.setup});

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.length != 6) {
      setState(() => _error = '请输入 6 位数字');
      return;
    }
    Navigator.pop(context, widget.setup ? v : 'ok:$v');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
      title: Text(widget.setup ? '设置密码' : '输入密码',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.setup ? '设置一个 6 位数字密码，用于保护已上锁的订阅' : '该订阅已上锁，请输入 6 位密码',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontFootnote),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            cursorColor: AppTheme.accentColor,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontTitle2, letterSpacing: 8),
            textAlign: TextAlign.center,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••••',
              hintStyle: TextStyle(
                  color: AppTheme.textTertiary, letterSpacing: 8),
              // 透明底：去掉灰填充；补一条细边框保持输入区可辨识
              filled: false,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
                borderSide: BorderSide(
                  color: AppTheme.borderMedium,
                  width: 0.5,
                ),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: AppTheme.fontFootnote)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消',
              style: TextStyle(color: AppTheme.textTertiary)),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
