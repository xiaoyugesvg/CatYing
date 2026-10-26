import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/generic_source_service.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「通用源」管理页（2026-10-22；2026-10-23 重做）。
///
/// 只收标准 MacCMS / TVBox JSON 接口：填域名或 `api.php/provide/vod/`
/// 地址即可，添加后与订阅线路同权（首页分类 / 搜索 / 短剧聚合）。
///
/// 这次补上了**批量导入**：一行一个地址（可选 `名称,地址`），
/// 顺序检测、逐条汇报结果 —— 以前只能一条条加，源多了很折磨。
class GenericSourcePage extends StatefulWidget {
  const GenericSourcePage({super.key});

  @override
  State<GenericSourcePage> createState() => _GenericSourcePageState();
}

class _GenericSourcePageState extends State<GenericSourcePage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _busy = false;
  int _batchDone = 0;
  int _batchTotal = 0;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);

  /// 文字 / 图标用的强调色（暗色下 accentColor 是墨灰，看不见）
  Color get _accent => AppTheme.accentOnSurface;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await GenericSourceService.instance.list();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  // ── 单个添加 ─────────────────────────────────────────────────

  Future<void> _add() async {
    final nameC = TextEditingController();
    final urlC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加通用源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(
                labelText: '名称（可留空）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlC,
              decoration: const InputDecoration(
                labelText: '站点域名 / 接口地址',
                hintText: 'https://example.com 或 …/api.php/provide/vod/',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '只支持标准 MacCMS JSON 接口；私有签名站（红果等）不支持。',
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                height: 1.4,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) {
      nameC.dispose();
      urlC.dispose();
      return;
    }
    setState(() => _busy = true);
    AppToast.message('正在检测接口…');
    final r = await GenericSourceService.instance.add(
      name: nameC.text,
      input: urlC.text,
    );
    nameC.dispose();
    urlC.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.show(r.message, '', isError: !r.ok);
    if (r.ok) await _load();
  }

  // ── 批量导入 ─────────────────────────────────────────────────

  Future<void> _batch() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 420,
              child: TextField(
                controller: ctrl,
                maxLines: 8,
                minLines: 5,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: '一行一个，支持两种格式：\n'
                      'https://a.com\n'
                      '我的站点,https://b.com',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '会逐条检测接口，失败的跳过不影响其它条。',
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                height: 1.4,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始导入'),
          ),
        ],
      ),
    );
    final raw = ctrl.text;
    ctrl.dispose();
    if (ok != true || !mounted) return;

    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      AppToast.show('没有可导入的地址', '');
      return;
    }

    setState(() {
      _busy = true;
      _batchDone = 0;
      _batchTotal = lines.length;
    });
    var success = 0;
    final fails = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (!mounted) return;
      final line = lines[i];
      // 兼容「名称,地址」：取最后一个逗号后半段当地址
      var name = '';
      var url = line;
      final c = line.lastIndexOf(',');
      if (c > 0 && line.substring(c + 1).trim().startsWith('http')) {
        name = line.substring(0, c).trim();
        url = line.substring(c + 1).trim();
      }
      final r = await GenericSourceService.instance.add(name: name, input: url);
      if (r.ok) {
        success++;
      } else {
        fails.add('$url：${r.message}');
      }
      if (!mounted) return;
      setState(() => _batchDone = i + 1);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _batchDone = 0;
      _batchTotal = 0;
    });
    await _load();
    if (!mounted) return;
    if (fails.isEmpty) {
      AppToast.show('已导入 $success 个源', '');
    } else {
      AppToast.show('成功 $success 个，失败 ${fails.length} 个', fails.first);
    }
  }

  // ── 本地源（离线 JSON）────────────────────────────────────────

  /// 添加本地源：可以从文件选，也可以直接粘贴 JSON。
  ///
  /// 与上面的"在线源"不同，这份内容会存进 App 私有目录，
  /// 之后分类/列表/详情/搜索全部读本地文件，断网也能用。
  Future<void> _addLocal() async {
    final nameC = TextEditingController();
    final jsonC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加本地源'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(
                    labelText: '名称（可留空）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: jsonC,
                  maxLines: 6,
                  minLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'MacCMS JSON（含 class / list）',
                    alignLabelWithHint: true,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  onPressed: () async {
                    try {
                      final files = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: const ['json', 'txt'],
                      );
                      if (files.isEmpty) return;
                      final f = files.first;
                      final text = utf8.decode(
                        await f.readAsBytes(),
                        allowMalformed: true,
                      );
                      jsonC.text = text;
                      if (nameC.text.trim().isEmpty) {
                        final base = (f.path ?? '')
                            .split(RegExp(r'[\\/]'))
                            .last
                            .replaceAll(
                              RegExp(r'\.(json|txt)$', caseSensitive: false),
                              '',
                            );
                        nameC.text = base;
                      }
                    } catch (e) {
                      AppToast.show('读取文件失败', '$e');
                    }
                  },
                  icon: const Icon(Icons.folder_open_rounded, size: 19),
                  label: const Text('从文件选择'),
                ),
                Text(
                  '离线可用：导入后分类 / 列表 / 详情 / 搜索都直接读这份文件。',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    height: 1.4,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    final name = nameC.text;
    final json = jsonC.text;
    nameC.dispose();
    jsonC.dispose();
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await GenericSourceService.instance.addLocalJson(
      name: name,
      jsonText: json,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.show(r.message, '', isError: !r.ok);
    if (r.ok) await _load();
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final name = (item['name'] ?? '').toString();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除通用源'),
        content: Text('确定删除「$name」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await GenericSourceService.instance.remove(
      (item['key'] ?? '').toString(),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('通用源',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: '添加本地源（离线 JSON）',
            icon: Icon(Icons.folder_open_rounded, color: _fg),
            onPressed: _busy ? null : _addLocal,
          ),
          IconButton(
            tooltip: '批量导入',
            icon: Icon(Icons.playlist_add_rounded, color: _fg),
            onPressed: _busy ? null : _batch,
          ),
          IconButton(
            tooltip: '添加单个',
            icon: Icon(Icons.add_rounded, color: _fg),
            onPressed: _busy ? null : _add,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _intro(),
                if (_busy && _batchTotal > 0) ...[
                  const SizedBox(height: 12),
                  _progress(),
                ],
                const SizedBox(height: 14),
                if (_items.isEmpty)
                  _empty()
                else
                  for (var i = 0; i < _items.length; i++)
                    _card(_items[i], i),
              ],
            ),
    );
  }

  Widget _intro() => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _accent.withValues(alpha: _isDark ? 0.18 : 0.10),
              _accent.withValues(alpha: _isDark ? 0.04 : 0.02),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border:
              Border.all(color: _accent.withValues(alpha: 0.18), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dns_rounded, size: 18, color: _accent),
                const SizedBox(width: 7),
                Text('MacCMS / TVBox JSON',
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '填站点域名会自动尝试 /api.php/provide/vod/。\n'
              '右上角「文件夹」可导入本地源：粘贴或选择 MacCMS JSON，\n'
              '离线也能浏览、搜索。\n'
              '添加后与订阅线路同权：首页分类、搜索、短剧聚合都能用。',
              style: TextStyle(
                  color: _sub, fontSize: AppTheme.fontCaption, height: 1.6),
            ),
          ],
        ),
      );

  Widget _progress() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('正在检测 $_batchDone / $_batchTotal',
              style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: _batchTotal == 0 ? null : _batchDone / _batchTotal,
              minHeight: 5,
              backgroundColor: _isDark ? Colors.white12 : Colors.black12,
              valueColor: AlwaysStoppedAnimation(_accent),
            ),
          ),
        ],
      );

  Widget _empty() => Padding(
        padding: const EdgeInsets.only(top: 56),
        child: Column(
          children: [
            Icon(Icons.dns_outlined,
                size: 40, color: _sub.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Text('还没有通用源',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote)),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
              ),
              onPressed: _busy ? null : _batch,
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: const Text('批量导入'),
            ),
          ],
        ),
      );

  Widget _card(Map<String, dynamic> item, int index) {
    final name = (item['name'] ?? '').toString();
    final api = (item['api'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(11, 10, 6, 10),
      decoration: BoxDecoration(
        color: _tile,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        border: Border.all(color: _line, width: 0.8),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('${index + 1}',
                style: TextStyle(
                    color: _accent,
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isEmpty ? '未命名源' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(api,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
              ],
            ),
          ),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline_rounded, size: 19, color: _sub),
            onPressed: _busy ? null : () => _remove(item),
          ),
        ],
      ),
    );
  }
}
