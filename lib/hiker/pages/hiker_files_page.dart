import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../services/hiker_files.dart';

/// 「海阔 → 文件管理」（规则里的 `hiker://files/*`）
///
/// ── 这个页面解决什么（实测依据）──────────────────────────────────
/// 海阔有一批源依赖**用户自己导入的规则包 / 数据文件**：115 个源里
/// `hiker://files/` 出现 **387 次**（`rules/Apollo/*` 38 次、`libs/` 13、
/// `data/` 12、`icon/` 9…）。其中 **Apollo 规则包不在海阔 App 里**
/// （官方 assets 目录里没有），原版海阔同样要用户自己装 —— 装了才能用那批源。
///
/// 所以这里给三个动作：**导入 zip**（解压铺进去，保目录结构）、**放单文件**、
/// **看/删**。路径一律收敛在本目录内（zip 里的 `../` 会被拒绝）。
class HikerFilesPage extends StatefulWidget {
  const HikerFilesPage({super.key});

  @override
  State<HikerFilesPage> createState() => _HikerFilesPageState();
}

class _HikerFilesPageState extends State<HikerFilesPage> {
  List<HikerFileEntry> _files = const [];
  int _bytes = 0;
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await HikerFiles.list();
    var sum = 0;
    for (final e in l) {
      sum += e.size;
    }
    if (!mounted) return;
    setState(() {
      _files = l;
      _bytes = sum;
      _loaded = true;
    });
  }

  String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 导入 zip（Apollo 之类的规则包）
  Future<void> _importZip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      Uint8List? bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        final p = f.path;
        if (p != null) bytes = await _readAll(p);
      }
      if (bytes == null || bytes.isEmpty) {
        AppToast.error('读不出这个 zip');
        return;
      }
      if (!mounted) return;
      setState(() => _busy = true);
      final (written, skipped) = await HikerFiles.importZip(bytes);
      await _reload();
      if (!mounted) return;
      AppToast.message('已解压 $written 个文件'
          '${skipped > 0 ? '（跳过 $skipped 个目录项/越界项）' : ''}');
    } catch (e) {
      AppToast.error('导入失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 放单个文件（落在 `files/` 根）。多个文件请打包成 zip 走「导入 zip」。
  ///
  /// ⚠️ 本项目的 `FilePicker.pickFiles`（静态 API）**不支持 `allowMultiple`**，
  /// 所以这里按单文件实现（`FilePickerResult` 也支持多选时逐个遍历，兼容）。
  Future<void> _importFiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result.isEmpty) return;
      var ok = 0;
      for (final f in result) {
        final name = f.name.replaceAll('\\', '/').split('/').last;
        Uint8List? bytes;
        try {
          bytes = await f.readAsBytes();
        } catch (_) {
          final p = f.path;
          if (p != null) bytes = await _readAll(p);
        }
        if (bytes == null) continue;
        if (await HikerFiles.putBytes(name, bytes)) ok++;
      }
      await _reload();
      if (!mounted) return;
      AppToast.message('已放入 $ok 个文件');
    } catch (e) {
      AppToast.error('导入失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<Uint8List?> _readAll(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 建常用目录（rules / libs / data / icon / cache）
  Future<void> _makeCommonDirs() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 目录本身不需要内容：放一个 `.keep` 占位，让空目录也能列出来
      for (final d in HikerFiles.commonDirs) {
        await HikerFiles.putBytes('$d/.keep', Uint8List(0));
      }
      await _reload();
      if (!mounted) return;
      AppToast.message('已创建 ${HikerFiles.commonDirs.length} 个常用目录');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(HikerFileEntry e) async {
    final ok = await _confirm('删除「${e.path}」？', '只影响这个文件，源列表不受影响。');
    if (ok != true) return;
    await HikerFiles.delete(e.path);
    await _reload();
    if (mounted) AppToast.message('已删除');
  }

  Future<void> _clearAll() async {
    final ok = await _confirm('清空文件区？',
        '会删掉你导入的**全部**文件（含 Apollo 之类规则包）。规则里的 hiker://files/* 将读不到内容。');
    if (ok != true) return;
    await HikerFiles.clearAll();
    await _reload();
    if (mounted) AppToast.message('已清空');
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(title,
              style: TextStyle(
                  color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
          content: Text(body,
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: AppTheme.fontSubhead)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('确定', style: TextStyle(color: AppTheme.accentOnSurface)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          SizedBox(height: topInset),
          // 顶栏：与海阔其它页一致（返回 + 标题 + 圆形动作按钮）
          SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    iconSize: 20,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textPrimary),
                  ),
                  Text('文件管理',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.bold)),
                  const Spacer(),
                  _topIcon(Icons.folder_zip_outlined, '导入 zip', _importZip),
                  const SizedBox(width: 8),
                  _topIcon(Icons.note_add_outlined, '放单文件', _importFiles),
                  const SizedBox(width: 8),
                  _topIcon(Icons.delete_sweep_outlined, '清空', _clearAll),
                ],
              ),
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(
                minHeight: 2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
                backgroundColor: AppTheme.borderLight,
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_loaded) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor:
                  AlwaysStoppedAnimation(AppTheme.accentOnSurface)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10, top: 2),
          child: Text(
            '规则里的 hiker://files/* 读的就是这里 · 共 ${_files.length} 个文件'
            '${_bytes > 0 ? ' · ${_size(_bytes)}' : ''}',
            style: TextStyle(
                color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption),
          ),
        ),
        if (_files.isEmpty)
          _notice('还没有文件。\n\n'
              '海阔有一批源依赖**你自己导入的规则包**（最典型是 Apollo，'
              '它不在海阔 App 里，原版也要用户自己装）。'
              '把下载到的 zip 用右上角「导入 zip」铺进来，那批源就能跑。'),
        if (_files.isNotEmpty)
          _notice('依赖 hiker://files/* 的源读的就是这些文件。'
              '少了对应文件时，那类源会明确报"读不到文件"，不会静默出错数据。'),
        for (final e in _files)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: AppTheme.backgroundCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.insert_drive_file_outlined,
                  size: 18, color: AppTheme.textSecondary),
              title: Text(
                e.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead),
              ),
              subtitle: Text(_size(e.size),
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption)),
              trailing: IconButton(
                tooltip: '删除',
                iconSize: 18,
                onPressed: () => _delete(e),
                icon: Icon(Icons.close_rounded, color: AppTheme.textTertiary),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: _makeCommonDirs,
            child: Text('创建常用目录（rules / libs / data / icon / cache）',
                style: TextStyle(
                    color: AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontFootnote)),
          ),
        ),
      ],
    );
  }

  /// 顶栏圆形浅底按钮（与海阔其它页一致）
  Widget _topIcon(IconData icon, String tooltip, VoidCallback? onTap) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 15, color: AppTheme.textSecondary),
          ),
        ),
      );

  Widget _notice(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
              height: 1.6),
        ),
      );
}
