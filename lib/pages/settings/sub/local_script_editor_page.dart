// lib/pages/settings/sub/local_script_editor_page.dart
//
// 本地源脚本编辑器（2026-10-28）。
//
// 用户：「py 本地以及 js 本地源文件，加个修改脚本的功能呢」——
// 原来本地源只能导入 / 改名 / 分享 / 删除，想改一行规则必须去文件 App 里
// 找到 `Documents/local_py/*.py` 手改，iOS 上基本不可行。
// 这里给一个应用内编辑器：读原文 → 改 → 保存（写盘 + 重新注册引擎）。
//
// 刻意保持「纯文本」：不做语法高亮（几 MB 的源脚本高亮会卡），
// 只给等宽字体、行号统计、撤销改动、未保存提醒。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 保存回调：交给 Python / JS 各自的 service 落盘并重注册。
typedef SaveScriptCallback = Future<({bool ok, String? message})> Function(
    String code);

class LocalScriptEditorPage extends StatefulWidget {
  const LocalScriptEditorPage({
    super.key,
    required this.title,
    required this.filename,
    required this.initialCode,
    required this.onSave,
    this.language = 'python',
  });

  /// 源显示名（AppBar 标题）
  final String title;

  /// 文件名，如 `lp_xxx.py`（副标题）
  final String filename;

  final String initialCode;
  final SaveScriptCallback onSave;

  /// `python` / `javascript`，只用于提示文案
  final String language;

  @override
  State<LocalScriptEditorPage> createState() => _LocalScriptEditorPageState();
}

class _LocalScriptEditorPageState extends State<LocalScriptEditorPage> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialCode);
  final _scroll = ScrollController();
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
  }

  void _onChanged() {
    final d = _ctrl.text != widget.initialCode;
    if (d != _dirty) setState(() => _dirty = d);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int get _lines => '\n'.allMatches(_ctrl.text).length + 1;

  Future<void> _save() async {
    if (_saving) return;
    final code = _ctrl.text;
    if (code.trim().isEmpty) {
      AppToast.message('脚本内容为空，不能保存');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await widget.onSave(code);
      if (!mounted) return;
      if (r.ok) {
        AppToast.message('已保存');
        Navigator.of(context).pop(true);
      } else {
        AppToast.message(r.message ?? '保存失败');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _revert() async {
    if (!_dirty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销修改'),
        content: const Text('放弃本次修改，恢复成打开时的内容？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      _ctrl.text = widget.initialCode;
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还没保存'),
        content: const Text('修改还没保存，确定离开？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF111214) : const Color(0xFFFAFAF8);
    final fg = isDark ? const Color(0xFFE6E6E6) : const Color(0xFF1F2328);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: AppTheme.backgroundSecondary,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              Text(
                widget.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.textTertiary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '撤销修改',
              onPressed: _dirty ? _revert : null,
              icon: const Icon(Icons.undo_rounded, size: 20),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10, left: 2),
              child: TextButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // 状态条：语言 / 行数 / 字符数 / 未保存标记
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: AppTheme.backgroundSecondary.withValues(alpha: 0.6),
              child: Row(
                children: [
                  Text(
                    widget.language == 'python' ? 'Python' : 'JavaScript',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textTertiary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$_lines 行 · ${_ctrl.text.length} 字符',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  if (_dirty)
                    Text(
                      '未保存',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: TextField(
                  controller: _ctrl,
                  scrollController: _scroll,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.45,
                    color: fg,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.fromLTRB(14, 10, 14, 24),
                    hintText: '在这里编辑脚本…',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
