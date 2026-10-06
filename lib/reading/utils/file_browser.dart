import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// JellyTheme 的色值分 Light/Dark 两套字段，这里按当前主题明暗取。
Color _bg(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? JellyTheme.backgroundDark
    : JellyTheme.backgroundLight;

Color _fg(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? JellyTheme.textPrimaryDark
    : JellyTheme.textPrimaryLight;

/// 纯 Dart 本地文件浏览器（替代 `file_picker`）。
///
/// ── 为什么不用 file_picker ──────────────────────────────────────
/// 本项目是 **iOS TrollStore 侧载**，硬约束是"不新增原生插件"。
/// `file_picker` 是原生插件，需要 `pod install` 才能被链接；而之前的
/// `flutter_tts` 正因为没链接上，**装完直接 SIGABRT 闪退**。
/// 所以这里用 `dart:io` 自己实现一个目录浏览器，零插件依赖。
///
/// ── 使用方式 ──────────────────────────────────────────────────
/// 用户把书放进 App 沙盒的 `Documents/`（或其子目录）——
/// iOS 上该目录可通过「文件」App → 我的 iPhone → 猫影 访问。
///
/// 返回选中文件的绝对路径列表；取消返回 null。
Future<List<String>?> pickLocalFiles(
  BuildContext context, {
  Set<String> allowedExtensions = const {'txt', 'epub'},
  bool allowMultiple = true,
}) {
  return Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      builder: (_) => _LocalFileBrowserPage(
        allowedExtensions: allowedExtensions,
        allowMultiple: allowMultiple,
      ),
    ),
  );
}

class _LocalFileBrowserPage extends StatefulWidget {
  const _LocalFileBrowserPage({
    required this.allowedExtensions,
    required this.allowMultiple,
  });

  final Set<String> allowedExtensions;
  final bool allowMultiple;

  @override
  State<_LocalFileBrowserPage> createState() => _LocalFileBrowserPageState();
}

class _LocalFileBrowserPageState extends State<_LocalFileBrowserPage> {
  Directory? _dir;
  List<FileSystemEntity> _entries = const [];
  final Set<String> _selected = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      await _open(docs);
    } catch (e) {
      setState(() => _error = '无法访问存储目录：$e');
    }
  }

  Future<void> _open(Directory dir) async {
    try {
      final all = dir.listSync(followLinks: false);
      final items = <FileSystemEntity>[];
      for (final e in all) {
        final name = e.uri.pathSegments.last;
        if (name.startsWith('.')) continue; // 跳过隐藏文件
        if (e is Directory) {
          items.add(e);
        } else if (e is File && _isAllowed(name)) {
          items.add(e);
        }
      }
      // 目录在前，各自按名字排序
      items.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return a.uri.pathSegments.last
            .toLowerCase()
            .compareTo(b.uri.pathSegments.last.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _entries = items;
        _error = null;
        _selected.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '读取目录失败：$e');
    }
  }

  bool _isAllowed(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0) return false;
    return widget.allowedExtensions
        .contains(name.substring(i + 1).toLowerCase());
  }

  void _toggle(String path) {
    setState(() {
      if (!widget.allowMultiple) {
        _selected
          ..clear()
          ..add(path);
      } else if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, _selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final extLabel =
        widget.allowedExtensions.map((e) => e.toUpperCase()).join(' / ');
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: _fg(context)),
        title: Text(
          '选择 $extLabel 文件',
          style: TextStyle(color: _fg(context), fontSize: AppTheme.fontHeadline),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: JellyTheme.textSecondary)),
              ),
            )
          : Column(
              children: [
                // 当前路径
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    _dir?.path ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _fg(context).withValues(alpha: 0.55),
                        fontSize: AppTheme.fontCaption),
                  ),
                ),
                Expanded(
                  child: _entries.isEmpty
                      ? Center(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              '这个目录里没有可导入的文件。\n\n'
                              '把书放进「文件」App → 我的 iPhone → 猫影，\n'
                              '或用电脑通过文件共享拷进来。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: JellyTheme.textSecondary,
                                  height: 1.6),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (c, i) {
                            final e = _entries[i];
                            final name = e.uri.pathSegments.last;
                            final isDir = e is Directory;
                            final picked = _selected.contains(e.path);
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isDir
                                    ? Icons.folder_outlined
                                    : Icons.description_outlined,
                                color: isDir
                                    ? JellyTheme.accent
                                    : JellyTheme.primary,
                                size: 22,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: _fg(context), fontSize: AppTheme.fontBody),
                              ),
                              trailing: isDir
                                  ? Icon(Icons.chevron_right,
                                      size: 18,
                                      color:
                                          _fg(context).withValues(alpha: 0.4))
                                  : (picked
                                      ? Icon(Icons.check_circle,
                                          color: JellyTheme.primary, size: 20)
                                      : null),
                              onTap: () {
                                if (isDir) {
                                  _open(e);
                                } else {
                                  _toggle(e.path);
                                }
                              },
                            );
                          },
                        ),
                ),
                // 多选确认按钮
                if (widget.allowMultiple && _selected.isNotEmpty)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: JellyTheme.primary,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _confirm,
                          child: Text(
                            '导入选中的 ${_selected.length} 个文件',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
