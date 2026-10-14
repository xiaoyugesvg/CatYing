// lib/reading/pages/reader_core_page.dart
//
// 阅读核心（ReaderCore）设置页。
//
// ── 为什么单独一页 ─────────────────────────────────────────────
//   与影视的「播放器核心」同构：核心选择长在**模块自己的设置入口**里、独立成页，
//   不和封面 / 翻页那些排版设置混在一起（用户 2026-10-14：别把音乐/影视/阅读搅在一起）。
//
// ── 默认「不启用」就是安全阀 ───────────────────────────────────
//   `ReaderCorePrefs.activeCore == null` 时阅读器一律走**现有链路** ⇒
//   这页什么都不配也不会影响任何现存功能。
//
// ── 为什么列出「当前订阅里的 py 源」──────────────────────────
//   用户 2026-10-14 提的：影视订阅里本来就有能看漫画的 py 源，不该要求他在
//   阅读里再导入一遍。所以这里直接列出**当前订阅解析出来的 py 源**供挑选；
//   ⚠️ 订阅里的源**没有"这是漫画源"的标记**（type 都是 3，区别只在脚本内容里），
//      所以只能全列出来由用户自己认，不猜（猜错就是静默取不到图）。

import 'package:flutter/material.dart';

import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../cores/python_core.dart';
import '../cores/reader_core_prefs.dart';

class ReaderCorePage extends StatefulWidget {
  const ReaderCorePage({super.key});

  @override
  State<ReaderCorePage> createState() => _ReaderCorePageState();
}

class _ReaderCorePageState extends State<ReaderCorePage> {
  final _prefs = ReaderCorePrefs.instance;

  /// 当前订阅里的 py 源（漫画 / 图片类就在其中）
  List<SourceBean> get _pySources => ApiConfig.instance.sourceBeanList
      .where((s) => s.isSpiderSource && s.isPythonScriptSource)
      .toList();

  Future<void> _pickCore(String id) async {
    await _prefs.setCore(id);
    if (mounted) setState(() {});
  }

  Future<void> _pickSource(String url, String name) async {
    await _prefs.setSourceUrl(url);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已选择：$name')));
  }

  Future<void> _inputUrl() async {
    final ctl = TextEditingController(text: _prefs.sourceUrl);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动输入源地址'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://…/xxx.py'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (r != null && r.isNotEmpty) await _pickSource(r, r);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pyId = PythonCore.instance.id;
    final enabled = _prefs.coreId == pyId;

    return Scaffold(
      appBar: AppBar(title: const Text('阅读核心')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _hint('核心决定「阅读数据从哪来」。不启用时走 App 现有的漫画源 / 书源链路。'),
          _radio(scheme, id: '', title: '不启用（默认）', sub: '走现有链路'),
          _radio(scheme,
              id: pyId, title: 'Python 源', sub: '用 .py 脚本取正文 / 图片'),
          if (enabled) ...[
            const Divider(height: 28),
            Text('选择源脚本',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 2),
            _hint(_pySources.isEmpty
                ? '当前订阅里没有 py 源，可以在下面手动填地址。'
                : '下面列出当前订阅里的 py 源（漫画类就在其中，自行选择）。'),
            for (final s in _pySources)
              _sourceTile(scheme, name: s.name, url: s.api),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _inputUrl,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('手动输入地址'),
            ),
            const SizedBox(height: 12),
            _hint('当前：${_prefs.sourceUrl.isEmpty ? "（未设置）" : _prefs.sourceUrl}'),
          ],
        ],
      ),
    );
  }

  Widget _hint(String t) => Text(t,
      style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.5));

  Widget _radio(ColorScheme scheme,
      {required String id, required String title, required String sub}) {
    final sel = _prefs.coreId == id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _pickCore(id),
      leading: Icon(
        sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: sel ? scheme.primary : Colors.grey,
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle:
          Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    );
  }

  Widget _sourceTile(ColorScheme scheme,
      {required String name, required String url}) {
    final sel = url.isNotEmpty && _prefs.sourceUrl == url;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _pickSource(url, name),
      leading: Icon(
        sel ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: sel ? scheme.primary : Colors.grey,
      ),
      title: Text(name.isEmpty ? url : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
    );
  }
}
