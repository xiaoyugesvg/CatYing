import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../services/rfw_theme_service.dart';

/// 主题编辑器 —— 粘贴 / 手改 `.rfwtxt` 主题文本。
///
/// 为什么要有这个页面（而不是只做个"从剪贴板导入"按钮）：
/// - 主题是纯文本，用户经常需要**改几个颜色值**再试，只导入不能迭代；
/// - 粘贴后要能**先看语法检查结果**再决定是否保存，避免存进去一堆坏主题；
/// - 支持给主题起名，否则列表里全是时间戳文件名，没法认。
class RfwThemeEditorPage extends StatefulWidget {
  /// 编辑已有主题时传入；为 null 表示新建
  final RfwTheme? editing;

  const RfwThemeEditorPage({super.key, this.editing});

  @override
  State<RfwThemeEditorPage> createState() => _RfwThemeEditorPageState();
}

class _RfwThemeEditorPageState extends State<RfwThemeEditorPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _sourceCtrl;

  /// 最近一次语法检查结果：null = 未检查，'' = 通过，其它 = 错误信息
  String? _checkResult;
  bool _saving = false;

  RfwThemeService get _svc => RfwThemeService.instance;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _nameCtrl = TextEditingController(
        text: e == null ? '' : e.name);
    _sourceCtrl = TextEditingController(text: e?.source ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sourceCtrl.dispose();
    super.dispose();
  }

  void _runCheck() {
    final src = _sourceCtrl.text;
    if (src.trim().isEmpty) {
      setState(() => _checkResult = '主题内容为空');
      return;
    }
    final err = _svc.validate(src);
    setState(() => _checkResult = err ?? '');
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板为空')),
        );
      }
      return;
    }
    setState(() {
      _sourceCtrl.text = text;
      _checkResult = null;
    });
    _runCheck();
  }

  Future<void> _save() async {
    if (_saving) return;
    final src = _sourceCtrl.text;
    final name = _nameCtrl.text.trim();

    // 保存前必须过语法检查：存进去就渲染，坏了用户只会看到"首页没变"
    final err = _svc.validate(src);
    if (err != null) {
      setState(() => _checkResult = err);
      return;
    }

    setState(() => _saving = true);
    try {
      final id = await _svc.importFromText(
        src,
        fileName: name.isEmpty ? null : name,
      );
      if (id == null) {
        if (mounted) {
          setState(() {
            _saving = false;
            _checkResult = _svc.lastError.value;
          });
        }
        return;
      }
      // 保存即选中 + 打开总开关：否则用户导入完会以为"没生效"
      await _svc.setCurrent(id);
      await _svc.setEnabled(true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已保存并启用，返回首页即可看到效果'),
          duration: Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(widget.editing == null ? '新建主题' : '编辑主题',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存',
                style: TextStyle(
                    color: _saving
                        ? AppTheme.textTertiary
                        : AppTheme.accentColor,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          // ---------- 主题名 ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _nameCtrl,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                labelText: '主题名',
                labelStyle:
                    TextStyle(color: AppTheme.textTertiary, fontSize: 13),
                hintText: '例如：墨白极简',
                hintStyle:
                    TextStyle(color: AppTheme.textTertiary, fontSize: 13),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                ),
              ),
            ),
          ),

          // ---------- 操作行 ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: const Text('粘贴', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                TextButton.icon(
                  onPressed: _runCheck,
                  icon: const Icon(Icons.spellcheck, size: 16),
                  label: const Text('语法检查',
                      style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _sourceCtrl.clear();
                    _checkResult = null;
                  }),
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('清空', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                const Spacer(),
                Text(
                  '${_sourceCtrl.text.length} 字符',
                  style: TextStyle(
                      color: AppTheme.textTertiary, fontSize: 11.5),
                ),
              ],
            ),
          ),

          // ---------- 语法检查结果 ----------
          if (_checkResult != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _checkResult!.isEmpty
                    ? AppTheme.accentColor.withValues(alpha: 0.12)
                    : Colors.red.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _checkResult!.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: _checkResult!.isEmpty
                        ? AppTheme.accentColor
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _checkResult!.isEmpty
                          ? '语法检查通过，可以保存'
                          : _checkResult!,
                      style: TextStyle(
                        color: _checkResult!.isEmpty
                            ? AppTheme.accentColor
                            : Colors.redAccent,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ---------- 文本编辑区 ----------
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: TextField(
                controller: _sourceCtrl,
                maxLines: null,
                expands: true,
                onChanged: (_) {
                  // 编辑后旧的检查结论就失效了，避免显示过期的"通过"
                  if (_checkResult != null) {
                    setState(() => _checkResult = null);
                  } else {
                    setState(() {});
                  }
                },
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'import core.widgets;\nimport peek.home;\n\n'
                      'widget root = PeekStickyGrid(\n  ...\n);',
                  hintStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 12,
                      height: 1.5,
                      fontFamily: 'monospace'),
                  contentPadding: const EdgeInsets.all(12),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
