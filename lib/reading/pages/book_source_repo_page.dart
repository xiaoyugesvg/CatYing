import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../theme/jelly_theme.dart';

/// 书源仓库 —— 导入 / 管理小说书源。
///
/// ── 这是什么 ──────────────────────────────────────────────────
/// 用户导入 Legado（阅读 3.0）格式的书源 JSON，一个 JSON 描述一个小说网站
/// （搜索规则 / 详情规则 / 目录规则 / 正文规则）。导入后可以按任意书源搜书。
///
/// ── 与「漫画源仓库」的区别 ────────────────────────────────────
///   · 漫画源仓库 → `SiteConfig`，服务**漫画**（图片）
///   · 书源仓库   → `BookSource`， 服务**小说**（文字）
/// 两者格式不同、用途不同，所以是两个独立页面（老桌面版也是分开的）。
///
/// ── 导入方式 ─────────────────────────────────────────────────
///   1. **粘贴 JSON** —— 单个源 / 数组 / `{"sources":[...]}` 都吃
///   2. **从网址导入** —— 拉一份书源列表（常见分发方式）
///   3. **从剪贴板** —— 一键粘贴
class BookSourceRepoPage extends StatefulWidget {
  const BookSourceRepoPage({super.key});

  @override
  State<BookSourceRepoPage> createState() => _BookSourceRepoPageState();
}

class _BookSourceRepoPageState extends State<BookSourceRepoPage> {
  final store = BookSourceStore.instance;
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  bool _selectMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    if (store.isEmpty) store.init();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        title: Text(_selectMode ? '已选 ${_selected.length}' : '小说书源仓库'),
        actions: [
          if (store.all.isNotEmpty)
            IconButton(
              tooltip: _selectMode ? '退出多选' : '多选',
              icon: Icon(_selectMode
                  ? Icons.close_rounded
                  : Icons.checklist_rounded),
              onPressed: () => setState(() {
                _selectMode = !_selectMode;
                _selected.clear();
              }),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store.revision,
        builder: (context, _) {
          final list = store.sorted();
          return Column(
            children: [
              if (!_selectMode) ...[
                _importCard(),
                _statsBar(list),
              ] else
                _selectBar(list),
              Expanded(
                child: list.isEmpty ? _empty() : _sourceList(list),
              ),
            ],
          );
        },
      ),
      floatingActionButton: _selectMode && _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除选中'),
              backgroundColor: Colors.redAccent,
            )
          : null,
    );
  }

  // ============================================================
  // 导入
  // ============================================================

  Widget _importCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.library_add_rounded,
                  size: 18, color: JellyTheme.primary),
              const SizedBox(width: 6),
              Text(
                '导入书源',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '支持 Legado / 阅读 3.0 书源：粘贴 JSON，或填书源列表网址',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '书源列表网址（可选）',
                    hintStyle: TextStyle(
                        fontSize: 13, color: JellyTheme.textSecondary),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _importFromUrl,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('拉取'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _showPasteSheet,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('粘贴 JSON'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromClipboard,
                  icon: const Icon(Icons.assignment_rounded, size: 18),
                  label: const Text('从剪贴板'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statsBar(List<BookSource> list) {
    final on = list.where((e) => e.enabled).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Row(
        children: [
          Text(
            '共 ${list.length} 个书源 · 已启用 $on',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const Spacer(),
          if (list.isNotEmpty)
            TextButton(
              onPressed: () async {
                final allOn = on == list.length;
                await store.setAllEnabled(!allOn);
              },
              child: Text(on == list.length ? '全部停用' : '全部启用',
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _selectBar(List<BookSource> list) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == list.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(list.map((e) => e.id));
              }
            }),
            child: Text(_selected.length == list.length ? '取消全选' : '全选'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, true);
              }
              _toast('已启用 ${_selected.length} 个');
            },
            child: const Text('启用'),
          ),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, false);
              }
              _toast('已停用 ${_selected.length} 个');
            },
            child: const Text('停用'),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 42,
                  color: JellyTheme.textSecondary.withValues(alpha: 0.5)),
              const SizedBox(height: 14),
              Text('还没有小说书源',
                  style: TextStyle(
                      fontSize: 15,
                      color:
                          _isDark ? Colors.white : JellyTheme.textPrimaryLight)),
              const SizedBox(height: 8),
              Text(
                '书源是一份 JSON，描述从某个小说站怎么搜书、取目录、取正文。\n'
                '粘贴一份书源就能从那个站搜书看。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: JellyTheme.textSecondary),
              ),
            ],
          ),
        ),
      );

  Widget _sourceList(List<BookSource> list) {
    // 按分组展示：书源通常带 bookSourceGroup，分组后好找
    final groups = store.grouped();
    if (groups.length <= 1) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
        itemCount: list.length,
        itemBuilder: (c, i) => _sourceTile(list[i]),
      );
    }
    final out = <Widget>[];
    groups.forEach((g, items) {
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
        child: Text('$g（${items.length}）',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: JellyTheme.primary)),
      ));
      out.addAll(items.map(_sourceTile));
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: out,
    );
  }

  Widget _sourceTile(BookSource s) {
    final sel = _selected.contains(s.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: sel
            ? Border.all(color: JellyTheme.primary, width: 1.2)
            : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
        leading: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.menu_book_rounded,
              size: 19, color: JellyTheme.primary),
        ),
        title: Text(
          s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: s.enabled
                ? (_isDark ? Colors.white : JellyTheme.textPrimaryLight)
                : JellyTheme.textSecondary,
          ),
        ),
        subtitle: Text(
          s.url.isEmpty ? s.group : s.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: JellyTheme.textSecondary),
        ),
        onTap: _selectMode
            ? () => setState(() {
                  if (sel) {
                    _selected.remove(s.id);
                  } else {
                    _selected.add(s.id);
                  }
                })
            : () => _showDetail(s),
        trailing: _selectMode
            ? Icon(
                sel ? Icons.check_circle : Icons.circle_outlined,
                color: sel ? JellyTheme.primary : JellyTheme.textSecondary,
                size: 22,
              )
            : Switch(
                value: s.enabled,
                activeThumbColor: JellyTheme.primary,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
      ),
    );
  }

  // ============================================================
  // 操作
  // ============================================================

  Future<void> _importFromClipboard() async {
    final d = await Clipboard.getData('text/plain');
    final text = d?.text;
    if (text == null || text.trim().isEmpty) {
      _toast('剪贴板是空的');
      return;
    }
    await _doImport(text);
  }

  Future<void> _importFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写书源列表网址');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await Dio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final body = res.data ?? '';
      if (body.trim().isEmpty) {
        _toast('网址返回内容为空');
        return;
      }
      await _doImport(body);
    } catch (e) {
      _toast('拉取失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 解析并导入。
  ///
  /// 兼容 4 种形态（用户收集来的书源格式不统一）：
  ///   · 数组          `[{...},{...}]`
  ///   · 单个对象      `{...}`
  ///   · 包一层        `{"sources":[...]}`
  ///   · 逗号结尾的脏 JSON（有些分发文件带尾随逗号）
  Future<void> _doImport(String text) async {
    setState(() => _busy = true);
    try {
      final parsed = _parseSources(text);
      if (parsed.isEmpty) {
        _toast('没解析出书源。需要 Legado 书源 JSON（含 bookSourceName / bookSourceUrl）');
        return;
      }
      final r = await store.addAll(parsed);
      if (!mounted) return;
      _toast(r.added > 0 && r.updated > 0
          ? '新增 ${r.added} 个、更新 ${r.updated} 个书源'
          : (r.added > 0 ? '已导入 ${r.added} 个书源' : '已更新 ${r.updated} 个书源'));
    } catch (e) {
      _toast('解析失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<BookSource> _parseSources(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 有些分发文件带尾随逗号 / 注释，退回"宽松"处理：
      // 截取第一个 '[' 到最后一个 ']'（或 '{'..'}'）再试
      final a = text.indexOf('[');
      final b = text.lastIndexOf(']');
      final c = text.indexOf('{');
      final d = text.lastIndexOf('}');
      String? candidate;
      if (a >= 0 && b > a) {
        candidate = text.substring(a, b + 1);
      } else if (c >= 0 && d > c) {
        candidate = text.substring(c, d + 1);
      }
      if (candidate == null) rethrow;
      decoded = jsonDecode(candidate);
    }

    final out = <BookSource>[];
    void take(dynamic e) {
      if (e is! Map) return;
      final s = BookSource.fromJson(e.cast<String, dynamic>());
      if (s != null) out.add(s);
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return out;
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源', style: TextStyle(fontSize: 16)),
        content: Text('确定删除选中的 $n 个书源？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selected.toList()) {
      await store.remove(id);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    _toast('已删除 $n 个书源');
  }

  void _showDetail(BookSource s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: _isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight)),
                const SizedBox(height: 12),
                _kv('分组', s.group),
                _kv('网址', s.url.isEmpty ? '（未配置）' : s.url),
                if (s.comment.isNotEmpty) _kv('备注', s.comment),
                _kv('状态', s.enabled ? '已启用' : '已停用'),
                _kv('字段数', '${s.raw.length}'),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                            text: const JsonEncoder.withIndent('  ')
                                .convert(s.toJson()),
                          ));
                          Navigator.pop(ctx);
                          _toast('已复制这个书源的 JSON');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 17),
                        label: const Text('复制'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await store.remove(s.id);
                          _toast('已删除「${s.name}」');
                        },
                        icon: const Icon(Icons.delete_outline, size: 17),
                        label: const Text('删除',
                            style: TextStyle(color: Colors.redAccent)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 12, color: JellyTheme.textSecondary)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: _isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight)),
            ),
          ],
        ),
      );

  /// 粘贴 JSON 弹层
  Future<void> _showPasteSheet() async {
    final ctrl = TextEditingController();
    var error = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color:
                            JellyTheme.textSecondary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('粘贴书源 JSON',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight)),
                  const SizedBox(height: 6),
                  Text(
                    '支持：单个书源对象 / 书源数组 / {"sources":[...]}',
                    style: TextStyle(
                        fontSize: 11.5, color: JellyTheme.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    maxLines: 8,
                    minLines: 5,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '在此粘贴书源 JSON…',
                      hintStyle: TextStyle(
                          fontSize: 13, color: JellyTheme.textSecondary),
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(error,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await Clipboard.getData('text/plain');
                          final t = d?.text;
                          if (t != null && t.isNotEmpty) {
                            ctrl.text = t;
                            setSheet(() => error = '');
                          }
                        },
                        icon: const Icon(Icons.content_paste_rounded, size: 16),
                        label: const Text('粘贴剪贴板'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () async {
                          final text = ctrl.text.trim();
                          if (text.isEmpty) {
                            setSheet(() => error = '请先粘贴书源 JSON');
                            return;
                          }
                          final parsed = _parseSources(text);
                          if (parsed.isEmpty) {
                            setSheet(() => error =
                                '没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
                            return;
                          }
                          final r = await store.addAll(parsed);
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _toast(r.added > 0
                              ? '已导入 ${r.added} 个书源'
                              : '已更新 ${r.updated} 个书源');
                        },
                        child: const Text('导入'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }
}
