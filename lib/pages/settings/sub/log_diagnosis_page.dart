import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/reading/services/ai_service.dart';
import 'package:tvbox/services/log_diagnoser.dart';
import 'package:tvbox/pages/settings/sub/ai_settings_page.dart';

/// 「日志诊断」——读本地运行日志 → 聚合 → 交给 AI 出优化建议。
///
/// 设计：
///   · 只发**聚合摘要**给模型（不是原始日志），省 token 且减少幻觉；
///   · 报告里每条建议都基于"某个聚类出现多少次"这个事实；
///   · 未配置 AI 时引导去「AI 管理」，不静默失败。
class LogDiagnosisPage extends StatefulWidget {
  const LogDiagnosisPage({super.key});

  @override
  State<LogDiagnosisPage> createState() => _LogDiagnosisPageState();
}

class _LogDiagnosisPageState extends State<LogDiagnosisPage> {
  int _lines = 1000;
  bool _busy = false;
  bool _aiReady = true;
  LogDigest? _digest;
  String? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkAi();
  }

  Future<void> _checkAi() async {
    try {
      final ai = AiService();
      await ai.init();
      if (mounted) setState(() => _aiReady = ai.isConfigured);
    } catch (_) {}
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    try {
      final d = await LogDiagnoser.digest(lines: _lines);
      if (!mounted) return;
      setState(() => _digest = d);
      final r = await LogDiagnoser.diagnose(d);
      if (!mounted) return;
      setState(() => _report = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志诊断'),
        actions: [
          if (_report != null)
            IconButton(
              tooltip: '复制报告',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _report!));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '读取最近的应用运行日志，先在本地把同类错误合并计数，再把摘要交给 AI '
                '给出优化建议。\n\n'
                '只上传聚合结果（错误类型 + 次数 + 样例），不会上传完整日志。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (!_aiReady) ...[
            const SizedBox(height: 10),
            Card(
              color: scheme.errorContainer.withValues(alpha: 0.5),
              child: ListTile(
                leading: Icon(Icons.key_off_outlined, color: scheme.error),
                title: const Text('还没有配置 AI'),
                subtitle: const Text('先去 AI 管理填一个 API Key'),
                trailing: TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AiSettingsPage(),
                      ),
                    );
                    await _checkAi();
                  },
                  child: const Text('去配置'),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            '读取条数',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final n in [500, 1000, 2000])
                ChoiceChip(
                  label: Text('$n'),
                  selected: _lines == n,
                  onSelected: (_) => setState(() => _lines = n),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.troubleshoot, size: 18),
              label: Text(_busy ? '分析中…' : '开始诊断'),
            ),
          ),
          if (_digest != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '概览',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '共 ${_digest!.total} 条  ·  '
                      '${_digest!.levelCounts.entries.map((e) => '${e.key} ${e.value}').join(' / ')}\n'
                      '慢操作 ${_digest!.slowCount} 条  ·  '
                      '聚合出 ${_digest!.clusters.length} 类问题',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  _report!,
                  style: const TextStyle(fontSize: 13, height: 1.7),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '建议仅供参考，修改前请结合代码确认。',
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
