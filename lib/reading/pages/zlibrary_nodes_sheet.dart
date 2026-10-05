import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';

/// z-library **节点管理面板** ✓（"一键测试 + 延迟 + 切换 + 添加"✓）。
///
/// ── 为什么要有它（今天查清的现状 ✗）──────────────────────────────
/// 底层能力**全都有** ✓：内置节点 ✓（`CmbokConstants.zLibraryDefaultDomains` ✓）·
/// 切换/并入候选/落盘 ✓（`setDomain` ✓）· 单点测试 ✓（`probeDomain` ✓）·
/// **延迟测量** ✓（`_probeUrl` ✓）· 全候选并发选优 ✓（`_pickBestCandidate` ✓）。
/// 但界面上**只看得到"一个输入框 + 测一次"** ✗ —— 用户**看不到**有哪些节点 ✓、
/// 也不知道**哪个快** ✗。本面板把这些能力暴露出来 ✓✓（并**保留**原来的填地址与测试 ✓）。
///
/// ── 设计取舍 ──────────────────────────────────────────────────
///   · **只用公开 API** ✓：`candidates` ✓ `probeAll()` ✓ `setDomain()` ✓ `probeDomain()` ✓
///     `domain` ✓ —— 不碰任何私有成员 ✓（因此改这里**不会**影响自动选优逻辑 ✓）。
///   · 「添加节点」= `setDomain(raw)` ✓✓ —— 因为 `setDomain` 本身就会
///     "归一化 → 并入候选表（去重、置顶）→ 落盘" ✓（`:448-449` ✓），
///     所以**不需要**另造一个 addCandidate ✗✓（也就不会和既有行为打架 ✓）。
///   · 内置节点**不给删除** ✗（它们是兜底 ✓，删了会导致"开箱不可用" ✗）。
class ZlibraryNodesSheet extends StatefulWidget {
  const ZlibraryNodesSheet({super.key});

  @override
  State<ZlibraryNodesSheet> createState() => _ZlibraryNodesSheetState();
}

class _ZlibraryNodesSheetState extends State<ZlibraryNodesSheet> {
  bool _testing = false;
  bool _tested = false;
  String? _error;
  List<({String domain, bool ok, double? latency, String host})> _rows = [];
  final _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  ZlibraryService get _svc => ZlibraryService();

  /// 一键测试全部节点 ✓（**只读** ✓ 不会改当前节点 ✓）
  Future<void> _probeAll() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final rows = await _svc.probeAll();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _tested = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 切换为某个节点 ✓（`setDomain` 会归一化 + 并入候选 + 落盘 ✓）
  Future<void> _switchTo(String domain) async {
    final ok = await _svc.setDomain(domain);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已切换到 ${_svc.domain}' : '切换失败：地址不可用'),
    ));
    setState(() {});
  }

  /// 添加节点 ✓（= 同上：归一化 + 并入候选表 + 落盘 ✓）
  Future<void> _addNode() async {
    final raw = _addCtrl.text.trim();
    if (raw.isEmpty) return;
    final r = await _svc.probeDomain(raw); // 先验一次 ✓（失败会自动回滚 ✓ 不会把可用节点弄坏 ✓）
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(r.message)));
    if (r.ok) {
      _addCtrl.clear();
      await _probeAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = isDark ? JellyTheme.textPrimaryDark : JellyTheme.textSecondary;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('节点管理',
                    style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700,
                        color: label)),
              ),
              TextButton.icon(
                onPressed: _testing ? null : _probeAll,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed_rounded, size: 18),
                label: Text(_testing ? '测试中…' : '一键测试'),
              ),
            ],
          ),
          Text(
            '当前使用：${_svc.hasDomain ? _svc.domain : '（未设置）'}',
            style: TextStyle(fontSize: AppTheme.fontCaption, color: sub),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: JellyTheme.warning)),
            ),
          // 节点列表 ✓（点「一键测试」后出现 ✓；未测试时提示一下 ✓）
          if (_tested && _rows.isNotEmpty)
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, __) => Divider(
                    height: 1, color: isDark ? Colors.white12 : Colors.black12),
                itemBuilder: (_, i) {
                  final r = _rows[i];
                  final isCurrent = r.domain == _svc.domain;
                  final ms = r.latency == null
                      ? '—'
                      : '${(r.latency! * 1000).round()} ms';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      r.ok
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      size: 18,
                      color: r.ok ? JellyTheme.success : sub,
                    ),
                    title: Text(r.domain,
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight:
                                isCurrent ? FontWeight.w700 : FontWeight.w400,
                            color: label)),
                    subtitle: Text(
                      r.ok ? '可用 · 延迟 $ms' : '不可达',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: sub),
                    ),
                    trailing: isCurrent
                        ? Text('当前',
                            style: TextStyle(
                                fontSize: AppTheme.fontCaption,
                                color: JellyTheme.primary))
                        : TextButton(
                            onPressed: () => _switchTo(r.domain),
                            child: const Text('切换'),
                          ),
                  );
                },
              ),
            )
          else if (!_testing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '点右上「一键测试」可测出每个节点的可用性与延迟 ✓（内置节点与已添加节点都会测 ✓）',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption, color: sub, height: 1.4),
              ),
            ),
          const SizedBox(height: 12),
          // 添加节点 ✓（保留原有能力：填地址 → 先测试 → 通过则并入候选表 ✓）
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addCtrl,
                  decoration: const InputDecoration(
                    hintText: '添加节点（如 zh.zlibrary.by）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addNode(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: JellyTheme.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: _addNode,
                child: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '添加会先验证可达性 ✓ 通过后并入候选表并落盘 ✓；内置节点不可删除 ✓（它们是兜底 ✓）',
            style: TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.4),
          ),
        ],
      ),
    );
  }
}
