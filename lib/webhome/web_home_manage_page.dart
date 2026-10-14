// lib/webhome/web_home_manage_page.dart
//
// 「网页管理」页（用户 2026-10-14）：
//   · 列出全部网页源，**点一条即切换**（当前那条打勾）
//   · **长按拖动排序**（保存顺序，重启保持）
//   · 改名 / 删除 / 恢复内置
//   · **导入订阅链接**（远端 JSON 清单 或 单个网页地址）
//   · **导入本地文件**（手机里的 .html，复制进 App 目录后长期可用）
//
// 入口：设置 → 订阅管理 → 网页管理；以及「网页」页顶栏右边的设置按钮。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'web_home_prefs.dart';
import 'web_home_source.dart';

class WebHomeManagePage extends StatefulWidget {
  const WebHomeManagePage({super.key});

  @override
  State<WebHomeManagePage> createState() => _WebHomeManagePageState();
}

class _WebHomeManagePageState extends State<WebHomeManagePage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    webHomeSourcesTick.addListener(_refresh);
  }

  @override
  void dispose() {
    webHomeSourcesTick.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = WebHomePrefs.instance;
    final list = prefs.sources;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('网页管理',
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontTitle3)),
        actions: [
          IconButton(
            tooltip: '恢复内置',
            icon: Icon(Icons.restore_rounded,
                size: 20, color: AppTheme.textSecondary),
            onPressed: _busy
                ? null
                : () async {
                    final n = await prefs.restoreBuiltins();
                    if (mounted) {
                      AppToast.message(n == 0 ? '内置网页都在' : '已补回 $n 个内置网页');
                    }
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('点一条即切换；拖右侧把手可排序',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('还没有网页，用下面的按钮导入',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead)),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    buildDefaultDragHandles: false,
                    itemCount: list.length,
                    onReorder: prefs.reorder,
                    itemBuilder: (c, i) {
                      final s = list[i];
                      final cur = s.id == prefs.selectedId;
                      return Padding(
                        key: ValueKey(s.id),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundSecondary,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: cur
                                  ? AppTheme.accentColor.withValues(alpha: 0.6)
                                  : AppTheme.glassBorderSoft,
                              width: cur ? 1.2 : 0.6,
                            ),
                          ),
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                      left: 8, right: 4, top: 14, bottom: 14),
                                  child: Icon(Icons.drag_indicator,
                                      size: 18, color: AppTheme.textTertiary),
                                ),
                              ),
                              Expanded(
                                child: InkWell(
                                  onTap: () => prefs.select(s.id),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    child: Row(
                                      children: [
                                        Icon(
                                          cur
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          size: 18,
                                          color: cur
                                              ? AppTheme.accentColor
                                              : AppTheme.textTertiary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      s.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          color: AppTheme
                                                              .textPrimary,
                                                          fontSize: AppTheme
                                                              .fontSubhead),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 1),
                                                    decoration: BoxDecoration(
                                                      color: AppTheme
                                                          .backgroundTertiary,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              6),
                                                    ),
                                                    child: Text(s.kind.label,
                                                        style: TextStyle(
                                                            color: AppTheme
                                                                .textTertiary,
                                                            fontSize: AppTheme
                                                                .fontCaption)),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                s.value,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    color:
                                                        AppTheme.textTertiary,
                                                    fontSize:
                                                        AppTheme.fontCaption),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert,
                                    size: 20, color: AppTheme.textSecondary),
                                onSelected: (v) async {
                                  if (v == 'rename') {
                                    final n = await _askText(
                                        title: '重命名网页',
                                        hint: '网页名称',
                                        initial: s.name);
                                    if (n != null && n.trim().isNotEmpty) {
                                      await prefs.rename(s.id, n);
                                    }
                                  } else if (v == 'delete') {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor:
                                            AppTheme.backgroundSecondary,
                                        title: Text('删除网页',
                                            style: TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: AppTheme.fontHeadline)),
                                        content: Text('确定删除「${s.name}」吗？',
                                            style: TextStyle(
                                                color: AppTheme.textSecondary,
                                                fontSize: AppTheme.fontSubhead)),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('取消')),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text('删除',
                                                style: TextStyle(
                                                    color: Colors.redAccent)),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) await prefs.remove(s.id);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                      value: 'rename',
                                      child: Text('重命名',
                                          style: TextStyle(
                                              color: AppTheme.textPrimary))),
                                  const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除',
                                          style:
                                              TextStyle(color: Colors.redAccent))),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.backgroundTertiary,
                        foregroundColor: AppTheme.textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _importByUrl,
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: const Text('导入订阅链接'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.backgroundTertiary,
                        foregroundColor: AppTheme.textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _importByFile,
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: const Text('导入本地文件'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 导入：订阅链接 ──────────────────────────────────────────────
  //
  // 两种形态都支持（用户要求"能导入订阅链接"）：
  //   ① 远端是一份**清单**（JSON：`{"sources":[{name,value,kind?}]}` 或直接数组）
  //      → 一次导入多条
  //   ② 远端就是一个网页地址（HTML / 任意页面）→ 当成**一条**网页源，
  //      名字优先取页面 `<title>`，取不到就用域名
  Future<void> _importByUrl() async {
    final url = await _askText(
      title: '导入订阅链接',
      hint: 'https://…（清单 JSON 或网页地址）',
      initial: '',
    );
    if (url == null || url.trim().isEmpty) return;
    final link = url.trim();
    setState(() => _busy = true);
    Dio? dio;
    try {
      dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        responseType: ResponseType.plain,
        headers: {'User-Agent': 'Mozilla/5.0'},
      ));
      final resp = await dio.get<String>(link);
      final body = resp.data ?? '';
      if (body.trim().isEmpty) {
        AppToast.error('链接里没有内容');
        return;
      }

      // ① 先当"清单"解析
      final many = _parseSourceManifest(body);
      if (many != null && many.isNotEmpty) {
        var added = 0;
        for (final s in many) {
          if (await WebHomePrefs.instance.add(s)) added++;
        }
        AppToast.message(added == 0
            ? '清单里的网页都已经有了'
            : '已导入 $added 个网页（共 ${many.length} 条）');
        return;
      }

      // ② 当成单个网页
      final name = _titleOf(body) ?? _nameFromUrl(link);
      final ok = await WebHomePrefs.instance.add(WebHomeSource(
        id: 'ws_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        kind: WebHomeSourceKind.url,
        value: link,
      ));
      AppToast.message(ok ? '已导入「$name」' : '这个地址已经在列表里了');
    } catch (e) {
      AppToast.error('导入失败：${e.toString().split('\n').first}');
    } finally {
      dio?.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 解析"订阅清单"：
  ///   · `{"sources":[...]}` / `[...]` / 每行 `名称,地址` 的纯文本
  /// 不是清单就返回 null（交给调用方当单网页处理）。
  ///
  /// ⚠️ RSS / 资讯订阅源**不在这里**处理：那是独立的 RSS 模块
  /// （底栏「RSS」分类 + 设置里的「RSS 管理」），别再把它收成一条网页源。
  List<WebHomeSource>? _parseSourceManifest(String body) {
    final t = body.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final decoded = jsonDecode(t);
        final arr = decoded is Map
            ? (decoded['sources'] is List ? decoded['sources'] as List : null)
            : (decoded is List ? decoded : null);
        if (arr == null) return null;
        final out = <WebHomeSource>[];
        for (final e in arr) {
          if (e is Map) {
            final s = WebHomeSource.fromJson(Map<String, dynamic>.from(e));
            if (s != null) out.add(s);
          }
        }
        return out.isEmpty ? null : out;
      } catch (_) {
        return null;
      }
    }
    // 纯文本清单：每行 `名称,地址`（有些分享就是这种）
    final lines = t
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .toList();
    if (lines.isEmpty) return null;
    final out = <WebHomeSource>[];
    for (final l in lines) {
      final parts = l.split(RegExp(r'[,，|\s]+'));
      if (parts.length < 2) continue;
      final value = parts.last;
      if (!value.startsWith('http')) continue;
      final name = parts.take(parts.length - 1).join(' ').trim();
      out.add(WebHomeSource(
        id: 'ws_${value.hashCode.abs()}',
        name: name.isEmpty ? _nameFromUrl(value) : name,
        kind: WebHomeSourceKind.url,
        value: value,
      ));
    }
    return out.isEmpty ? null : out;
  }

  String? _titleOf(String html) {
    final m = RegExp(r'<title[^>]*>([^<]{1,40})</title>',
            caseSensitive: false)
        .firstMatch(html);
    final t = m?.group(1)?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  String _nameFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      final seg = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
      if (seg.toLowerCase().endsWith('.html') || seg.toLowerCase().endsWith('.htm')) {
        return seg.replaceAll(RegExp(r'\.html?$', caseSensitive: false), '');
      }
      return u.host.isEmpty ? url : u.host;
    } catch (_) {
      return url;
    }
  }

  // ── 导入：本地文件 ──────────────────────────────────────────────
  //
  // 复制进 App 自己的目录（`<Documents>/webhome/`）再登记 —— 直接引用
  // 沙箱外的临时路径，重启/系统清理后就打不开了。
  Future<void> _importByFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        // `.json` 也收：订阅清单（`{"sources":[…]}`）
        allowedExtensions: const ['html', 'htm', 'json'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final rawName = f.name;
      var bytes = const <int>[];
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        final p = f.path;
        if (p == null) {
          AppToast.error('读不出这个文件（没有本地路径）');
          return;
        }
        bytes = await File(p).readAsBytes();
      }
      if (bytes.isEmpty) {
        AppToast.error('文件是空的');
        return;
      }

      // ── ① JSON：当"订阅清单"导入（**不**把 JSON 本身存成网页）──
      if (rawName.toLowerCase().endsWith('.json')) {
        final text = utf8.decode(bytes, allowMalformed: true);
        final list = _parseSourceManifest(text);
        if (list == null || list.isEmpty) {
          AppToast.error('这个 JSON 里没有可导入的网页源');
          return;
        }
        var added = 0;
        for (final s in list) {
          if (await WebHomePrefs.instance.add(s)) added++;
        }
        AppToast.message(added == 0
            ? '里面的网页都已经有了'
            : '已导入 $added 个网页（共 ${list.length} 条）');
        return;
      }

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/webhome');
      if (!dir.existsSync()) await dir.create(recursive: true);
      // 文件名净化：去掉路径分隔符等，前面加时间戳防重名
      final safe = rawName.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final path =
          '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe';
      await File(path).writeAsBytes(bytes, flush: true);

      final name = rawName
          .replaceAll(RegExp(r'\.html?$', caseSensitive: false), '')
          .trim();
      final ok = await WebHomePrefs.instance.add(WebHomeSource(
        id: 'ws_${DateTime.now().microsecondsSinceEpoch}',
        name: name.isEmpty ? rawName : name,
        kind: WebHomeSourceKind.file,
        value: path,
      ));
      AppToast.message(ok ? '已导入「$name」' : '同一个文件已经在列表里了');
    } catch (e) {
      AppToast.error('导入失败：${e.toString().split('\n').first}');
    }
  }

  Future<String?> _askText({
    required String title,
    required String hint,
    required String initial,
  }) async {
    final ctrl = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(title,
              style: TextStyle(
                  color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                  color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('确定')),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }
}
