import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../common/theme.dart';
import '../../../../services/music_service.dart';

/// 从本地文件导入落雪音源脚本
///
/// **为什么不用 file_picker 插件**：
/// 本 App 是 TrollStore 侧载，每加一个原生插件就多一份签名与运行时风险；
/// 而"选一个 .js 文件"用 dart:io 自己列目录即可，零新依赖。
///
/// 两条路径都给：
///   1. 粘贴脚本内容（最稳，任何来源都能用）
///   2. 浏览 App 沙盒目录里的 .js 文件
class MusicScriptImportPage extends StatefulWidget {
  const MusicScriptImportPage({super.key});

  @override
  State<MusicScriptImportPage> createState() => _MusicScriptImportPageState();
}

class _MusicScriptImportPageState extends State<MusicScriptImportPage> {
  final _pasteCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  /// 当前浏览的目录
  Directory? _dir;
  final files = <FileSystemEntity>[].obs;
  final browsing = true.obs;
  final err = ''.obs;

  /// 粘贴模式 / 浏览模式
  final pasteMode = false.obs;

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  @override
  void dispose() {
    _pasteCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _initDir() async {
    // 从 App 的 Documents 开始（用户通过「文件」App / 电脑助手 放进来）
    try {
      final docs = await getApplicationDocumentsDirectory();
      await _openDir(docs);
    } catch (e) {
      err.value = '无法访问目录：$e';
      browsing.value = false;
    }
  }

  Future<void> _openDir(Directory d) async {
    browsing.value = true;
    err.value = '';
    try {
      if (!await d.exists()) {
        err.value = '目录不存在：${d.path}';
        files.clear();
        return;
      }
      final items = <FileSystemEntity>[];
      await for (final e in d.list(followLinks: false)) {
        final name = e.path.split(Platform.pathSeparator).last;
        // 跳过隐藏文件
        if (name.startsWith('.')) continue;
        // 只显示目录 + .js/.txt/.json（脚本常见后缀）
        if (e is Directory) {
          items.add(e);
        } else if (e is File) {
          final lower = name.toLowerCase();
          if (lower.endsWith('.js') ||
              lower.endsWith('.txt') ||
              lower.endsWith('.json')) {
            items.add(e);
          }
        }
      }
      items.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return a.path.compareTo(b.path);
      });
      _dir = d;
      files.assignAll(items);
    } catch (e) {
      err.value = '读取目录失败：$e';
      files.clear();
    } finally {
      browsing.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('导入音源脚本',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        actions: [
          // 粘贴模式 / 浏览模式切换
          Obx(() => IconButton(
                icon: Icon(
                  pasteMode.value ? Icons.folder_outlined : Icons.edit_note,
                  size: 21,
                  color: AppTheme.accentColor,
                ),
                tooltip: pasteMode.value ? '浏览文件' : '粘贴脚本',
                onPressed: () => pasteMode.value = !pasteMode.value,
              )),
        ],
      ),
      body: Obx(() => pasteMode.value ? _buildPaste() : _buildBrowse()),
    );
  }

  // ============================================================
  // 粘贴模式
  // ============================================================

  Widget _buildPaste() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            '把落雪音源脚本的完整内容粘贴到下面。\n'
            '脚本里应包含 lx.on("request", ...) 。',
            style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                height: 1.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
              border: Border.all(color: AppTheme.borderLight, width: 0.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _nameCtrl,
              cursorColor: AppTheme.accentColor,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '音源名称（可留空自动识别）',
                hintStyle: TextStyle(
                    color: AppTheme.textTertiary, fontSize: 12.5),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
                border: Border.all(color: AppTheme.borderLight, width: 0.5),
              ),
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _pasteCtrl,
                maxLines: null,
                expands: true,
                cursorColor: AppTheme.accentColor,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    height: 1.35),
                decoration: InputDecoration(
                  hintText: '// 在这里粘贴脚本内容…',
                  hintStyle: TextStyle(
                      color: AppTheme.textTertiary, fontSize: 12),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _primaryButton('导入', _importPasted),
          ),
        ),
      ],
    );
  }

  Future<void> _importPasted() async {
    final messenger = ScaffoldMessenger.of(context);
    final src = _pasteCtrl.text.trim();
    if (src.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先粘贴脚本内容')));
      return;
    }
    if (!src.contains('lx.') && !src.contains('module.exports')) {
      messenger.showSnackBar(const SnackBar(
        content: Text('内容不像落雪音源脚本（未找到 lx.* 调用）'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    await MusicService.instance
        .saveLxScript(src, name: _nameCtrl.text.trim());
    messenger.showSnackBar(SnackBar(
        content: Text('已导入：${MusicService.instance.lxName.value}')));
    if (mounted) Navigator.of(context).pop();
  }

  // ============================================================
  // 浏览模式
  // ============================================================

  Widget _buildBrowse() {
    return Column(
      children: [
        // 当前路径 + 上级
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              if (_dir != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final parent = _dir!.parent;
                    if (parent.path != _dir!.path) _openDir(parent);
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.arrow_upward,
                        size: 18, color: AppTheme.accentColor),
                  ),
                ),
              Expanded(
                child: Text(
                  _dir?.path ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_dir != null) _openDir(_dir!);
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.refresh,
                      size: 18, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),
        if (err.value.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(err.value,
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontCaption)),
          ),
        Expanded(
          child: browsing.value
              ? Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.accentColor),
                  ),
                )
              : files.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          '这个目录里没有 .js 文件。\n\n'
                          '把落雪音源脚本放到 App 的 Documents 目录\n'
                          '（用「文件」App 或电脑助手），或改用右上角「粘贴脚本」。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption,
                              height: 1.6),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      itemCount: files.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (c, i) => _fileRow(files[i]),
                    ),
        ),
      ],
    );
  }

  Widget _fileRow(FileSystemEntity e) {
    final name = e.path.split(Platform.pathSeparator).last;
    final isDir = e is Directory;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        if (isDir) {
          await _openDir(e);
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        final r = await MusicService.instance.importFromFile(e.path);
        messenger.showSnackBar(SnackBar(
          content: Text(r.message),
          backgroundColor: r.ok ? null : Colors.redAccent,
        ));
        if (r.ok && mounted) Navigator.of(context).pop();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Row(
          children: [
            Icon(isDir ? Icons.folder : Icons.description_outlined,
                size: 18,
                color: isDir ? AppTheme.accentColor : AppTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead)),
            ),
            if (!isDir)
              Icon(Icons.chevron_right,
                  size: 16, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _primaryButton(String text, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.accentColor,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
